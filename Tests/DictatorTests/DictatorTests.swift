import AVFoundation
import CoreAudio
import FluidAudio
import XCTest
@testable import Dictator
import DictationKit

final class DictationKeyGestureTests: XCTestCase {
    func testShortPressIsATapOnRelease() {
        var gesture = DictationKeyGesture()
        gesture.pressed(at: 10)
        XCTAssertNil(gesture.holdDelayElapsed(at: 10.1))
        XCTAssertEqual(gesture.released(at: 10.2), .tap)
        XCTAssertNil(gesture.released(at: 10.3))
    }

    func testHoldStartsAfterDelayAndEndsOnRelease() {
        var gesture = DictationKeyGesture()
        gesture.pressed(at: 1)
        XCTAssertEqual(gesture.holdDelayElapsed(at: 1 + DictationKeyGesture.holdDelay), .holdBegan)
        XCTAssertEqual(gesture.released(at: 4), .holdEnded)
    }

    func testChordIsNeverDictation() {
        var gesture = DictationKeyGesture()
        gesture.pressed(at: 1)
        XCTAssertNil(gesture.chord()) // Right Command + C before the hold began.
        XCTAssertNil(gesture.holdDelayElapsed(at: 1.5))
        XCTAssertNil(gesture.released(at: 1.6))
    }

    func testChordAfterHoldCancelsIt() {
        var gesture = DictationKeyGesture()
        gesture.pressed(at: 1)
        XCTAssertEqual(gesture.holdDelayElapsed(at: 1.4), .holdBegan)
        XCTAssertEqual(gesture.chord(), .holdCancelled)
        XCTAssertNil(gesture.released(at: 2))
    }

    func testRightCommandFlags() {
        XCTAssertTrue(RightCommandFlags.isDown(0x0010))
        XCTAssertFalse(RightCommandFlags.isDown(0x0008)) // Left Command.
        XCTAssertTrue(RightCommandFlags.hasOtherModifier(0x0012))
        XCTAssertFalse(RightCommandFlags.hasOtherModifier(0x0010))
    }
}

final class LocalTranscriberTests: XCTestCase {
    func testSpeechRangeIsPaddedAndRejectsNoise() {
        let rate = Double(VadManager.sampleRate)
        XCTAssertNil(LocalTranscriber.speechRange([], sampleCount: 48_000))
        // A 0.1 s click is not speech.
        XCTAssertNil(LocalTranscriber.speechRange([VadSegment(startTime: 1, endTime: 1.1)], sampleCount: 48_000))
        let range = LocalTranscriber.speechRange(
            [VadSegment(startTime: 1, endTime: 1.5), VadSegment(startTime: 2, endTime: 2.5)], sampleCount: 48_000)
        XCTAssertEqual(range, Int(0.7 * rate)..<Int(2.8 * rate))
    }

    func testTextCleanupPreservesWordsAndPunctuation() {
        XCTAssertEqual(LocalTranscriber.clean("  Hello,\n\nworld.  "), "Hello, world.")
        XCTAssertEqual(LocalTranscriber.clean("Привет   мир"), "Привет мир")
        XCTAssertEqual(LocalTranscriber.clean(" \n "), "")
    }

