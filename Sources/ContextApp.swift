import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

/// The application: a group of document tabs, and the menu commands that act on
/// whichever one has focus.
///
/// Everything stateful lives in a tab's own `Document` and `FindModel` or in
/// `@AppStorage`, so the scene itself holds nothing that would be lost if
/// SwiftUI rebuilt it.
@main
struct ContextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Scene identifier for the document group. Named because `openWindow` has
    /// to ask for a window with no file by id, there being no value to open by.
    static let documentScene = "document"

    /// The document group and the menu items that drive it.
    ///
    /// A `WindowGroup` keyed on the file's URL, so a window *is* a document and
    /// AppKit can stack several of them as tabs. Commands are declared here
    /// rather than in `ContentView` so they stay enabled while a window is
    /// unfocused.
    var body: some Scene {
        WindowGroup(id: Self.documentScene, for: URL.self) { $url in
            ContentView(fileURL: $url)
                .frame(minWidth: 460, minHeight: 340)
        }
        .defaultSize(width: 940, height: 800)
        .commands { DocumentCommands() }
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
        // Several files are no longer a request that can only be partly
        // honoured: each one gets a tab.
        panel.allowsMultipleSelection = true
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

        if panel.runModal() == .OK {
            WindowRouter.shared.open(panel.urls)
        }
    }

    /// Sends a find command to whichever pane has the keyboard.
    ///
    /// The editor is an `NSTextView` with a find bar of its own, and taking ⌘F
    /// away from it while you are typing in it would be a regression. Anywhere
    /// else — which is to say, while reading — find means the reading pane.
    ///
    /// - Parameters:
    ///   - action: What to do. Forwarded verbatim to the editor; the reading
    ///     pane's equivalent is picked from the same value.
    ///   - find: The focused tab's search, or nil when no tab has focus.
    static func find(_ action: NSTextFinder.Action, in find: FindModel?) {
        // isFieldEditor rules out the find bar's own text field, which is an
        // NSTextView too — without it, typing a query and pressing ⌘G would
        // search the field you are typing in.
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, !textView.isFieldEditor {
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            textView.performTextFinderAction(sender)
            return
        }

        guard let find else { return }
        switch action {
        case .showFindInterface: find.open()
        case .nextMatch: find.next()
        case .previousMatch: find.previous()
        default: break
        }
    }
}

/// The menu items, and the focused tab they act on.
///
/// A `Commands` type of its own rather than a closure in the scene, because
/// `@FocusedValue` needs somewhere to live that SwiftUI re-evaluates when focus
/// moves from one tab to another.
struct DocumentCommands: Commands {
    @FocusedValue(\.document) private var doc: Document?
    @FocusedValue(\.find) private var find: FindModel?
    @AppStorage(Prefs.editorVisible) private var editorVisible = false
    @AppStorage(Prefs.zoom) private var zoom: Double = 1.0

