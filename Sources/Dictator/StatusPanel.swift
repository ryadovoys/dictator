import AppKit
import SwiftUI

/// One 50 ms UI tick reads only fresh microphone state and advances the character.
@MainActor
final class DictationLevels: ObservableObject {
    static let barCount = 9
    private(set) var input = DictationLevelInput()
    @Published private(set) var animation = CharacterSpeechAnimation()
    @Published private(set) var bars = [CGFloat](repeating: 0, count: barCount)
    private var timer: Timer?

    func start() {
        stop()
        input = DictationLevelInput()
        animation = CharacterSpeechAnimation()
        bars = [CGFloat](repeating: 0, count: Self.barCount)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        input.stop()
        animation = CharacterSpeechAnimation()
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let sample = input.snapshot(at: now)
        animation.update(lastVoice: sample.lastVoice, at: now)
        bars.removeFirst(); bars.append(CGFloat(sample.level))
    }
}

/// The bar row both the wave and the working state draw, so the bubble keeps one size.
private struct BarRow: View {
    let heights: [CGFloat]
    static let minBar: CGFloat = 3, maxBar: CGFloat = 12
    var body: some View {
        HStack(alignment: .center, spacing: Space.s2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Tokens.bubbleText)
                    .frame(width: 2, height: Self.minBar + heights[index] * (Self.maxBar - Self.minBar))
            }
        }
        .frame(height: Self.maxBar)
        .padding(.horizontal, Space.s10)
        .dictationBubble()
    }
}

/// Recording: the bars follow the voice. Esc cancels (`DictationKeyMonitor`).
struct RecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var levels: DictationLevels

    var body: some View {
        BarRow(heights: levels.bars)
            .animation(reduceMotion ? nil : .linear(duration: 0.05), value: levels.bars)
            .accessibilityElement()
            .accessibilityLabel("Recording dictation. Tap Right Command again to insert, or press Escape to cancel.")
    }
}

/// The one capsule every dictation state lives in, next to the caret: wave, working, message.
private struct DictationBubble: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, Space.s6)
            .fixedSize()
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Tokens.bubbleTint))
            }
            .overlay(Capsule().strokeBorder(Tokens.bubbleBorder, lineWidth: 1))
    }
}

extension View {
    fileprivate func dictationBubble() -> some View { modifier(DictationBubble()) }
}

/// Transcribing: the same bars, with a soft wave rolling left to right instead of the voice.
private struct WorkingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            BarRow(heights: (0..<DictationLevels.barCount).map { index in
                CGFloat(0.5 + 0.5 * sin(time * 6 - Double(index) * 0.7)) * 0.6
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Transcribing dictation")
    }
}

/// A short result or error, a few words, on a pixel plaque drawn like the Dictator's speech
/// bubble: white outline, black line, white inside.
private struct MessageBubble: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Tokens.pixelInk)
            .lineLimit(1)
            .padding(.horizontal, Space.s8)
            .padding(.vertical, Space.s4)
            .fixedSize()
            .background { PixelPlaque() }
            .accessibilityElement(children: .combine)
    }
}

/// The speech bubble's frame at any size: its top-left corner, mirrored to the other three,
/// with straight edges between. Cells match the bubble beside the character.
private struct PixelPlaque: View {
    static let cell = Size.indicator / CGFloat(PixelDictator.rows) * PixelDictator.bubbleScale
    /// From `PixelArt.bubbles`: . clear, k black, w white.
    static let corner = ["....ww", "...wwk", "..wwkw", ".wwkww", ".wkwww", ".wkwww"]

    static func grid(columns: Int, rows: Int) -> [String] {
        let size = corner.count
        return (0..<rows).map { y in
            String((0..<columns).map { x -> Character in
                let cx = min(x, columns - 1 - x), cy = min(y, rows - 1 - y)
                switch (cx < size, cy < size) {
                case (true, true): return Array(corner[cy])[cx]
                case (false, true): return Array(corner[cy])[size - 1]
                case (true, false): return Array(corner[size - 1])[cx]
                case (false, false): return "w"
                }
            })
        }
    }

