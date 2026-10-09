import SwiftUI

/// Dictator's design tokens. Primitives hold raw values; the rest of the app uses the semantic names.
enum Palette {
    static let white = Color.white
    static let black = Color.black
}

enum Tokens {
    /// The caret bubble is always dark, whatever the system appearance.
    static let bubbleText = Palette.white.opacity(0.92)
    static let bubbleTint = Palette.black.opacity(0.32)
    static let bubbleBorder = Palette.white.opacity(0.10)
    /// The character and bubble are strictly black and white: PixelArt's colour codes from the
    /// trace all render as white.
    static let pixelInk = Palette.black
    static let pixelPaper = Palette.white
    static let pixelCap = Palette.white
    static let pixelBand = Palette.white
    static let pixelBadge = Palette.white
    static let pixelPiping = Palette.white
}

enum Space {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s10: CGFloat = 10
}

enum Size {
    /// Height of the pixel Dictator; the character and speech bubble scale together.
    static let indicator: CGFloat = 40
}
