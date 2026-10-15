// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum JSONLayout {
    /// Lex and validate without decoding numbers, escapes, or duplicate object keys.
    public static func tokens(_ source: String) throws -> [String] {

        let text = source as NSString
        let units = Array(source.utf16)
        var position = 0
        var tokens: [String] = []
        let number = try NSRegularExpression(pattern: #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#)
        while position < units.count {
            if [9, 10, 13, 32].contains(units[position]) { position += 1; continue }
            let start = position
            let unit = units[position]
            if unit == 34 {
                position += 1
                var closed = false
                while position < units.count {
                    let value = units[position]
                    guard value >= 32 else { throw ContentError.invalid("JSON 字符串中含有未转义的控制字符。") }
                    position += 1
                    if value == 34 { closed = true; break }
                    if value == 92 {
                        guard position < units.count else { break }
                        let escaped = units[position]; position += 1
                        if escaped == 117 {
                            guard position + 4 <= units.count,
                                  units[position..<position + 4].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
                            else { throw ContentError.invalid("JSON Unicode 转义必须有四位十六进制数字。") }
                            position += 4
                        } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) {
                            throw ContentError.invalid("JSON 转义字符无效。")
                        }
                    }
                }
                guard closed else { throw ContentError.invalid("JSON 字符串没有闭合。") }
            } else if [123, 125, 91, 93, 44, 58].contains(unit) { position += 1 }
            else if unit == 45 || (48...57).contains(unit) {
                guard let match = number.firstMatch(in: source, options: .anchored, range: NSRange(location: position, length: units.count - position)) else { throw ContentError.invalid("JSON 数字无效。") }
                position = NSMaxRange(match.range)
            } else {
                let literal = ["true", "false", "null"].first { text.substring(from: position).hasPrefix($0) }
                guard let literal else { throw ContentError.invalid("JSON 中出现了无效内容。") }
                position += literal.utf16.count
            }
            tokens.append(text.substring(with: NSRange(location: start, length: position - start)))
        }
        var cursor = 0
        func take(_ token: String) -> Bool {
            guard cursor < tokens.count, tokens[cursor] == token else { return false }
            cursor += 1; return true
        }
        func value(depth: Int) throws {
            guard depth < 512, cursor < tokens.count else { throw ContentError.invalid("JSON 不完整，或嵌套层级过深。") }
            if take("{") {
                if take("}") { return }
                repeat {
                    guard cursor < tokens.count, tokens[cursor].hasPrefix("\"") else { throw ContentError.invalid("JSON 对象的字段名必须使用双引号。") }
                    cursor += 1
                    guard take(":") else { throw ContentError.invalid("JSON 字段名后缺少冒号。") }
                    try value(depth: depth + 1)
                    if take("}") { return }
                } while take(",")
                throw ContentError.invalid("JSON 对象缺少逗号或右花括号。")
            } else if take("[") {
                if take("]") { return }
                repeat {
                    try value(depth: depth + 1)
                    if take("]") { return }
                } while take(",")
                throw ContentError.invalid("JSON 数组缺少逗号或右方括号。")
            } else {
                let token = tokens[cursor]
                guard token.hasPrefix("\"") || token.first?.isNumber == true || token.hasPrefix("-") || ["true", "false", "null"].contains(token) else { throw ContentError.invalid("JSON 值无效。") }
                cursor += 1
            }
        }
        try value(depth: 0)
        guard cursor == tokens.count else { throw ContentError.invalid("JSON 根节点后还有多余内容。") }
        return tokens
    }

    public static func toggle(_ source: String) throws -> String {

        let tokens = try self.tokens(source)
        if source.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline) { return tokens.joined() }
        var result = "", depth = 0
        for (index, token) in tokens.enumerated() {
            let previous = index > 0 ? tokens[index - 1] : ""
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            switch token {
                case "{", "[":
                    result += token
                    if !["}", "]"].contains(next) { depth += 1; result += "\n" + String(repeating: "  ", count: depth) }
                case "}", "]":
                    if !["{", "["].contains(previous) { depth -= 1; result += "\n" + String(repeating: "  ", count: depth) }
                    result += token
                case ",": result += ",\n" + String(repeating: "  ", count: depth)
                case ":": result += ": "
                default: result += token
            }
        }
        return result
    }
}
