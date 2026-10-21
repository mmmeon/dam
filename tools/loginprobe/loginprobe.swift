//
//  loginprobe.swift
//
//  Tries, once, what DAM would need in order to work where it runs: which session it is in,
//  the displays, a picture of the main display by each capture API DAM could use, a
//  CGVirtualDisplay, and moving the pointer. Writes report.txt and a PNG per picture to the
//  folder it is given. Built and installed by tools/loginprobe/loginprobe, which runs it as a
//  LaunchAgent in the login window's session.
//
//    loginprobe <folder> [--delay seconds]
//

import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import SystemConfiguration

var arguments = Array(CommandLine.arguments.dropFirst())
var delay: Double = 0
if let i = arguments.firstIndex(of: "--delay"), i + 1 < arguments.count {
    delay = Double(arguments[i + 1]) ?? 0
    arguments.removeSubrange(i...(i + 1))
}
guard let folderPath = arguments.first else {
    FileHandle.standardError.write(Data("usage: loginprobe <folder> [--delay seconds]\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: folderPath)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

var report = ""
let reportLock = NSLock()
/// Callable from any queue: the virtual display's termination handler notes on its own.
func note(_ line: String) {
    reportLock.lock(); defer { reportLock.unlock() }
    let stamped = String(format: "%8.3f  ", ProcessInfo.processInfo.systemUptime) + line
    report += stamped + "\n"
    print(stamped)
    try? report.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
}

let ciContext = CIContext()

/// Writes `image` as <name>.png and says how bright it is on average (0 to 255), since a
/// capture refused by TCC or made of nothing comes back black rather than failing.
func keep(_ image: CGImage, _ name: String) -> String {
    let url = folder.appendingPathComponent(name + ".png")
    if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
    let context = CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    var sum = 0
    for i in stride(from: 0, to: pixels.count, by: 4) { sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
    let mean = Double(sum) / Double(64 * 64 * 3)
    return String(format: "%d×%d, mean %.0f%@ → %@.png", image.width, image.height, mean,
                  mean < 2 ? " (black)" : "", name)
}

func session() {
    note("pid \(getpid()), uid \(getuid()), euid \(geteuid())")
    var uid: uid_t = 0
    let console = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?
    note("console user: \(console ?? "none") (uid \(uid))")
    if let info = CGSessionCopyCurrentDictionary() as? [String: Any] {
        let keys = ["kCGSSessionUserNameKey", "kCGSSessionOnConsoleKey", "kCGSessionLoginDoneKey",
                    "CGSSessionScreenIsLocked", "kCGSSessionSecureInputPID"]
        note("CG session: " + keys.map { "\($0)=\(info[$0].map { "\($0)" } ?? "-")" }.joined(separator: " "))
    } else {
        note("CG session: none (no window server connection for this process)")
    }
    note("CGPreflightScreenCaptureAccess \(CGPreflightScreenCaptureAccess()), "
         + "CGPreflightPostEventAccess \(CGPreflightPostEventAccess()), AXIsProcessTrusted \(AXIsProcessTrusted())")
}

func displays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func listDisplays() {
    for id in displays() {
        let bounds = CGDisplayBounds(id)
        note("display \(id): \(Int(bounds.width))×\(Int(bounds.height)) at \(Int(bounds.minX)),\(Int(bounds.minY))"
             + "\(CGDisplayIsMain(id) != 0 ? " main" : "")\(CGDisplayIsBuiltin(id) != 0 ? " built-in" : "")"
             + "\(CGDisplayIsActive(id) == 0 ? " inactive" : "")\(CGDisplayIsAsleep(id) != 0 ? " asleep" : "")"
             + "\(CGDisplayMirrorsDisplay(id) != 0 ? " mirrors \(CGDisplayMirrorsDisplay(id))" : "")")
    }
}

func displayImage(_ id: CGDirectDisplayID, _ name: String) {
    if let image = CGDisplayCreateImage(id) {
        note("CGDisplayCreateImage \(id): " + keep(image, name))
    } else {
        note("CGDisplayCreateImage \(id): nil")
    }
}

func displayStream(_ id: CGDirectDisplayID) {
    let bounds = CGDisplayBounds(id)
    let done = DispatchSemaphore(value: 0)
    var result = "no frame in 5 s"
    var finished = false
    let queue = DispatchQueue(label: "displaystream")
    guard let stream = CGDisplayStream(dispatchQueueDisplay: id, outputWidth: Int(bounds.width),
                                       outputHeight: Int(bounds.height),
                                       pixelFormat: Int32(kCVPixelFormatType_32BGRA), properties: nil,
                                       queue: queue, handler: { status, _, surface, _ in
        guard !finished, status == .frameComplete, let surface else { return }
        finished = true
        let image = CIImage(ioSurface: surface)
        if let cg = ciContext.createCGImage(image, from: image.extent) {
            result = keep(cg, "displaystream-\(id)")
        } else {
            result = "frame, but no image from it"
        }
        done.signal()
    }) else {
        return note("CGDisplayStream \(id): could not be made")
    }
    let error = stream.start()
    guard error == .success else { return note("CGDisplayStream \(id): start → \(error.rawValue)") }
    _ = done.wait(timeout: .now() + 5)
    stream.stop()
    queue.sync {}
    note("CGDisplayStream \(id): \(result)")
}

final class FirstFrame: NSObject, SCStreamOutput {
    let done = DispatchSemaphore(value: 0)
    var result = "no frame in 5 s"
    private var finished = false

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        finished = true
        let image = CIImage(cvPixelBuffer: pixels)
        result = ciContext.createCGImage(image, from: image.extent).map { keep($0, "screencapturekit") }
            ?? "frame, but no image from it"
        done.signal()
    }
}

func screenCaptureKit() async {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        return note("ScreenCaptureKit: SCShareableContent → \(error)")
    }
    note("ScreenCaptureKit: \(content.displays.count) displays, \(content.windows.count) windows, "
         + "apps: \(Set(content.windows.compactMap { $0.owningApplication?.bundleIdentifier }).sorted().joined(separator: " "))")
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        return note("ScreenCaptureKit: no display to capture")
    }
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    let output = FirstFrame()
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                          configuration: configuration, delegate: nil)
    do {
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck"))
        try await stream.startCapture()
    } catch {
        return note("ScreenCaptureKit: stream of display \(display.displayID) → \(error)")
    }
    _ = output.done.wait(timeout: .now() + 5)
    try? await stream.stopCapture()
    note("ScreenCaptureKit: display \(display.displayID): \(output.result)")
}

