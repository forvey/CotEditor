// SPDX-License-Identifier: Apache-2.0
import AppKit
import CustomizationCore

@MainActor final class ForkMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = ForkMenus()
    private var favorites = FavoriteFiles()
    private var favoritesMenu: NSMenu?
    private var decodingError: (any Error)?
    private var scopes: [URL] = []
    private let defaultsKey = "ForveyFavoriteFiles.v1"

    func install() {

        guard self.favoritesMenu == nil, let main = NSApp.mainMenu else { return }
        if let data = UserDefaults.standard.data(forKey: self.defaultsKey) {
            do { self.favorites = try JSONDecoder().decode(FavoriteFiles.self, from: data) }
            catch { self.decodingError = error }
        }
        let file = main.items.compactMap(\.submenu).first { menu in menu.items.contains { $0.action == #selector(NSDocumentController.openDocument(_:)) } }
        file?.items.filter { $0.action == #selector(DocumentController.newDocumentAsWindow(_:)) }.forEach { file?.removeItem($0) }
        if let new = file?.items.first(where: { $0.action == #selector(NSDocumentController.newDocument(_:)) }) {
            new.title = String(localized: "New Tab", table: "Fork")
        }
        let edit = main.items.compactMap(\.submenu).first { menu in menu.items.contains { $0.action == Selector(("undo:")) } }
        let format = NSMenuItem(title: String(localized: "Format / Minify JSON or SQL", table: "Fork"), action: #selector(EditorTextView.toggleStructuredLayout(_:)), keyEquivalent: "l")
        format.keyEquivalentModifierMask = [.command, .option]
        (edit ?? file)?.addItem(.separator())
        (edit ?? file)?.addItem(format)
        let favoritesMenu = NSMenu(title: String(localized: "Favorite Files", table: "Fork"))
        favoritesMenu.delegate = self
        self.favoritesMenu = favoritesMenu
        let item = NSMenuItem(title: favoritesMenu.title, action: nil, keyEquivalent: "")
        item.submenu = favoritesMenu
        file?.addItem(.separator())
        file?.addItem(item)
        let reopen = NSMenuItem(title: String(localized: "Reopen Closed Tab", table: "Fork"), action: #selector(DraftWorkspace.reopenTab(_:)), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        reopen.target = DraftWorkspace.shared
        file?.addItem(reopen)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {

        if menuItem.action == #selector(self.toggleFavorite(_:)) {
            return DraftWorkspace.shared.selected?.fileURL != nil && self.decodingError == nil
        }
        return self.decodingError == nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {

        guard menu === self.favoritesMenu else { return }
        menu.removeAllItems()
        let url = DraftWorkspace.shared.selected?.fileURL?.standardizedFileURL
        let existing = self.favorites.files.first { $0.url == url }
        let toggle = NSMenuItem(title: existing == nil ? String(localized: "Add Current File to Favorites", table: "Fork") : String(localized: "Remove Current File from Favorites", table: "Fork"), action: #selector(self.toggleFavorite(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = url != nil && self.decodingError == nil
        menu.addItem(toggle)
        menu.addItem(.separator())
        if self.favorites.files.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No Favorite Files", table: "Fork"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let removeMenu = NSMenu(title: String(localized: "Remove Favorite", table: "Fork"))
        for favorite in self.favorites.files {
            let item = NSMenuItem(title: favorite.url.lastPathComponent, action: #selector(self.openFavorite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = favorite.id
            item.toolTip = favorite.url.path
            menu.addItem(item)
            let remove = NSMenuItem(title: favorite.url.lastPathComponent, action: #selector(self.removeFavorite(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = favorite.id
            remove.toolTip = favorite.url.path
            removeMenu.addItem(remove)
        }
        if !removeMenu.items.isEmpty {
            menu.addItem(.separator())
            let item = NSMenuItem(title: removeMenu.title, action: nil, keyEquivalent: "")
            item.submenu = removeMenu
            menu.addItem(item)
        }
    }

    @objc private func toggleFavorite(_ sender: Any?) {

        guard let url = DraftWorkspace.shared.selected?.fileURL?.standardizedFileURL else { return }
        if let file = self.favorites.files.first(where: { $0.url == url }) { self.favorites.remove(id: file.id) }
        else {
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            self.favorites.add(FavoriteFile(url: url, bookmark: bookmark))
        }
        self.persist()
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {

        guard let id = sender.representedObject as? UUID else { return }
        self.favorites.remove(id: id)
        self.persist()
    }

    @objc private func openFavorite(_ sender: NSMenuItem) {

        guard let id = sender.representedObject as? UUID, let favorite = self.favorites.files.first(where: { $0.id == id }) else { return }
        var url = favorite.url
        if let bookmark = favorite.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = resolved
                if resolved.startAccessingSecurityScopedResource() { self.scopes.append(resolved) }
            }
        }
        Task {
            do { _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true) }
            catch { NSApp.presentError(error) }
        }
    }

    private func persist() {

        guard self.decodingError == nil else { return }
        do { UserDefaults.standard.set(try JSONEncoder().encode(self.favorites), forKey: self.defaultsKey) }
        catch { NSApp.presentError(error) }
    }
}
