import Foundation

/// Pupils sit below the existing squint, on the same whole-cell grid as the head.
enum PixelEyePose: Int, CaseIterable {
    case squint, forward, left, blink, screaming
}

extension PixelArt {
    /// Eye states drawn over the closed-mouth face. Only the eye window differs between them,
    /// so switching states never moves the head, outline or mouth.
    static let restingFaces: [[String]] = [
        faces[0],
        restingFace(eyes: [ // forward
            "wwwwwwwwwwwwwwwwwwkw",
            "wwwwkkwwwwwwwwwwwkkk",
            "wwwwwkkkwwwwwwwwkkkk",
            "wwwwwwkkkkwwkwwkkwwk",
            "wwwwwwwwkkkkkkkkwwkk",
            "wwkkkkkkkkkkwkkkkkkk",
            "wwwwwkkwwwwwwkwkkwwk",
            "wwwwwkkwwwwwwwwkkwwk",
            "wwwwwwwwwwwwwwkwwwwk",
            "wwwwwkkkkwwwwwwkkwkk",
            "wwwwwwwwwwwwwwwwkwwk",
        ]),
        restingFace(eyes: [ // left
            "wwwwwwwwwwwwwwwwwwkw",
            "wwwwkkwwwwwwwwwwwkkk",
            "wwwwwkkkwwwwwwwwkkkk",
            "wwwwwwkkkkwwkwwkkwwk",
            "wwwwwwwwkkkkkkkkwwkk",
            "wwkkkkkkkkkkwkkkkkkk",
            "wwwwkkwwwwwwwkkkwwwk",
            "wwwwkkwwwwwwwwkkwwwk",
            "wwwwwwwwwwwwwwkwwwwk",
            "wwwwwkkkkwwwwwwkkwkk",
            "wwwwwwwwwwwwwwwwkwwk",
        ]),
        restingFace(eyes: [ // blink
            "wwwwwwwwwwwwwwwwwwkw",
            "wwwwkkwwwwwwwwwwwkkk",
            "wwwwwkkkwwwwwwwwkkkk",
            "wwwwwwkkkkwwkwwkkwwk",
            "wwwwwwwwkkkkkkkkwwwk",
            "wwwwwwwwwwwwwkwwwwwk",
            "wwwkkkkkkkwwwkwkkkkk",
            "wwwwwwwwwwwwwwwwwwwk",
            "wwwwwwwwwwwwwwkkwwwk",
            "wwwwwkkkkwwwwwwkkwkk",
            "wwwwwwwwwwwwwwwwkwwk",
        ]),
    ]

    private static func restingFace(eyes: [String]) -> [String] {
        var grid = faces[0].map(Array.init)
        for (y, row) in eyes.enumerated() {
            for (x, cell) in row.enumerated() {
                grid[18 + y][15 + x] = cell
            }
        }
        return grid.map { String($0) }
    }
}

enum CharacterEyeAnimation {
    static func working(elapsed: TimeInterval, reduceMotion: Bool) -> PixelEyePose {
        guard !reduceMotion else { return .forward }
        return max(0, elapsed).truncatingRemainder(dividingBy: 1.5) < 1 ? .forward : .left
    }

    static func silent(elapsed: TimeInterval, reduceMotion: Bool) -> PixelEyePose {
        guard !reduceMotion else { return .forward }
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 12.3)
        let blinking = [3.4, 7.8, 12.1].contains { phase >= $0 && phase < $0 + 0.16 }
        return blinking ? .blink : .forward
    }
}