func virtualDisplay() {
    let before = Set(displays())
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.setDispatchQueue(DispatchQueue(label: "virtualdisplay"))
    descriptor.name = "DAM Login Probe"
    descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
    descriptor.maxPixelsWide = 1920
    descriptor.maxPixelsHigh = 1080
    descriptor.vendorID = 0x3456
    descriptor.productID = 0x1234
    descriptor.serialNum = 0x1009
    descriptor.terminationHandler = { _, _ in note("CGVirtualDisplay: ended by the system") }
    var vd: CGVirtualDisplay? = CGVirtualDisplay(descriptor: descriptor)
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
    // Only its ID past here: a reference kept to it would hold it up past `vd = nil`.
    guard let id = vd.flatMap({ $0.apply(settings) ? $0.displayID : nil }) else {
        return note("CGVirtualDisplay: applySettings failed")
    }
    note("CGVirtualDisplay: made \(id)")
    // WindowServer takes a moment to bring a new display online.
    for _ in 0..<50 where !displays().contains(id) { usleep(100_000) }
    note("CGVirtualDisplay: online \(displays().contains(id)); new: \(Set(displays()).subtracting(before).sorted())")
    listDisplays()
    sleep(2)
    displayImage(id, "virtual")
    displayStream(id)
    vd = nil
    sleep(1)
    note("CGVirtualDisplay: released; still online \(displays().contains(id))")
}

func pointer() {
    guard let start = CGEvent(source: nil)?.location else { return note("pointer: no location") }
    let target = CGPoint(x: start.x + 40, y: start.y + 40)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(300_000)
    let after = CGEvent(source: nil)?.location ?? .zero
    note("pointer: at \(Int(start.x)),\(Int(start.y)), posted a move to \(Int(target.x)),\(Int(target.y)), "
         + "now at \(Int(after.x)),\(Int(after.y)) → \(hypot(after.x - target.x, after.y - target.y) < 2 ? "moved" : "did not move")")
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

Task {
    note("loginprobe, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    if delay > 0 {
        note("waiting \(delay) s")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    session()
    listDisplays()
    let main = CGMainDisplayID()
    displayImage(main, "displayimage")
    displayStream(main)
    await screenCaptureKit()
    virtualDisplay()
    pointer()
    note("done")
    exit(0)
}
dispatchMain()
