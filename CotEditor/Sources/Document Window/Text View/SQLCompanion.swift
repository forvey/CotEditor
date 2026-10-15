// SPDX-License-Identifier: Apache-2.0
import AppKit
import CustomizationCore
import SwiftUI

/// A native, transient popover. No text replacement, global mouse hook or accessibility API.
@MainActor final class SQLCompanion: NSObject, NSPopoverDelegate {
    private weak var textView: EditorTextView?
    private var popover: NSPopover?
    private var ranges: [NSRange] = []
    private var query: Task<Void, Never>?

    init(textView: EditorTextView) {

        self.textView = textView
        super.init()
    }

    func clear() {

        self.query?.cancel()
        self.popover?.close()
        self.popover = nil
        self.ranges = []
        self.textView?.needsDisplay = true
    }

    func popoverDidClose(_ notification: Notification) {

        self.ranges = []
        self.textView?.needsDisplay = true
    }

    func doubleClick(at position: Int) {

        self.clear()
        guard let textView = self.textView, textView.structuredLanguage == .postgresql else { return }
        let source = NSString(string: textView.string) as String
        self.query = Task { [weak self] in
            let insert = await Task.detached(priority: .userInitiated) {
                try? SQLInsertParser.inserts(in: source).first { NSLocationInRange(position, $0.range) }
            }.value
            guard !Task.isCancelled, let self, let textView = self.textView, textView.string == source,
                  let insert else { return }
            let ranges = insert.counterparts(at: position)
            guard !ranges.isEmpty else { return }
            self.ranges = ranges
            textView.needsDisplay = true
            let content = ranges.enumerated().map { index, range in
                let value = (source as NSString).substring(with: range)
                return ranges.count > 1 ? "\(index + 1). \(value)" : value
            }.joined(separator: "\n\n")
            self.show(content, at: NSRange(location: position, length: 1))
        }
    }

    func show(_ message: String, at range: NSRange) {

        guard let textView = self.textView, let container = textView.textContainer, let layout = textView.layoutManager,
              let window = textView.window, window.isVisible else { return }
        self.popover?.close()
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let maximumWidth = min(500, max(100, textView.visibleRect.width - 32))
        let naturalWidth = message.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(maximumWidth, max(64, ceil(naturalWidth) + 24))
        let textBounds = (message as NSString).boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
                                                          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let height = min(260, max(40, ceil(textBounds.height) + 24))
        let controller = NSHostingController(rootView: ScrollView {
            Text(message)
                .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }.frame(width: width, height: height))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: width, height: height)
        self.popover = popover
        let safeRange = NSRange(location: min(range.location, textView.string.utf16.count), length: range.location < textView.string.utf16.count ? min(range.length, 1) : 0)
        let glyphs = layout.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        var anchor = layout.boundingRect(forGlyphRange: glyphs, in: container)
        anchor.origin.x += textView.textContainerOrigin.x
        anchor.origin.y += textView.textContainerOrigin.y
        anchor.size.width = max(anchor.width, 2)
        anchor.size.height = max(anchor.height, textView.font?.pointSize ?? 14)
        let selections = textView.selectedRanges
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        // Keep typing, selection and keyboard shortcuts in the editor.
        window.makeFirstResponder(textView)
        textView.selectedRanges = selections
    }

    func draw(in dirtyRect: NSRect) {

        guard let textView = self.textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        for range in self.ranges where NSMaxRange(range) <= textView.string.utf16.count {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                if rect.intersects(dirtyRect) { NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill() }
            }
        }
    }
}

extension EditorTextView {
    var structuredLanguage: ContentLayout.Language? {

        let syntax = self.structuredSyntax?().lowercased() ?? ""
        if syntax == "json" { return .json }
        if syntax == "sql" || syntax.contains("postgres") { return .postgresql }
        let trimmed = self.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        if let first = try? SQLLexer.tokens(in: trimmed).first(where: { $0.kind != .comment && $0.kind != .lineComment }),
           first.kind == .word,
           ["select", "insert", "update", "delete", "with", "create", "alter", "drop", "begin", "explain", "truncate"].contains(first.text.lowercased()) {
            return .postgresql
        }
        return nil
    }

    @IBAction func toggleStructuredLayout(_ sender: Any?) {

        guard self.isEditable else { return }
        guard let language = self.structuredLanguage else {
            self.sqlCompanion.show(String(localized: "Choose JSON or SQL syntax before formatting.", table: "Fork"), at: self.selectedRange())
            return
        }
        let source = NSString(string: self.string) as String
        let selection = self.selectedRange()
        self.structuredLayoutTask?.cancel()
        self.structuredLayoutTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try ContentLayout.toggle(source, language: language) } }.value
            guard !Task.isCancelled, let self, self.string == source else { return }
            do {
                let formatted = try result.get()
                guard formatted != source else { return }
                self.sqlCompanion.clear()
                self.breakUndoCoalescing()
                let undoManager = self.undoManager
                undoManager?.beginUndoGrouping()
                defer { undoManager?.endUndoGrouping(); self.breakUndoCoalescing() }
                let cursor = NSRange(location: min(selection.location, formatted.utf16.count), length: 0)
                self.replace(with: formatted, range: NSRange(location: 0, length: source.utf16.count), selectedRange: cursor,
                             actionName: String(localized: "Format / Minify JSON or SQL", table: "Fork"))
            } catch {
                self.sqlCompanion.show(error.localizedDescription, at: selection)
            }
        }
    }
}
