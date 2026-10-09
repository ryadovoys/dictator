import Foundation

/// The apology printed when a dictation fails: a line in character that fits the kind of
/// failure, never the same twice in a row. The plain reason follows it.
enum DictatorQuips {
    enum Kind: CaseIterable { case silence, microphone, permission, model, other }

    static let lines: [Kind: [String]] = [
        .silence: [
            "The people have chosen silence. A historic consensus, but there is nothing to type. Speak up.",
            "The listening ministry worked a full shift and heard nothing. They have been commended. Try again.",
            "Not a single word reached the palace. The palace remains optimistic. Once more, louder.",
            "Silence has been noted and filed. Filing it was the easy part. Please speak.",
            "Official reports describe your speech as very quiet. Unofficial reports describe it as absent. Try again.",
            "The census found zero words in that recording. A recount is available: speak up.",
        ],
        .microphone: [
            "The microphone has left on a voluntary vacation. Appoint a replacement with /mic.",
            "The microphone failed to report for duty. A loyal alternative is waiting in /mic.",
            "The microphone is in exile. Bring it back, or choose a successor with /mic.",
            "The ministry of audio is temporarily closed for reorganization. Try another microphone with /mic.",
            "The microphone has resigned for personal reasons. Its replacement can be chosen with /mic.",
        ],
        .permission: [
            "The microphone is waiting for its papers. Allow microphone access for your terminal in System Settings.",
            "Your voice was stopped at the border without a permit. Allow microphone access in System Settings.",
        ],
        .model: [
            "The scribes are still in their morning briefing. One moment.",
            "The ministry of transcription opens shortly. The queue is orderly. Try again in a moment.",
            "The speech model is still putting on its uniform. It will be ready for the parade shortly.",
        ],
        .other: [
            "A minor setback, already removed from the official record. Try again.",
            "The decree was lost in the mail. The postal service has been reminded of its duties. Try again.",
            "A small irregularity in the transcription office. It has been investigated, and nobody is to blame. Try again.",
            "This failure will not appear in any history book. Please try again.",
            "The palace experienced a brief hiccup. Officially, it was a celebration. Try again.",
        ],
    ]

    static func kind(of message: String) -> Kind {
        let text = message.lowercased()
        if text.hasPrefix("no speech") { return .silence }
        if text.hasPrefix("microphone access") || text.contains("restricted") { return .permission }
        if ["not sending audio", "no microphone audio", "disconnected", "not connected", "could not be opened",
            "did not start", "unavailable", "no microphone you chose", "could not be recorded"].contains(where: text.contains) {
            return .microphone
        }
        if text.contains("model") { return .model }
        return .other
    }

    private nonisolated(unsafe) static var last: String?

    /// A line for this failure, different from the previous one.
    static func line(for message: String) -> String {
        let pool = lines[kind(of: message)] ?? lines[.other]!
        let choice = pool.filter { $0 != last }.randomElement() ?? pool[0]
        last = choice
        return choice
    }
}

