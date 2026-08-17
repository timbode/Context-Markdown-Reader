import AppKit
import SwiftUI

/// Where a request to open a file turns into a tab.
///
/// Files arrive from outside any view — the app delegate takes Finder
/// double-clicks, and the menu commands live in the `Commands` tree — but
/// SwiftUI's `openWindow` exists only inside a view's environment. This object is
/// the one place both can reach: each window hands it a way to make more, and
/// everything that opens a file asks it rather than making a window itself.
///
/// It also keeps the register of live tabs, which is what lets one request be
/// answered three different ways: raise the tab already showing that file, fill a
/// tab that has nothing in it, or make a new one.
///
/// On macOS a tab *is* a window — a tab group is several `NSWindow`s stacked
/// under one title bar — so nothing here fights SwiftUI's scene model. The only
/// part AppKit will not do by itself is deciding which group a newly made window
/// belongs to; that is `host`.
@MainActor
final class WindowRouter {
    /// One router for the process: the register only means anything if every
    /// window is in the same one.
    static let shared = WindowRouter()

    private init() {}

    /// One live tab.
    ///
    /// Both references are weak. The window owns the view that owns the
    /// document, so a strong one here would keep a closed tab alive and its file
    /// watcher with it.
    private struct Tab {
        weak var document: Document?
        weak var window: NSWindow?

        /// The file this tab was opened for, known from the moment it appears —
        /// before its document has read anything.
        var intended: URL?

        /// What the tab is showing, or is about to.
        ///
        /// Asking the document alone is not enough at launch: a restored tab
        /// exists, and is empty, for the moment between appearing and loading
        /// its file. A tab judged on that would be mistaken for a free one, or
        /// for a different file than it is about to become.
        @MainActor var file: URL? { document?.url ?? intended }
    }

    private var tabs: [Tab] = []

    /// Makes a window, given a file to show or nil for an empty one. Nil until
    /// the first window has appeared and registered its `openWindow`.
    private var makeWindow: ((URL?) -> Void)?

    /// Files asked for before they could be answered — during launch, or before
    /// any window existed to make more from.
    ///
    /// Launching by double-clicking a document lands here.
    private var deferred: [URL] = []

    /// True until the launch has finished bringing back whatever it is going to.
    ///
    /// Cleared by `settleAfterLaunch()`, which the app delegate schedules.
    private var isSettling = true

    /// The window a newly made one should join, remembered from the moment it was
    /// asked for.
    ///
    /// It has to be captured then, because by the time the new window appears it
    /// is itself key and the answer to "which group?" has been overwritten. Not
    /// cleared once used: opening three files at once makes three windows against
    /// the same host, and each has to find it.
    private weak var host: NSWindow?

    // MARK: - Registration

    /// Hands the router a way to make windows, and flushes anything that was
    /// asked for before there was one.
    ///
    /// - Parameter make: Opens a window for the given file, or an empty one for
    ///   nil. Every window registers as it appears; they are interchangeable, and
    ///   the point is only that at least one is live.
    func register(_ make: @escaping (URL?) -> Void) {
        makeWindow = make
        flushDeferred()
    }

    /// Enters a document in the register, before its window exists.
    ///
    /// - Parameters:
    ///   - document: The new tab's document.
    ///   - url: The file the tab was opened for, or nil for an empty one.
    ///     Recorded now rather than waited for: at launch this is the only thing
    ///     that tells a restored tab from a free one, since the document behind
    ///     it has not read its file yet.
    func adopt(_ document: Document, intending url: URL?) {
        prune()
        guard !tabs.contains(where: { $0.document === document }) else { return }
        tabs.append(Tab(document: document, window: nil, intended: url))
    }

