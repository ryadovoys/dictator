import Combine
import CoreAudio
import Foundation

/// Which microphone records: whatever macOS has selected, or one chosen device.
enum DictationMicrophoneMode: String {
    case systemDefault
    /// Never falls back to another device: a missing microphone is an error, not a surprise.
    case specific
}

struct DictationMicrophoneDevice: Identifiable, Equatable {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID?
    let isAvailable: Bool
    let isSystemDefault: Bool
    let transportType: UInt32

    var id: String { uid }
}

struct ResolvedDictationMicrophone: Equatable {
    let uid: String
    let name: String
}

enum MicrophoneSelectionPolicy {
    static func resolvedUID(
        mode: DictationMicrophoneMode,
        selectedUID: String?,
        availableUIDs: Set<String>,
        defaultUID: String?
    ) -> String? {
        switch mode {
        case .systemDefault:
            guard let defaultUID, availableUIDs.contains(defaultUID) else { return nil }
            return defaultUID
        case .specific:
            guard let selectedUID, availableUIDs.contains(selectedUID) else { return nil }
            return selectedUID
        }
    }
}

@MainActor
final class MicrophonePreferences: ObservableObject {
    @Published var mode: DictationMicrophoneMode { didSet { save() } }
    @Published private(set) var selectedUID: String? { didSet { save() } }
    /// Connected microphones first (the system default leading), then ones seen before.
    @Published private(set) var devices: [DictationMicrophoneDevice] = []

    private let defaults: UserDefaults
    private let deviceProvider: () -> [DictationMicrophoneDevice]
    private var knownNames: [String: String]
    private var knownTransports: [String: UInt32]
    private var monitor: AudioDeviceChangeMonitor?

    // Stored under these names since the first release; renaming them would reset everyone's choice.
    private enum Key {
        static let mode = "localDictation.microphone.mode"
        static let selected = "localDictation.microphone.selectedUID"
        static let names = "localDictation.microphone.knownNames"
        static let transports = "localDictation.microphone.knownTransports"
    }

    init(
        defaults: UserDefaults = .standard,
        observeHardware: Bool = true,
        deviceProvider: @escaping () -> [DictationMicrophoneDevice] = AudioDeviceCatalog.inputDevices
    ) {
        self.defaults = defaults
        self.deviceProvider = deviceProvider
        mode = DictationMicrophoneMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .systemDefault
        selectedUID = defaults.string(forKey: Key.selected)
        knownNames = defaults.dictionary(forKey: Key.names) as? [String: String] ?? [:]
        let savedTransports = defaults.dictionary(forKey: Key.transports) ?? [:]
        knownTransports = savedTransports.reduce(into: [:]) { result, pair in
            if let number = pair.value as? NSNumber { result[pair.key] = number.uint32Value }
        }
        refresh()
        if observeHardware {
            monitor = AudioDeviceChangeMonitor { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    var activeUID: String? {
        MicrophoneSelectionPolicy.resolvedUID(
            mode: mode,
            selectedUID: selectedUID,
            availableUIDs: Set(devices.filter(\.isAvailable).map(\.uid)),
            defaultUID: devices.first(where: { $0.isSystemDefault && $0.isAvailable })?.uid
        )
    }

    var activeName: String {
        guard let activeUID, let device = devices.first(where: { $0.uid == activeUID }) else {
            return "No microphone available"
        }
        return device.name
    }

    func refresh() {
        let live = deviceProvider()
        for device in live {
            knownNames[device.uid] = device.name
            knownTransports[device.uid] = device.transportType
        }

        let liveByUID = Dictionary(uniqueKeysWithValues: live.map { ($0.uid, $0) })
        let order = knownNames.keys.sorted { lhs, rhs in
            let left = liveByUID[lhs], right = liveByUID[rhs]
            if (left != nil) != (right != nil) { return left != nil }
            if left?.isSystemDefault != right?.isSystemDefault { return left?.isSystemDefault == true }
            return (knownNames[lhs] ?? lhs).localizedCaseInsensitiveCompare(knownNames[rhs] ?? rhs) == .orderedAscending
        }
        devices = order.compactMap { uid in
            if let device = liveByUID[uid] { return device }
            guard let name = knownNames[uid] else { return nil }
            return DictationMicrophoneDevice(
                uid: uid,
                name: name,
                deviceID: nil,
                isAvailable: false,
                isSystemDefault: false,
                transportType: knownTransports[uid] ?? 0
            )
        }
        if selectedUID == nil {
            selectedUID = devices.first(where: { $0.isSystemDefault && $0.isAvailable })?.uid
                ?? devices.first(where: \.isAvailable)?.uid
        }
        save()
    }

    func select(_ uid: String) {
        guard devices.contains(where: { $0.uid == uid }) else { return }
        selectedUID = uid
    }

    func resolveForRecording() throws -> ResolvedDictationMicrophone {
        refresh()
        guard let uid = activeUID,
              let device = devices.first(where: { $0.uid == uid }),
              device.deviceID != nil,
              device.isAvailable else {
            if mode == .specific, let selectedUID,
               let selected = devices.first(where: { $0.uid == selectedUID }) {
                throw DictationError.message("\(selected.name) is unavailable. Connect it or choose another microphone.")
            }
            throw DictationError.message("No microphone you chose is connected. Choose another microphone.")
        }
        return ResolvedDictationMicrophone(uid: uid, name: device.name)
    }

    private func save() {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(selectedUID, forKey: Key.selected)
        defaults.set(knownNames, forKey: Key.names)
        defaults.set(knownTransports.mapValues(NSNumber.init(value:)), forKey: Key.transports)
    }
}

enum AudioDeviceCatalog {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func inputDevices() -> [DictationMicrophoneDevice] {
        let defaultID = defaultInputDeviceID()
        return allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID), !boolProperty(kAudioDevicePropertyIsHidden, deviceID: deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID) else { return nil }
            let alive = boolProperty(kAudioDevicePropertyDeviceIsAlive, deviceID: deviceID, fallback: true)
            return DictationMicrophoneDevice(
                uid: uid,
                name: stringProperty(kAudioObjectPropertyName, deviceID: deviceID) ?? "Unnamed Microphone",
                deviceID: deviceID,
                isAvailable: alive,
                isSystemDefault: deviceID == defaultID,
                transportType: uint32Property(kAudioDevicePropertyTransportType, deviceID: deviceID)
            )
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &value) == noErr,
              value != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return value
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func boolProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        fallback: Bool = false
    ) -> Bool {
        var value = UInt32(fallback ? 1 : 0)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return fallback }
        return value != 0
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return value
    }
}

private final class AudioDeviceChangeMonitor: @unchecked Sendable {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var addresses = [
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    ]
    private let listener: AudioObjectPropertyListenerBlock

    init(change: @escaping @Sendable () -> Void) {
        listener = { _, _ in change() }
        for index in addresses.indices {
            AudioObjectAddPropertyListenerBlock(Self.systemObject, &addresses[index], .main, listener)
        }
    }

    deinit {
        for index in addresses.indices {
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &addresses[index], .main, listener)
        }
    }
}
