import Foundation

/// Colours for the terminal interface. Primitives are 24-bit RGB, mapped to the semantic roles
/// the console uses. `mono` (NO_COLOR) uses no colour, only bold and dim.
struct TerminalTheme: Equatable {
    typealias RGB = (r: Int, g: Int, b: Int)

    let name: String
    let summary: String
    let accent: RGB?
    let success: RGB?
    let warning: RGB?
    let error: RGB?
    let muted: RGB?
    let recording: RGB?
    let ready: RGB?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }

    // Primitives.
    private static let green: RGB = (0x22, 0xC5, 0x5E)
    /// Recording indicator.
    private static let signalRed: RGB = (0xFF, 0x2D, 0x2D)
    /// Mid grey: readable on both dark and light terminal backgrounds.
    private static let grey: RGB = (0x8A, 0x8A, 0x8A)

    /// Monochrome UI; only the Recording and Ready status dots carry colour.
    static let dictator = TerminalTheme(name: "dictator", summary: "monochrome with status indicators", accent: nil, success: nil, warning: nil, error: nil, muted: grey, recording: signalRed, ready: green)
    /// NO_COLOR: bold and dim only.
    static let mono = TerminalTheme(name: "mono", summary: "no colour", accent: nil, success: nil, warning: nil, error: nil, muted: nil, recording: nil, ready: nil)

}

/// ANSI styling. Every helper resets only what it set, so styles nest.
enum Style {
    static func color(_ rgb: TerminalTheme.RGB?, _ text: String) -> String {
        guard let rgb else { return text }
        return "\u{1B}[38;2;\(rgb.r);\(rgb.g);\(rgb.b)m\(text)\u{1B}[39m"
    }
    static func bold(_ text: String) -> String { "\u{1B}[1m\(text)\u{1B}[22m" }
    static func dim(_ text: String) -> String { "\u{1B}[2m\(text)\u{1B}[22m" }
    static func inverse(_ text: String) -> String { "\u{1B}[7m\(text)\u{1B}[27m" }

    /// Columns a string takes on screen, ignoring ANSI codes: wide (CJK, emoji) count 2,
    /// combining marks 0.
    static func width(_ text: String) -> Int {
        var total = 0, escape = false
        for scalar in text.unicodeScalars {
            if escape { if (0x40...0x7E).contains(scalar.value) && scalar != "[" { escape = false }; continue }
            if scalar == "\u{1B}" { escape = true; continue }
            total += columns(scalar)
        }
        return total
    }

    static func columns(_ scalar: Unicode.Scalar) -> Int {
        let properties = scalar.properties
        if properties.generalCategory == .nonspacingMark || properties.generalCategory == .enclosingMark { return 0 }
        if properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            return 2
        default: return 1
        }
    }

    /// Cuts plain text to at most `columns`, adding … when it had to cut.
    static func fit(_ text: String, _ columns: Int) -> String {
        guard width(text) > columns, columns > 1 else { return text }
        var result = "", used = 0
        for character in text {
            let w = character.unicodeScalars.reduce(0) { $0 + Self.columns($1) }
            if used + w > columns - 1 { break }
            result.append(character); used += w
        }
        return result + "…"
    }
}
