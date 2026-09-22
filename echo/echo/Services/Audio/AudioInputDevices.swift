import CoreAudio
import Foundation
import IOKit

/// CoreAudio device lookup for capture.
///
/// Echo must never disturb what the user is listening to. Opening a Bluetooth headset's
/// microphone forces it from A2DP into its call profile (HFP): the music drops to call quality,
/// the volume jumps, and the stem press turns into call mute. So when the default input is
/// Bluetooth, capture from a wired or built-in mic instead and leave the headset alone.
nonisolated enum AudioInputDevices {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
        let isBluetooth: Bool
    }

    /// The device echo should record from, or nil when there is no input at all.
    static func captureDevice() -> Device? {
        guard let fallback = defaultInput() else { return nil }
        guard isBluetooth(fallback) else { return describe(fallback) }

        let candidates = allDevices().filter { $0 != fallback && hasInput($0) && isAlive($0) }
        let lidClosed = isClamshellClosed()

        // The built-in mic is dead with the lid shut, even though CoreAudio still lists it.
        if !lidClosed, let builtIn = candidates.first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn }) {
            return describe(builtIn)
        }
        let wired: Set<UInt32> = [
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypePCI,
        ]
        if let external = candidates.first(where: { wired.contains(transport($0)) }) {
            return describe(external)
        }
        // Nothing else to record from. The headset is the only mic, so use it.
        return describe(fallback)
    }

    /// First input stream's virtual format. The HAL hands IOProcs data in this format.
    static func inputStreamFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr,
              let first = streams.first else { return nil }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(first, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    // MARK: - Properties

    private static func describe(_ device: AudioObjectID) -> Device {
        Device(id: device, name: name(device), isBluetooth: isBluetooth(device))
    }

    private static func defaultInput() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &device),
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isAlive(_ device: AudioObjectID) -> Bool {
        var alive: UInt32 = 0
        return read(device, kAudioDevicePropertyDeviceIsAlive, into: &alive) && alive != 0
    }

    private static func transport(_ device: AudioObjectID) -> UInt32 {
        var value: UInt32 = 0
        _ = read(device, kAudioDevicePropertyTransportType, into: &value)
        return value
    }

    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let value = transport(device)
        return value == kAudioDeviceTransportTypeBluetooth || value == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func name(_ device: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return "device \(device)" }
        return value.takeRetainedValue() as String
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func isClamshellClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }
}
