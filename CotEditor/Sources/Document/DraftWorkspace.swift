// SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine
import CustomizationCore
import FileEncoding
import LineEnding

/// One physical editor window. Each tab retains its own text view and undo manager.
@MainActor final class DraftWorkspace: NSObject {
    static let shared = DraftWorkspace()

    private(set) var windowController: DocumentWindowController?
    private(set) var documents: [Document] = []
    private(set) weak var selected: Document?
    private var identities: [ObjectIdentifier: UUID] = [:]
    private var modificationDates: [ObjectIdentifier: Date] = [:]
    private var knownURLs: [ObjectIdentifier: URL] = [:]
    private var bookmarks: [ObjectIdentifier: Data] = [:]
    private var scopes: [ObjectIdentifier: URL] = [:]
    private var observers: [ObjectIdentifier: AnyCancellable] = [:]
    private var closed: [Draft] = []
    private var tabBar: WorkspaceTabBar?
    private var saveTask: Task<Void, Never>?
    private var didRestore = false
    private var isRestoring = false
    private(set) var isTerminating = false
    private var backupErrorShown = false
    private var recoveryError: (any Error)?
    private let store: DraftStore

    private override init() {

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.store = DraftStore(directory: support.appendingPathComponent("com.forvey.CotEditor/Workspace", isDirectory: true))
        super.init()
    }

    func attach(_ document: Document) {

        self.restoreIfNeeded()
        if !self.documents.contains(document) {
            self.documents.append(document)
            self.identities[ObjectIdentifier(document)] = self.identities[ObjectIdentifier(document)] ?? UUID()
            document.isTransient = false
            self.knownURLs[ObjectIdentifier(document)] = document.fileURL
            self.modificationDates[ObjectIdentifier(document)] = document.fileModificationDate ?? document.fileURL.flatMap { self.modificationDate(at: $0) }
            self.observers[ObjectIdentifier(document)] = NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification, object: document.textStorage)
                .filter { ($0.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true }
                .sink { [weak self] _ in self?.scheduleSave() }
        }
        if self.windowController == nil {
            let controller = DocumentWindowController(document: document)
            self.windowController = controller
            controller.window?.tabbingMode = .disallowed
            controller.window?.isRestorable = false
            let tabBar = WorkspaceTabBar(workspace: self)
            self.tabBar = tabBar
            controller.window?.addTitlebarAccessoryViewController(tabBar)
        }
        self.select(document)
    }

    func select(_ document: Document) {

        guard self.documents.contains(document), let controller = self.windowController else {
            self.attach(document)
            return
        }
        if self.selected !== document {
            let previous = self.selected
            previous?.textViews.forEach { ($0 as? EditorTextView)?.sqlCompanion.clear() }
            if let previous, previous.windowControllers.contains(controller) {
                previous.removeWindowController(controller)
                previous.windowController = controller
            }
            self.selected = document
            if !document.windowControllers.contains(controller) { document.addWindowController(controller) }
            controller.fileDocument = document
            controller.synchronizeWindowTitleWithDocumentName()
            controller.setDocumentEdited(document.isDocumentEdited)
            if let textView = document.textView { controller.window?.makeFirstResponder(textView) }
        }
        self.tabBar?.reload()
        self.scheduleSave()
    }

    func selectTab(at index: Int) {

        guard !self.documents.isEmpty else { return }
        self.select(self.documents[min(max(index, 0), self.documents.count - 1)])
    }

    func stepTab(_ delta: Int) {

        guard let selected, let index = self.documents.firstIndex(of: selected), !self.documents.isEmpty else { return }
        self.selectTab(at: (index + delta + self.documents.count) % self.documents.count)
    }

    @objc func newTab(_ sender: Any?) {

        NSDocumentController.shared.newDocument(sender)
    }

    @objc func closeTab(_ sender: Any?) {

        self.selected?.close()
    }

    @objc func reopenTab(_ sender: Any?) {

        guard let draft = self.closed.last else { return }
        self.isRestoring = true
        self.restore(draft)
        self.closed.removeLast()
        self.isRestoring = false
        self.scheduleSave()
    }

