import SwiftUI

/// The recording indicator: the pixel Dictator, drawn cell by cell from `PixelArt`.
/// While you speak his mouth cycles through the talking faces whatever the volume;
/// a speech bubble with 1-2-3 dots shows beside him while he talks.
enum PixelDictator {
    static let columns = PixelArt.faces[0].first?.count ?? 39
    static let rows = PixelArt.faces[0].count
    static let bubbleColumns = PixelArt.bubbles[0].first?.count ?? 23
    /// Enlarge the bubble toward the head's top edge, keeping its tail at the same height.
    static let bubbleScale: CGFloat = 1.2
    static let bubbleOrigin = (x: columns - 1, y: 5)
    /// Reserve space for the left scream rays in every state so hovering never moves the head.
    static let headOrigin = (x: 8, y: 0)
    static let totalColumns = headOrigin.x + bubbleOrigin.x + Int(ceil(CGFloat(bubbleColumns) * bubbleScale))

    static func grid(face: Int, eyes: PixelEyePose) -> [String] {
        switch eyes {
        case .squint: return PixelArt.faces[min(max(face, 0), PixelArt.faces.count - 1)]
        case .screaming: return PixelArt.hoverScream
        case .forward, .left, .blink: return PixelArt.restingFaces[eyes.rawValue]
        }
    }

    /// The order talking faces follow, so the mouth never repeats the same shape twice running.
    static let talkSequence = [2, 4, 1, 5, 3, 1, 4, 2, 5, 3]
    static let mouthStep: TimeInterval = 0.11
    static let dotStep: TimeInterval = 0.3

    static func color(_ cell: Character) -> Color? {
        switch cell {
        case "k": return Tokens.pixelInk
        case "w": return Tokens.pixelPaper
        case "g": return Tokens.pixelCap
        case "r": return Tokens.pixelBand
        case "y": return Tokens.pixelBadge
        case "b": return Tokens.pixelPiping
        default: return nil
        }
    }

    static func draw(_ grid: [String], at origin: (x: Int, y: Int), cell: CGFloat, in context: GraphicsContext) {
        for (y, row) in grid.enumerated() {
            for (x, character) in row.enumerated() {
                guard let color = color(character) else { continue }
                // A hair of overlap so neighbouring cells never show a seam when scaled.
                let rect = CGRect(x: CGFloat(origin.x + x) * cell, y: CGFloat(origin.y + y) * cell,
                                  width: cell + 0.25, height: cell + 0.25)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}

/// The character with face `face` and, when `dots` is 1…3, the bubble beside him.
struct PixelDictatorView: View {
    var face: Int
    var dots: Int?
    var eyes: PixelEyePose = .squint

    var body: some View {
        Canvas { context, size in
            let cell = size.height / CGFloat(PixelDictator.rows)
            PixelDictator.draw(PixelDictator.grid(face: face, eyes: eyes),
                               at: PixelDictator.headOrigin, cell: cell, in: context)
            if eyes == .screaming {
                let origin = (x: PixelDictator.headOrigin.x + PixelArt.screamOrigin.x,
                              y: PixelArt.screamOrigin.y)
                PixelDictator.draw(PixelArt.screamLines, at: origin, cell: cell, in: context)
            }
            if let dots, (1...3).contains(dots) {
                var bubbleContext = context
                bubbleContext.translateBy(
                    x: CGFloat(PixelDictator.headOrigin.x + PixelDictator.bubbleOrigin.x) * cell,
                    y: CGFloat(PixelDictator.bubbleOrigin.y) * cell)
                PixelDictator.draw(PixelArt.bubbles[dots - 1], at: (0, 0),
                                   cell: cell * PixelDictator.bubbleScale, in: bubbleContext)
            }
        }
        .frame(width: Size.indicator * CGFloat(PixelDictator.totalColumns) / CGFloat(PixelDictator.rows),
               height: Size.indicator)
    }
}

/// Recording: mouth and bubble move together during speech; silence looks at you and blinks.
struct CharacterRecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var levels: DictationLevels
    var showsBubble = true
    var hoverEyes: PixelEyePose?

    var body: some View {
        let animation = levels.animation
        let talking = animation.isSpeaking
        let time = animation.speechElapsed
        let step = Int(time / PixelDictator.mouthStep)
        let face = !talking || hoverEyes != nil ? 0
            : reduceMotion ? 2
            : PixelDictator.talkSequence[step % PixelDictator.talkSequence.count]
        let dots = talking && showsBubble && hoverEyes == nil
            ? (reduceMotion ? 3 : Int(time / PixelDictator.dotStep) % 3 + 1) : nil
        let eyes = hoverEyes ?? (talking ? .squint : CharacterEyeAnimation.silent(
            elapsed: animation.silenceElapsed, reduceMotion: reduceMotion))
        PixelDictatorView(face: face, dots: dots, eyes: eyes)
        .accessibilityElement()
        .accessibilityLabel("Recording dictation. Tap Right Command again to insert, or press Escape to cancel.")
    }
}

/// Transcribing: mouth shut, no speech bubble; look at you for 1 s, then left for 0.5 s.
struct CharacterWorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    var hoverEyes: PixelEyePose?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            let eyes = hoverEyes ?? CharacterEyeAnimation.working(
                elapsed: context.date.timeIntervalSince(started), reduceMotion: reduceMotion)
            PixelDictatorView(face: 0, dots: nil, eyes: eyes)
        }
        .accessibilityElement()
        .accessibilityLabel("Transcribing dictation")
    }
}

/// Hovering the head reveals Cancel; pointing at Cancel makes him scream.
/// All states share the same reserved canvas, so neither the head nor the button moves.
struct CancellableCharacterIndicator<Content: View>: View {
    let cancel: () -> Void
    @ViewBuilder var content: (Bool, PixelEyePose?) -> Content
    @State private var hovered = false
    @State private var hoverEyes: PixelEyePose?

    private static var cross: [String] { [
        ".www...www.",
        "wkkkw.wkkkw",
        "wwkkkwkkkww",
        ".wwkkkkkww.",
        "..wwkkkww..",
        "...wkkkw...",
        "..wwkkkww..",
        ".wwkkkkkww.",
        "wwkkkwkkkww",
        "wkkkw.wkkkw",
        ".www...www."
    ] }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content(hovered, hoverEyes)
            Button(action: cancel) {
                Canvas { context, size in
                    PixelDictator.draw(Self.cross, at: (0, 0), cell: size.width / 11, in: context)
                }
                .frame(width: 13, height: 13)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel dictation")
            .accessibilityLabel("Cancel dictation")
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .accessibilityHidden(!hovered)
            .onHover { inside in hoverEyes = inside ? .screaming : nil }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            if !inside { hoverEyes = nil }
        }
    }
}
