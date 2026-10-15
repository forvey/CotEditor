// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import CustomizationCore

@Test func jsonPreservesExactValues() throws {

    let source = #"{"id":123456789012345678901234567890,"x":1.2300e+99,"id":"\u0041","emoji":"🙂"}"#
    let formatted = try ContentLayout.toggle(source, language: .json)
    #expect(formatted.contains("\n"))
    #expect(try ContentLayout.toggle(formatted, language: .json) == source)
    #expect(throws: (any Error).self) { try ContentLayout.toggle("{\"a\":}", language: .json) }
}

@Test func postgresRoundTrip() throws {

    let source = "insert into demo (id, payload) values (1, jsonb_build_object('a', ARRAY[1,2]));\nselect MixedCase::text from demo where id >= 1;"
    let formatted = try ContentLayout.toggle(source, language: .postgresql)
    #expect(formatted.contains("MixedCase"))
    #expect(!formatted.contains("SELECT"))
    let compact = try ContentLayout.toggle(formatted, language: .postgresql)
    #expect(compact.components(separatedBy: "\n").count == 2)
    #expect(try SQLLexer.hasSameTokens(source, compact))
}

@Test func stringsAndCommentsAreNeverRewritten() throws {

    let source = "SELECT\n E'a\\'b', $$hello;\nworld$$, 'x--y' /* outer /* nested */ end */;\n-- next\nSELECT\n 2;"
    let compact = try ContentLayout.toggle(source, language: .postgresql)
    #expect(compact.contains("-- next\nSELECT"))
    #expect(try SQLLexer.hasSameTokens(source, compact))
    #expect(throws: (any Error).self) { try ContentLayout.toggle("SELECT\n 'a'\n'b';", language: .postgresql) }
    #expect(throws: (any Error).self) { try SQLLexer.tokens(in: "SELECT $q$unfinished") }
}

@Test func insertMatchingUsesUTF16AndExpressions() throws {

    let source = "-- 🙂\nINSERT INTO demo (\"姓名\", amount, payload) VALUES ('甲,乙', round(1.23, 1), ARRAY[1,2]), ('丙', 42, $$a;b$$); INSERT INTO demo (id) VALUES (3);"
    let inserts = try SQLInsertParser.inserts(in: source)
    #expect(inserts.count == 2)
    let first = try #require(inserts.first)
    #expect(first.rows.count == 2)
    #expect(first.rows[0][1].text == "round(1.23, 1)")
    #expect(first.counterparts(at: first.columns[0].range.location) == [first.rows[0][0].range, first.rows[1][0].range])
    #expect(first.counterparts(at: first.rows[1][2].range.location) == [first.columns[2].range])
    for row in first.rows { for value in row { #expect((source as NSString).substring(with: value.range) == value.text) } }
    #expect(try SQLInsertParser.inserts(in: "INSERT INTO t (a,b) VALUES (1);").isEmpty)
    #expect(try SQLInsertParser.inserts(in: "INSERT INTO t (a) SELECT x FROM s;").isEmpty)
}

@Test func sessionRecoveryAndPermissions() throws {

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DraftStore(directory: directory)
    let draft = Draft(text: "unsaved 🙂", title: "Untitled", selection: NSRange(location: 8, length: 2))
    let first = DraftSession(drafts: [draft], selected: draft.id)
    try store.save(first)
    #expect(try store.load() == first)
    var second = first
    second.drafts[0].text = "changed draft"
    try store.save(second)
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("session.json"))
    #expect(try store.load() == first)
    try store.save(second)
    #expect(try store.load() == second)
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("session.json").path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    var invalid = first
    invalid.drafts[0].selection = NSRange(location: Int.max, length: 2)
    #expect(throws: (any Error).self) { try store.save(invalid) }
    #expect(try store.load() == second)
}

@Test func favoritesArePersistentAndDeduplicated() throws {

    var favorites = FavoriteFiles()
    let file = FavoriteFile(url: URL(fileURLWithPath: "/tmp/example.sql"), bookmark: Data([1, 2]))
    favorites.add(file)
    favorites.add(FavoriteFile(url: file.url, bookmark: Data([3])))
    #expect(favorites.files.count == 1)
    #expect(favorites.files.first?.id == file.id)
    #expect(favorites.files.first?.bookmark == Data([3]))
    let restored = try JSONDecoder().decode(FavoriteFiles.self, from: JSONEncoder().encode(favorites))
    #expect(restored == favorites)
    favorites.remove(id: file.id)
    #expect(favorites.files.isEmpty)
}

@Test func unsafeSQLAndInvalidJSONAreRejected() throws {

    #expect(try !SQLLexer.hasSameTokens("SELECT a @@@ b;", "SELECT a @ @ @ b;"))
    #expect(try SQLLexer.hasSameTokens("SELECT a+-b;", "SELECT a + - b;"))

    for source in ["SELECT\n ARRAY[1,2);", "SELECT\n 'unterminated;", "SELECT\n (1;"] {
        #expect(throws: (any Error).self) { try ContentLayout.toggle(source, language: .postgresql) }
    }
    for source in ["{\"a\":1,}", "[01]", "{\"a\":NaN}", "true false", "[1,]", #"{"a":"\z"}"#] {
        #expect(throws: (any Error).self) { try ContentLayout.toggle(source, language: .json) }
    }
}

@Test func failedSessionWritesLeavePreviousSessionIntact() throws {

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DraftStore(directory: directory)
    let draft = Draft(text: "draft", title: "Untitled")
    let session = DraftSession(drafts: [draft], selected: draft.id)
    try store.save(session)
    // A filesystem failure while creating the last-good backup must abort before replacing the primary.
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("session.previous.json"), withIntermediateDirectories: true)
    var changed = session
    changed.drafts[0].text = "changed"
    #expect(throws: (any Error).self) { try store.save(changed) }
    #expect(try store.load() == session)
}
