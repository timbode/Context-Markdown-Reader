import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The reading pane: a WKWebView showing `Resources/app/index.html`, driven by
/// `window.Quire.renderBase64`.
struct PreviewView: NSViewRepresentable {
    @ObservedObject var doc: Document
    var zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

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

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        context.coordinator.render(doc.renderSource, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        static let scheme = "quire-doc"

        private var isLoaded = false
        private var pending: String?
        private var lastRendered: String?

        // MARK: Rendering

        func render(_ source: String, in webView: WKWebView) {
            guard source != lastRendered else { return }
            lastRendered = source
            guard isLoaded else {
                pending = source
                return
            }
            push(source, to: webView)
        }

        private func push(_ source: String, to webView: WKWebView) {
            let encoded = Data(source.utf8).base64EncodedString()
            webView.evaluateJavaScript("window.Quire.renderBase64('\(encoded)')")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pending {
                push(pending, to: webView)
                self.pending = nil
            }
        }

        // MARK: Link handling

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
                // A relative link in the document. Markdown opens in Quire;
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

        static let markdownExtensions: Set<String> = [
            "md", "markdown", "mdown", "mkd", "mdwn", "qmd", "rmd", "text", "txt",
        ]

        // MARK: Local resources

        /// `quire-doc://doc/<relative>` resolves against the open document's
        /// folder; `quire-doc://abs/<path>` is an absolute filesystem path.
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

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }
}
