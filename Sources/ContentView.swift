import AppKit
import SwiftUI

enum Prefs {
    static let editorVisible = "editorVisible"
    static let editorWidth = "editorWidth"
    static let zoom = "zoom"
}

struct ContentView: View {
    @ObservedObject private var doc = Document.shared
    @AppStorage(Prefs.editorVisible) private var editorVisible = false
    @AppStorage(Prefs.editorWidth) private var editorWidth: Double = 400
    @AppStorage(Prefs.zoom) private var zoom: Double = 1.0
    @State private var dragStartWidth: Double?

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
        }
        .animation(.easeOut(duration: 0.18), value: editorVisible)
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
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
    }
}