    func testModelsLiveInDictatorsOwnFolder() {
        XCTAssertTrue(DictatorPaths.support.path.hasSuffix("/Library/Application Support/Dictator Terminal"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(LocalTranscriber(modelsRoot: root).modelsAreInstalled)
    }

    func testMissingModelsFailWithoutCreatingOrDownloadingAnything() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = LocalTranscriber(modelsRoot: root)
        do { try await transcriber.prepare(); XCTFail("Expected missing model error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("speech model is not installed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let loadCount = await transcriber.modelLoadCount
        XCTAssertEqual(loadCount, 0)
    }

    func testVoiceActivityRejectsNoiseAndKeepsSpeech() async throws {
        guard let models = ProcessInfo.processInfo.environment["LD_TEST_MODELS"],
              let vad = ProcessInfo.processInfo.environment["LD_TEST_VAD"] else {
            throw XCTSkip("Set LD_TEST_MODELS and LD_TEST_VAD to run against cached models.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-vad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcriber = LocalTranscriber(modelsRoot: URL(fileURLWithPath: models, isDirectory: true),
                                           vadRoot: URL(fileURLWithPath: vad, isDirectory: true))
        // Two seconds of quiet room noise: the kind of clip Parakeet hears "Yeah" in.
        let noise = folder.appendingPathComponent("noise.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        for index in 0..<32_000 { buffer.floatChannelData![0][index] = Float.random(in: -0.01...0.01) }
        try AVAudioFile(forWriting: noise, settings: format.settings).write(from: buffer)
        do { _ = try await transcriber.transcribe(noise); XCTFail("Noise must not become text") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("No speech")) }
        let speech = folder.appendingPathComponent("speech.aiff")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-o", speech.path, "[[slnc 1500]] Dictation keeps the words. [[slnc 1500]]"]
        try process.run(); process.waitUntilExit()
        let text = try await transcriber.transcribe(speech)
        XCTAssertTrue(text.lowercased().contains("keeps the words"), text)
    }

    func testPersistentLocalModelTranscribesTwoSyntheticClipsWithOneLoad() async throws {
        guard let models = ProcessInfo.processInfo.environment["LD_TEST_MODELS"] else {
            throw XCTSkip("Set LD_TEST_MODELS to reuse cached models with synthetic speech only.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-asr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcriber = LocalTranscriber(modelsRoot: URL(fileURLWithPath: models, isDirectory: true))
        for (index, phrase) in ["Local dictation stays on this Mac.", "The second dictation reuses the same model."].enumerated() {
            let audio = folder.appendingPathComponent("\(index).aiff")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", "Samantha", "-r", "165", "-o", audio.path, phrase]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            let text = try await transcriber.transcribe(audio)
            XCTAssertFalse(text.isEmpty)
        }
        let loadCount = await transcriber.modelLoadCount
        XCTAssertEqual(loadCount, 1)
    }
}

final class DictationPermissionTests: XCTestCase {
    @MainActor
    func testPermissionStatesDoNotOpenMicrophoneInTests() async {
        var requests = 0
        try? await DictationMicrophonePermission.requireAccess(status: { .authorized }, request: { requests += 1; return false })
        XCTAssertEqual(requests, 0)
        do {
            try await DictationMicrophonePermission.requireAccess(status: { .denied }, request: { requests += 1; return true })
            XCTFail("Expected denial")
        } catch { XCTAssertEqual(error as? DictationError, .microphoneDenied) }
        XCTAssertEqual(requests, 0)
        do {
            try await DictationMicrophonePermission.requireAccess(status: { .restricted }, request: { requests += 1; return true })
            XCTFail("Expected restriction")
        } catch { XCTAssertEqual(error as? DictationError, .microphoneRestricted) }
        XCTAssertEqual(requests, 0)
    }
}

final class MicrophoneSelectionPolicyTests: XCTestCase {
    func testEachModeHasAnExplicitSelectionRule() {
        let available: Set<String> = ["built-in", "usb"]
        XCTAssertEqual(MicrophoneSelectionPolicy.resolvedUID(
            mode: .systemDefault, selectedUID: "usb", availableUIDs: available, defaultUID: "built-in"
        ), "built-in")
        XCTAssertEqual(MicrophoneSelectionPolicy.resolvedUID(
            mode: .specific, selectedUID: "usb", availableUIDs: available, defaultUID: "built-in"
        ), "usb")
    }

    func testSpecificModeNeverSilentlyFallsBack() {
        XCTAssertNil(MicrophoneSelectionPolicy.resolvedUID(
            mode: .specific, selectedUID: "offline", availableUIDs: ["built-in"], defaultUID: "built-in"
        ))
    }
}

@MainActor
final class MicrophonePreferencesTests: XCTestCase {
    func testChoiceAndUnavailableDevicesPersistAcrossRefreshAndRelaunch() throws {
        let suite = "MicrophonePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var live = [
            device("built-in", "Mac Microphone", 1, default: true),
            device("usb", "Desk Microphone", 2)
        ]
        var preferences: MicrophonePreferences? = MicrophonePreferences(
            defaults: defaults, observeHardware: false, deviceProvider: { live }
        )
        preferences?.mode = .specific
        preferences?.select("usb")
        XCTAssertEqual(preferences?.devices.map(\.uid), ["built-in", "usb"])
        XCTAssertEqual(preferences?.activeUID, "usb")

        live = [device("built-in", "Mac Microphone", 1, default: true)]
        preferences?.refresh()
        XCTAssertEqual(preferences?.devices.last?.name, "Desk Microphone")
        XCTAssertEqual(preferences?.devices.last?.isAvailable, false)
        XCTAssertNil(preferences?.activeUID)

        preferences = nil
        let restored = MicrophonePreferences(
            defaults: defaults, observeHardware: false, deviceProvider: { live }
        )
        XCTAssertEqual(restored.mode, .specific)
        XCTAssertEqual(restored.selectedUID, "usb")
        XCTAssertEqual(restored.devices.last?.isAvailable, false)
    }

    func testUnavailableSpecificMicrophoneProducesAUsefulError() throws {
        let suite = "MicrophonePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var live = [device("usb", "Desk Microphone", 2, default: true)]
        let preferences = MicrophonePreferences(
            defaults: defaults, observeHardware: false, deviceProvider: { live }
        )
        preferences.mode = .specific
        preferences.select("usb")
        live = []
        XCTAssertThrowsError(try preferences.resolveForRecording()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Desk Microphone is unavailable"))
        }
    }

    private func device(
        _ uid: String,
        _ name: String,
        _ id: AudioDeviceID,
        default isDefault: Bool = false
    ) -> DictationMicrophoneDevice {
        DictationMicrophoneDevice(
            uid: uid,
            name: name,
            deviceID: id,
            isAvailable: true,
            isSystemDefault: isDefault,
            transportType: 0
        )
    }
}

@MainActor
final class DictationFailureTests: XCTestCase {
    func testSilentOrMissingMicrophoneGetsAShortBubble() {
        XCTAssertEqual(DictationController.shortFailure("USB Mic is not sending audio. Reconnect it."), "Microphone is silent")
        XCTAssertEqual(DictationController.shortFailure("AirPods was disconnected."), "Microphone unavailable")
        XCTAssertEqual(DictationController.shortFailure("No speech was detected."), "Your voice was not heard")
    }

    func testStoppingWithoutRecordingIsAnErrorNotACrash() {
        XCTAssertThrowsError(try MicrophoneRecorder().stop())
    }
}

final class CharacterIndicatorTests: XCTestCase {
    func testEveryFaceAndBubbleIsARectangleOfKnownColours() {
        let known = Set(".kwgryb")
        for grid in PixelArt.faces + PixelArt.bubbles {
            XCTAssertEqual(Set(grid.map(\.count)).count, 1, "rows of one drawing have one width")
            XCTAssertTrue(grid.allSatisfy { $0.allSatisfy(known.contains) })
        }
        XCTAssertEqual(PixelArt.faces.count, 6)
        XCTAssertEqual(PixelArt.bubbles.count, 3)
        XCTAssertTrue(PixelArt.faces.allSatisfy { $0.count == PixelDictator.rows && $0[0].count == PixelDictator.columns })
    }

    func testTheBubbleIsAboutAThirdOfHisHeight() {
        let ratio = Double(PixelArt.bubbles[0].count) / Double(PixelDictator.rows)
        XCTAssertEqual(ratio, 1.0 / 3.0, accuracy: 0.05)
    }

    func testTalkingFacesNeverRepeatBackToBack() {
        let sequence = PixelDictator.talkSequence
        for index in sequence.indices {
            XCTAssertNotEqual(sequence[index], sequence[(index + 1) % sequence.count])
            XCTAssertTrue((1...5).contains(sequence[index]))
        }
    }
}

@MainActor
final class TerminalWrapTests: XCTestCase {
    func testLongAnswerLinesWrapUnderTheirBullet() {
        let lines = TerminalConsole.wrap("  ⎿ /theme [name]    list colour themes, or switch", 30)
        XCTAssertEqual(lines, ["  ⎿ /theme [name]    list", "    colour themes, or switch"])
        XCTAssertTrue(lines.allSatisfy { Style.width($0) <= 30 })
    }

    func testShortLinesAndStylingAreLeftAlone() {
        XCTAssertEqual(TerminalConsole.wrap("⏺ hello", 30), ["⏺ hello"])
        let styled = Style.color((255, 0, 0), "red words that go on and on")
        XCTAssertEqual(TerminalConsole.wrap(styled, 12).count, 3)
    }
}

final class DictatorQuipsTests: XCTestCase {
    func testFailuresGetAQuipOfTheirKind() {
        XCTAssertEqual(DictatorQuips.kind(of: "No speech was detected. Check the selected microphone."), .silence)
        XCTAssertEqual(DictatorQuips.kind(of: "USB Mic is not sending audio. Reconnect it."), .microphone)
        XCTAssertEqual(DictatorQuips.kind(of: "Microphone access is off. Enable Dictator…"), .permission)
        XCTAssertEqual(DictatorQuips.kind(of: "The speech model could not be downloaded: offline"), .model)
        XCTAssertEqual(DictatorQuips.kind(of: "Something odd"), .other)
        XCTAssertTrue(DictatorQuips.Kind.allCases.allSatisfy { (DictatorQuips.lines[$0]?.count ?? 0) >= 2 })
    }

    func testTheSameQuipNeverComesTwiceInARow() {
        var previous = ""
        for _ in 0..<50 {
            let next = DictatorQuips.line(for: "No speech was detected.")
            XCTAssertNotEqual(next, previous)
            previous = next
        }
    }
}

@MainActor
final class CopySnippetTests: XCTestCase {
    func testLongDictationsAreCutAtAWord() {
        XCTAssertEqual(TerminalConsole.snippet("Short one."), "Short one.")
        XCTAssertEqual(TerminalConsole.snippet("Давай попробуем ещё раз, но теперь с другим микрофоном и громче"),
                       "Давай попробуем ещё раз, но теперь с…")
    }
}