    var body: some Commands {
        // "New" opens an empty tab rather than an untitled document: Context has
        // no document model to promise one, but a tab with nothing in it is
        // where the next ⌘O or drag-and-drop lands.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { WindowRouter.shared.newTab() }
                .keyboardShortcut("t", modifiers: .command)

            Button("Open…") { ContextApp.openFile() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { doc?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(doc?.url == nil)

            Button("Revert to Saved") { if let url = doc?.url { doc?.open(url) } }
                .disabled(doc?.url == nil || doc?.isDirty != true)

            Divider()

            Button("Reveal in Finder") {
                if let url = doc?.url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(doc?.url == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { ContextApp.find(.showFindInterface, in: find) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { ContextApp.find(.nextMatch, in: find) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { ContextApp.find(.previousMatch, in: find) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
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

/// The focused tab's document, for menu items that act on a file.
struct DocumentFocusKey: FocusedValueKey {
    typealias Value = Document
}

/// The focused tab's search, so ⌘F reaches the pane you are reading.
struct FindFocusKey: FocusedValueKey {
    typealias Value = FindModel
}

extension FocusedValues {
    var document: Document? {
        get { self[DocumentFocusKey.self] }
        set { self[DocumentFocusKey.self] = newValue }
    }

    var find: FindModel? {
        get { self[FindFocusKey.self] }
        set { self[FindFocusKey.self] = newValue }
    }
}

/// Handles the parts of the app lifecycle SwiftUI does not expose: files opened
/// from outside the process, and what closing the last tab means.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Turns on window tabbing, and clears the stray tabs a restore leaves.
    ///
    /// Tabbing is on by default, but the whole shape of the app depends on it —
    /// and on a machine where the system-wide preference is "never", this is what
    /// keeps the `.preferred` mode each window sets meaningful.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true

        // All of this has to wait out the launch, and none of it has a hook to
        // wait on: restored windows appear after this method returns, the
        // launch's own open-documents event has not been delivered yet, and
        // until both have happened the router cannot tell whether a file it is
        // asked for is one that is about to come back on its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchSettles) {
            MainActor.assumeIsolated {
                WindowRouter.shared.settleAfterLaunch()
                self.takeOverOpenDocuments()
            }
        }
    }

    /// How long to let a launch settle before touching what it built.
    ///
    /// Long enough that restored tabs have loaded their files — measured at
    /// around a tenth of this — and that the launch's own document event has
    /// been delivered and answered.
    private static let launchSettles: TimeInterval = 1.0

    /// Takes the open-documents Apple Event away from AppKit, *after* launch.
    ///
    /// Finder double-clicks and `open -a Context file.md` arrive as this event.
    /// Left to the default handler, SwiftUI answers it by opening the window
    /// group's *default* window — an empty one, since it has no way to turn a
    /// file into the group's `URL` value — and only then calls
    /// `application(_:open:)`, which opens the file properly. The stray blank tab
    /// that leaves behind is what this avoids. Measured, not guessed: the blank
    /// window is adopted before the delegate method runs at all.
    ///
    /// **The timing is the whole point.** Registering this before launch — the
    /// obvious place, and where it was first put — breaks opening a file by
    /// double-clicking it while Context is closed. On a launch driven by
    /// documents SwiftUI does not open its default window at all: it expects the
    /// document handler to make the windows. Take the event away and there is
    /// never a window, so `WindowRouter` never gets an `openWindow` to call and
    /// the file waits in `deferred` forever. The app comes up with nothing on
    /// screen and no way to say why.
    ///
    /// So the launch keeps AppKit's handler, which opens a blank window that
    /// `application(_:open:)` then fills — the stray costs nothing when there is
    /// nothing else on screen — and everything after it comes here.
    private func takeOverOpenDocuments() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    /// Opens every file the event names, each in a tab.
    ///
    /// Replaces `application(_:open:)` once `takeOverOpenDocuments()` has run;
    /// both route to the same place, and a file that somehow reached both would
    /// simply be raised the second time.
    ///
    /// - Parameters:
    ///   - event: An `odoc` event; its direct object is a file or a list of them.
    ///   - reply: Unused — there is nothing to say back.
    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let object = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        MainActor.assumeIsolated { WindowRouter.shared.open(Self.fileURLs(in: object)) }
    }

    /// The launch's own documents, and any that arrive before the handler above
    /// is installed.
    ///
    /// - Parameter urls: Candidates from the system, each of which gets a tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { WindowRouter.shared.open(urls) }
    }

    /// Pulls file URLs out of an Apple Event descriptor.
    ///
    /// - Parameter descriptor: A list, or a single item. Items arrive as file
    ///   URLs from `open(1)` and as aliases from some senders, so anything that
    ///   isn't already a URL is coerced before being given up on.
    /// - Returns: Every file named, in the order the sender listed them.
    private static func fileURLs(in descriptor: NSAppleEventDescriptor) -> [URL] {
        if descriptor.numberOfItems > 0 {
            return (1...descriptor.numberOfItems)
                .compactMap { descriptor.atIndex($0) }
                .flatMap(fileURLs(in:))
        }
        if let url = descriptor.fileURLValue { return [url] }
        if let coerced = descriptor.coerce(toDescriptorType: DescType(typeFileURL)),
           let url = coerced.fileURLValue {
            return [url]
        }
        return []
    }

    /// - Returns: True — with no document model to keep alive, closing the last
    ///   tab means quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// - Parameter flag: Whether anything is already on screen.
    /// - Returns: True only when nothing is, so clicking the Dock icon restores a
    ///   window rather than leaving a running app with nothing visible.
    ///
    /// Returning true unconditionally — which is right for a single-window app —
    /// costs a stray empty tab every time the app is activated with `open -a` or
    /// from the Dock: AppKit takes it as "make me a window", and SwiftUI does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }
}
