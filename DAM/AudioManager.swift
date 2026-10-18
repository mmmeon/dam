//
//  AudioManager.swift
//

import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String

    /// What the app shows for this device: its nickname if the user set one, else its name.
    var label: String { VisibilityPreferences.nickname(.audio, for: name) ?? name }
}

final class AudioManager: ObservableObject {
    /// All hardware output devices, regardless of visibility preference.
    private(set) var allOutputDevices: [AudioDevice] = []
    /// Devices filtered by VisibilityPreferences — used by the menu and Touch Bar.
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown

    private var knownDeviceIDs: Set<AudioDeviceID> = []
    private var lastDefaultID: AudioDeviceID = kAudioObjectUnknown
    /// Devices that appeared recently, with when they appeared. macOS may switch the
    /// default output to one shortly after it shows up.
    private var recentlyAdded: [AudioDeviceID: Date] = [:]

    init() {
        knownDeviceIDs = Set(fetchOutputDevices().map(\.id))
        lastDefaultID = fetchDefaultOutputDeviceID()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { [weak self] _, _ in
                self?.hardwareChanged()
            }
        }
    }

    /// Tracks newly added devices and, when the user has turned off following a new
    /// display's audio, undoes macOS's switch to it.
    private func hardwareChanged() {
        let now = Date()
        let ids = Set(fetchOutputDevices().map(\.id))
        for id in ids.subtracting(knownDeviceIDs) { recentlyAdded[id] = now }
        knownDeviceIDs = ids
        recentlyAdded = recentlyAdded.filter { now.timeIntervalSince($0.value) < 5 }

        let current = fetchDefaultOutputDeviceID()
        if current != lastDefaultID,
           !VisibilityPreferences.followNewDisplayAudio,
           recentlyAdded[current] != nil,
           isDisplayDevice(current),
           ids.contains(lastDefaultID) {
            recentlyAdded[current] = nil
            setDefaultDeviceID(lastDefaultID)
        } else {
            lastDefaultID = current
        }
        refresh()
    }

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
    /// The hiding step is skipped when autoHideVirtualAudio is off, but seen-device
    /// tracking always runs so toggling the preference later has no retroactive effect.
    private func autoHideNewVirtualDevices(in devices: [AudioDevice]) {
        var seen = VisibilityPreferences.seenAudioDevices
        for device in devices where !seen.contains(device.name) {
            if VisibilityPreferences.autoHideVirtualAudio && !isHardwareDevice(device.id) {
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

    /// The device after the one with `currentID` in `devices`, wrapping around; the first
    /// device when `currentID` isn't listed (e.g. the current output is hidden). Nil if empty.
    static func device(after currentID: AudioDeviceID, in devices: [AudioDevice]) -> AudioDevice? {
        guard let idx = devices.firstIndex(where: { $0.id == currentID }) else { return devices.first }
        return devices[(idx + 1) % devices.count]
    }

    func setDefaultDevice(_ device: AudioDevice) {
        setDefaultDeviceID(device.id)
    }

    /// Makes the device with `uid` the default output; false when it isn't connected or
    /// macOS didn't take it, as for a device that can't be the default.
    @discardableResult
    func setDefaultDevice(uid: String) -> Bool {
        guard let id = Self.deviceID(forUID: uid) else { return false }
        setDefaultDeviceID(id)
        let current = fetchDefaultOutputDeviceID()
        guard current == id else {
            defaultDeviceID = current
            lastDefaultID = current
            return false
        }
        return true
    }

    /// The UID of the default output, or nil when there is none.
    var defaultDeviceUID: String? { Self.uid(of: fetchDefaultOutputDeviceID()) }

    private func setDefaultDeviceID(_ id: AudioDeviceID) {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
        defaultDeviceID = id
        lastDefaultID = id
    }

    /// The device's persistent UID. Unlike its AudioDeviceID, it survives reconnects and reboots.
    static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: id)
    }

    /// The current AudioDeviceID of the device with `uid`, or nil when it isn't connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &deviceID
            )
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
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
            guard let name = Self.stringProperty(kAudioObjectPropertyName, of: id) else { return nil }
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

    private func transportType(_ id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    /// True for a display's audio: HDMI or DisplayPort transport.
    private func isDisplayDevice(_ id: AudioDeviceID) -> Bool {
        let t = transportType(id)
        return t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort
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

    /// Reads a CFString property such as kAudioObjectPropertyName, taking ownership of the retained CFString.
    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
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
