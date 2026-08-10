// Development tool — generates Resources/AppIcon.icns.
//
// Without Xcode there is no asset catalog to drop PNGs into, so the icon is
// drawn with Core Graphics at each required size and handed to iconutil.
//
// The mark is a New York "C": the app's own reading face, so the icon states
// what the app is for rather than showing yet another generic page-and-fold.
//
//   makeicon <output.iconset directory>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: makeicon <out.iconset>\n".data(using: .utf8)!)
    exit(64)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let paper = NSColor(srgbRed: 0.980, green: 0.976, blue: 0.968, alpha: 1)
let inkTop = NSColor(srgbRed: 0.200, green: 0.188, blue: 0.169, alpha: 1)
let inkBottom = NSColor(srgbRed: 0.098, green: 0.090, blue: 0.082, alpha: 1)

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setShouldAntialias(true)

    let side = Double(pixels)
    // The macOS icon grid leaves the outer ~10% clear; art lives inside that.
    let inset = side * 0.098
    let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    // Apple's continuous corner is close to 0.2237 of the tile's side.
    let radius = tile.width * 0.2237

    // Drop shadow, scaled with the icon so it reads the same at every size.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -side * 0.012),
        blur: side * 0.028,
        color: NSColor(white: 0, alpha: 0.30).cgColor
    )
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(tilePath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Ink gradient
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = NSGradient(starting: inkBottom, ending: inkTop)!
    gradient.draw(in: tile, angle: 90)
    context.restoreGState()

    // The letterform.
    let pointSize = tile.height * 0.66
    let serif = NSFont.systemFont(ofSize: pointSize, weight: .regular)
    let font: NSFont
    if let descriptor = serif.fontDescriptor.withDesign(.serif),
       let newYork = NSFont(descriptor: descriptor, size: pointSize) {
        font = newYork
    } else {
        font = NSFont(name: "Georgia", size: pointSize) ?? serif
    }

    let glyph = NSAttributedString(string: "C", attributes: [
        .font: font,
        .foregroundColor: paper,
    ])
    let glyphSize = glyph.size()
    // Centre on the cap-height box, not the line box. The line box reserves
    // descender space the "C" never uses, so centring that would seat the
    // letter visibly high. draw(at:) takes the line box's lower-left in an
    // unflipped context, and the baseline sits |descender| above it.
    let baselineY = tile.midY - font.capHeight / 2
    let origin = CGPoint(
        x: tile.midX - glyphSize.width / 2,
        y: baselineY - abs(font.descender)
    )
    glyph.draw(at: origin)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// name → pixel size, per the .iconset convention
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in variants {
    let rep = drawIcon(pixels: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
}
print("wrote \(variants.count) sizes to \(outputDirectory.path)")
