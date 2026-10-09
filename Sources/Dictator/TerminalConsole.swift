import AppKit
import Darwin

/// The terminal interface: dictations and command answers
/// scroll by in the terminal's own history, and a sticky block stays at the bottom with the input
/// box, a live status line and slash-command suggestions. Voice starts from Right Command
/// in any app; this window is for watching and control.
///
/// The bottom block is redrawn in place: before anything is printed above it, the cursor goes to
/// the block's first line and clears to the end of the screen, the message is written (scrolling
/// normally), then the block is drawn again. Keys are read in raw mode.
@MainActor
final class TerminalConsole {
    private struct Command {
        let name: String, usage: String, summary: String
        /// Without the slash: commands work typed either way.
        var bare: String { String(name.dropFirst()) }
    }
    private static let commands = [
        Command(name: "/mic", usage: "/mic [number]", summary: "choose a microphone, or pick number n"),
        Command(name: "/copy", usage: "/copy [n]", summary: "copy the last dictation, or the n-th from the end"),
        Command(name: "/status", usage: "/status", summary: "model, microphone, permissions"),
        Command(name: "/accessibility", usage: "/accessibility", summary: "let Dictator type the text for you"),
        Command(name: "/clear", usage: "/clear", summary: "clear the screen"),
        Command(name: "/quit", usage: "/quit", summary: "quit Dictator (Ctrl+C works too)"),
    ]

    private let controller: DictationController
    private let preferences: MicrophonePreferences
    private let defaults: UserDefaults
    /// A real terminal gets the interactive block; piped or started with `&`, plain lines.
    private let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    private var theme: TerminalTheme

    // Input line.
    private var input: [Character] = []
    private var cursor = 0
    private var pendingBytes: [UInt8] = []
    private var commandHistory: [String] = []
    private var historyIndex: Int?
    private var suggestionIndex = 0

    // Session state.
    private var dictations: [String] = []
    private var seenDictations = 0
    private var lastFailure: String?
    private var wasTrusted = false
    /// The app this was started from (Terminal, iTerm, …): macOS grants Accessibility to it.
    private let terminalApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "your terminal app"

    // Drawing. The block owns the bottom `blockHeight` rows; above it is a scroll region where the
    // history scrolls (lines leaving its top go to the terminal's scrollback as usual).
    /// The input box (3 rows) and one status line under it. Suggestions and the picker float above the box.
    private let blockHeight = 4
    private var picker: MicrophonePicker?
    private var started = false
    /// The history wrapped to the current width; its tail is what the scroll region shows.
    private var historyLines: [String] = []
    /// Suggestion rows currently drawn over the bottom of the history, to restore when they go.
    private var overlayRows = 0
    private var resize: DispatchSourceSignal?
    private var resizeWork: DispatchWorkItem?
    /// Everything printed above the block, so a resize can redraw the screen from scratch.
    private var transcript: [String] = []
    private nonisolated(unsafe) static var savedTerminal = termios()
    private nonisolated(unsafe) static var rawMode = false

    init(controller: DictationController, preferences: MicrophonePreferences, defaults: UserDefaults) {
        self.controller = controller
        self.preferences = preferences
        self.defaults = defaults
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        theme = noColor ? .mono : .dictator
    }

    static let keysHint = "Tap or hold Right Command (or ⌃Space) to dictate · Esc to cancel"

    private static let clipboardModeExplanation = [
        "Clipboard mode · Accessibility is off",
        "You can dictate without it. Press ⌘V to paste the text.",
        "Type /accessibility to enable automatic insertion.",
    ]

    // MARK: - Lifecycle

