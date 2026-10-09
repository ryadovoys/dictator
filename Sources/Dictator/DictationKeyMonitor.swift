import AppKit
import Carbon

/// Secure keyboard entry (Terminal's "Secure Keyboard Entry", password fields, some password
/// managers) hides every key press from other apps, so Right Command never reaches Dictator
/// while it is on. It can also stay on after the app that set it lost focus.
enum SecureKeyboardEntry {
    /// The app holding it, or nil when key presses reach Dictator.
    static var owner: String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        return pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "Another app"
    }
}

/// Watches the dictation keys: Right Command and ⌃Space (tap or hold), and Esc (cancel).
///
/// Right Command is read from a listen-only event tap, which macOS allows once the terminal
/// has Accessibility or Input Monitoring. Without either, the tap cannot be created;
/// it then polls the keyboard state instead, which some Macs answer without permission, and
/// ⌃Space keeps working everywhere because a registered hot key needs no permission at all.
@MainActor
final class DictationKeyMonitor {
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var polledDown = false
    private var polledChord = false
    private var escapeDown = false
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var rightCommand = DictationKeyGesture()
    private var controlSpace = DictationKeyGesture()
    private var pressGeneration = 0
    private let action: (DictationKeyGesture.Event) -> Void
    private let cancelAction: () -> Void

    private static let rightCommandKey: CGKeyCode = 54
    private static let escapeKey: CGKeyCode = 53

    init(action: @escaping (DictationKeyGesture.Event) -> Void, cancelAction: @escaping () -> Void) {
        self.action = action
        self.cancelAction = cancelAction
    }

    /// True when Right Command is read from key events; false while polling without permission.
    private(set) var usesEvents = false
    /// True when ⌃Space is registered (another app may already own it).
    private(set) var hasControlSpace = false

    static var canListen: Bool { AXIsProcessTrusted() || CGPreflightListenEventAccess() }

    func start() {
        stop()
        if !startEventTap() { startPolling() }
        registerControlSpace()
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
        pollTimer?.invalidate(); pollTimer = nil
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
        hasControlSpace = false
        rightCommand.cancel(); controlSpace.cancel()
        usesEvents = false
    }

    // MARK: - Right Command from an event tap

    private func startEventTap() -> Bool {
        guard Self.canListen else { return false }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DictationKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            let flags = Int(event.flags.rawValue) & 0xFFFF
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let time = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in monitor.handle(type, flags: flags, keyCode: keyCode, at: time) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap; tapSource = source
        usesEvents = true
        return true
    }

    private func handle(_ type: CGEventType, flags: Int, keyCode: CGKeyCode, at time: TimeInterval) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            rightCommandChanged(down: RightCommandFlags.isDown(flags),
                                chord: RightCommandFlags.hasOtherModifier(flags), at: time)
        case .keyDown:
            if rightCommand.isDown { emit(rightCommand.chord()) }
            if keyCode == Self.escapeKey { cancelAction() } // While starting, recording or transcribing.
        default: break
        }
    }

    // MARK: - Right Command by polling (no permission)

    private func startPolling() {
        polledDown = false; polledChord = false; escapeDown = false
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        // Input Monitoring lets the next start use the event tap; macOS asks once per terminal.
        _ = CGRequestListenEventAccess()
    }

    private func poll() {
        let isDown = { (key: CGKeyCode) in CGEventSource.keyState(.combinedSessionState, key: key) }
        let escape = isDown(Self.escapeKey)
        if escape && !escapeDown { cancelAction() }
        escapeDown = escape
        let right = isDown(Self.rightCommandKey)
        // Only scan the rest of the keyboard while Right Command is held: any other key or
        // modifier then makes it a shortcut, not dictation.
        let other = right && (0...127).contains { CGKeyCode($0) != Self.rightCommandKey && isDown(CGKeyCode($0)) }
        guard right != polledDown || other != polledChord else { return }
        polledDown = right; polledChord = other
        rightCommandChanged(down: right, chord: other, at: ProcessInfo.processInfo.systemUptime)
    }

    private func rightCommandChanged(down: Bool, chord: Bool, at time: TimeInterval) {
        if down, !rightCommand.isDown {
            rightCommand.pressed(at: time)
            if chord { emit(rightCommand.chord()) }
            scheduleHold { $0.rightCommand.holdDelayElapsed(at: $1) }
        } else if down, chord {
            emit(rightCommand.chord())
        } else if !down, rightCommand.isDown {
            emit(rightCommand.released(at: time))
        }
    }

    // MARK: - ⌃Space (a registered hot key: works without any permission)

    private func registerControlSpace() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let handler: EventHandlerUPP = { _, event, userInfo in
            guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<DictationKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let time = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in monitor.controlSpaceChanged(pressed: pressed, at: time) }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), handler, types.count, &types,
                                  Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler) == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x4443_5452), id: 1) // "DCTR"
        hasControlSpace = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey), id,
                                              GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    private func controlSpaceChanged(pressed: Bool, at time: TimeInterval) {
        if pressed {
            guard !controlSpace.isDown else { return } // Key repeat.
            controlSpace.pressed(at: time)
            scheduleHold { $0.controlSpace.holdDelayElapsed(at: $1) }
        } else {
            emit(controlSpace.released(at: time))
        }
    }

    // MARK: - Shared

    private func scheduleHold(_ check: @escaping (DictationKeyMonitor, TimeInterval) -> DictationKeyGesture.Event?) {
        pressGeneration += 1
        let generation = pressGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DictationKeyGesture.holdDelay))
            guard let self, self.pressGeneration == generation else { return }
            self.emit(check(self, ProcessInfo.processInfo.systemUptime))
        }
    }

    private func emit(_ event: DictationKeyGesture.Event?) {
        if let event { action(event) }
    }
}
