import Foundation

/// Tidies the recognizer output before it is inserted.
enum DictationText {
    /// Collapses the recognizer's whitespace into single spaces.
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
