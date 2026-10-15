// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing
@testable import CotEditor

@MainActor struct NativeEditorToolsTests {
    @Test func formattingIsOneUndoableEdit() async throws {

        let source = #"{"id":123456789012345678901234567890,"name":"示例"}"#
        let document = Document()
        document.textStorage.replaceCharacters(in: NSRange(), with: source)
        let delegate = EditorTextViewController(document: document)
        let textView = EditorTextView(textStorage: document.textStorage, lineEndingScanner: document.lineEndingScanner)
        textView.delegate = delegate
        textView.structuredSyntax = { "JSON" }
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        textView.toggleStructuredLayout(nil)
        await textView.structuredLayoutTask?.value
        #expect(textView.string.contains("\n"))
        #expect(undo.canUndo)
        undo.undo()
        #expect(textView.string == source)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(textView.string.contains("\n"))
        withExtendedLifetime(delegate) { }
    }

    @Test func interveningEditsCancelFormatting() async {

        let document = Document()
        document.textStorage.replaceCharacters(in: NSRange(), with: #"{"id":1}"#)
        let textView = EditorTextView(textStorage: document.textStorage, lineEndingScanner: document.lineEndingScanner)
        textView.structuredSyntax = { "JSON" }
        textView.toggleStructuredLayout(nil)
        // The main actor cannot apply the asynchronous result until after this edit.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length), with: "new content")
        await textView.structuredLayoutTask?.value
        #expect(textView.string == "new content")
    }

    @Test func switchingTabsPreservesViewSelectionAndUndo() throws {

        let first = Document(), second = Document()
        first.textStorage.replaceCharacters(in: NSRange(), with: "first")
        second.textStorage.replaceCharacters(in: NSRange(), with: "second")
        let controller = ContentViewController(document: first)
        _ = controller.view
        let textView = try #require((controller.hostedViewController as? DocumentViewController)?.textViews.first)
        let undo = try #require(first.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        textView.replace(with: "changed", range: NSRange(location: 0, length: 5), selectedRange: NSRange(location: 2, length: 0))
        undo.endUndoGrouping()
        controller.document = second
        controller.document = first
        let restored = try #require((controller.hostedViewController as? DocumentViewController)?.textViews.first)
        #expect(restored === textView)
        #expect(restored.selectedRange() == NSRange(location: 2, length: 0))
        undo.undo()
        #expect(restored.string == "first")
    }
}
