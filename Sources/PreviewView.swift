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
        return webView
    }

    /// Pushes the current zoom and document text into the page.
    ///
    /// Called on every SwiftUI update, so both writes are guarded against
    /// no-op churn.
    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        context.coordinator.render(doc.renderSource, in: webView)
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

        // MARK: Rendering

        /// Renders `source`, or defers it if the page is still loading.
        ///
        /// - Parameters:
        ///   - source: Markdown to display.
        ///   - webView: The view to render into.
        /// - Note: Identical source is dropped, which is what makes this safe to
        ///   call from `updateNSView` on every SwiftUI pass.
        func render(_ source: String, in webView: WKWebView) {
            guard source != lastRendered else { return }
            lastRendered = source
            guard isLoaded else {
                pending = source
                return
            }
            push(source, to: webView)
        }

        /// Hands source to the page's renderer.
        ///
        /// - Parameters:
        ///   - source: Markdown, base64-encoded on the way across so no quoting
        ///     or escaping is needed to build the call.
        ///   - webView: The view to evaluate in; must have finished loading.
        private func push(_ source: String, to webView: WKWebView) {
            let encoded = Data(source.utf8).base64EncodedString()
            webView.evaluateJavaScript("window.Context.renderBase64('\(encoded)')")
        }

        /// Marks the page ready and flushes anything that arrived while loading.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pending {
                push(pending, to: webView)
                self.pending = nil
            }
        }

        // MARK: Link handling

        /// Routes clicked links; nothing ever navigates the pane away from the
        /// rendered document.
        ///
        /// Markdown opens in Context, other local files and web links go to the
        /// system, and in-page anchors are left to WebKit.
        ///
        /// - Parameter decisionHandler: Called exactly once, as WebKit requires.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            switch url.scheme {
            case Self.scheme:
                // A relative link in the document. Markdown opens in Context;
                // anything else goes to whichever app owns it.
                if let resolved = Self.resolve(url) {
                    if Self.markdownExtensions.contains(resolved.pathExtension.lowercased()) {
                        MainActor.assumeIsolated { Document.shared.open(resolved) }
                    } else {
                        NSWorkspace.shared.open(resolved)
                    }
                }
                decisionHandler(.cancel)

            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)

            default:
                // file:// with a fragment — an in-page anchor. Let WebKit scroll.
                decisionHandler(.allow)
            }
        }

        /// Extensions a link may point at and still open in Context rather than
        /// being handed to the system.
        static let markdownExtensions: Set<String> = [
            "md", "markdown", "mdown", "mkd", "mdwn", "qmd", "rmd", "text", "txt",
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
