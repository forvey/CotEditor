// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ContentError: Error, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {

        switch self { case .invalid(let message): message }
    }
}

public struct SQLToken: Equatable, Sendable {
    public enum Kind: Sendable { case word, number, string, identifier, symbol, comment, lineComment }
    public let kind: Kind
    public let text: String
    public let range: NSRange

    public func isWord(_ word: String) -> Bool {

        self.kind == .word && self.text.lowercased() == word
    }
}

public enum SQLLexer {
    public static func tokens(in source: String) throws -> [SQLToken] {

        let units = Array(source.utf16)
        let string = source as NSString
        var position = 0
        var tokens: [SQLToken] = []
        func at(_ index: Int) -> UInt16 { units.indices.contains(index) ? units[index] : 0 }
        func wordStart(_ value: UInt16) -> Bool { value == 95 || (65...90).contains(value) || (97...122).contains(value) || value >= 128 }
        func wordPart(_ value: UInt16) -> Bool { wordStart(value) || (48...57).contains(value) || value == 36 }
        func slice(_ start: Int, _ end: Int) -> String { string.substring(with: NSRange(location: start, length: end - start)) }
        let number = try NSRegularExpression(pattern: #"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"#)
        let operators: Set<String> = ["!~*", "#>>", "->>", "::", ">=", "<=", "!=", "<>", "||", "&&", "->", "#>", "@>", "<@", "?&", "?|", "~*", "!~", ":=", "=>", "<<", ">>", ".."]
        let operatorUnits = Set("+-*/<>=~!@#%^&|`?".utf16)
        let specialOperatorUnits = Set("~!@#%^&|`?".utf16)
        while position < units.count {
            if [9, 10, 11, 12, 13, 32].contains(at(position)) { position += 1; continue }
            let start = position
            var kind: SQLToken.Kind = .symbol
            if at(position) == 45 && at(position + 1) == 45 {
                position += 2
                while position < units.count && at(position) != 10 && at(position) != 13 { position += 1 }
                kind = .lineComment
            } else if at(position) == 47 && at(position + 1) == 42 {
                position += 2
                var depth = 1
                while position < units.count && depth > 0 {
                    if at(position) == 47 && at(position + 1) == 42 { depth += 1; position += 2 }
                    else if at(position) == 42 && at(position + 1) == 47 { depth -= 1; position += 2 }
                    else { position += 1 }
                }
                guard depth == 0 else { throw ContentError.invalid("SQL 块注释没有闭合。") }
                kind = .comment
            } else {
                var quoteStart = position
                var backslashEscapes = false
                if [69, 101, 66, 98, 88, 120].contains(at(position)) && [39, 34].contains(at(position + 1)) {
                    quoteStart += 1; backslashEscapes = [69, 101].contains(at(position))
                } else if [85, 117].contains(at(position)) && at(position + 1) == 38 && [39, 34].contains(at(position + 2)) {
                    quoteStart += 2
                }
                var dollarEnd: Int?
                if at(position) == 36 {
                    var end = position + 1
                    if at(end) != 36 && wordStart(at(end)) {
                        end += 1
                        while end < units.count && (wordStart(at(end)) || (48...57).contains(at(end))) { end += 1 }
                    }
                    if at(end) == 36 { dollarEnd = end + 1 }
                }
                if let delimiterEnd = dollarEnd {
                    let delimiter = slice(position, delimiterEnd)
                    let rest = NSRange(location: delimiterEnd, length: units.count - delimiterEnd)
                    let end = string.range(of: delimiter, options: [], range: rest)
                    guard end.location != NSNotFound else { throw ContentError.invalid("SQL 美元引号没有闭合。") }
                    position = NSMaxRange(end); kind = .string
                } else if at(quoteStart) == 39 || at(quoteStart) == 34 {
                    let quote = at(quoteStart)
                    position = quoteStart + 1
                    var closed = false
                    while position < units.count {
                        if backslashEscapes && at(position) == 92 { position += min(2, units.count - position) }
                        else if at(position) == quote {
                            position += 1
                            if at(position) == quote { position += 1 }
                            else { closed = true; break }
                        } else { position += 1 }
                    }
                    guard closed else { throw ContentError.invalid("SQL 字符串或字段名引号没有闭合。") }
                    kind = quote == 34 ? .identifier : .string
                } else if at(position) == 36 && (48...57).contains(at(position + 1)) {
                    position += 2
                    while (48...57).contains(at(position)) { position += 1 }
                    kind = .word
                } else if (48...57).contains(at(position)) || (at(position) == 46 && (48...57).contains(at(position + 1))) {
                    let rest = NSRange(location: position, length: units.count - position)
                    guard let match = number.firstMatch(in: source, options: .anchored, range: rest) else { throw ContentError.invalid("SQL 数字无效。") }
                    position = NSMaxRange(match.range); kind = .number
                } else if wordStart(at(position)) {
                    position += 1
                    while position < units.count && wordPart(at(position)) { position += 1 }
                    kind = .word
                } else {
                    position += 1
                    if operatorUnits.contains(at(start)) {
                        while position < units.count, operatorUnits.contains(at(position)) {
                            if (at(position) == 45 && at(position + 1) == 45) || (at(position) == 47 && at(position + 1) == 42) { break }
                            position += 1
                        }
                        // PostgreSQL permits arbitrary operators, but most cannot end in + or -.
                        if !units[start..<position].contains(where: { specialOperatorUnits.contains($0) }) {
                            while position > start + 1, [43, 45].contains(at(position - 1)) { position -= 1 }
                        }
                    } else {
                        for length in [3, 2] where start + length <= units.count {
                            if operators.contains(slice(start, start + length)) { position = start + length; break }
                        }
                    }
                }
            }
            tokens.append(SQLToken(kind: kind, text: slice(start, position), range: NSRange(location: start, length: position - start)))
        }
        return tokens
    }

    /// Includes comments and token types; a formatter must not silently alter either.
    public static func hasSameTokens(_ first: String, _ second: String) throws -> Bool {

        let a = try self.tokens(in: first), b = try self.tokens(in: second)
        guard a.count == b.count else { return false }
        for (left, right) in zip(a, b) where left.kind != right.kind || left.text != right.text { return false }
        // PostgreSQL concatenates adjacent string literals only across a newline.
        for index in a.indices.dropFirst() where a[index - 1].kind == .string && a[index].kind == .string {
            func hasNewline(_ source: String, _ tokens: [SQLToken]) -> Bool {
                let range = NSRange(location: NSMaxRange(tokens[index - 1].range), length: tokens[index].range.location - NSMaxRange(tokens[index - 1].range))
                return (source as NSString).substring(with: range).contains(where: \.isNewline)
            }
            if hasNewline(first, a) != hasNewline(second, b) { return false }
        }
        return true
    }
}
