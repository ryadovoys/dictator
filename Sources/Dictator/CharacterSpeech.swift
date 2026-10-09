import Foundation

/// Latest microphone state, read by the UI without queuing audio callbacks on the main actor.
///
/// Voice is judged against the room, not a fixed level: microphones differ by 20 dB and more, and
/// some raise their gain in silence until the room is only 3-5 dB below the voice. So the level
/// is smoothed in dB (a click barely moves it), a noise floor follows the quiet moments, speech starts once the smoothed level stays a few dB
/// above the floor for `onset`, and keeps going while it stays a little above it (hysteresis).
final class DictationLevelInput: @unchecked Sendable {
    /// dB above the floor to start talking, and to keep talking.
    static let startMargin: Float = 3.5
    static let keepMargin: Float = 2.0
    /// Smoothed level above the start margin for this long before the mouth moves.
    static let onset: TimeInterval = 0.1
    /// Smoothing of the level, seconds.
    static let smoothing: Float = 0.12
    /// The floor settles onto quieter moments within `floorFall` seconds but rises at most
    /// `floorRise` dB per second, so steady speech is never mistaken for the room.
    static let floorFall: Float = 0.3
    static let floorRise: Float = 0.4
    private let lock = NSLock()
    private var active = true
    private var level: Float = 0
    private var sampleTime: TimeInterval?
    private var voiceTime: TimeInterval?
    private var smoothed: Float?
    private var floor: Float?
    private var loudSince: TimeInterval?

    /// `level` is 0…1 over -50…-12 dB, as `MicrophoneRecorder.levels` reports it.
    func push(_ level: Float, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard active, sampleTime.map({ time >= $0 }) ?? true else { return }
        let elapsed = Float(sampleTime.map { time - $0 } ?? 0)
        self.level = level
        sampleTime = time

        let decibels = level * 38 - 50
        var smoothed = self.smoothed ?? decibels
        smoothed += (decibels - smoothed) * min(1, elapsed / Self.smoothing)
        self.smoothed = smoothed
        var floor = self.floor ?? smoothed
        floor += smoothed < floor
            ? (smoothed - floor) * min(1, elapsed / Self.floorFall)
            : min(smoothed - floor, Self.floorRise * elapsed)
        self.floor = floor

        let speaking = voiceTime.map { time - $0 < CharacterSpeechAnimation.hold } ?? false
        if speaking {
            loudSince = nil
            if smoothed >= floor + Self.keepMargin { voiceTime = time }
            return
        }
        guard smoothed >= floor + Self.startMargin else { loudSince = nil; return }
        let since = loudSince ?? time
        loudSince = since
        if time - since >= Self.onset { voiceTime = time }
    }

    func snapshot(at time: TimeInterval) -> (level: Float, lastVoice: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        let fresh = sampleTime.map { time - $0 < 0.15 } ?? false
        return (active && fresh ? level : 0, active ? voiceTime : nil)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false; level = 0; sampleTime = nil; voiceTime = nil; smoothed = nil; floor = nil; loudSince = nil
    }
}

/// One clock owns speech activation, the silence grace period and both animation phases.
struct CharacterSpeechAnimation {
    static let hold: TimeInterval = 0.7
    private(set) var isSpeaking = false
    private(set) var now: TimeInterval = 0
    private var speechStarted: TimeInterval = 0
    private var silenceStarted: TimeInterval = 0
    private var initialized = false

    var speechElapsed: TimeInterval { max(0, now - speechStarted) }
    var silenceElapsed: TimeInterval { max(0, now - silenceStarted) }

    mutating func update(lastVoice: TimeInterval?, at time: TimeInterval) {
        now = time
        if !initialized { silenceStarted = time; initialized = true }
        let speaking = lastVoice.map { time >= $0 && time - $0 < Self.hold } ?? false
        if speaking && !isSpeaking { speechStarted = time }
        if !speaking && isSpeaking { silenceStarted = time }
        isSpeaking = speaking
    }
}
