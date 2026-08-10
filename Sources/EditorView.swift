import AppKit
import SwiftUI

/// The editing pane: a plain NSTextView over the Markdown source. Deliberately
/// unstyled beyond type and colour — this is the pane you summon to fix a typo,
/// not the one you live in.
struct EditorView: NSViewRepresentable {
    @ObservedObject var doc: Document

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var doc: Document

        init(doc: Document) { self.doc = doc }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated { doc.edit(textView.string) }
        }
    }
}
