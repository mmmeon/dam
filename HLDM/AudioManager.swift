//
//  AudioManager.swift
//  boar
//

import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

final class AudioManager: ObservableObject {
    /// All hardware output devices, regardless of visibility preference.
    private(set) var allOutputDevices: [AudioDevice] = []
    /// Devices filtered by VisibilityPreferences — used by the menu and Touch Bar.
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown

    func refresh() {
        let fetched = fetchOutputDevices()
        autoHideNewVirtualDevices(in: fetched)
        if allOutputDevices != fetched { allOutputDevices = fetched }
        applyVisibility()
        let newID = fetchDefaultOutputDeviceID()
        if defaultDeviceID != newID { defaultDeviceID = newID }
    }

    /// On first discovery, virtual devices are hidden by default so they don't
    /// clutter the list. The user can re-enable them in Settings at any time.
    private func autoHideNewVirtualDevices(in devices: [AudioDevice]) {
        var seen = VisibilityPreferences.seenAudioDevices
        for device in devices where !seen.contains(device.name) {
            if !isHardwareDevice(device.id) {
                VisibilityPreferences.setVisible(false, audioDevice: device.name)
            }
            seen.insert(device.name)
        }
        VisibilityPreferences.seenAudioDevices = seen
    }

    /// Re-applies the current visibility preferences without re-querying CoreAudio.
    func applyVisibility() {
        let filtered = AudioManager.filter(devices: allOutputDevices, hidden: VisibilityPreferences.hiddenAudioDevices)
        if devices != filtered { devices = filtered }
    }

    static func filter(devices: [AudioDevice], hidden: Set<String>) -> [AudioDevice] {
        devices.filter { !hidden.contains($0.name) }
    }

    func setDefaultDevice(_ device: AudioDevice) {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = device.id
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
        defaultDeviceID = device.id
    }

    // MARK: - Private

    private func fetchOutputDevices() -> [AudioDevice] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id -> AudioDevice? in
            // Only include devices that have output streams.
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &outAddr, 0, nil, &streamSize)
            guard streamSize > 0 else { return nil }
            guard let name = objectName(for: id) else { return nil }
            return AudioDevice(id: id, name: name)
        }
    }

    private func fetchDefaultOutputDeviceID() -> AudioDeviceID {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    /// Returns true when the device uses a physical or AirPlay transport type.
    /// Virtual devices (Teams, Zoom, BlackHole, Loopback, etc.) use
    /// kAudioDeviceTransportTypeVirtual or kAudioDeviceTransportTypeAggregate.
    private func isHardwareDevice(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else {
            return true   // if we can't read it, include it to be safe
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn,
             kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeThunderbolt:
            return true
        default:
            return false
        }
    }

    /// Reads kAudioObjectPropertyName, taking ownership of the retained CFString.
    private func objectName(for id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStrPtr: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfStrPtr) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let ptr = cfStrPtr else { return nil }
        return ptr.takeRetainedValue() as String
    }
}
