import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The reading pane: a WKWebView showing `Resources/app/index.html`, driven by
/// `window.Context.renderBase64`.
///
/// The page is loaded once and never reloaded; new documents arrive as calls
/// into the already-running JavaScript, which is what makes re-rendering cheap
/// enough to do on a debounced keystroke.
struct PreviewView: NSViewRepresentable {
    @ObservedObject var doc: Document

    /// Page zoom, 1.0 being actual size.
    var zoom: Double

    /// - Returns: The object that outlives view updates and so can remember what
    ///   has already been rendered.
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Builds the webview and starts loading the bundled page.
    ///
    /// - Returns: A webview that is not yet ready to render; `render(_:in:)`
    ///   queues work until navigation finishes.
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: Coordinator.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        // Painted behind the page so resizing and launch never flash white.
        webView.underPageBackgroundColor = Palette.paper

        let appDirectory = Bundle.main.resourceURL!.appendingPathComponent("app", isDirectory: true)
        webView.loadFileURL(
            appDirectory.appendingPathComponent("index.html"),
            allowingReadAccessTo: appDirectory
        )

        // The one pane find searches. Set here rather than passed in, because the
        // find bar is a sibling in the layout and never sees this view.
        FindModel.shared.webView = webView
        return webView
    }

    /// Pushes the current zoom and document text into the page.
    ///
    /// Called on every SwiftUI update, so both writes are guarded against
    /// no-op churn.
    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        context.coordinator.render(doc.renderSource, from: doc.url, in: webView)
    }

    /// Owns everything that has to survive a view update: the load state, the
    /// last-rendered source, and the handlers for links and local files.
    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        /// Custom scheme for the document's own relative links and images. A
        /// custom scheme rather than `file://` because the page is loaded from
        /// the app bundle and must not be granted read access to the whole disk.
        static let scheme = "context-doc"

        private var isLoaded = false
        private var pending: String?
        private var lastRendered: String?

        /// The file last rendered, which is the only way to tell a re-render of
        /// what you are reading from a move to a different document.
        private var lastURL: URL?

        /// The fragment of a link into another file, waiting for that file to be
        /// on screen before it can be spent.
        private var pendingAnchor: String?

        // MARK: Rendering

        /// Renders `source`, or defers it if the page is still loading.
        ///
        /// - Parameters:
        ///   - source: Markdown to display.
        ///   - url: The file it came from, or nil for an empty document.
        ///   - webView: The view to render into.
        /// - Note: Identical source is dropped, which is what makes this safe to
        ///   call from `updateNSView` on every SwiftUI pass.
        func render(_ source: String, from url: URL?, in webView: WKWebView) {
            let isSameDocument = url == lastURL
            lastURL = url

            guard source != lastRendered else {
                // No new text, but a link may still be waiting to scroll: one
                // pointing into the file that is already open changes nothing.
                flushAnchor(in: webView)
                return
            }
            lastRendered = source
            guard isLoaded else {
                pending = source
                return
            }
            push(source, to: webView, keepScroll: isSameDocument)
        }

        /// Hands source to the page's renderer.
        ///
        /// - Parameters:
        ///   - source: Markdown, base64-encoded on the way across so no quoting
        ///     or escaping is needed to build the call.
        ///   - webView: The view to evaluate in; must have finished loading.
        ///   - keepScroll: Whether to hold the reading position. True re-renders
        ///     what is already on screen — an edit, or a reload from the watcher.
        ///     False opens something else, which starts at the top rather than at
        ///     the offset the last document happened to be left at.
        private func push(_ source: String, to webView: WKWebView, keepScroll: Bool) {
            let encoded = Data(source.utf8).base64EncodedString()
            webView.evaluateJavaScript("window.Context.renderBase64('\(encoded)', \(keepScroll))")
            // A render replaces every node an active search was pointing at, so
            // the matches have to be found again. WebKit runs these scripts in
            // the order they were queued, so both see the new document.
            MainActor.assumeIsolated { FindModel.shared.refresh() }
            flushAnchor(in: webView)
        }

        /// Scrolls to the fragment a cross-file link was carrying, if any.
        ///
        /// - Parameter webView: The view now showing the linked document.
        /// - Note: A fragment naming nothing is simply dropped, as it is in a
        ///   browser.
        private func flushAnchor(in webView: WKWebView) {
            guard let anchor = pendingAnchor else { return }
            pendingAnchor = nil
            let encoded = Data(anchor.utf8).base64EncodedString()
            webView.evaluateJavaScript("window.Context.scrollToAnchor('\(encoded)')")
        }

        /// Marks the page ready and flushes anything that arrived while loading.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pending {
                push(pending, to: webView, keepScroll: false)
                self.pending = nil
            }
        }

        // MARK: Link handling

        /// Routes clicked links; nothing ever navigates the pane away from the
        /// rendered document.
        ///
        /// Markdown opens in Context, web links go to the browser, other local
        /// files are shown or revealed, and in-page anchors are left to WebKit.
        ///
        /// The policy is deny-by-default. A document is untrusted input, and the
        /// only navigations it has any business causing are the ones enumerated
        /// here — everything else is cancelled rather than allowed, including the
        /// navigations it did not have to be clicked to start.
        ///
        /// - Parameter decisionHandler: Called exactly once, as WebKit requires.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // Not a click: either the initial load of the bundled page, or
            // something the document started on its own. Only the first is
            // wanted. A scripted `location.href` is reported as `.other`, and
            // allowing it would let a document replace the reader with a remote
            // page — inside a window with no address bar to give it away.
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(Self.isBundledPage(url) ? .allow : .cancel)
                return
            }

            switch url.scheme {
            case Self.scheme:
                // A relative link in the document. Markdown opens in Context;
                // anything else is handed over only if opening it merely shows it.
                if let resolved = Self.resolve(url) {
                    if Self.markdownExtensions.contains(resolved.pathExtension.lowercased()) {
                        // `resolve` deals in file paths and drops the fragment, so
                        // a link to a section of another file — the one link that
                        // crosses documents — would land at the top without this.
                        pendingAnchor = url.fragment
                        MainActor.assumeIsolated { Document.shared.open(resolved) }
                    } else {
                        MainActor.assumeIsolated { Self.reveal(resolved) }
                    }
                }
                decisionHandler(.cancel)

            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)

            default:
                // A fragment inside the page already on screen: WebKit scrolls
                // it. Any other file:// target is a document trying to read the
                // disk through the window, and is refused.
                decisionHandler(Self.isBundledPage(url) ? .allow : .cancel)
            }
        }

        /// Extensions a link may point at and still open in Context rather than
        /// being handed to the system.
        static let markdownExtensions: Set<String> = [
            "md", "markdown", "mdown", "mkd", "mdwn", "qmd", "rmd", "text", "txt",
        ]

        /// The one page this pane is ever allowed to be showing.
        static let bundledPage: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("app/index.html")
            .standardizedFileURL

        /// Whether `url` addresses the bundled page itself.
        ///
        /// - Parameter url: Any navigation target.
        /// - Returns: True for `…/Resources/app/index.html`, with or without a
        ///   fragment — `path` carries neither query nor fragment, so an in-page
        ///   anchor compares equal to the bare page, which is what makes a
        ///   heading link work while `file:///etc/passwd` does not.
        static func isBundledPage(_ url: URL) -> Bool {
            guard url.isFileURL, let page = Self.bundledPage else { return false }
            return url.standardizedFileURL.path == page.path
        }

        /// Opens a non-Markdown local file if that only displays it, and reveals
        /// it in the Finder if it might do anything more.
        ///
        /// A link is a reader's instruction to *look* at something. LaunchServices
        /// draws no such line: handed a `.command` or an `.app` sitting beside the
        /// document, it runs it, and a file that arrived by `git clone` carries no
        /// quarantine, so Gatekeeper does not intervene either. One click would be
        /// the whole of the attack.
        ///
        /// - Parameter url: A resolved local file.
        /// - Postcondition: Either the file is open in its owning app, or it is
        ///   selected in the Finder and the banner says why.
        static func reveal(_ url: URL) {
            guard Self.isInert(url) else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                Document.shared.note(
                    "Revealed \(url.lastPathComponent) in the Finder — Context doesn't run files"
                )
                return
            }
            NSWorkspace.shared.open(url)
        }

        /// Whether opening `url` through LaunchServices can only display it.
        ///
        /// Conformance alone is not enough in either direction, so both lists are
        /// consulted. The trap is `.command`: it conforms to `public.shell-script`,
        /// which conforms up through `public.script` to `public.plain-text` — so an
        /// allowlist naming plain text would wave straight past it, and Terminal
        /// would run it.
        ///
        /// - Parameter url: A local file.
        /// - Returns: True only for a type on the viewable list that is on no
        ///   runnable list and carries no execute bit.
        static func isInert(_ url: URL) -> Bool {
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            if FileManager.default.isExecutableFile(atPath: url.path) { return false }
            if Self.runnableTypes.contains(where: type.conforms(to:)) { return false }
            return Self.viewableTypes.contains(where: type.conforms(to:))
        }

        /// Types LaunchServices executes, installs or follows rather than shows.
        ///
        /// The named identifiers have no `UTType` constant but are the two that
        /// slipped through the allowlist when it was first measured: a `.pkg`
        /// conforms to `public.archive`, and a `.mobileconfig` — which can carry
        /// a certificate or an MDM enrolment — conforms to `public.xml`.
        static let runnableTypes: [UTType] = [
            .application, .unixExecutable, .executable, .script, .shellScript,
            .appleScript, .osaScript, .diskImage, .symbolicLink, .aliasFile,
            .internetShortcut, .bookmark,
        ] + ["com.apple.mobileconfig", "com.apple.installer-package-archive"]
            .compactMap { UTType($0) }

        /// Types a reader can be shown with nothing running on their behalf.
        ///
        /// Deliberately narrow, and narrowed twice already by measurement rather
        /// than by reading the type graph. `public.archive` is left out because an
        /// installer conforms to it; `public.xml` because a configuration profile
        /// does. What remains are formats whose only reading is "look at this".
        /// A type that misses the list is revealed in the Finder, which costs a
        /// reader one click and costs an attacker the whole attack.
        static let viewableTypes: [UTType] = [
            .image, .pdf, .plainText, .rtf, .html, .json, .sourceCode,
            .movie, .audio, .spreadsheet, .presentation,
        ]

        // MARK: Local resources

        /// `context-doc://doc/<relative>` resolves against the open document's
        /// folder; `context-doc://abs/<path>` is an absolute filesystem path.
        ///
        /// - Parameter url: A URL in the custom scheme.
        /// - Returns: The file URL it denotes, or nil if the path is empty or no
        ///   document is open to resolve against.
        static func resolve(_ url: URL) -> URL? {
            let path = (url.path.removingPercentEncoding ?? url.path)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { return nil }

            switch url.host {
            case "abs":
                return URL(fileURLWithPath: "/" + path)
            default:
                guard let directory = MainActor.assumeIsolated({ Document.shared.directory })
                else { return nil }
                return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
            }
        }

        /// Serves an image or other asset the page asked for over the custom
        /// scheme.
        ///
        /// - Parameter urlSchemeTask: Answered with the file's bytes, or failed
        ///   with `NSURLErrorFileDoesNotExist` if it cannot be resolved or read.
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let requested = urlSchemeTask.request.url,
                  let fileURL = Self.resolve(requested),
                  let data = try? Data(contentsOf: fileURL) else {
                urlSchemeTask.didFailWithError(
                    NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
                )
                return
            }

            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(
                url: requested,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            // Read synchronously and answer immediately — local files are small,
            // and this sidesteps the "task already stopped" race entirely.
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        /// Required by the protocol; nothing to cancel, as `start` completes
        /// synchronously.
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }
}
