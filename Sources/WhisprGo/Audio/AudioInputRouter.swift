import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct AudioInputRoute: Sendable, Equatable {
    let deviceID: AudioDeviceID
    let name: String
    let isBuiltIn: Bool
}

enum AudioInputRouter {
    enum RoutingError: LocalizedError {
        case cannotSelectBuiltInMicrophone(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .cannotSelectBuiltInMicrophone(status):
                return "The Mac microphone could not be selected (Core Audio error \(status))."
            }
        }
    }

    /// Pins this app's input Audio Unit to the built-in microphone. Output is
    /// untouched, so AirPods can remain a high-quality playback-only device.
    static func configure(
        inputNode: AVAudioInputNode,
        preferBuiltInMicrophone: Bool
    ) throws -> AudioInputRoute? {
        let defaultRoute = defaultInputRoute()
        guard preferBuiltInMicrophone,
              let builtInRoute = inputRoutes().first(where: \.isBuiltIn),
              let audioUnit = inputNode.audioUnit
        else {
            return defaultRoute
        }

        var deviceID = builtInRoute.deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw RoutingError.cannotSelectBuiltInMicrophone(status)
        }
        return builtInRoute
    }

    static func preferredRouteName(preferBuiltInMicrophone: Bool) -> String? {
        if preferBuiltInMicrophone,
           let builtIn = inputRoutes().first(where: \.isBuiltIn)
        {
            return builtIn.name
        }
        return defaultInputRoute()?.name
    }

    private static func defaultInputRoute() -> AudioInputRoute? {
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
        return route(for: deviceID)
    }

    private static func inputRoutes() -> [AudioInputRoute] {
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

    private static func route(for deviceID: AudioDeviceID) -> AudioInputRoute? {
        guard hasInputStreams(deviceID), let name = deviceName(deviceID) else { return nil }
        return AudioInputRoute(
            deviceID: deviceID,
            name: name,
            isBuiltIn: transportType(deviceID) == kAudioDeviceTransportTypeBuiltIn
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

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &name
        ) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }
}