    /// Completes a register entry with the window its document ended up in, and
    /// puts that window in the right tab group.
    ///
    /// Called from `WindowAccessor` on every SwiftUI update, so all of it past
    /// the first call is a no-op.
    ///
    /// - Parameters:
    ///   - window: The host window.
    ///   - document: The document it is showing.
    func attach(_ window: NSWindow, to document: Document) {
        // A shared identifier is what lets "Merge All Windows" and dragging a tab
        // between groups work; `.preferred` asks AppKit to open new windows as
        // tabs whatever the system-wide preference says.
        window.tabbingIdentifier = "context-document"
        window.tabbingMode = .preferred

        guard let index = tabs.firstIndex(where: { $0.document === document }),
              tabs[index].window == nil else { return }
        tabs[index].window = window

        // Where `.preferred` has already done it, `tabbedWindows` is non-nil and
        // there is nothing left to do. Where it hasn't — a window made through
        // `openWindow` usually isn't tabbed — this puts it in the group of
        // whichever tab asked for it, or of whatever is already on screen when
        // nothing did: restoring a session at launch has no host to name.
        let target = host ?? tabs.first { $0.window != nil && $0.document !== document }?.window
        guard let target, target !== window, window.tabbedWindows == nil else { return }
        target.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// Removes a closed tab's entry.
    ///
    /// - Parameter document: The document whose window is going away.
    func forget(_ document: Document) {
        tabs.removeAll { $0.document === document || $0.document == nil }
    }

    // MARK: - Opening

    /// Shows `url`, in the tab that best fits it.
    ///
    /// - Parameter url: A file to read.
    /// - Postcondition: Exactly one tab is showing `url`, and it is the frontmost
    ///   one.
    func open(_ url: URL) {
        // A request arriving during launch cannot be answered yet: restoration
        // is still bringing tabs back, so "is this one already open?" has no
        // answer. Guessing costs a second tab on a file that was about to
        // reappear — measured, and only for the file whose restored tab happened
        // to come back last.
        guard !isSettling else {
            deferred.append(url)
            return
        }
        prune()

        // Already open. Two tabs on one file would be two watchers on one path
        // and two answers to whether it has unsaved edits, so this raises the
        // tab that has it instead of making a second.
        if let tab = tabs.first(where: { Self.isSameFile($0.file, url) }) {
            raise(tab)
            return
        }

        // A tab with nothing in it — the one at launch, or one just made with ⌘T
        // — is a better home for the file than a new tab beside it.
        if let tab = untouched() {
            tab.document?.open(url)
            raise(tab)
            return
        }

        host = NSApp.keyWindow ?? tabs.compactMap(\.window).first
        guard let makeWindow else {
            deferred.append(url)
            return
        }
        makeWindow(url)
    }

    /// Shows each of `urls` in a tab of its own.
    ///
    /// - Parameter urls: Candidates from the Finder, the open panel or a drop.
    ///   Anything that isn't a file is ignored.
    func open(_ urls: [URL]) {
        urls.filter(\.isFileURL).forEach(open)
    }

    /// Opens an empty tab, or raises one that is already empty.
    ///
    /// An empty tab is not useless in a reader: it is where a drag-and-drop or
    /// the next ⌘O lands, and `open(_:)` prefers filling it to accumulating tabs.
    func newTab() {
        prune()
        if let tab = untouched() {
            raise(tab)
            return
        }
        host = NSApp.keyWindow ?? tabs.compactMap(\.window).first
        makeWindow?(nil)
    }

    /// Closes the tabs a restore leaves behind that nothing would have made.
    ///
    /// Two kinds, and both accumulate silently across launches:
    ///
    /// - **Empty ones.** SwiftUI brings back the windows the group had at quit
    ///   *and* opens the group's default one, so a session that ended with an
    ///   empty tab comes back with two, and the count climbs by one every launch.
    /// - **Duplicates.** Nothing else can make a second tab on one file —
    ///   `open(_:)` raises the tab that has it — but a session that once did
    ///   comes back that way for good, with two watchers on one path.
    ///
    /// Nothing in the scene model tells a restored window from a fresh one, so
    /// this runs once, shortly after launch, when every restored tab has loaded
    /// its file. A restored tab has no unsaved edits to lose: it was read from
    /// disk moments earlier.
    ///
    /// One empty tab survives if there is nothing else, since an app with no
    /// window is an app with nothing on screen. Only launch needs any of this:
    /// after it, an empty tab is one somebody asked for with ⌘T.
    func settleAfterLaunch() {
        isSettling = false
        tidyRestoredTabs()
        flushDeferred()
    }

    /// Answers whatever was asked for before it could be.
    private func flushDeferred() {
        guard !isSettling, makeWindow != nil, !deferred.isEmpty else { return }
        let pending = deferred
        deferred = []
        pending.forEach(open)
    }

    /// Closes the tabs a restore leaves behind that nothing would have made.
    private func tidyRestoredTabs() {
        prune()

        var seen: [URL] = []
        var doomed: [Tab] = []
        var empty: [Tab] = []

        for tab in tabs {
            guard let url = tab.file else {
                empty.append(tab)
                continue
            }
            if seen.contains(where: { Self.isSameFile($0, url) }) {
                doomed.append(tab)
            } else {
                seen.append(url)
            }
        }

        // Keep an empty tab only when it would otherwise be an empty screen.
        let spare = seen.isEmpty ? 1 : 0
        doomed.append(contentsOf: empty.dropFirst(spare))
        for tab in doomed { tab.window?.close() }
    }

    // MARK: - Register upkeep

    /// The best tab to open a file into without displacing anything.
    ///
    /// - Returns: The key window's tab if it is empty, otherwise any empty tab,
    ///   otherwise nil. The key window comes first so that ⌘O in an untouched
    ///   window fills the one you are looking at.
    private func untouched() -> Tab? {
        // `intended` has to be nil too: a restored tab that has not loaded yet
        // looks empty, and filling it would put a file in a tab that is about to
        // replace it with its own.
        let isFree = { (tab: Tab) in tab.intended == nil && tab.document?.isUntouched == true }
        if let key = NSApp.keyWindow, let tab = tabs.first(where: { $0.window === key }), isFree(tab) {
            return tab
        }
        return tabs.first(where: isFree)
    }

    /// Brings a tab to the front of its group and gives it the keyboard.
    ///
    /// - Parameter tab: The tab to show. One whose window has not appeared yet is
    ///   left alone — it is on its way to the front regardless.
    private func raise(_ tab: Tab) {
        guard let window = tab.window else { return }
        // Selecting within the group first: `makeKeyAndOrderFront` on a window
        // behind another tab raises the group, not necessarily this member.
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Whether two URLs name the same file on disk.
    ///
    /// `==` is not that question. A link resolved against the document's folder,
    /// a path from the Finder and one typed with a symlink in it can all reach
    /// one file and compare unequal — and each mismatch is a second tab on a
    /// document that is already open, with a second watcher on the same path.
    ///
    /// - Parameters:
    ///   - lhs: A candidate, or nil for a tab with nothing open.
    ///   - rhs: The file being asked for.
    /// - Returns: True only if both name one file.
    private static func isSameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Drops entries whose document has been deallocated.
    ///
    /// Closing a tab releases its document, so a stale entry is how a closed tab
    /// looks from here. `forget(_:)` catches most of them; this catches the rest.
    private func prune() {
        tabs.removeAll { $0.document == nil }
    }
}
