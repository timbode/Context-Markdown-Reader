import AppKit
import Combine
import Foundation

/// The open Markdown file. Quire is a single-window reader, so one instance is
/// shared by the app delegate, the menu commands and both panes.
@MainActor
final class Document: ObservableObject {
    static let shared = Document()

    /// Live text. The editor writes here; the preview reads `renderSource`.
    @Published var text: String = ""

    /// `text` debounced, so typing doesn't re-render on every keystroke.
    @Published private(set) var renderSource: String = ""

    @Published private(set) var url: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var status: String?

    private var watcher: FileWatcher?
    /// Set around our own writes so the resulting fs event isn't mistaken for
    /// somebody else editing the file.
    private var isSavingOurselves = false

    var displayName: String { url?.lastPathComponent ?? "Quire" }
    var directory: URL? { url?.deletingLastPathComponent() }

    private init() {
        $text
            .debounce(for: .milliseconds(110), scheduler: DispatchQueue.main)
            .assign(to: &$renderSource)
    }

    // MARK: - Opening

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

    private func apply(_ contents: String, from url: URL) {
        text = contents
        renderSource = contents      // render immediately, don't wait out the debounce
        self.url = url
        isDirty = false
        status = nil
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        startWatching(url)
    }

    func clearStatus() { status = nil }

    /// Editor edits arrive here so they can be distinguished from a disk load.
    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = url != nil
    }

    // MARK: - Saving

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

    private func startWatching(_ url: URL) {
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in
            self?.fileChangedOnDisk()
        }
        watcher?.start()
    }

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
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var rearm: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { closeSource() }

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

    func stop() {
        rearm?.cancel()
        rearm = nil
        closeSource()
    }

    /// Give the replacing write a moment to land, then re-open and report.
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

    private func closeSource() {
        source?.cancel()   // cancel handler closes the descriptor
        source = nil
        descriptor = -1
    }
}
