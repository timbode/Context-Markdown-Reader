// Development tool — not part of Context.app.
//
// Renders a Markdown file through the app's own web assets and writes a PNG,
// so the typography can be reviewed without Screen Recording permission.
//
//   snapshot <appResourcesDir> <file.md> <out.png> <width> <light|dark> [sliceHeight]

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 6 else {
    FileHandle.standardError.write(
        "usage: snapshot <appDir> <file.md> <out.png> <width> <light|dark>\n".data(using: .utf8)!)
    exit(64)
}

let appDirectory = URL(fileURLWithPath: args[1], isDirectory: true)
let markdownURL = URL(fileURLWithPath: args[2])
let outputURL = URL(fileURLWithPath: args[3])
let width = Double(args[4]) ?? 940
let theme = args[5]

/// Optional 6th argument: cut the page into slices this many points tall.
let sliceHeight = args.count > 6 ? (Double(args[6]) ?? 0) : 0

/// Drives an offscreen WKWebView through one render and writes the result.
///
/// A one-shot object: `run()` starts an asynchronous chain that ends in
/// `exit()`, so nothing is returned and the instance is never reused.
final class Snapshotter: NSObject, WKNavigationDelegate {
    /// Derives the filename for one slice of a sliced capture.
    ///
    /// - Parameters:
    ///   - url: The output path given on the command line.
    ///   - index: Zero-based slice number.
    /// - Returns: `<stem>-NN.png` beside the original.
    static func numbered(_ url: URL, _ index: Int) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(String(format: "%@-%02d.png", stem, index))
    }

    let webView: WKWebView
    let window: NSWindow

    /// Builds the webview and the offscreen window that hosts it.
    ///
    /// Reads the parsed command-line globals above; there is exactly one
    /// instance per process, so they are not worth threading through.
    override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900),
                            configuration: configuration)
        // A window far off the visible desktop: WebKit only rasterises content
        // that belongs to an on-screen window, but nobody has to watch it.
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 900),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        super.init()
        window.contentView = webView
        window.orderFront(nil)
        webView.navigationDelegate = self
    }

    /// Starts the page load. Everything after this happens in delegate
    /// callbacks, so the caller must run the main loop.
    func run() {
        webView.loadFileURL(appDirectory.appendingPathComponent("index.html"),
                            allowingReadAccessTo: appDirectory)
    }

    /// Renders the Markdown once the page is ready, then captures it.
    ///
    /// Exits with status 1 if the Markdown cannot be read. Content height is
    /// clamped to 400…6000pt, past which a single capture stops being useful.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let source = try? String(contentsOf: markdownURL, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read markdown\n".data(using: .utf8)!)
            exit(1)
        }
        let encoded = Data(source.utf8).base64EncodedString()
        // data-theme pins the palette so the snapshot doesn't depend on
        // whatever appearance the machine happens to be in.
        let script = """
        document.documentElement.dataset.theme = '\(theme)';
        window.Context.renderBase64('\(encoded)');
        document.documentElement.scrollHeight;
        """
        webView.evaluateJavaScript(script) { result, _ in
            let contentHeight = (result as? Double) ?? 900
            self.capture(height: min(max(contentHeight, 400), 6000))
        }
    }

    /// Grows the window to the full content height, captures it, and writes PNGs.
    ///
    /// - Parameter height: Content height in points.
    /// - Note: Never returns — exits 0 once the files are written, or 1 if the
    ///   capture fails.
    private func capture(height: Double) {
        window.setContentSize(NSSize(width: width, height: height))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Let fonts settle and KaTeX finish laying out before the shutter.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            self.webView.takeSnapshot(with: configuration) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let full = bitmap.cgImage else {
                    FileHandle.standardError.write(
                        "snapshot failed: \(error?.localizedDescription ?? "unknown")\n".data(using: .utf8)!)
                    exit(1)
                }
                // A whole document is too tall to read once scaled down, so cut
                // it into screen-sized slices. CGImage is top-left origin, which
                // sidesteps the flipped-view question entirely.
                let scale = Double(full.height) / height
                let slice = sliceHeight > 0 ? sliceHeight : height
                var index = 0
                var top = 0.0
                while top < height - 1 {
                    let pixelHeight = min(slice, height - top) * scale
                    let rect = CGRect(x: 0, y: top * scale,
                                      width: Double(full.width), height: pixelHeight)
                    guard let piece = full.cropping(to: rect) else { break }
                    let rep = NSBitmapImageRep(cgImage: piece)
                    let url = sliceHeight > 0 ? Self.numbered(outputURL, index) : outputURL
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: url)
                        print("wrote \(url.lastPathComponent) (\(piece.width)×\(piece.height))")
                    }
                    index += 1
                    top += slice
                }
                exit(0)
            }
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let snapshotter = Snapshotter()
snapshotter.run()
application.run()
