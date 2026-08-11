import AppKit
import SwiftUI
import WebKit

/// Find state for the reading pane, and the only thing that talks to the page's
/// search.
///
/// A singleton for the same reason `Document` is one: the menu commands live in
/// the `App` and the bar lives in `ContentView`, and both drive the one search
/// in the one window.
///
/// Every method is a no-op until `webView` has been set, which `PreviewView`
/// does as it builds the pane — before that there is nothing to search anyway.
@MainActor
final class FindModel: ObservableObject {
    static let shared = FindModel()

    /// Whether the find bar is on screen. Searching only happens while it is.
    @Published private(set) var isPresented = false

    /// What has been typed. The bar owns this binding and searches on change.
    @Published var query = ""

    /// Matches in the rendered document.
    @Published private(set) var count = 0

    /// 1-based position of the current match; 0 when there is none.
    @Published private(set) var position = 0

    /// Bumped whenever the field should take the keyboard. The bar watches it, so
    /// a second ⌘F puts you back in the field instead of doing nothing.
    @Published private(set) var focusToken = 0

    /// The pane being searched, set by `PreviewView`. Weak because the SwiftUI
    /// view hierarchy owns it and this object outlives any particular webview.
    weak var webView: WKWebView?

    private init() {}

    /// What the bar shows beside the field.
    ///
    /// Empty before anything is typed, so an untouched bar carries no verdict.
    var summary: String {
        if query.isEmpty { return "" }
        if count == 0 { return "No matches" }
        return "\(position) of \(count)"
    }

    /// Shows the bar, focuses the field, and re-runs whatever is still in it.
    ///
    /// Keeping the previous query is the usual macOS behaviour: ⌘F, Escape, ⌘F
    /// gets you back to where you were rather than to an empty field.
    func open() {
        isPresented = true
        focusToken += 1
        if !query.isEmpty { search() }
    }

    /// Hides the bar and drops every highlight, keeping the query for next time.
    func close() {
        isPresented = false
        count = 0
        position = 0
        evaluate("window.Context.findClear()")
    }

    /// Searches for the current `query`, starting from the top of the window.
    ///
    /// An empty query clears the highlights without closing the bar.
    func search() {
        guard isPresented else { return }
        let encoded = Data(query.utf8).base64EncodedString()
        evaluate("window.Context.find('\(encoded)')")
    }

    /// Moves to the next match, wrapping at the end of the document.
    func next() { evaluate("window.Context.findNext()") }

    /// Moves to the previous match, wrapping at the start of the document.
    func previous() { evaluate("window.Context.findPrevious()") }

    /// Rebuilds the match list against a freshly rendered document.
    ///
    /// Called after every render: the ranges held in the page point at text nodes
    /// that a render has just replaced. Does not scroll, so a reload from the file
    /// watcher leaves you where you were.
    func refresh() {
        guard isPresented, !query.isEmpty else { return }
        evaluate("window.Context.findRefresh()")
    }

    /// Runs one find call in the page and adopts the counts it reports.
    ///
    /// - Parameter script: JavaScript evaluating to `{count, index}`. Anything
    ///   else — including the page not being loaded yet — zeroes the counts,
    ///   which is the truthful answer when nothing was searched.
    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script) { result, _ in
            MainActor.assumeIsolated {
                let status = result as? [String: Any]
                self.count = status?["count"] as? Int ?? 0
                self.position = status?["index"] as? Int ?? 0
            }
        }
    }
}

/// The find bar: a field, a match count, and the two arrows.
///
/// Floats over the top of the reading pane rather than pushing it down — the
/// page's own top padding means it usually covers nothing at all, and resizing
/// the webview to make room would reflow the document under the reader.
struct FindBar: View {
    @ObservedObject var model: FindModel

    /// Keyboard focus for the field, driven by `model.focusToken`.
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            field

            Text(model.summary)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: Palette.muted))
                .frame(minWidth: 76, alignment: .leading)

            stepper

            Button("Done") { model.close() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Palette.rule))
                .frame(height: 1)
        }
        .onAppear { isFieldFocused = true }
        .onChange(of: model.focusToken) { isFieldFocused = true }
        .onChange(of: model.query) { model.search() }
    }

    /// The text field, dressed as one — `.plain` so it sits inside the bar's own
    /// border rather than bringing a second, mismatched one.
    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Palette.muted))

            TextField("Find in document", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isFieldFocused)
                .onSubmit { model.next() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Palette.paper)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.rule), lineWidth: 1))
        .frame(width: 250)
    }

    /// Previous and next. Disabled together, since neither means anything
    /// without matches to step through.
    private var stepper: some View {
        HStack(spacing: 4) {
            Button { model.previous() } label: { Image(systemName: "chevron.up") }
            Button { model.next() } label: { Image(systemName: "chevron.down") }
        }
        .controlSize(.small)
        .disabled(model.count == 0)
    }
}
