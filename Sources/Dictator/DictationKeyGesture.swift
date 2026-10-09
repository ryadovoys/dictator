import Foundation

/// Turns presses of a dictation key (Right Command, ⌃Space) into two gestures:
/// a short tap toggles dictation; holding past `holdDelay` records until release (push-to-talk).
/// Any other key or modifier while it is down makes it a shortcut, never dictation.
struct DictationKeyGesture: Sendable {
    enum Event: Equatable, Sendable { case tap, holdBegan, holdEnded, holdCancelled }

    static let holdDelay: TimeInterval = 0.3

    private(set) var isDown = false
    private var chorded = false
    private var holding = false
    private var pressedAt: TimeInterval = 0

    mutating func pressed(at time: TimeInterval) {
        isDown = true; chorded = false; holding = false; pressedAt = time
    }

    /// Another key or modifier while the key is down (Right Command + C and the like).
    mutating func chord() -> Event? {
        guard isDown, !chorded else { return nil }
        chorded = true
        return holding ? .holdCancelled : nil
    }

    /// The owner calls this `holdDelay` after a press; a still-held clean press becomes a hold.
    mutating func holdDelayElapsed(at time: TimeInterval) -> Event? {
        guard isDown, !chorded, !holding, time - pressedAt >= Self.holdDelay - 0.01 else { return nil }
        holding = true
        return .holdBegan
    }

    mutating func released(at time: TimeInterval) -> Event? {
        defer { cancel() }
        guard isDown, !chorded else { return nil }
        return holding ? .holdEnded : .tap
    }

    mutating func cancel() {
        isDown = false; chorded = false; holding = false; pressedAt = 0
    }
}

/// Reads Right Command from device-specific modifier flags, which tell it apart from left Command.
enum RightCommandFlags {
    static let rightCommandMask = 0x0010
    static let otherModifierMask = 0x206F

    static func isDown(_ flags: Int) -> Bool { flags & rightCommandMask != 0 }
    static func hasOtherModifier(_ flags: Int) -> Bool { flags & otherModifierMask != 0 }
}
