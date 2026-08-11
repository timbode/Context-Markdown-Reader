import AppKit
import Combine
import Foundation

/// The open Markdown file. Context is a single-window reader, so one instance is
/// shared by the app delegate, the menu commands and both panes.
///
/// The type owns three things that have to stay consistent: the text, the URL it
/// came from, and a watch on that URL. Every transition between them goes
/// through this class — nothing else opens, saves or reloads a file.
///
/// Invariants:
/// - `isDirty` is true only when `url != nil` and `text` differs from disk.
/// - `renderSource` trails `text` by the debounce interval, except on open,
///   where both are set together so the first paint is immediate.
/// - A disk change never overwrites unsaved edits.
@MainActor
final class Document: ObservableObject {
    /// The process-wide document. Not lazy-initialised state to be passed
    /// around: the menu bar and the app delegate both need it before any view
    /// exists.
    static let shared = Document()

    /// Live text. The editor writes here; the preview reads `renderSource`.
    @Published var text: String = ""

    /// `text` debounced, so typing doesn't re-render on every keystroke.
    @Published private(set) var renderSource: String = ""

    /// Where `text` came from, and where `save()` writes. Nil before the first
    /// open, which is what disables the save and revert commands.
    @Published private(set) var url: URL?

    /// True when `text` has edits not yet written to `url`.
    @Published private(set) var isDirty = false

    /// Transient message for the status banner; nil when there is nothing to say.
    @Published private(set) var status: String?

    private var watcher: FileWatcher?

    /// Set around our own writes so the resulting fs event isn't mistaken for
    /// somebody else editing the file.
    private var isSavingOurselves = false

    /// The window title: the file's name, or the app's before anything is open.
    var displayName: String { url?.lastPathComponent ?? "Context" }

    /// The folder relative links and images resolve against; nil before any open.
    var directory: URL? { url?.deletingLastPathComponent() }

    /// Wires `text` to `renderSource` through a debounce.
    ///
    /// Private: `shared` is the only instance, because a second one would mean a
    /// second watcher on the same path.
    private init() {
        $text
            .debounce(for: .milliseconds(110), scheduler: DispatchQueue.main)
            .assign(to: &$renderSource)
    }

    // MARK: - Opening

    /// Loads `url` and makes it the open document, replacing any current one.
    ///
    /// Decoding is attempted as UTF-8 and then Latin-1. Failure is reported
    /// through `status` rather than thrown: opening a file the user asked for is
    /// not an error the caller can do anything about.
    ///
    /// - Parameter url: A file URL. Directories and unreadable paths set
    ///   `status` and leave the current document untouched.
    /// - Postcondition: On success `isDirty` is false and the file is watched.
    func open(_ url: URL) {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            apply(contents, from: url)
        } catch {
            // Not every .md on disk is UTF-8; fall back rather than refusing.
            if let data = try? Data(contentsOf: url),
               let contents = String(data: data, encoding: .isoLatin1) {
                apply(contents, from: url)
                status = "Opened as Latin-1 — not valid UTF-8"
            } else {
                status = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Opens the first of several files, and says which one that was.
    ///
    /// Context shows one document at a time, so a request to open a set — Finder
    /// with three files selected, or `open -a Context *.md` — can only be partly
    /// honoured. Discarding the rest in silence is indistinguishable from failing
    /// to open them, so the banner names the one that was taken.
    ///
    /// - Parameter urls: Candidates. Non-file URLs are ignored, and an empty list
    ///   leaves the current document alone.
    func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard let first = files.first else { return }
        open(first)

        // `open` clears the banner on success and writes to it on failure. Both
        // are more specific than a count — including the Latin-1 fallback, which
        // is worth more to the reader than knowing two files were skipped.
        guard files.count > 1, url == first, status == nil else { return }
        status = "Opened \(first.lastPathComponent) — Context shows one file at a time"
    }

    /// Installs decoded contents as the current document.
    ///
    /// The single place where all of the open-state fields move together, so
    /// they cannot drift apart.
    ///
    /// - Parameters:
    ///   - contents: Already-decoded text.
    ///   - url: The file it was decoded from.
    private func apply(_ contents: String, from url: URL) {
        text = contents
        renderSource = contents      // render immediately, don't wait out the debounce
        self.url = url
        isDirty = false
        status = nil
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        startWatching(url)
    }

    /// Dismisses the status banner.
    func clearStatus() { status = nil }

    /// Records an edit made in the editor pane.
    ///
    /// Editor edits arrive here so they can be distinguished from a disk load:
    /// only these mark the document dirty.
    ///
    /// - Parameter newText: The full new contents. Identical text is ignored, so
    ///   the editor may call this on every keystroke.
    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = url != nil
    }

