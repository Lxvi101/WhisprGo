import CoreAudio
import Foundation

struct AudioInputRoute: Identifiable, Sendable, Equatable {
    enum Transport: String, Sendable {
        case builtIn
        case bluetooth
        case bluetoothLE
        case usb
        case aggregate
        case virtual
        case other

        var isBluetooth: Bool {
            self == .bluetooth || self == .bluetoothLE
        }

        var label: String {
            switch self {
            case .builtIn: return "Built in"
            case .bluetooth, .bluetoothLE: return "Bluetooth"
            case .usb: return "USB"
            case .aggregate: return "Aggregate device"
            case .virtual: return "Virtual device"
            case .other: return "External device"
            }
        }
    }

    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let transport: Transport

    var id: String { uid }
    var isBuiltIn: Bool { transport == .builtIn }
    var isBluetooth: Bool { transport.isBluetooth }
}

enum AudioInputPolicy {
    /// Explicitly allowed professional/external microphones take priority while
    /// connected. Otherwise capture stays on the Mac microphone. Bluetooth
    /// inputs are never selected, even if an old preference contains their UID.
    static func preferredRoute(
        from routes: [AudioInputRoute],
        defaultDeviceID: AudioDeviceID?,
        allowedExternalMicrophoneUIDs: Set<String>
    ) -> AudioInputRoute? {
        let allowed = routes.filter {
            !$0.isBuiltIn
                && !$0.isBluetooth
                && allowedExternalMicrophoneUIDs.contains($0.uid)
        }

        if let current = allowed.first(where: { $0.deviceID == defaultDeviceID }) {
            return current
        }
        if let external = allowed.first {
            return external
        }
        if let builtIn = routes.first(where: \.isBuiltIn) {
            return builtIn
        }

        // Desktops and unusual Core Audio configurations may not expose a
        // built-in input. Prefer a non-Bluetooth default as the safest fallback.
        if let current = routes.first(where: {
            $0.deviceID == defaultDeviceID && !$0.isBluetooth
        }) {
            return current
        }
        return routes.first(where: { !$0.isBluetooth })
    }
}

enum AudioInputRouter {
    enum RoutingError: LocalizedError {
        case noSafeMicrophoneAvailable

        var errorDescription: String? {
            switch self {
            case .noSafeMicrophoneAvailable:
                return "No built-in or allowed external microphone is available. Bluetooth headset microphones are not used."
            }
        }
    }

    static func preferredRouteName(
        allowedExternalMicrophoneUIDs: Set<String>
    ) -> String? {
        preferredRoute(
            allowedExternalMicrophoneUIDs: allowedExternalMicrophoneUIDs
        )?.name
    }

    static func preferredRoute(
        allowedExternalMicrophoneUIDs: Set<String>
    ) -> AudioInputRoute? {
        AudioInputPolicy.preferredRoute(
            from: inputRoutes(),
            defaultDeviceID: defaultInputDeviceID(),
            allowedExternalMicrophoneUIDs: allowedExternalMicrophoneUIDs
        )
    }

    static func inputRoutes() -> [AudioInputRoute] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap(route(for:))
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    private static func route(for deviceID: AudioDeviceID) -> AudioInputRoute? {
        guard hasInputStreams(deviceID),
              let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
              let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID)
        else { return nil }

        return AudioInputRoute(
            deviceID: deviceID,
            uid: uid,
            name: name,
            transport: transport(for: transportType(deviceID))
        )
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private static func transport(for value: UInt32?) -> AudioInputRoute.Transport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth: return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
}

final class AudioInputDeviceMonitor {
    private let queue = DispatchQueue(label: "com.whisprgo.audio-device-monitor")
    private var listener: AudioObjectPropertyListenerBlock?
    private var pendingNotification: DispatchWorkItem?

    func start(_ handler: @escaping @Sendable () -> Void) {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            pendingNotification?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingNotification = nil
                handler()
            }
            pendingNotification = work
            // Core Audio clients create and remove private aggregate devices
            // while their graphs initialize. Wait until that burst settles so a
            // temporarily incomplete device list cannot replace a valid route.
            queue.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        listener = block

        var devices = Self.devicesAddress
        var defaultInput = Self.defaultInputAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(system, &devices, queue, block)
        AudioObjectAddPropertyListenerBlock(system, &defaultInput, queue, block)
    }

    func stop() {
        guard let listener else { return }
        var devices = Self.devicesAddress
        var defaultInput = Self.defaultInputAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(system, &devices, queue, listener)
        AudioObjectRemovePropertyListenerBlock(system, &defaultInput, queue, listener)
        queue.sync {
            pendingNotification?.cancel()
            pendingNotification = nil
        }
        self.listener = nil
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
