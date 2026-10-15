// SPDX-License-Identifier: Apache-2.0
import Foundation
import JavaScriptCore

public enum ContentLayout {
    public enum Language: Sendable { case json, postgresql }

    public static func toggle(_ source: String, language: Language) throws -> String {

        switch language {
            case .json: return try JSONLayout.toggle(source)
            case .postgresql:
                let tokens = try SQLLexer.tokens(in: source)
                guard !tokens.isEmpty else { return source }
                var previous: SQLToken?
                var multiline = false
                let string = source as NSString
                for token in tokens {
                    if let previous, previous.text != ";", previous.kind != .lineComment {
                        let gap = NSRange(location: NSMaxRange(previous.range), length: token.range.location - NSMaxRange(previous.range))
                        if string.substring(with: gap).contains(where: \.isNewline) { multiline = true }
                    }
                    previous = token
                }
                let result = try multiline ? self.compactSQL(tokens) : self.prettySQL(source)
                guard try SQLLexer.hasSameTokens(source, result) else { throw ContentError.invalid("排版结果改变了 SQL 内容，已取消操作。") }
                return result
        }
    }

    public static func prettySQL(_ source: String) throws -> String {

        guard let url = Bundle.module.url(forResource: "sql-formatter", withExtension: "js"),
              let context = JSContext()
        else { throw ContentError.invalid("无法加载内置 SQL 格式化引擎。") }
        let script = try String(contentsOf: url, encoding: .utf8)
        context.evaluateScript(script)
        guard context.exception == nil else { throw ContentError.invalid("内置 SQL 格式化引擎加载失败。") }
        let options: [String: Any] = ["language": "postgresql", "tabWidth": 4, "useTabs": false,
            "keywordCase": "preserve", "dataTypeCase": "preserve", "functionCase": "preserve",
            "identifierCase": "preserve", "logicalOperatorNewline": "before", "expressionWidth": 70,
            "linesBetweenQueries": 2, "denseOperators": false, "newlineBeforeSemicolon": false]
        let result = context.objectForKeyedSubscript("sqlFormatter")?.invokeMethod("format", withArguments: [source, options])
        guard context.exception == nil, let output = result?.toString(), !output.isEmpty else {
            throw ContentError.invalid("SQL 无法解析，请检查语句、引号和括号。")
        }
        let formatted = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try SQLLexer.hasSameTokens(source, formatted) else { throw ContentError.invalid("排版结果改变了 SQL 内容，已取消操作。") }
        return formatted
    }

    private static func compactSQL(_ tokens: [SQLToken]) throws -> String {

        var output = "", previous: SQLToken?
        var stack: [String] = []
        for token in tokens {
            if !output.isEmpty && !output.hasSuffix("\n") {
                if previous?.kind == .lineComment { output += "\n" }
                else if ![")", "]", ",", ";"].contains(token.text) && !["(", "["].contains(previous?.text ?? "") { output += " " }
            }
            output += token.text
            if token.kind == .symbol {
                if ["(", "["].contains(token.text) { stack.append(token.text) }
                if [")", "]"].contains(token.text) {
                    guard stack.last == (token.text == ")" ? "(" : "[") else { throw ContentError.invalid("SQL 括号不匹配。") }
                    stack.removeLast()
                }
                if token.text == ";" && stack.isEmpty { output += "\n" }
            }
            previous = token
        }
        guard stack.isEmpty else { throw ContentError.invalid("SQL 括号没有闭合。") }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