    func documentDidChange(_ document: Document, fileURLChanged: Bool = false) {

        guard self.documents.contains(document) else { return }
        let key = ObjectIdentifier(document)
        if fileURLChanged, self.knownURLs[key] != document.fileURL {
            self.bookmarks[key] = nil
            self.knownURLs[key] = document.fileURL
            self.modificationDates[key] = document.fileModificationDate
        }
        if !document.isDocumentEdited {
            self.modificationDates[key] = document.fileURL.flatMap { self.modificationDate(at: $0) }
        }
        self.scheduleSave()
    }

    /// Called even for scripted closes, so removing a tab cannot silently discard its contents.
    func prepareToClose(_ document: Document) -> Bool {

        guard self.documents.contains(document), !self.isTerminating else { return true }
        let oldClosed = self.closed
        self.closed.append(self.snapshot(document))
        self.closed = Array(self.closed.suffix(20))
        do { try self.save(excluding: document) }
        catch { self.closed = oldClosed; NSApp.presentError(error); return false }
        self.documents.removeAll { $0 === document }
        if let controller = self.windowController, document.windowControllers.contains(controller) {
            document.removeWindowController(controller)
        }
        document.windowController = nil
        if self.selected === document {
            self.selected = nil
            if let next = self.documents.last { self.select(next) }
            else {
                // Keep the single window and its permanent + button alive with a blank tab.
                self.newTab(nil)
            }
        }
        (self.windowController?.contentViewController as? WindowContentViewController)?.forget(document)
        let key = ObjectIdentifier(document)
        self.observers.removeValue(forKey: key)
        self.identities.removeValue(forKey: key)
        self.modificationDates.removeValue(forKey: key)
        self.knownURLs.removeValue(forKey: key)
        self.bookmarks.removeValue(forKey: key)
        self.scopes.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
        self.tabBar?.reload()
        return true
    }

