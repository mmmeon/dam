//
//  layout.swift
//
//  What sessiontest compares before and after a remote session, and the changes it makes in
//  the middle of one, for a shell script to read.
//
//    swiftc -O -import-objc-header DAM/CGVirtualDisplayPrivate.h -o layout tools/sessiontest/layout.swift
//    ./layout snapshot            one line per online display, sorted by ID:
//                                 display id kind x y width height pixel-width hz main mirrors dark
//                                 then `output <uid>`, the default sound output
//    ./layout outputs             `uid<TAB>name` for each sound output; the default first
//    ./layout main ID             makes display ID main, as System Settings does (not through DAM)
//    ./layout standin NAME        makes a 1280×800 display called NAME, as another app's, until killed
//    ./layout regamma             puts every display's gamma back, as macOS can by itself
//    ./layout output UID          makes UID the default sound output, as System Settings does
//
//  kind is "streaming" for DAM's streaming displays (vendor 0x3456, product 0x1236), "dam"
//  for DAM's other virtual displays (anchors), "standin" for one made here, else "other".
//  x and y are CoreGraphics coordinates. dark is 1 when the display's gamma is blacked out.
//

import AppKit
import CoreAudio

setvbuf(stdout, nil, _IONBF, 0)

let damVendor: UInt32 = 0x3456
let streamingProduct: UInt32 = 0x1236
let standinVendor: UInt32 = 0x7E57

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("layout: \(message)\n".utf8))
    exit(1)
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count))).sorted()
}

func kind(_ id: CGDirectDisplayID) -> String {
    switch (CGDisplayVendorNumber(id), CGDisplayModelNumber(id)) {
    case (damVendor, streamingProduct): return "streaming"
    case (damVendor, _): return "dam"
    case (standinVendor, _): return "standin"
    default: return "other"
    }
}

/// Whether the display's gamma table is black, as LocalBlackout leaves it.
func isDark(_ id: CGDirectDisplayID) -> Bool {
    var red = [CGGammaValue](repeating: 0, count: 256)
    var green = red, blue = red
    var count: UInt32 = 0
    guard CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count) == .success, count > 0 else { return false }
    return (red.prefix(Int(count)) + green.prefix(Int(count)) + blue.prefix(Int(count))).max() ?? 0 < 0.05
}

func line(_ id: CGDirectDisplayID) -> String {
    let bounds = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    let fields: [Any] = [
        "display", id, kind(id), Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height),
        mode?.pixelWidth ?? 0, Int((mode?.refreshRate ?? 0).rounded()),
        CGDisplayIsMain(id) != 0 ? 1 : 0, CGDisplayMirrorsDisplay(id), isDark(id) ? 1 : 0,
    ]
    return fields.map { "\($0)" }.joined(separator: " ")
}

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    (property(object, selector, Unmanaged<CFString>?.none)??.takeRetainedValue() as String?) ?? "?"
}

func defaultOutput() -> AudioObjectID? {
    property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
}

func outputDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr && size > 0
    }
}

/// Makes `id` main by moving it to the origin and the others with it, as System Settings does.
func makeMain(_ id: CGDirectDisplayID) {
    let online = onlineDisplays()
    guard online.contains(id) else { fail("display \(id) isn't online") }
    let shift = CGDisplayBounds(id).origin
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { fail("can't configure displays") }
    for other in online where CGDisplayMirrorsDisplay(other) == 0 {
        let origin = CGDisplayBounds(other).origin
        CGConfigureDisplayOrigin(cfg, other, Int32(origin.x - shift.x), Int32(origin.y - shift.y))
    }
    let err = CGCompleteDisplayConfiguration(cfg, .forSession)
    guard err == .success else { fail("CGCompleteDisplayConfiguration: \(err.rawValue)") }
}

/// Keeps a display called `name` online until the process is killed.
func standIn(named name: String) -> Never {
    let descriptor = CGVirtualDisplayDescriptor()
    // Not `queue`, which sets what the system ignores (see DAM's enableVirtualAnchor).
    descriptor.setDispatchQueue(.main)
    descriptor.name = name
    descriptor.maxPixelsWide = 1280
    descriptor.maxPixelsHigh = 800
    descriptor.sizeInMillimeters = CGSize(width: 300, height: 190)
    descriptor.vendorID = standinVendor
    descriptor.productID = 1
    descriptor.serialNum = 1
    let display = CGVirtualDisplay(descriptor: descriptor)
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60)]
    guard display.apply(settings) else { fail("applySettings failed") }
    print(display.displayID)
    signal(SIGTERM) { _ in exit(0) }
    withExtendedLifetime(display) { dispatchMain() }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "snapshot" {
case "snapshot":
    onlineDisplays().forEach { print(line($0)) }
    print("output \(defaultOutput().map { string($0, kAudioDevicePropertyDeviceUID) } ?? "none")")
case "outputs":
    let current = defaultOutput()
    let devices = outputDevices()
    for id in devices.filter({ $0 == current }) + devices.filter({ $0 != current }) {
        print("\(string(id, kAudioDevicePropertyDeviceUID))\t\(string(id, kAudioObjectPropertyName))")
    }
case "main":
    guard args.count == 2, let id = UInt32(args[1]) else { fail("usage: layout main ID") }
    makeMain(id)
case "output":
    guard args.count == 2, let id = outputDevices().first(where: { string($0, kAudioDevicePropertyDeviceUID) == args[1] })
    else { fail("usage: layout output UID (of a connected output)") }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = id
    guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                     UInt32(MemoryLayout<AudioObjectID>.size), &device) == noErr else { fail("can't switch") }
case "regamma":
    CGDisplayRestoreColorSyncSettings()
case "standin":
    guard args.count == 2 else { fail("usage: layout standin NAME") }
    standIn(named: args[1])
default:
    fail("usage: layout snapshot|outputs|main ID|output UID|regamma|standin NAME")
}
