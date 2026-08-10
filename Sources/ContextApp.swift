import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The application: one window, one document, and the menu commands that act on
/// it.
///
/// Everything stateful lives in `Document.shared` or `@AppStorage`, so the scene
/// itself holds nothing that would be lost if SwiftUI rebuilt it.
@main
struct ContextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var doc = Document.shared
    @AppStorage(Prefs.editorVisible) private var editorVisible = false
    @AppStorage(Prefs.zoom) private var zoom: Double = 1.0

    /// The single window and the menu items that drive it.
    ///
    /// Commands are declared here rather than in `ContentView` so they stay
    /// enabled while the window is unfocused, and so their state comes from the
    /// document rather than from whichever view happens to be on screen.
    var body: some Scene {
        Window("Context", id: "main") {
            ContentView()
                .frame(minWidth: 460, minHeight: 340)
        }
        .defaultSize(width: 940, height: 800)
        .commands {
            // Context opens one file at a time; a "New" item would promise a
            // document model it doesn't have.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Self.openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { doc.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(doc.url == nil)

                Button("Revert to Saved") { if let url = doc.url { doc.open(url) } }
                    .disabled(doc.url == nil || !doc.isDirty)

                Divider()

                Button("Reveal in Finder") {
                    if let url = doc.url {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(doc.url == nil)
            }

            CommandMenu("View") {
                Button(editorVisible ? "Hide Editor" : "Show Editor") {
                    editorVisible.toggle()
                }
                .keyboardShortcut("e", modifiers: .command)

                Divider()

                Button("Bigger Text") { zoom = min(zoom * 1.1, 2.4) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { zoom = max(zoom / 1.1, 0.6) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { zoom = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    /// Runs the open panel and opens whatever is chosen.
    ///
    /// The content-type list only sets what the panel *suggests*;
    /// `allowsOtherFileTypes` keeps any text file openable, since Markdown lives
    /// under plenty of extensions this list will never finish enumerating.
    ///
    /// Blocks on a modal panel; does nothing if cancelled.
    static func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            UTType(filenameExtension: "qmd"),
            UTType.plainText,
            UTType.text,
        ].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            Document.shared.open(url)
        }
    }
}

/// Handles the parts of the app lifecycle SwiftUI does not expose: files opened
/// from outside the process, and what closing the last window means.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder double-clicks and `open -a Context file.md` arrive here.
    ///
    /// - Parameter urls: Candidates from the system. Context is single-document,
    ///   so the first file URL wins and the rest are ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        MainActor.assumeIsolated { Document.shared.open(url) }
    }

    /// - Returns: True — with one window and no document model to keep alive,
    ///   closing it means quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// - Returns: True, so clicking the Dock icon restores the window rather
    ///   than leaving a running app with nothing on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
