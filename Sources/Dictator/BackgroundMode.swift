import Foundation

/// `dictator --background` starts a copy detached from the terminal tab, so the tab can be closed;
/// `dictator --stop` ends it. The copy is a child of the terminal app, so it keeps the terminal's
/// Microphone and Accessibility permissions. One running copy at a time, tracked by a PID file.
enum BackgroundMode {
    private static let pidFile = DictatorPaths.pidFile
    private static let log = DictatorPaths.backgroundLog

    /// The PID of another running Dictator, if any.
    static var runningPID: pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != getpid(), kill(pid, 0) == 0, isDictator(pid) else { return nil }
        return pid
    }

    /// Records this process as the running copy; removed again on exit.
    static func claim() {
        try? FileManager.default.createDirectory(at: DictatorPaths.support, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)
        atexit { BackgroundMode.release() }
    }

    static func release() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid() else { return }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Starts a detached copy with the same arguments minus `--background`. Returns its PID.
    static func spawn() throws -> pid_t {
        guard let executable = Bundle.main.executablePath else { throw DictationError.message("Cannot find the Dictator binary.") }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A session of its own: closing the tab (SIGHUP to the tab's session) does not reach it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let arguments = [executable] + CommandLine.arguments.dropFirst().filter { $0 != "--background" }
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard status == 0 else { throw DictationError.message("Could not start in the background: \(String(cString: strerror(status))).") }
        return pid
    }

    /// Asks the running copy to quit (as Ctrl+C would: a dictation in flight finishes first).
    static func stop() -> Bool {
        guard let pid = runningPID else { return false }
        kill(pid, SIGINT)
        for _ in 0..<100 where kill(pid, 0) == 0 { usleep(100_000) }
        return true
    }

    private static func isDictator(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent.lowercased() == "dictator"
    }
}
