import AppKit
import SwiftUI

/// `UserDefaults` keys for the handful of things that survive a quit.
///
/// Named constants rather than string literals at each use site, because
/// `@AppStorage` silently reads a fresh default from a typo.
enum Prefs {
    static let editorVisible = "editorVisible"
    static let editorWidth = "editorWidth"
    static let zoom = "zoom"
}

/// The window's contents: the editor pane, a draggable divider, and the reading
/// pane, with a status banner floating over them.
struct ContentView: View {
    @ObservedObject private var doc = Document.shared
    @ObservedObject private var find = FindModel.shared
    @AppStorage(Prefs.editorVisible) private var editorVisible = false
    @AppStorage(Prefs.editorWidth) private var editorWidth: Double = 400
    @AppStorage(Prefs.zoom) private var zoom: Double = 1.0

    /// Editor width when the current drag began; nil when no drag is in flight.
    @State private var dragStartWidth: Double?

    /// Lays out both panes and keeps the window chrome in step with the document.
    var body: some View {
        // Both panes stay in the tree at all times and the editor collapses to
        // zero width. Branching on `editorVisible` here would tear down and
        // rebuild the WKWebView on every toggle, losing your place in the text.
        HStack(spacing: 0) {
            EditorView(doc: doc)
                .frame(width: editorVisible ? editorWidth : 0)
                .opacity(editorVisible ? 1 : 0)
                .disabled(!editorVisible)
                .allowsHitTesting(editorVisible)
                .clipped()

            divider

            PreviewView(doc: doc, zoom: zoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Over the pane, not above it: the page's own top padding means
                // the bar usually covers nothing, and giving it a row of its own
                // would resize the webview and reflow the text mid-read.
                .overlay(alignment: .top) {
                    if find.isPresented {
                        FindBar(model: find)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
        .animation(.easeOut(duration: 0.18), value: editorVisible)
        .animation(.easeOut(duration: 0.14), value: find.isPresented)
        .background(Color(nsColor: Palette.paper))
        .overlay(alignment: .bottom) { statusBanner }
        .background(WindowAccessor { window in
            window.title = doc.displayName
            window.representedURL = doc.url
            window.isDocumentEdited = doc.isDirty
        })
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            doc.open(url)
            return true
        }
    }

    /// The hairline between the panes, and the handle that resizes them.
    ///
    /// Collapses to zero width with the editor. Dragging is clamped to
    /// 240…900pt so neither pane can be lost off an edge.
    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: Palette.rule))
            .frame(width: editorVisible ? 1 : 0)
            .overlay {
                // A wider invisible grab area than the hairline it drags.
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? editorWidth
                                if dragStartWidth == nil { dragStartWidth = editorWidth }
                                editorWidth = min(max(start + value.translation.width, 240), 900)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .allowsHitTesting(editorVisible)
            }
    }

    /// Transient message over the bottom of the window, or nothing when
    /// `doc.status` is nil.
    ///
    /// Dismisses itself after six seconds, or on a click. Keyed on the message
    /// so a new one restarts the timer rather than inheriting the old deadline.
    @ViewBuilder
    private var statusBanner: some View {
        if let status = doc.status {
            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.muted))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(nsColor: Palette.rule), lineWidth: 1))
                .padding(.bottom, 22)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .onTapGesture { doc.clearStatus() }
                .task(id: status) {
                    try? await Task.sleep(for: .seconds(6))
                    doc.clearStatus()
                }
        }
    }
}

/// Reaches the hosting NSWindow so the title bar can show the file name and its
/// proxy icon without branching the SwiftUI tree.
///
/// Used as a zero-sized `.background()`. The closure runs on every SwiftUI
/// update, so it must be cheap and idempotent.
struct WindowAccessor: NSViewRepresentable {
    /// Applied to the window once it exists, and again on each update.
    let configure: (NSWindow) -> Void

    /// - Returns: An empty view whose only purpose is to acquire a `window`.
    ///
    /// The configuration is deferred by one run-loop turn because a view has no
    /// window at the moment it is made.
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    /// Re-applies `configure`, which is how title and edited state stay current.
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
    }
}