    func start() {
        guard interactive else {
            var lines = ["Dictator v\(DictatorVersion.current)",
                         "Local speech to text, nothing leaves this Mac",
                         "Audio is deleted after transcription",
                         Self.keysHint]
            if !controller.accessibilityTrusted { lines += [""] + Self.clipboardModeExplanation }
            print(lines.joined(separator: "\n"))
            return
        }
        // Library logs would tear the bottom block; send stderr to a log file instead.
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        freopen(logs.appendingPathComponent("Dictator Terminal.log").path, "a", stderr)
        enterRawMode()
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        signal(SIGWINCH, SIG_IGN)
        // The terminal rewraps old lines when its width changes, so the block's old position is
        // unknown: once resizing settles, clear and replay everything.
        resize.setEventHandler { [weak self] in Task { @MainActor in self?.scheduleReplay() } }
        resize.resume()
        self.resize = resize
        layout()
        started = true
        wasTrusted = controller.accessibilityTrusted
        if !wasTrusted { requestInitialAccessibility() }
        readInput()
    }

    func bye() {
        guard interactive else { print("Dictator stopped."); return }
        // Free the scroll region and leave the cursor under everything.
        write("\u{1B}[r\u{1B}[\(regionBottom + 1);1H\u{1B}[J" + Style.color(theme.muted, "Dictator stopped.") + "\r\n")
        Self.leaveRawMode()
    }

    /// Called on every controller change.
    func update() {
        if controller.dictationCount > seenDictations {
            seenDictations = controller.dictationCount
            dictations.append(controller.lastText)
            emit(dictationEntry())
        }
        if case .failed(let message) = controller.phase {
            if message != lastFailure {
                lastFailure = message
                var reason = message.trimmingCharacters(in: .whitespaces)
                if !reason.isEmpty, !reason.hasSuffix(".") { reason += "." }
                emit(Style.color(theme.error, "✗ ") + DictatorQuips.line(for: message)
                     + (reason.isEmpty ? "" : "\n" + Style.color(theme.muted, "  ⎿ " + reason)))
            }
        } else {
            lastFailure = nil
        }
        if wasTrusted != controller.accessibilityTrusted {
            wasTrusted = controller.accessibilityTrusted
            if interactive, started { layout() }
            if wasTrusted {
                emit(Style.color(theme.success, "✓ ") + "Accessibility is on: text is typed into the field for you.")
            }
        }
        if interactive { if started { drawBlock() } } else { plainStatus() }
    }

    // MARK: - Output above the block

    private func emit(_ text: String) {
        guard interactive else { print(Self.stripANSI(text)); return }
        transcript.append(text)
        if transcript.count > 400 { transcript.removeFirst(transcript.count - 400) }
        guard started else { return }
        appendLines(entryLines(text))
        drawBlock()
    }

    /// Two logo sizes: largest that fits; narrow terminals show the text header alone.
    static let wordmarks: [[String]] = [
        [
            "▀▀▀▀▀▀╗ ▀▀╗▀▀▀▀▀▀▀╗▀▀▀▀▀▀▀▀╗ ▀▀▀▀▀╗ ▀▀▀▀▀▀▀▀╗ ▀▀▀▀▀▀╗ ▀▀▀▀▀▀╗",
            "▀▀╔══▀▀╗▀▀║▀▀╔════╝╚══▀▀╔══╝▀▀╔══▀▀╗╚══▀▀╔══╝▀▀╔═══▀▀╗▀▀╔══▀▀╗",
            "▀▀║  ▀▀║▀▀║▀▀║        ▀▀║   ▀▀▀▀▀▀▀║   ▀▀║   ▀▀║   ▀▀║▀▀▀▀▀▀╔╝",
            "▀▀║  ▀▀║▀▀║▀▀║        ▀▀║   ▀▀╔══▀▀║   ▀▀║   ▀▀║   ▀▀║▀▀╔══▀▀╗",
            "▀▀▀▀▀▀╔╝▀▀║▀▀▀▀▀▀▀╗   ▀▀║   ▀▀║  ▀▀║   ▀▀║   ╚▀▀▀▀▀▀╔╝▀▀║  ▀▀║",
            "╚═════╝ ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝",
        ],
        [
            "▀▀  ▀▀▀ ▀▀▀ ▀▀▀  ▀  ▀▀▀  ▀  ▀▀▀",
            "▀ ▀  ▀  ▀    ▀  ▀▀▀  ▀  ▀ ▀ ▀▀▀",
            "▀▀  ▀▀▀ ▀▀▀  ▀  ▀ ▀  ▀   ▀  ▀ ▀",
        ],
    ]

