import AVFoundation
import Foundation

enum DictationError: LocalizedError, Equatable {
    case microphoneDenied, microphoneRestricted, microphoneRequestFailed
    case message(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Enable Dictator in System Settings → Privacy & Security → Microphone."
        case .microphoneRestricted:
            return "Microphone access is restricted by macOS or device management."
        case .microphoneRequestFailed:
            return "macOS could not complete the microphone request. Reopen Dictator and try again."
        case .message(let text): return text
        }
    }
}

enum DictationMicrophonePermission {
    @MainActor
    static func requireAccess(
        status: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        request: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    ) async throws {
        switch status() {
        case .authorized: return
        case .denied: throw DictationError.microphoneDenied
        case .restricted: throw DictationError.microphoneRestricted
        case .notDetermined:
            if await request() { return }
            switch status() {
            case .authorized: return
            case .denied: throw DictationError.microphoneDenied
            case .restricted: throw DictationError.microphoneRestricted
            default: throw DictationError.microphoneRequestFailed
            }
        @unknown default: throw DictationError.microphoneRequestFailed
        }
    }
}
