// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct Draft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var title: String
    public var fileURL: URL?
    public var bookmark: Data?
    public var fileModificationDate: Date?
    public var encoding: UInt
    public var utf8BOM: Bool
    public var lineEnding: String
    public var syntax: String
    public var isEdited: Bool
    public var selection: NSRange

    public init(id: UUID = UUID(), text: String, title: String, fileURL: URL? = nil, bookmark: Data? = nil,
                encoding: UInt = String.Encoding.utf8.rawValue, utf8BOM: Bool = false, lineEnding: String = "\n",
                syntax: String = "Plain Text", isEdited: Bool = true, selection: NSRange = NSRange(location: 0, length: 0)) {

        self.id = id; self.text = text; self.title = title; self.fileURL = fileURL; self.bookmark = bookmark
        self.encoding = encoding; self.utf8BOM = utf8BOM; self.lineEnding = lineEnding; self.syntax = syntax
        self.isEdited = isEdited; self.selection = selection
    }
}

public struct DraftSession: Codable, Equatable, Sendable {
    public var version = 1
    public var drafts: [Draft]
    public var selected: UUID?
    public var closed: [Draft]

    public init(drafts: [Draft], selected: UUID?, closed: [Draft] = []) {

        self.drafts = drafts; self.selected = selected; self.closed = closed
    }
}

/// The session is separate from the user's files. A failed save must cancel closing/quit.
public struct DraftStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> DraftSession? {

        var lastError: (any Error)?
        for name in ["session.json", "session.previous.json"] {
            let url = self.directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { return try self.decode(Data(contentsOf: url)) }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        return nil
    }

    public func save(_ session: DraftSession) throws {

        let data = try JSONEncoder().encode(session)
        _ = try self.decode(data)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = self.directory.appendingPathComponent("session.json")
        // Preserve only a validated last-good copy. Never replace the backup with corrupt bytes.
        if let previous = try? Data(contentsOf: url), (try? self.decode(previous)) != nil {
            let backup = self.directory.appendingPathComponent("session.previous.json")
            try previous.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func decode(_ data: Data) throws -> DraftSession {

        let session = try JSONDecoder().decode(DraftSession.self, from: data)
        guard session.version == 1, Set(session.drafts.map(\.id)).count == session.drafts.count,
              session.selected == nil || session.drafts.contains(where: { $0.id == session.selected }),
              (session.drafts + session.closed).allSatisfy({
                  $0.selection.location >= 0 && $0.selection.length >= 0 &&
                  $0.selection.location <= $0.text.utf16.count && $0.selection.length <= $0.text.utf16.count - $0.selection.location
              })
        else { throw ContentError.invalid("会话备份无效，已保留原备份文件。") }
        return session
    }
}