    func scheduleSave() {

        guard !self.isRestoring, !self.isTerminating, self.saveTask == nil else { return }
        self.saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self else { return }
            self.saveTask = nil
            do { try self.save(); self.backupErrorShown = false }
            catch {
                if !self.backupErrorShown { self.backupErrorShown = true; NSApp.presentError(error) }
            }
        }
    }

    func save(excluding excluded: Document? = nil) throws {

        guard !self.isRestoring, !self.isTerminating else { return }
        if let recoveryError = self.recoveryError { throw recoveryError }
        let documents = self.documents.filter { $0 !== excluded }
        let drafts = documents.map { self.snapshot($0) }
        let active = documents.first { $0 === self.selected } ?? documents.last
        try self.store.save(DraftSession(drafts: drafts, selected: active.flatMap { self.identities[ObjectIdentifier($0)] }, closed: self.closed))
        self.tabBar?.reload()
    }

    func prepareToTerminate() -> Bool {

        do {
            try self.save()
            self.isTerminating = true
            self.saveTask?.cancel()
            return true
        } catch { NSApp.presentError(error); return false }
    }

    @discardableResult func restoreIfNeeded() -> Bool {

        guard !self.didRestore else { return !self.documents.isEmpty }
        self.didRestore = true
        self.isRestoring = true
        defer { self.isRestoring = false }
        do {
            guard let session = try self.store.load() else { return false }
            self.closed = session.closed
            for draft in session.drafts { self.restore(draft) }
            if let document = self.documents.first(where: { self.identities[ObjectIdentifier($0)] == session.selected }) { self.select(document) }
            self.windowController?.showWindow(nil)
            return !self.documents.isEmpty
        } catch {
            // Do not overwrite an unreadable session with a newly created empty tab.
            self.recoveryError = error
            NSApp.presentError(error)
            return false
        }
    }

    private func snapshot(_ document: Document) -> Draft {

        let key = ObjectIdentifier(document)
        let url = document.fileURL
        if let url, !document.isDocumentEdited {
            self.modificationDates[key] = self.modificationDate(at: url)
        }
        if let url {
            self.bookmarks[key] = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? self.bookmarks[key]
        }
        var draft = Draft(id: self.identities[key] ?? UUID(), text: NSString(string: document.textStorage.string) as String,
                          title: document.displayName ?? "Untitled", fileURL: url, bookmark: self.bookmarks[key],
                          encoding: document.fileEncoding.encoding.rawValue, utf8BOM: document.fileEncoding.withUTF8BOM,
                          lineEnding: document.lineEnding.string, syntax: document.syntaxName,
                          isEdited: document.isDocumentEdited, selection: document.textView?.selectedRange() ?? NSRange(location: 0, length: 0))
        draft.fileModificationDate = self.modificationDates[key]
        return draft
    }

    private func restore(_ draft: Draft) {

        var url = draft.fileURL
        var scopedURL: URL?
        if let bookmark = draft.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               resolved.startAccessingSecurityScopedResource() {
                url = resolved
                scopedURL = resolved
            }
        }
        let modified = url.flatMap { self.modificationDate(at: $0) }
        let unchanged = modified != nil && draft.fileModificationDate == modified
        let document: Document
        if let url, (!draft.isEdited || unchanged),
           let type = try? NSDocumentController.shared.typeForContents(of: url),
           let loaded = try? NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: type) as? Document {
            document = loaded
            if draft.isEdited { document.restoreDraft(draft) }
            else { document.setSyntax(name: draft.syntax) }
        } else {
            document = Document()
            document.fileType = "public.plain-text"
            document.displayName = draft.title
            document.restoreDraft(draft)
        }
        let key = ObjectIdentifier(document)
        self.identities[key] = draft.id
        self.bookmarks[key] = draft.bookmark
        self.scopes[key] = scopedURL
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let length = document.textStorage.length
        if draft.selection.location <= length, draft.selection.length <= length - draft.selection.location {
            document.textView?.setSelectedRange(draft.selection)
            document.textView?.scrollRangeToVisible(draft.selection)
        }
    }

    private func modificationDate(at url: URL) -> Date? {

        var url = url
        url.removeCachedResourceValue(forKey: .contentModificationDateKey)
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

@MainActor private final class WorkspaceTabBar: NSTitlebarAccessoryViewController {
    private unowned let workspace: DraftWorkspace
    private let stack = NSStackView()

    init(workspace: DraftWorkspace) {

        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        self.layoutAttribute = .bottom
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 34))
        container.autoresizingMask = [.width]
        self.view = container
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        self.stack.orientation = .horizontal
        self.stack.spacing = 4
        scroll.documentView = self.stack
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "New Tab", table: "Fork"))!, target: workspace, action: #selector(DraftWorkspace.newTab))
        plus.bezelStyle = .accessoryBarAction
        plus.toolTip = String(localized: "New Tab", table: "Fork") + " (⌘N)"
        for item in [scroll, plus] { item.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(item) }
        self.stack.setFrameSize(NSSize(width: 600, height: 30))
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            scroll.trailingAnchor.constraint(equalTo: plus.leadingAnchor, constant: -6),
            plus.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            plus.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {

        self.stack.arrangedSubviews.forEach { self.stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, document) in self.workspace.documents.enumerated() {
            let title = (document.isDocumentEdited ? "• " : "") + (document.displayName ?? "Untitled")
            let button = NSButton(title: title, target: self, action: #selector(self.selectTab))
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            button.state = document === self.workspace.selected ? .on : .off
            button.toolTip = document.fileURL?.path ?? document.displayName
            button.bezelStyle = .accessoryBarAction
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close Tab", table: "Fork"))!, target: self, action: #selector(self.closeTab))
            close.tag = index
            close.isBordered = false
            let tab = NSStackView(views: [button, close])
            tab.spacing = 2
            self.stack.addArrangedSubview(tab)
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        }
        self.stack.setFrameSize(NSSize(width: self.stack.fittingSize.width, height: 30))
    }

    @objc private func selectTab(_ sender: NSButton) {

        self.workspace.selectTab(at: sender.tag)
    }

    @objc private func closeTab(_ sender: NSButton) {

        self.workspace.selectTab(at: sender.tag)
        self.workspace.closeTab(sender)
    }
}