    /// Logo above the compact four-line introduction, with an empty line at the top.
    private func banner() -> [String] {
        let title = Style.bold(Style.color(theme.accent, "Dictator"))
            + Style.color(theme.muted, " v\(DictatorVersion.current)")
        let subtitle = Style.color(theme.muted, "Local speech to text, nothing leaves this Mac")
        let audioHint = Style.color(theme.muted, "Audio is deleted after transcription")
        let hint = Style.color(theme.muted, Self.keysHint)
        var lines = [""]
        if let mark = Self.wordmarks.first(where: { width - 1 >= ($0.map { Style.width($0) }.max() ?? 0) }) {
            lines += mark.map { Style.bold(Style.color(theme.accent, $0)) } + [""]
        }
        lines += wrapped(title) + wrapped(subtitle) + wrapped(audioHint) + wrapped(hint)
        if !controller.accessibilityTrusted {
            lines.append("")
            for (index, line) in Self.clipboardModeExplanation.enumerated() {
                lines += wrapped(index == 0
                    ? Style.bold(Style.color(theme.warning, line))
                    : Style.color(theme.muted, line))
            }
        }
        return lines + [""]
    }

    private func dictationEntry() -> String {
        let bullet = Style.color(theme.accent, "⏺ ")
        var details: [String] = []
        if let delivery = controller.lastDelivery {
            details = [delivery.outcome, String(format: "%.1f s", delivery.seconds), delivery.microphone]
        }
        let detail = details.isEmpty ? "" : "\n" + Style.color(theme.muted, "  ⎿ " + details.joined(separator: " · "))
        return bullet + controller.lastText + detail
    }

    /// A command's answer: the command echoed, then its lines under ⎿.
    private func answer(_ command: String, _ lines: [String]) {
        var text = Style.bold(command)
        for (index, line) in lines.enumerated() {
            text += "\n" + (index == 0 ? Style.color(theme.muted, "  ⎿ ") : "    ") + line
        }
        emit(text)
    }

    // MARK: - The bottom block

