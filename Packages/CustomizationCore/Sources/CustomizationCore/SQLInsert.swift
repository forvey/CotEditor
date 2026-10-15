// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct SQLInsert: Sendable {
    public struct Item: Sendable {
        public let text: String
        public let range: NSRange
    }
    public let range: NSRange
    public let columns: [Item]
    public let rows: [[Item]]

    /// A column maps to each VALUES row; a value maps to its column. All offsets are UTF-16.
    public func counterparts(at position: Int) -> [NSRange] {

        if let column = self.columns.firstIndex(where: { NSLocationInRange(position, $0.range) }) {
            return self.rows.compactMap { $0.indices.contains(column) ? $0[column].range : nil }
        }
        for row in self.rows {
            if let column = row.firstIndex(where: { NSLocationInRange(position, $0.range) }), self.columns.indices.contains(column) {
                return [self.columns[column].range]
            }
        }
        return []
    }
}

public enum SQLInsertParser {
    /// Supports explicit INSERT column lists and VALUES, including multi-row expressions.
    /// INSERT SELECT, omitted columns and mismatched row lengths deliberately have no guessed mapping.
    public static func inserts(in source: String) throws -> [SQLInsert] {

        let tokens = try SQLLexer.tokens(in: source).filter { $0.kind != .comment && $0.kind != .lineComment }
        let string = source as NSString
        var result: [SQLInsert] = []
        var start = 0
        var depth = 0
        for index in 0...tokens.count {
            if index < tokens.count, tokens[index].kind == .symbol {
                if ["(", "["].contains(tokens[index].text) { depth += 1 }
                if [")", "]"].contains(tokens[index].text) { depth -= 1 }
            }
            guard index == tokens.count || (tokens[index].text == ";" && depth == 0) else { continue }
            let statement = Array(tokens[start..<index])
            start = index + 1
            guard statement.first?.isWord("insert") == true,
                  let into = statement.firstIndex(where: { $0.isWord("into") }),
                  let open = statement.indices.dropFirst(into + 1).first(where: { statement[$0].text == "(" }),
                  let fields = self.list(statement, opening: open),
                  fields.end + 1 < statement.count
            else { continue }
            var cursor = fields.end + 1
            if statement[cursor].isWord("overriding") {
                cursor += 3  // OVERRIDING { SYSTEM | USER } VALUE
            }
            guard cursor < statement.count, statement[cursor].isWord("values") else { continue }
            cursor += 1
            var rows: [[SQLInsert.Item]] = []
            while cursor < statement.count, statement[cursor].text == "(", let row = self.list(statement, opening: cursor) {
                guard row.items.count == fields.items.count else { rows.removeAll(); break }
                rows.append(self.items(row.items, source: string))
                cursor = row.end + 1
                if cursor < statement.count, statement[cursor].text == "," { cursor += 1 }
                else { break }
            }
            guard !rows.isEmpty, let first = statement.first, let last = statement.last else { continue }
            result.append(SQLInsert(range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location),
                                    columns: self.items(fields.items, source: string), rows: rows))
        }
        return result
    }

    private static func items(_ groups: [[SQLToken]], source: NSString) -> [SQLInsert.Item] {

        groups.map {
            let range = NSRange(location: $0.first!.range.location, length: NSMaxRange($0.last!.range) - $0.first!.range.location)
            return SQLInsert.Item(text: source.substring(with: range), range: range)
        }
    }

    private static func list(_ tokens: [SQLToken], opening: Int) -> (items: [[SQLToken]], end: Int)? {

        var stack = ["("]
        var groups: [[SQLToken]] = []
        var start = opening + 1
        for index in (opening + 1)..<tokens.count {
            let token = tokens[index]
            if token.kind == .symbol {
                if ["(", "["].contains(token.text) { stack.append(token.text) }
                if [")", "]"].contains(token.text) {
                    guard stack.last == (token.text == ")" ? "(" : "[") else { return nil }
                    stack.removeLast()
                    if stack.isEmpty {
                        guard index > start else { return nil }
                        groups.append(Array(tokens[start..<index]))
                        return (groups, index)
                    }
                }
                if token.text == ",", stack.count == 1 {
                    guard index > start else { return nil }
                    groups.append(Array(tokens[start..<index])); start = index + 1
                }
            }
        }
        return nil
    }
}