    // MARK: - Saving

    /// Writes `text` back to `url`.
    ///
    /// The write is atomic, which replaces the inode — `isSavingOurselves`
    /// keeps the resulting watch event from being read as an external change.
    ///
    /// - Returns: True on success. False if there is no URL to save to, or the
    ///   write failed — in which case `status` carries the reason.
    @discardableResult
    func save() -> Bool {
        guard let url else { return false }
        isSavingOurselves = true
        defer {
            // The write lands before the fs event does; clear the guard a beat later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isSavingOurselves = false
            }
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            status = nil
            return true
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Watching

    /// Points the watcher at `url`, replacing any previous watch.
    ///
    /// - Parameter url: The file to observe.
    private func startWatching(_ url: URL) {
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in
            self?.fileChangedOnDisk()
        }
        watcher?.start()
    }

    /// Reloads after an external write, if that is safe.
    ///
    /// Skipped entirely when the change was our own save, and refused when there
    /// are unsaved edits — the user is told instead. This is what lets Context
    /// serve as a live preview beside another editor.
    private func fileChangedOnDisk() {
        guard let url, !isSavingOurselves else { return }
        // Unsaved edits win — a reader shouldn't silently discard your typing.
        guard !isDirty else {
            status = "File changed on disk — unsaved edits kept"
            return
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              contents != text else { return }
        text = contents
        renderSource = contents
        status = nil
    }
}

/// Watches a single path for writes. Editors that save atomically replace the
/// inode, which kills a plain vnode source — so a rename or delete re-arms the
/// watch on the path rather than treating the file as gone.
///
/// The watcher observes a *path*, not a file: after any replacement it ends up
/// holding a descriptor on whatever now lives at that path. Callbacks are
/// delivered on the main queue.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var rearm: DispatchWorkItem?

    /// Prepares a watch without starting it.
    ///
    /// - Parameters:
    ///   - url: File to observe.
    ///   - onChange: Called on the main queue after each write, and once after
    ///     each re-arm. May fire more than once per logical save.
    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { closeSource() }

    /// Opens the path and begins delivering events, replacing any current watch.
    ///
    /// Silently does nothing if the path cannot be opened — a file that has
    /// vanished is not an error worth surfacing to a reader.
    func start() {
        closeSource()
        descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .link],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.rename) || flags.contains(.delete) {
                self.scheduleRearm()
            } else {
                self.onChange()
            }
        }
        src.setCancelHandler { [descriptor] in
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        source = src
        src.resume()
    }

    /// Ends the watch and cancels any pending re-arm. Safe to call repeatedly.
    func stop() {
        rearm?.cancel()
        rearm = nil
        closeSource()
    }

    /// Give the replacing write a moment to land, then re-open and report.
    ///
    /// Coalescing: a fresh call supersedes a pending one, so the burst of
    /// events an atomic save produces results in a single reload.
    private func scheduleRearm() {
        rearm?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.start()
            self.onChange()
        }
        rearm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Tears down the dispatch source and its descriptor.
    private func closeSource() {
        source?.cancel()   // cancel handler closes the descriptor
        source = nil
        descriptor = -1
    }
}
