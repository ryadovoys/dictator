import XCTest
@testable import Dictator

/// Feeds levels every 20 ms (a typical capture buffer) and records when the Dictator talks.
final class CharacterSpeechTests: XCTestCase {
    private struct Run {
        let input = DictationLevelInput()
        var animation = CharacterSpeechAnimation()
        var time: TimeInterval = 0
        var talking: [(time: TimeInterval, on: Bool)] = []
        private var seed: UInt64 = 42

        /// Room noise: `average` with a few dB of wobble, deterministic.
        mutating func noise(_ average: Float, wobble: Float = 0.08) -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(seed >> 40) / Float(1 << 24)
            return max(0, average + (unit * 2 - 1) * wobble)
        }

        mutating func feed(seconds: TimeInterval, _ level: (inout Run, TimeInterval) -> Float) {
            let end = time + seconds
            while time < end - 1e-9 {
                let value = level(&self, time)
                input.push(value, at: time)
                animation.update(lastVoice: input.snapshot(at: time).lastVoice, at: time)
                talking.append((time, animation.isSpeaking))
                time += 0.02
            }
        }

        func talked(from start: TimeInterval, to end: TimeInterval) -> Bool {
            talking.contains { $0.time >= start && $0.time < end && $0.on }
        }
        func talkedThroughout(from start: TimeInterval, to end: TimeInterval) -> Bool {
            talking.filter { $0.time >= start && $0.time < end }.allSatisfy(\.on)
        }
    }

    /// Syllables of ~200 ms with short dips between them.
    private static func speech(_ loud: Float, dip: Float) -> (inout Run, TimeInterval) -> Float {
        { run, time in time.truncatingRemainder(dividingBy: 0.26) < 0.2 ? run.noise(loud, wobble: 0.05) : dip }
    }

    func testRoomNoiseAloneNeverTalks() {
        for average: Float in [0.05, 0.25, 0.45] {
            var run = Run()
            run.feed(seconds: 8) { run, _ in run.noise(average) }
            XCTAssertFalse(run.talked(from: 0, to: 8), "noise at \(average)")
        }
    }

    func testKeyClicksDoNotTalk() {
        var run = Run()
        run.feed(seconds: 6) { run, time in
            time.truncatingRemainder(dividingBy: 0.3) < 0.03 ? 0.9 : run.noise(0.25)
        }
        XCTAssertFalse(run.talked(from: 0, to: 6))
    }

    func testSpeechTalksQuicklyAndThroughShortPauses() {
        var run = Run()
        run.feed(seconds: 2) { run, _ in run.noise(0.25) }
        run.feed(seconds: 2, Self.speech(0.75, dip: 0.3))
        run.feed(seconds: 0.4) { run, _ in run.noise(0.25) } // thinking
        run.feed(seconds: 2, Self.speech(0.75, dip: 0.3))
        run.feed(seconds: 3) { run, _ in run.noise(0.25) }
        XCTAssertFalse(run.talked(from: 0, to: 2))
        XCTAssertTrue(run.talkedThroughout(from: 2.25, to: 6.4), "starts within 250 ms, no glitch in the pause")
        XCTAssertTrue(run.talked(from: 6.4, to: 6.8))
        XCTAssertFalse(run.talked(from: 7.3, to: 9.4), "stops within a second of silence")
    }

    func testQuietMicrophoneStillHearsSoftSpeech() {
        var run = Run()
        run.feed(seconds: 2) { run, _ in run.noise(0.03, wobble: 0.02) }
        run.feed(seconds: 2, Self.speech(0.45, dip: 0.05))
        XCTAssertTrue(run.talkedThroughout(from: 2.3, to: 4))
    }

    /// Right Command, then the first word a moment later.
    func testSpeakingRightAfterTheKeyIsHeard() {
        var run = Run()
        run.feed(seconds: 0.25) { run, _ in run.noise(0.25) }
        run.feed(seconds: 2, Self.speech(0.75, dip: 0.3))
        XCTAssertTrue(run.talkedThroughout(from: 0.5, to: 2.25))
    }

    func testLoudRoomNeedsLouderSpeech() {
        var run = Run()
        run.feed(seconds: 3) { run, _ in run.noise(0.5) }
        run.feed(seconds: 2, Self.speech(0.95, dip: 0.5))
        XCTAssertFalse(run.talked(from: 0, to: 3))
        XCTAssertTrue(run.talked(from: 3, to: 5))
    }

    /// Measured on a real microphone: room about -33 dB (level 0.45), voice -30…-27 dB (0.55…0.6).
    func testNoisyMicrophoneWithQuietVoice() {
        var run = Run()
        run.feed(seconds: 4) { run, _ in run.noise(0.45, wobble: 0.1) }
        run.feed(seconds: 4, Self.speech(0.6, dip: 0.47))
        run.feed(seconds: 3) { run, _ in run.noise(0.45, wobble: 0.1) }
        XCTAssertFalse(run.talked(from: 0, to: 4))
        XCTAssertTrue(run.talked(from: 4, to: 5))
        XCTAssertFalse(run.talked(from: 9.2, to: 11))
    }
}