    private var size: (rows: Int, columns: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return (24, 80) }
        return (Int(size.ws_row), Int(size.ws_col))
    }
    private var rows: Int { size.rows }
    private var width: Int { size.columns }
    /// The last row of the history region; the block starts on the next one.
    private var regionBottom: Int { max(3, rows - blockHeight) }

    private func scheduleReplay() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.layout() } }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Lays the whole screen out from memory: history from the top of the scroll region, block
    /// under it. Clears the screen and the scrollback first: the shell's earlier output at start,
    /// and the terminal's rewrapped copy of the old screen after a resize.
    private func layout() {
        write("\u{1B}[r\u{1B}[H\u{1B}[2J\u{1B}[3J")
        historyLines = banner() + transcript.flatMap(entryLines)
        write("\u{1B}[1;\(regionBottom)r")
        overlayRows = 0
        write(paintHistory(1...regionBottom))
        drawBlock()
    }

    /// What history row `row` (1-based, inside the region) shows. Until the history fills the
    /// region it is top-aligned; after that the newest line sits on the region's last row.
    private func historyLine(atRow row: Int) -> String {
        let index = max(0, historyLines.count - regionBottom) + row - 1
        return historyLines.indices.contains(index) ? historyLines[index] : ""
    }

    /// Repaints history rows `rows` from memory (all of them, or those an overlay covered).
    private func paintHistory(_ rows: ClosedRange<Int>) -> String {
        rows.reduce(into: "") { out, row in
            guard row >= 1, row <= regionBottom else { return }
            out += "\u{1B}[\(row);1H\u{1B}[2K" + historyLine(atRow: row)
        }
    }

    /// New history lines enter at the bottom of the region, scrolling older ones up.
    private func appendLines(_ lines: [String]) {
        var out = "\u{1B}[?25l"
        if overlayRows > 0 { out += paintHistory((regionBottom - overlayRows + 1)...regionBottom); overlayRows = 0 }
        for line in lines {
            if historyLines.count < regionBottom {
                // Still filling the region from the top: write on the next free row.
                out += "\u{1B}[\(historyLines.count + 1);1H\u{1B}[2K" + line
            } else {
                // Full: scroll the region up one row and write on its last row.
                out += "\u{1B}[\(regionBottom);1H\n\u{1B}[2K" + line
            }
            historyLines.append(line)
        }
        if historyLines.count > 2000 { historyLines.removeFirst(historyLines.count - 2000) }
        write(out)
    }

    /// An entry as screen lines, with one empty line after it so entries read apart.
    private func entryLines(_ text: String) -> [String] { wrapped(text) + [""] }

    private func wrapped(_ text: String) -> [String] {
        let limit = max(20, width - 1)
        return text.components(separatedBy: "\n").flatMap { Self.wrap($0, limit) }
    }

    private func drawBlock() {
        let columns = max(24, width - 1)
        let border = theme.muted
        // Rules above and below, no sides; input and status start at the left edge.
        let rule = Style.color(border, String(repeating: "─", count: columns))
        var lines: [String] = [rule]

        // Input starts in column 1, scrolled so the cursor stays visible.
        let field = columns
        var start = 0
        while Style.width(String(input[start..<cursor])) > field - 1 { start += 1 }
        var shown = "", used = 0
        for character in input[start...] {
            let w = Style.width(String(character))
            if used + w > field { break }
            shown.append(character); used += w
        }
        let hintText = picker == nil ? "Type / to see commands" : "Choose a microphone above"
        let placeholder = input.isEmpty ? Style.color(theme.muted, Style.fit(hintText, field)) : ""
        lines.append(input.isEmpty ? placeholder : shown)
        lines.append(rule)
        lines.append(statusLine(columns))

        // Suggestions float over the bottom of the history, just above the box.
        let overlay = picker.map { pickerLines($0, columns) } ?? suggestionLines(columns)
        var out = "\u{1B}[?25l"
        if overlayRows > overlay.count {
            out += paintHistory((regionBottom - overlayRows + 1)...(regionBottom - overlay.count))
        }
        for (index, line) in overlay.enumerated() where regionBottom - overlay.count + 1 + index >= 1 {
            out += "\u{1B}[\(regionBottom - overlay.count + 1 + index);1H\u{1B}[2K" + line
        }
        overlayRows = overlay.count
        for (index, line) in lines.enumerated() {
            out += "\u{1B}[\(regionBottom + 1 + index);1H\u{1B}[2K" + line
        }
        // The cursor sits in the input box, after the typed text.
        let column = 1 + Style.width(String(input[start..<cursor]))
        out += "\u{1B}[\(regionBottom + 2);\(column)H\u{1B}[?25h"
        write(out)
    }

    private func statusLine(_ columns: Int) -> String {
        let microphone = controller.microphoneStatus
        // Text is typed into the field; only the exception (no Accessibility) is worth a word.
        let mode = controller.accessibilityTrusted ? "" : " · clipboard"
        let (dot, color, text): (String, TerminalTheme.RGB?, String) = switch controller.phase {
        case .recording: ("●", theme.recording, "Recording \(DictationController.duration(controller.elapsed)) · \(microphone)")
        case .starting: ("◌", theme.warning, "Starting microphone…")
        case .transcribing: ("◌", theme.accent, "Transcribing…")
        case .failed: ("✗", theme.error, "Last attempt failed")
        case .modelsMissing:
            if let progress = controller.downloadProgress {
                ("↓", theme.accent, "Downloading speech model \(Int(progress * 100))% · about 470 MB, once")
            } else {
                ("✗", theme.error, "Speech model not found")
            }
        case .ready:
            controller.modelLoading
                ? ("◌", theme.warning, "Loading speech model…")
                : ("●", theme.ready, "Ready · \(microphone)\(mode)")
        }
        return Style.color(color, dot) + " " + Style.color(theme.muted, Style.fit(text, columns - 2))
    }

    /// One row above the box: what it shows and the command Enter runs.
    private struct Suggestion {
        let label: String, detail: String, run: String
        var active = false
        var isCommand = false
        var isDictation = false
    }

    /// Typed with or without "/": matching commands, and for "mi…"/"mic …" every microphone as
    /// "mic N", so one can be picked without opening the picker. Exact matches come first.
    private var suggestions: [Suggestion] {
        let typed = String(input).trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return [] }
        let query = typed.hasPrefix("/") ? String(typed.dropFirst()) : typed
        let parts = query.split(separator: " ", maxSplits: 1).map(String.init)
        let head = parts.first ?? "", rest = parts.count > 1 ? parts[1] : ""
        var items: [Suggestion] = []
        if rest.isEmpty {
            // /accessibility only matters until it is granted.
            for command in Self.commands where command.bare.hasPrefix(head)
                && !(command.name == "/accessibility" && controller.accessibilityTrusted) {
                items.append(Suggestion(label: command.bare, detail: command.summary, run: command.name, isCommand: true))
            }
        }
        if !head.isEmpty, "mic".hasPrefix(head) || head == "mic" {
            for (index, item) in microphoneItems(refresh: false).enumerated() {
                let label = "mic \(index + 1)"
                guard rest.isEmpty || label.hasPrefix("mic " + rest) else { continue }
                items.append(Suggestion(label: label, detail: item.title, run: "/mic \(index + 1)", active: item.active))
            }
        }
        if !head.isEmpty, "copy".hasPrefix(head) || head == "copy" {
            // The last five dictations, newest first, shown by their opening words.
            // A word after "copy " filters by content.
            for (offset, text) in dictations.suffix(5).reversed().enumerated() {
                guard rest.isEmpty || text.localizedCaseInsensitiveContains(rest) else { continue }
                items.append(Suggestion(label: "copy", detail: "\"" + Self.snippet(text) + "\"",
                                        run: "/copy \(offset + 1)", isDictation: true))
            }
        }
        let exact = items.filter { $0.label == query && !$0.isDictation }
        return exact + items.filter { !($0.label == query && !$0.isDictation) }
    }

    /// The opening of a dictation for a suggestion row: about 40 characters, cut at a word.
    static func snippet(_ text: String, limit: Int = 40) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    private func suggestionLines(_ columns: Int) -> [String] {
        let list = suggestions
        guard !list.isEmpty else { return [] }
        let selected = min(suggestionIndex, list.count - 1)
        // At most six rows; the window follows the selection so ↑↓ never moves into hidden rows.
        let visible = 6
        let first = min(max(0, selected - visible + 1), max(0, list.count - visible))
        return list[first..<min(list.count, first + visible)].enumerated().map { offset, item in
            let index = first + offset
            let label = item.label.padding(toLength: item.isDictation ? 5 : 16, withPad: " ", startingAt: 0)
            let mark = item.active ? Style.color(theme.accent, " ●") : ""
            let text = Style.fit(label + item.detail, columns - 2 - Style.width(mark))
            return index == selected
                ? Style.bold(Style.color(theme.accent, "▸ " + text)) + mark
                : "  " + Style.color(theme.muted, text) + mark
        }
    }

    // MARK: - Keys

    private func readInput() {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 { break }
                let chunk = Array(buffer[0..<count])
                Task { @MainActor [weak self] in self?.feed(chunk) }
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
        thread.name = "Dictator console input"
        thread.start()
    }

    private func feed(_ chunk: [UInt8]) {
        var bytes = pendingBytes + chunk
        pendingBytes = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x03: NSApp.terminate(nil); return                      // Ctrl+C
            case 0x04: if input.isEmpty { NSApp.terminate(nil); return } // Ctrl+D
            case 0x0D, 0x0A: if picker != nil { choosePicked() } else { submit() }
            case 0x7F, 0x08: if cursor > 0 { input.remove(at: cursor - 1); cursor -= 1 }
            case 0x01: cursor = 0                                         // Ctrl+A
            case 0x05: cursor = input.count                               // Ctrl+E
            case 0x15: input.removeSubrange(0..<cursor); cursor = 0       // Ctrl+U
            case 0x0B: input.removeSubrange(cursor..<input.count)         // Ctrl+K
            case 0x17: deleteWord()                                       // Ctrl+W
            case 0x0C: layout()                               // Ctrl+L
            case 0x09: complete()                                         // Tab
            case 0x1B:
                let consumed = escape(Array(bytes[(index + 1)...]))
                index += consumed
            default:
                if byte < 0x20 { break }
                if picker != nil {
                    // Digits pick directly; other typing is ignored while the picker is open.
                    if (0x31...0x39).contains(byte) { choosePicked(Int(byte - 0x30) - 1) }
                    break
                }
                // UTF-8: wait for the rest of a character split across reads.
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                guard index + length <= bytes.count else { pendingBytes = Array(bytes[index...]); index = bytes.count; continue }
                if let text = String(bytes: bytes[index..<(index + length)], encoding: .utf8) {
                    for character in text { input.insert(character, at: cursor); cursor += 1 }
                }
                index += length - 1
                historyIndex = nil; suggestionIndex = 0
            }
            index += 1
        }
        bytes.removeAll()
        drawBlock()
    }

    /// Handles what follows an ESC; returns how many bytes it used.
    private func escape(_ rest: [UInt8]) -> Int {
        guard let first = rest.first else {
            // A lone Esc: close the picker, cancel a recording, otherwise clear the line.
            if picker != nil { closePicker() } else if controller.isBusy { controller.cancel() } else { input = []; cursor = 0 }
            return 0
        }
        guard first == UInt8(ascii: "[") || first == UInt8(ascii: "O") else { return 0 }
        var length = 1
        while length < rest.count, !(0x40...0x7E).contains(rest[length]) { length += 1 }
        guard length < rest.count else { return rest.count }
        let parameters = String(bytes: rest[1..<length], encoding: .ascii) ?? ""
        switch rest[length] {
        case UInt8(ascii: "A"): moveUp()
        case UInt8(ascii: "B"): moveDown()
        case UInt8(ascii: "C"): cursor = min(input.count, cursor + 1)
        case UInt8(ascii: "D"): cursor = max(0, cursor - 1)
        case UInt8(ascii: "H"): cursor = 0
        case UInt8(ascii: "F"): cursor = input.count
        case UInt8(ascii: "~") where parameters == "3":
            if cursor < input.count { input.remove(at: cursor) }
        default: break
        }
        return length + 1
    }

    private func moveUp() {
        if var open = picker { open.selected = max(0, open.selected - 1); picker = open; return }
        if !suggestions.isEmpty { suggestionIndex = max(0, suggestionIndex - 1); return }
        guard !commandHistory.isEmpty else { return }
        let next = max(0, (historyIndex ?? commandHistory.count) - 1)
        historyIndex = next
        setInput(commandHistory[next])
    }

    private func moveDown() {
        if var open = picker { open.selected = min(open.items.count - 1, open.selected + 1); picker = open; return }
        let list = suggestions
        if !list.isEmpty { suggestionIndex = min(list.count - 1, suggestionIndex + 1); return }
        guard let current = historyIndex else { return }
        if current + 1 < commandHistory.count {
            historyIndex = current + 1; setInput(commandHistory[current + 1])
        } else {
            historyIndex = nil; setInput("")
        }
    }

    private func complete() {
        let list = suggestions
        guard !list.isEmpty else { return }
        let item = list[min(suggestionIndex, list.count - 1)]
        setInput(item.label + (item.isCommand ? " " : ""))
        suggestionIndex = 0
    }

    private func deleteWord() {
        var start = cursor
        while start > 0, input[start - 1] == " " { start -= 1 }
        while start > 0, input[start - 1] != " " { start -= 1 }
        input.removeSubrange(start..<cursor); cursor = start
    }

    private func setInput(_ text: String) { input = Array(text); cursor = input.count }

    private func submit() {
        // Enter runs the highlighted suggestion; otherwise the line as typed, "/" optional.
        let list = suggestions
        var line = String(input).trimmingCharacters(in: .whitespaces)
        if !list.isEmpty {
            line = list[min(suggestionIndex, list.count - 1)].run
        } else if !line.isEmpty, !line.hasPrefix("/") {
            line = "/" + line
        }
        setInput(""); suggestionIndex = 0; historyIndex = nil
        guard !line.isEmpty else { return }
        if commandHistory.last != line { commandHistory.append(line) }
        run(line)
    }

    private static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// macOS's own prompt on the first start only; the banner explains clipboard mode.
    private func requestInitialAccessibility() {
        let key = "terminal.accessibilityPrompted"
        if !defaults.bool(forKey: key) {
            defaults.set(true, forKey: key)
            controller.requestAccessibility()
        }

    }

    // MARK: - Commands

    private func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        // Commands without parameters must stand alone: dictated words in this box ("quit smoking",
        // "clear the table") never quit or clear.
        if argument != nil, ["/status", "/accessibility", "/clear", "/quit", "/exit", "/q"].contains(command) {
            answer(line, [Style.color(theme.warning, "Unknown command.") + " Type / to see them."]); return
        }
        switch command {
        case "/mic", "/microphone": microphone(line, argument)
        case "/copy": copy(line, argument)
        case "/status": status(line)
        case "/accessibility":
            if controller.accessibilityTrusted {
                answer(line, [Style.color(theme.success, "On.") + " Text is typed into the field you were in."])
            } else {
                controller.requestAccessibility()
                NSWorkspace.shared.open(Self.accessibilitySettings)
                answer(line, ["Opened Privacy & Security → Accessibility. Turn on " + Style.bold(terminalApp) + ".",
                              Style.color(theme.muted, "If the switch is greyed out, IT has to allow it. Dictator notices by itself.")])
            }
        case "/clear":
            transcript = []
            layout()
        case "/quit", "/exit", "/q": NSApp.terminate(nil)
        default:
            // Words dictated while this window has focus land here; Enter only runs real commands.
            answer(line, [Style.color(theme.warning, "Unknown command.") + " Type / to see them."])
        }
    }

    private struct MicrophonePicker {
        struct Item { let title: String; let uid: String?; let active: Bool }
        var items: [Item]
        var selected: Int
    }

    /// `refresh: false` for suggestions, which redraw on every key: the device list is kept
    /// current by the hardware listener anyway.
    private func microphoneItems(refresh: Bool = true) -> [MicrophonePicker.Item] {
        if refresh { preferences.refresh() }
        let systemName = preferences.devices.first(where: \.isSystemDefault)?.name ?? "none"
        return [MicrophonePicker.Item(title: "System Default (\(systemName))", uid: nil, active: preferences.mode == .systemDefault)]
            + preferences.devices.filter(\.isAvailable).map { device in
                MicrophonePicker.Item(title: device.name, uid: device.uid,
                                      active: preferences.mode == .specific && preferences.selectedUID == device.uid)
            }
    }

    /// `/mic` opens a picker under the box; `/mic 3` picks the third entry straight away.
    private func microphone(_ line: String, _ argument: String?) {
        let items = microphoneItems()
        guard let argument else {
            setPicker(MicrophonePicker(items: items, selected: items.firstIndex(where: \.active) ?? 0))
            return
        }
        guard let index = Int(argument), items.indices.contains(index - 1) else {
            answer(line, [Style.color(theme.warning, "There is no microphone \(argument).") + " Type /mic to choose."]); return
        }
        apply(items[index - 1])
        answer(line, ["Microphone: " + Style.bold(controller.microphoneStatus)])
    }

    private func apply(_ item: MicrophonePicker.Item) {
        if let uid = item.uid { preferences.mode = .specific; preferences.select(uid) } else { preferences.mode = .systemDefault }
    }

    private func choosePicked(_ index: Int? = nil) {
        guard let open = picker else { return }
        let chosen = index ?? open.selected
        guard open.items.indices.contains(chosen) else { return }
        apply(open.items[chosen])
        setPicker(nil)
        answer("/mic", ["Microphone: " + Style.bold(controller.microphoneStatus)])
    }

    private func closePicker() { setPicker(nil) }

    /// The picker floats above the box like the suggestions; closing it restores the history.
    private func setPicker(_ value: MicrophonePicker?) {
        picker = value
        drawBlock()
    }

    private func pickerLines(_ picker: MicrophonePicker, _ columns: Int) -> [String] {
        picker.items.enumerated().map { index, item in
            let marker = item.active ? Style.color(theme.accent, "●") : Style.color(theme.muted, "○")
            let number = Style.color(theme.muted, index < 9 ? "\(index + 1)" : " ")
            let title = Style.fit(item.title, columns - 6)
            return index == picker.selected
                ? Style.color(theme.accent, "▸ ") + marker + " " + number + " " + Style.bold(title)
                : "  " + marker + " " + number + " " + title
        }
    }

    private func copy(_ line: String, _ argument: String?) {
        let back = argument.flatMap(Int.init) ?? 1
        guard back >= 1, back <= dictations.count else {
            answer(line, [Style.color(theme.muted, dictations.isEmpty ? "Nothing dictated yet." : "Only \(dictations.count) so far.")])
            return
        }
        let text = dictations[dictations.count - back]
        FocusInserter.copy(text)
        answer(line, [Style.color(theme.success, "Copied: ") + text])
    }

    private func status(_ line: String) {
        let trusted = controller.accessibilityTrusted
        let rows: [(String, String)] = [
            ("State", controller.status),
            ("Model", "NVIDIA Parakeet TDT 0.6b v3, on this Mac"),
            ("Microphone", controller.microphoneStatus),
            ("Accessibility", trusted ? "On" : "Off, type /accessibility to turn on"),
            ("Right Command", controller.couldListen ? "On"
                : "Needs Accessibility or Input Monitoring for \(terminalApp); ⌃Space works without"),
        ]
        let labelWidth = (rows.map { Style.width($0.0) }.max() ?? 0) + 2
        answer(line, rows.map { Style.color(theme.muted, $0.0.padding(toLength: labelWidth, withPad: " ", startingAt: 0)) + $0.1 })
    }

    // MARK: - Plain mode and terminal plumbing

    private var lastPlain = ""
    private func plainStatus() {
        let text = controller.status
        guard text != lastPlain, controller.phase != .recording || !lastPlain.hasPrefix("Recording") else { return }
        lastPlain = text
        print(text)
    }

    static func wrap(_ line: String, _ limit: Int) -> [String] {
        guard Style.width(line) > limit else { return [line] }
        // Hanging indent: leading spaces plus a leading marker (⏺ ⎿ ›) and its space.
        let plain = stripANSI(line)
        var indent = plain.prefix { $0 == " " }.count
        let rest = plain.dropFirst(indent)
        if let marker = rest.first, "⏺⎿›".contains(marker), rest.dropFirst().first == " " { indent += 2 }
        indent = min(indent, limit / 2)
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = [], current = ""
        for (index, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let candidate = index == 0 ? String(word) : current + " " + word
            if Style.width(candidate) > limit, Style.width(current) > indent, !word.isEmpty {
                lines.append(current)
                current = pad + word
            } else {
                current = candidate
            }
        }
        lines.append(current)
        return lines
    }

    private func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func enterRawMode() {
        guard tcgetattr(STDIN_FILENO, &Self.savedTerminal) == 0 else { return }
        var raw = Self.savedTerminal
        // Keys arrive one by one, unechoed; Ctrl+C is read as a key. Output processing stays on.
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        Self.rawMode = true
        atexit { TerminalConsole.leaveRawMode() }
    }

    nonisolated static func leaveRawMode() {
        guard rawMode else { return }
        rawMode = false
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTerminal)
        FileHandle.standardOutput.write(Data("\u{1B}[?25h".utf8))
    }
}
