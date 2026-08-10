import AppKit

/// Native-side colours, kept in step with the values in `Web/style.css` so the
/// chrome around the webview never disagrees with the page inside it.
///
/// Every colour is appearance-sensitive: the same `NSColor` resolves light or
/// dark at draw time, so nothing here has to be recomputed when the system
/// appearance changes.
enum Palette {
    static let paper = dynamic(light: 0xFA_F9_F7, dark: 0x1B_1A_19)
    static let editorBackground = dynamic(light: 0xF3_F1_ED, dark: 0x20_1F_1E)
    static let ink = dynamic(light: 0x24_22_1F, dark: 0xDD_D8_D0)
    static let muted = dynamic(light: 0x6B_66_5F, dark: 0x91_8B_83)
    static let rule = dynamic(light: 0xE4_E0_D8, dark: 0x33_31_2E)
    static let accent = dynamic(light: 0x2C_5D_87, dark: 0x8A_B4_DD)

    /// Pairs two fixed colours into one that follows the system appearance.
    ///
    /// - Parameters:
    ///   - light: sRGB hex (`0xRRGGBB`) used under Aqua.
    ///   - dark: sRGB hex (`0xRRGGBB`) used under Dark Aqua.
    /// - Returns: A colour that resolves its pair member each time it is drawn,
    ///   so it tracks appearance changes without observation.
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = rgb(light)
        let darkColor = rgb(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    /// Unpacks a hex literal into an opaque sRGB colour.
    ///
    /// - Parameter value: Packed `0xRRGGBB`; the high byte is ignored.
    /// - Returns: The colour in the sRGB space — matching CSS, which is the
    ///   point: the same literal means the same colour on both sides.
    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
