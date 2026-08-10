import AppKit
import SwiftUI

/// The editing pane: a plain NSTextView over the Markdown source. Deliberately
/// unstyled beyond type and colour — this is the pane you summon to fix a typo,
/// not the one you live in.
///
/// Text flows both ways: edits here reach the document through the coordinator,
/// and external reloads come back through `updateNSView`.
struct EditorView: NSViewRepresentable {
    @ObservedObject var doc: Document

    /// - Returns: The text view's delegate, which forwards edits to the document.
    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    /// Builds the scrolling text view and seeds it with the current text.
    ///
    /// - Returns: The scroll view; its `documentView` is the text view. If
    ///   AppKit hands back something else, the scroll view is returned
    ///   unconfigured rather than trapping.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.editorBackground

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Every one of these would quietly corrupt Markdown source.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.32

        textView.font = font
        textView.textColor = Palette.ink
        textView.insertionPointColor = Palette.accent
        textView.backgroundColor = Palette.editorBackground
        textView.drawsBackground = true
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: Palette.ink,
            .paragraphStyle: paragraph,
        ]
        textView.textContainerInset = NSSize(width: 16, height: 18)
        textView.string = doc.text

        return scrollView
    }

    /// Adopts text that changed outside the editor, preserving the caret.
    ///
    /// Replacing `string` collapses the selection, so the caret is restored and
    /// clamped — the new text may well be shorter than where the caret was.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.doc = doc

        // Only fires when the text changed underneath us — a disk reload or a
        // freshly opened file. Edits made here are already in sync.
        guard textView.string != doc.text else { return }
        let selection = textView.selectedRange()
        textView.string = doc.text
        let caret = min(selection.location, (doc.text as NSString).length)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Text view delegate: the one-way path from typing to the document.
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Re-assigned on each update, so the delegate never holds a stale
        /// document.
        var doc: Document

        /// - Parameter doc: The document edits are reported to.
        init(doc: Document) { self.doc = doc }

        /// Forwards the full text on every keystroke; the document debounces and
        /// ignores no-ops.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated { doc.edit(textView.string) }
        }
    }
}