    var body: some View {
        Canvas { context, size in
            let columns = max(12, Int((size.width / Self.cell).rounded()))
            let rows = max(12, Int((size.height / Self.cell).rounded()))
            PixelDictator.draw(Self.grid(columns: columns, rows: rows), at: (0, 0),
                               cell: min(size.width / CGFloat(columns), size.height / CGFloat(rows)), in: context)
        }
    }
}

@MainActor
final class DictationStatusPanel {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    /// The caret the current dictation started at; every later state of it appears there too.
    private var caretRect: CGRect?
    /// The bubble's left edge, fixed by the first state shown at the caret, so a wider message
    /// grows to the right instead of both ways.
    private var leftEdge: CGFloat?
    /// Fed by the recorder while dictation records; drives the indicator's bars.
    let levels = DictationLevels()
    var onCancel: () -> Void = {}

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 60, height: 24)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
    }

    /// The wave, from the tap on: flat until the microphone delivers audio.
    /// Without a caret (no Accessibility), the bubble goes above the mouse pointer instead.
    func showRecording(aboveCaret caretRect: CGRect? = nil) {
        if let anchor = caretRect ?? Self.pointerRect { self.caretRect = anchor; leftEdge = nil }
        levels.start()
        let levels = levels
        present(CancellableCharacterIndicator(cancel: onCancel) { hovered, eyes in
            CharacterRecordingIndicator(levels: levels, showsBubble: !hovered, hoverEyes: eyes)
        })
    }

    func showWorking() {
        levels.stop()
        present(CancellableCharacterIndicator(cancel: onCancel) { _, eyes in CharacterWorkingIndicator(hoverEyes: eyes) })
    }

    func showMessage(_ text: String, hideAfter: TimeInterval = 2.5) {
        levels.stop()
        present(MessageBubble(text: text))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
    }

    func hide() { hideWork?.cancel(); levels.stop(); caretRect = nil; leftEdge = nil; panel.orderOut(nil) }

    private func present<Content: View>(_ view: Content) {
        hideWork?.cancel()
        let host = DictationHostingView(rootView: view)
        panel.contentView = host
        position(size: host.fittingSize)
        panel.orderFrontRegardless()
    }

    /// Above the caret when there is room, else below it; bottom right when there is no caret.
    /// The mouse pointer as a thin caret-like rect, in the same top-left Accessibility coordinates.
    private static var pointerRect: CGRect? {
        guard let top = NSScreen.screens.first?.frame.maxY else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: top - mouse.y - 8, width: 1, height: 16)
    }

    private func position(size: NSSize) {
        let gap: CGFloat = 8
        guard let caretRect, let mainScreen = NSScreen.screens.first else {
            guard let area = NSScreen.main?.visibleFrame else { return }
            panel.setFrame(NSRect(x: area.maxX - size.width - 22, y: area.minY + 22,
                                  width: size.width, height: size.height), display: true)
            return
        }
        // Accessibility coordinates run down from the main display's top edge.
        let caret = NSRect(x: caretRect.minX,
                           y: mainScreen.frame.maxY - caretRect.maxY,
                           width: caretRect.width, height: caretRect.height)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: caret.midX, y: caret.midY)) })
            ?? mainScreen
        let area = screen.visibleFrame
        let left = leftEdge ?? caret.midX - size.width / 2
        leftEdge = left
        let x = min(max(left, area.minX + gap), area.maxX - size.width - gap)
        let above = caret.maxY + gap
        let below = caret.minY - size.height - gap
        let preferredY = above + size.height <= area.maxY - gap ? above : max(area.minY + gap, below)
        let y = min(max(preferredY, area.minY + gap), area.maxY - size.height - gap)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

/// The cancel control works with one click while the text editor keeps keyboard focus.
private final class DictationHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
