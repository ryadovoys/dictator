import Foundation

/// Where Dictator keeps its files. Everything lives in one Application Support folder.
enum DictatorPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dictator Terminal", isDirectory: true)

    /// The speech model. `DICTATOR_MODELS` points at a copy made elsewhere, for networks that
    /// block the download.
    static var models: URL {
        if let custom = ProcessInfo.processInfo.environment["DICTATOR_MODELS"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return support.appendingPathComponent("Models", isDirectory: true)
    }

    static let voiceActivityModel = support.appendingPathComponent("VAD", isDirectory: true)
    /// Recordings in progress; each is deleted once it is transcribed or cancelled.
    static let recordings = support.appendingPathComponent("Recordings", isDirectory: true)
    static let pidFile = support.appendingPathComponent("dictator.pid")

    static let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    /// Output of a copy started with `--background`.
    static let backgroundLog = logs.appendingPathComponent("Dictator.log")
    /// Library logging while the interactive console owns the screen.
    static let consoleLog = logs.appendingPathComponent("Dictator Terminal.log")
}
