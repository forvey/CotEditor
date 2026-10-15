// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct FavoriteFile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var url: URL
    public var bookmark: Data?

    public init(id: UUID = UUID(), url: URL, bookmark: Data? = nil) {

        self.id = id; self.url = url.standardizedFileURL; self.bookmark = bookmark
    }
}

public struct FavoriteFiles: Codable, Equatable, Sendable {
    public private(set) var files: [FavoriteFile] = []
    public init() { }

    public mutating func add(_ file: FavoriteFile) {

        if let index = self.files.firstIndex(where: { $0.url.standardizedFileURL == file.url.standardizedFileURL }) {
            self.files[index].bookmark = file.bookmark
        } else { self.files.append(file) }
    }

    public mutating func remove(id: UUID) {

        self.files.removeAll { $0.id == id }
    }
}
