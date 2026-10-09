import AppKit
import Combine

/// Runs the controller with the terminal console, plus an optional menu-bar icon (`--menu`).
@MainActor
final class DictatorAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences: MicrophonePreferences
    private let controller: DictationController
    private let defaults: UserDefaults
    private let showsMenu: Bool
    private var console: TerminalConsole?
    private var status: NSStatusItem?
    private var updates: AnyCancellable?
    private var interrupt: DispatchSourceSignal?
    private let cancelItem = NSMenuItem(title: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "")
    private let copyItem = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Allow Auto-Paste…", action: #selector(allowAccessibility), keyEquivalent: "")
    private let microphoneMenu = NSMenu()

    init(showsMenu: Bool) {
        self.showsMenu = showsMenu
        // A bare binary has no bundle ID, so its preferences need a suite name of their own.
        defaults = UserDefaults(suiteName: "com.sergey.dictator.terminal") ?? .standard
        preferences = MicrophonePreferences(defaults: defaults)
        controller = DictationController(
            modelsRoot: DictatorPaths.models,
            vadRoot: DictatorPaths.voiceActivityModel,
            recordingsFolder: DictatorPaths.recordings,
            microphonePreferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if showsMenu { buildMenu() }
        updates = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        // Ctrl+C quits like /quit: a dictation in flight is inserted first.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        interrupt = source
        let console = TerminalConsole(controller: controller, preferences: preferences, defaults: defaults)
        console.start()
        self.console = console
        controller.start()
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { preferences.refresh(); refresh() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isBusy else { console?.bye(); return .terminateNow }
        controller.finishForQuit()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, !self.controller.isBusy, timer.isValid else { return }
                timer.invalidate()
                self.console?.bye()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func buildMenu() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        for item in [cancelItem, copyItem] { item.target = self; menu.addItem(item) }
        let microphones = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphones.submenu = microphoneMenu
        menu.addItem(microphones)
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(NSMenuItem(title: "Quit Dictator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        self.status = status
    }

    private func refresh() {
        let phase = controller.phase
        console?.update()
        guard let status else { return }
        let symbol = switch phase {
        case .recording: "waveform"
        case .starting, .transcribing: "ellipsis"
        case .modelsMissing where controller.downloadProgress != nil: "arrow.down.circle"
        case .failed, .modelsMissing: "mic.slash"
        default: "mic"
        }
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictator")
        status.button?.title = phase == .recording ? " \(DictationController.duration(controller.elapsed))" : ""
        status.button?.toolTip = "Dictator · \(controller.status)"
        cancelItem.isHidden = phase != .starting && phase != .recording
        copyItem.isHidden = controller.lastText.isEmpty
        accessibilityItem.isHidden = controller.accessibilityTrusted
        rebuildMicrophoneMenu()
    }

    private func rebuildMicrophoneMenu() {
        microphoneMenu.removeAllItems()
        let system = NSMenuItem(title: "System Default", action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
        system.target = self; system.state = preferences.mode == .systemDefault ? .on : .off
        microphoneMenu.addItem(system)
        for device in preferences.devices where device.isAvailable {
            let item = NSMenuItem(title: device.name, action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = device.uid
            item.state = preferences.mode == .specific && preferences.selectedUID == device.uid ? .on : .off
            microphoneMenu.addItem(item)
        }
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            preferences.mode = .specific; preferences.select(uid)
        } else {
            preferences.mode = .systemDefault
        }
        refresh()
    }

    @objc private func cancelDictation() { controller.cancel() }
    @objc private func copyLast() { controller.copyLastText() }
    @objc private func allowAccessibility() { controller.requestAccessibility() }
}

@main
enum DictatorMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") { print(DictatorVersion.current); return }
        if args.contains("--help") || args.contains("-h") {
            print("""
            Usage: dictator [--background] [--menu]
              Runs until /quit or Ctrl+C. Tap Right Command (or ⌃Space) to start and stop,
              or hold it while you speak. Type / inside for commands (/mic, /copy, /status, …).
              --background  keep running after this tab is closed (output goes to ~/Library/Logs/Dictator.log)
              --stop        stop the copy running in the background
              --menu        also show a menu-bar icon
              --version     print the version
              DICTATOR_MODELS=<folder>  use a speech model folder instead of downloading one
            """)
            return
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard runInstanceCommands(args) else { return }
        let app = NSApplication.shared
        let delegate = DictatorAppDelegate(showsMenu: args.contains("--menu"))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Handles `--stop` and `--background` and keeps two copies from dictating at once.
    /// Returns true when this process should run Dictator itself.
    @MainActor private static func runInstanceCommands(_ args: [String]) -> Bool {
        if args.contains("--stop") {
            print(BackgroundMode.stop() ? "Dictator stopped." : "Dictator is not running.")
            return false
        }
        if let running = BackgroundMode.runningPID {
            print("Dictator is already running (process \(running)). Stop it with: dictator --stop")
            return false
        }
        guard args.contains("--background") else {
            BackgroundMode.claim()
            return true
        }
        do {
            let pid = try BackgroundMode.spawn()
            usleep(500_000)
            guard kill(pid, 0) == 0 else {
                print("Dictator stopped right away. See \(DictatorPaths.backgroundLog.path)")
                return false
            }
            print("""
            Dictator is running in the background. You can close this tab.
            Stop it with: dictator --stop · Log: \(DictatorPaths.backgroundLog.path)
            """)
        } catch {
            print(error.localizedDescription)
        }
        return false
    }
}
