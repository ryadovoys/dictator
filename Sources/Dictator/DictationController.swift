import AppKit
import Combine
import DictationKit

enum DictationPhase: Equatable {
    case ready, modelsMissing, starting, recording, transcribing, failed(String)
}

@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var phase: DictationPhase = .ready
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var accessibilityTrusted = FocusInserter.isTrusted
    @Published private(set) var lastText = ""
    /// Successful dictations this session; lets the terminal tell a repeat of the same words apart.
    @Published private(set) var dictationCount = 0
    /// How the newest dictation went, for the terminal's history: where the text went, how long
    /// the recording was, and which microphone heard it. Set together with `dictationCount`.
    private(set) var lastDelivery: (outcome: String, seconds: TimeInterval, microphone: String)?
    /// What was said, when the newest dictation was inserted as a translation of it.
    private(set) var lastOriginal: String?
    /// The language each dictation is translated into (`/translate`), nil to insert it as spoken.
    var translationTarget: String?
    @Published private(set) var modelLoading = false
    @Published private(set) var modelLoaded = false
    @Published private(set) var activeMicrophoneName: String?
    /// The app whose secure keyboard entry is hiding Right Command from Dictator, if any.
    @Published private(set) var secureInputOwner: String?
    /// 0…1 while the speech model downloads, nil otherwise.
    @Published private(set) var downloadProgress: Double?

    /// How long a started microphone may stay silent at the file level before it counts as broken.
    /// Real silence still writes frames; zero frames means the device is not delivering audio.
    static let noAudioTimeout: TimeInterval = 2

    private var recorder = MicrophoneRecorder()
    private var transcriber: LocalTranscriber
    private let transcription = DictationTranscription()
    private var transcriptionAudio: URL?
    private var translation: DictationTranslator.Outcome?
    private var modelGeneration = UUID()
    private let panel = DictationStatusPanel()
    let microphonePreferences: MicrophonePreferences
    private var keyMonitor: DictationKeyMonitor?
    private var elapsedTimer: Timer?
    private var accessTimer: Timer?
    private var modelTask: Task<Void, Error>?
    private var microphoneUpdates: AnyCancellable?
    private var focusTarget: FocusSnapshot?
    private var startAttempt = UUID()
    private var lastExternalPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    /// The current recording was started by holding a key; releasing it stops the recording.
    private var heldRecording = false
    /// Whether Right Command could be read from key events at the last check.
    @Published private(set) var couldListen = DictationKeyMonitor.canListen
    let recordingsFolder: URL

    init(modelsRoot: URL, vadRoot: URL?, recordingsFolder: URL, microphonePreferences: MicrophonePreferences) {
        transcriber = LocalTranscriber(modelsRoot: modelsRoot, vadRoot: vadRoot)
        self.microphonePreferences = microphonePreferences
        self.recordingsFolder = recordingsFolder
        // Audio is never kept after a dictation; clear anything a crash left behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        leftovers.filter { $0.lastPathComponent.hasPrefix("dictation-") && $0.pathExtension == "caf" }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        phase = transcriber.modelsAreInstalled ? .ready : .modelsMissing
        panel.onCancel = { [weak self] in self?.cancel() }
        microphoneUpdates = microphonePreferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func start() {
        guard keyMonitor == nil else { return }
        updateExternalApplication(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.updateExternalApplication(app) }
        }
        // DICTATOR_NO_HOTKEYS: test runs must not react to keys meant for a copy already running.
        if ProcessInfo.processInfo.environment["DICTATOR_NO_HOTKEYS"] == nil {
            keyMonitor = DictationKeyMonitor(action: { [weak self] in self?.handleKey($0) },
                                        cancelAction: { [weak self] in self?.cancel() })
            keyMonitor?.start()
        }
        accessTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibility()
                if self?.phase == .modelsMissing { self?.refreshModels() }
            }
        }
        RunLoop.main.add(accessTimer!, forMode: .common)
        if transcriber.modelsAreInstalled { preloadModel() } else { downloadModel() }
    }

    private func downloadModel() {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        Task {
            do {
                try await transcriber.download { fraction in
                    Task { @MainActor in
                        // Callbacks arrive out of order and per phase; progress only ever moves forward.
                        if let current = self.downloadProgress, fraction > current { self.downloadProgress = fraction }
                    }
                }
                downloadProgress = nil
                refreshModels()
            } catch {
                downloadProgress = nil
                fail("The speech model could not be downloaded: \(error.localizedDescription)", audio: nil)
            }
        }
    }

    var isBusy: Bool { phase == .starting || phase == .recording || phase == .transcribing }

    /// Tap: start or stop. Hold: record while the key is down (push-to-talk). A shortcut typed
    /// with the key after a hold began (Right Command + C) drops that recording.
    func handleKey(_ event: DictationKeyGesture.Event) {
        switch event {
        case .tap:
            heldRecording = false
            toggle()
        case .holdBegan:
            // Holding during a tapped recording just stops it on release.
            guard !isBusy else { heldRecording = phase == .recording || phase == .starting; return }
            toggle()
            heldRecording = phase == .starting
        case .holdEnded:
            guard heldRecording else { return }
            heldRecording = false
            if phase == .recording { finishRecording() } else if phase == .starting { stopWhenStarted = true }
        case .holdCancelled:
            guard heldRecording else { return }
            heldRecording = false
            cancel()
        }
    }

    /// A hold released while the microphone was still starting: stop as soon as it records.
    private var stopWhenStarted = false

    func toggle() {
        // A failed attempt is recoverable: the next tap starts a new recording.
        if isFailed || phase == .modelsMissing { refreshModels() }
        switch phase {
        case .ready: beginRecording()
        case .recording: finishRecording()
        case .modelsMissing where downloadProgress != nil:
            panel.showMessage("Model is still downloading", hideAfter: 3)
        case .modelsMissing:
            panel.showMessage("Downloading the model", hideAfter: 3)
            downloadModel()
        default: break
        }
    }

    func cancel() {
        // Idle, Esc only dismisses a message that is still showing.
        guard isBusy else { panel.hide(); return }
        let wasTranscribing = phase == .transcribing
        startAttempt = UUID() // Ignore microphone startup that is still in flight.
        transcription.cancel()
        elapsedTimer?.invalidate(); elapsedTimer = nil
        let abandonedRecorder = recorder
        recorder = MicrophoneRecorder()
        // stop() is already running on the old recorder during transcription. Do not race it.
        // AVCaptureSession shutdown must never block the main thread or the cancel control.
        if !wasTranscribing { Task.detached { abandonedRecorder.cancel() } }
        if let audio = transcriptionAudio { try? FileManager.default.removeItem(at: audio) }
        transcriptionAudio = nil
        if wasTranscribing {
            // A stuck Core ML call must not hold the next dictation behind the same actor.
            modelGeneration = UUID()
            modelTask?.cancel(); modelTask = nil
            transcriber = LocalTranscriber(modelsRoot: transcriber.modelsRoot, vadRoot: transcriber.vadRoot)
            modelLoaded = false; modelLoading = false
        }
        focusTarget = nil; activeMicrophoneName = nil
        heldRecording = false; stopWhenStarted = false
        elapsed = 0; phase = .ready
        panel.hide()
    }

    /// Lets an in-flight recording or transcription finish before quitting.
    func finishForQuit() {
        keyMonitor?.stop()
        if phase == .recording { finishRecording() } else if phase == .starting { cancel() }
    }

    func refreshModels() {
        guard !isBusy else { return }
        phase = transcriber.modelsAreInstalled ? .ready : .modelsMissing
        if phase == .ready, !modelLoaded { preloadModel() }
    }

    func requestAccessibility() {
        FocusInserter.requestTrust()
        refreshAccessibility()
    }

    func copyLastText() {
        guard !lastText.isEmpty else { return }
        FocusInserter.copy(lastText)
        panel.showMessage("Copied")
    }

    var status: String {
        switch phase {
        case .ready:
            if modelLoading { return "Loading the speech model…" }
            if let secureInputOwner { return "Right Command is blocked: \(secureInputOwner) has Secure Keyboard Entry on" }
            // Without Accessibility or Input Monitoring, Right Command may not be seen; ⌃Space always is.
            return couldListen ? "Ready · tap or hold Right Command" : "Ready · tap or hold ⌃Space"
        case .modelsMissing:
            if let downloadProgress { return "Downloading the speech model… \(Int(downloadProgress * 100))%" }
            return "Speech model not found."
        case .starting: return "Starting microphone…"
        case .recording: return "Recording \(Self.duration(elapsed))"
        case .transcribing: return "Transcribing…"
        case .failed(let message): return message
        }
    }
    var isFailed: Bool { if case .failed = phase { return true }; return false }
    var canToggle: Bool { phase == .ready || phase == .recording || phase == .modelsMissing || isFailed }
    var microphoneStatus: String { activeMicrophoneName ?? microphonePreferences.activeName }

    private func beginRecording() {
        guard transcriber.modelsAreInstalled else { phase = .modelsMissing; return }
        let attempt = UUID()
        let recorder = recorder // A late startup belongs only to this recording.
        startAttempt = attempt
        stopWhenStarted = false
        let frontmost = NSWorkspace.shared.frontmostApplication
        let preferredPID: pid_t? = if let frontmost,
            frontmost.bundleIdentifier == Bundle.main.bundleIdentifier || frontmost.activationPolicy == .regular {
            frontmost.processIdentifier
        } else {
            lastExternalPID
        }
        focusTarget = FocusInserter.capture(preferredPID: preferredPID)
        phase = .starting
        panel.showRecording(nearCaret: focusTarget?.caretRect)
        Task {
            do {
                try await DictationMicrophonePermission.requireAccess()
                guard startAttempt == attempt, phase == .starting else { return }
                let microphone = try microphonePreferences.resolveForRecording()
                // Each recording owns its input. Late callbacks cannot revive a stopped indicator.
                let input = panel.levels.input
                recorder.onLevel = { level in input.push(level) }
                _ = try await recorder.start(in: recordingsFolder, deviceUID: microphone.uid)
                guard startAttempt == attempt, phase == .starting else { return }
                activeMicrophoneName = microphone.name
                elapsed = 0; phase = .recording
                if modelTask == nil { preloadModel() }
                startElapsedTimer(attempt: attempt)
                if stopWhenStarted { stopWhenStarted = false; finishRecording() }
            } catch {
                guard startAttempt == attempt else { return }
                fail(error.localizedDescription, audio: nil)
            }
        }
    }

    private func startElapsedTimer(attempt: UUID) {
        let started = Date()
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(started: started, attempt: attempt) }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func tick(started: Date, attempt: UUID) {
        guard phase == .recording, startAttempt == attempt else { return }
        elapsed = Date().timeIntervalSince(started)
        // Say so right away instead of letting the user talk into a dead microphone.
        if elapsed >= Self.noAudioTimeout, recorder.capturedFrames == 0 {
            let name = activeMicrophoneName ?? "The microphone"
            let abandonedRecorder = recorder
            recorder = MicrophoneRecorder()
            Task.detached { abandonedRecorder.cancel() }
            fail("\(name) is not sending audio. Reconnect it or choose another microphone.", audio: nil)
        }
    }

    private func finishRecording() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        let seconds = elapsed, microphone = microphoneStatus
        let target = focusTarget, translateTo = translationTarget
        let recorder = recorder, transcriber = transcriber, modelTask = modelTask
        focusTarget = nil; translation = nil
        phase = .transcribing
        panel.showWorking()
        transcription.start(recognize: {
            // Device shutdown can stall; keep hover/cancel and the next recording responsive.
            let audio = try await Task.detached { try recorder.stop() }.value
            do {
                try Task.checkCancellation()
                self.transcriptionAudio = audio
                try await modelTask?.value
                try Task.checkCancellation()
                let text = try await transcriber.transcribe(audio)
                guard let translateTo else { return text }
                let translation = await DictationTranslator.translate(text, to: translateTo)
                try Task.checkCancellation()
                self.translation = translation
                return translation.text
            } catch {
                if Task.isCancelled { try? FileManager.default.removeItem(at: audio) }
                throw error
            }
        }, deliver: { text in
            try await FocusInserter.deliver(text, to: target)
        }, completed: { text, result in
            if let audio = self.transcriptionAudio { try? FileManager.default.removeItem(at: audio) }
            self.transcriptionAudio = nil
            let translation = self.translation
            self.translation = nil
            self.lastText = text
            self.lastOriginal = translation?.original
            let note = translation?.note.map { " · " + $0 } ?? ""
            self.lastDelivery = (Self.outcome(result) + note, seconds, microphone)
            self.dictationCount += 1
            self.phase = .ready
            self.activeMicrophoneName = nil
            switch result {
            case .inserted: self.panel.hide()
            case .copiedFocusChanged: self.panel.showMessage("Field changed, copied", hideAfter: 4)
            case .copiedNoAccessibility: self.panel.showMessage("Copied · ⌘V to paste", hideAfter: 4)
            case .copiedPasteUnavailable, .copiedPasteUnconfirmed:
                self.panel.showMessage("Copied to clipboard", hideAfter: 4)
            }
        }, failed: { error in
            let audio = self.transcriptionAudio
            self.transcriptionAudio = nil; self.translation = nil
            self.fail(error.localizedDescription, audio: audio)
        })
    }

    static func outcome(_ result: DeliveryResult) -> String {
        switch result {
        case .inserted: return "inserted"
        case .copiedFocusChanged: return "copied, the field changed"
        case .copiedNoAccessibility, .copiedPasteUnavailable, .copiedPasteUnconfirmed: return "copied, press ⌘V"
        }
    }

    private func fail(_ message: String, audio: URL?) {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        if let audio { try? FileManager.default.removeItem(at: audio) }
        focusTarget = nil; phase = .failed(message)
        activeMicrophoneName = nil
        // A few words in the bubble; the full message goes to the terminal.
        panel.showMessage(Self.shortFailure(message), hideAfter: 4)
    }

    static func shortFailure(_ message: String) -> String {
        if message.hasPrefix("No speech") { return "Your voice was not heard" }
        if message.contains("not sending audio") || message.hasPrefix("No microphone audio") { return "Microphone is silent" }
        if message.hasPrefix("Microphone access") { return "Allow microphone access" }
        if message.contains("model") { return "Model not ready" }
        if message.localizedCaseInsensitiveContains("microphone") || message.contains("disconnected") {
            return "Microphone unavailable"
        }
        return "Not inserted"
    }

    private func refreshAccessibility() {
        let owner = SecureKeyboardEntry.owner
        if secureInputOwner != owner { secureInputOwner = owner }
        let value = FocusInserter.isTrusted, listen = DictationKeyMonitor.canListen
        if accessibilityTrusted != value { accessibilityTrusted = value }
        // Reinstalling makes the key monitor observe newly granted permissions. Not mid-dictation:
        // that would lose a held key's release; the next check after it picks the change up.
        guard couldListen != listen, !isBusy else { return }
        couldListen = listen
        keyMonitor?.start()
    }

    private func preloadModel() {
        guard transcriber.modelsAreInstalled, !modelLoaded, !modelLoading else { return }
        modelLoading = true
        let generation = modelGeneration
        let transcriber = transcriber
        let task = Task { try await transcriber.prepare() }
        modelTask = task
        Task {
            do {
                try await task.value
                guard modelGeneration == generation else { return }
                modelLoaded = true; modelLoading = false
            } catch {
                guard modelGeneration == generation else { return }
                modelTask = nil; modelLoading = false
                if !isBusy { fail(error.localizedDescription, audio: nil) }
            }
        }
    }

    private func updateExternalApplication(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular else { return }
        lastExternalPID = app.processIdentifier
    }

    static func duration(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", max(0, Int(seconds)) / 60, max(0, Int(seconds)) % 60)
    }
}
