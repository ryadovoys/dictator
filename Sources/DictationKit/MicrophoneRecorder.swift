@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Records one microphone clip to a CAF file until the caller stops or cancels it.
///
/// Built on `AVCaptureSession`, not `AVAudioEngine`. The engine always drives the output
/// device too: pointing its input at a non-default microphone, a Bluetooth headset switching
/// profile, or the default device changing makes it stop on its own mid-recording. The capture
/// session opens only the chosen input, by its Core Audio UID, and is left alone by output changes.
///
/// A clip that stops early (the device was unplugged, macOS took it away) is still returned by
/// `stop()` with whatever was heard; only a clip with no audio at all is an error.
public final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Loudness of each ~50 ms of input, 0 (silence) to 1 (loud speech), on the capture queue.
    public var onLevel: ((Float) -> Void)?

    private let samples = DispatchQueue(label: "dictation.capture.samples")
    private let control = DispatchQueue(label: "dictation.capture.session")
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var writeFailure: Error?
    private var interruption: String?
    private(set) public var url: URL?

    public var isRecording: Bool { url != nil }
    /// Frames written so far; zero a moment after start means the device is not delivering audio.
    public var capturedFrames: AVAudioFramePosition { lock.lock(); defer { lock.unlock() }; return frames }

    /// Starts recording `deviceUID` (a Core Audio device UID), or the macOS default input when nil.
    public func start(in folder: URL, deviceUID: String? = nil) async throws -> URL {
        guard url == nil else { throw Failure("Dictation is already recording.") }
        let device: AVCaptureDevice
        if let deviceUID {
            guard let chosen = AVCaptureDevice(uniqueID: deviceUID) else {
                throw Failure("The selected microphone is not connected.")
            }
            device = chosen
        } else {
            guard let fallback = AVCaptureDevice.default(for: .audio) else {
                throw Failure("No microphone is connected.")
            }
            device = fallback
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("dictation-\(UUID().uuidString.lowercased()).caf")

        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw Failure("\(device.localizedName) could not be opened: \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else { throw Failure("\(device.localizedName) could not be opened.") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // 16 kHz mono float is what the speech model reads; asking for it here skips a resample later.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: samples)
        guard session.canAddOutput(output) else { throw Failure("\(device.localizedName) could not be recorded.") }
        session.addOutput(output)

        lock.withLock { file = nil; frames = 0; writeFailure = nil; interruption = nil }
        url = destination
        self.session = session
        observe(session, device: device)

        let running = await withCheckedContinuation { continuation in
            control.async {
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
        guard running else {
            teardown()
            url = nil
            throw Failure("\(device.localizedName) did not start. Try again, or choose another microphone.")
        }
        return destination
    }

    /// Ends the clip and returns it, even when capture already stopped on its own.
    public func stop() throws -> URL {
        guard let url else { throw Failure("No dictation is recording.") }
        teardown()
        lock.lock()
        let failure = writeFailure, captured = frames, interrupted = interruption
        file?.close(); file = nil
        lock.unlock()
        self.url = nil
        if let failure { throw Failure("Microphone recording failed: \(failure.localizedDescription). Audio was kept.") }
        guard captured > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw Failure(interrupted ?? "No microphone audio was captured. Check the microphone and try again.")
        }
        return url
    }

    public func cancel() {
        guard let url else { return }
        teardown()
        lock.lock()
        file?.close(); file = nil; frames = 0; writeFailure = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
        self.url = nil
    }

    /// Splits a buffer into ~50 ms chunks so the indicator moves at speech pace.
    /// RMS in decibels, with -50 dB as silence and -12 dB as full height.
    public static func levels(in buffer: AVAudioPCMBuffer) -> [Float] {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let total = Int(buffer.frameLength)
        let chunk = max(1, Int(buffer.format.sampleRate * 0.05))
        return stride(from: 0, to: total, by: chunk).map { start in
            let end = min(start + chunk, total)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            let rms = (sum / Float(end - start)).squareRoot()
            let decibels = 20 * log10(max(rms, 1e-7))
            return min(max((decibels + 50) / 38, 0), 1)
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard writeFailure == nil, let url else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat,
                                       interleaved: buffer.format.isInterleaved)
            }
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch { writeFailure = error }
        if let onLevel { Self.levels(in: buffer).forEach(onLevel) }
    }

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private func observe(_ session: AVCaptureSession, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        let name = device.localizedName
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.interrupted("\(name) stopped: \(error?.localizedDescription ?? "audio error").")
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.interrupted("\(name) was disconnected.")
            }
        ]
    }

    private func interrupted(_ message: String) {
        lock.lock(); if interruption == nil { interruption = message }; lock.unlock()
    }

    /// Stops the session and waits for buffers already queued, so the file is complete.
    private func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let session { control.sync { session.stopRunning() } }
        session = nil
        samples.sync {}
    }
}
