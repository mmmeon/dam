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
//    loginprobe <folder> --stream port [--delay seconds]   (MJPEG over HTTP, below)
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
var streamPort: UInt16?
if let i = arguments.firstIndex(of: "--stream"), i + 1 < arguments.count {
    streamPort = UInt16(arguments[i + 1])
    arguments.removeSubrange(i...(i + 1))
}
guard let folderPath = arguments.first else {
    FileHandle.standardError.write(Data("usage: loginprobe <folder> [--stream port] [--delay seconds]\n".utf8))
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
    // At the login window it first listed as 1×1: whether its mode has applied by now.
    listDisplays()
    displayImage(id, "virtual")
    displayStream(id)
    vd = nil
    sleep(1)
    note("CGVirtualDisplay: released; still online \(displays().contains(id))")
}

// At the login window, with every permission granted, a plain post to the HID tap still left
// the pointer where it was: each way of moving it, tried and reported on its own.
func pointer() {
    func move(_ how: String, _ by: CGFloat, _ post: (CGPoint) -> Void) {
        // At the login window one of these hung, silently: each step is noted before it starts.
        note("pointer, \(how): trying")
        guard let start = CGEvent(source: nil)?.location else { return note("pointer: no location") }
        let target = CGPoint(x: start.x + by, y: start.y + by)
        post(target)
        usleep(300_000)
        let after = CGEvent(source: nil)?.location ?? .zero
        note("pointer, \(how): at \(Int(start.x)),\(Int(start.y)), moved to \(Int(target.x)),\(Int(target.y)), "
             + "now at \(Int(after.x)),\(Int(after.y)) → \(hypot(after.x - target.x, after.y - target.y) < 2 ? "moved" : "did not move")")
        post(start)
        usleep(100_000)
        note("pointer, \(how): moved back")
    }
    func event(_ source: CGEventSource?, _ tap: CGEventTapLocation) -> (CGPoint) -> Void {
        { CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: $0, mouseButton: .left)?.post(tap: tap) }
    }
    move("HID tap", 40, event(nil, .cghidEventTap))
    move("session tap", 50, event(nil, .cgSessionEventTap))
    move("CGWarpMouseCursorPosition", 60) { CGWarpMouseCursorPosition($0) }
    note("pointer: making a HID system state source")
    let source = CGEventSource(stateID: .hidSystemState)
    move("HID tap, HID system state source", 70, event(source, .cghidEventTap))
}

if let streamPort {
    note("loginprobe --stream, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        session()
        listDisplays()
        LoginStream(display: CGMainDisplayID(), port: streamPort, fps: 15).start()
    }
    dispatchMain()
}

// At the login window a capture call can hang until someone logs in; the report then says
// so, and that the step above it is the one.
DispatchQueue.global().asyncAfter(deadline: .now() + delay + 120) {
    note("timed out after \(Int(delay) + 120) s: the step above never finished")
    exit(1)
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
    virtualDisplay()
    pointer()
    // Last: at the login window ScreenCaptureKit crashed the probe, in ReplayKit's
    // NSApplication.shared on a background queue (LaunchServices check-in as root).
    await screenCaptureKit()
    note("done")
    exit(0)
}
dispatchMain()

// MARK: --stream

// The main display as MJPEG over HTTP, to see the login window from another device.
// CGDisplayStream, since ScreenCaptureKit crashes there; CIContext makes the JPEGs. A browser
// on the network opens http://<this Mac>:<port>/. Runs until launchd stops it at sign-in.
// For a test only: no authentication, so anyone on the network can watch the login window
// while it runs.

final class LoginStream {
    private let display: CGDirectDisplayID
    private let port: UInt16
    private let fps: Double
    private let lock = NSCondition()
    private var jpeg = Data()
    private var sequence = 0
    private var captured = 0
    private var encodeTime = 0.0
    private var viewers = 0
    private var sent = 0
    private var stream: CGDisplayStream?

    init(display: CGDirectDisplayID, port: UInt16, fps: Double) {
        self.display = display
        self.port = port
        self.fps = fps
    }

    func start() {
        let bounds = CGDisplayBounds(display)
        let properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: 1 / fps,
            CGDisplayStream.showCursor: true,
        ]
        let queue = DispatchQueue(label: "loginstream.capture")
        stream = CGDisplayStream(dispatchQueueDisplay: display, outputWidth: Int(bounds.width),
                                 outputHeight: Int(bounds.height),
                                 pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                                 properties: properties as CFDictionary, queue: queue) { [weak self] status, _, surface, _ in
            guard status == .frameComplete, let surface, let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let image = CIImage(ioSurface: surface)
            guard let data = ciContext.jpegRepresentation(
                of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6])
            else { return }
            self.lock.lock()
            self.jpeg = data
            self.sequence += 1
            self.captured += 1
            self.encodeTime += ProcessInfo.processInfo.systemUptime - started
            self.lock.broadcast()
            self.lock.unlock()
        }
        guard let stream else { return note("stream: CGDisplayStream could not be made") }
        let error = stream.start()
        guard error == .success else { return note("stream: CGDisplayStream start → \(error.rawValue)") }
        note("stream: capturing display \(display), \(Int(bounds.width))×\(Int(bounds.height)), up to \(Int(fps)) fps")
        listen()
        report()
    }

    // MARK: HTTP

    private func listen() {
        signal(SIGPIPE, SIG_IGN)
        let server = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(server, 8) == 0 else {
            return note("stream: could not listen on port \(port): \(String(cString: strerror(errno)))")
        }
        note("stream: open " + addresses().map { "http://\($0):\(port)/" }.joined(separator: " or "))
        Thread.detachNewThread {
            while true {
                let client = accept(server, nil, nil)
                guard client >= 0 else { continue }
                Thread.detachNewThread { self.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var request = [UInt8](repeating: 0, count: 2048)
        let count = recv(client, &request, request.count, 0)
        guard count > 0 else { return }
        let line = String(decoding: request.prefix(count), as: UTF8.self).prefix { $0 != "\r" && $0 != "\n" }
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        switch path {
        case "/mjpeg":
            mjpeg(client)
        case "/frame.jpg":
            lock.lock(); let frame = jpeg; lock.unlock()
            _ = write(client, "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n"
                      + "Cache-Control: no-store\r\nConnection: close\r\n\r\n")
            _ = write(client, frame)
        default:
            let page = """
                <!doctype html><meta name="viewport" content="width=device-width">
                <title>Login window</title>
                <style>body{margin:0;background:#000}img{width:100vw;height:100vh;object-fit:contain}</style>
                <img src="/mjpeg">
                """
            _ = write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                      + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page)
        }
    }

    /// Every new frame as one part of a multipart/x-mixed-replace response, until the viewer
    /// goes away. A slow viewer skips frames rather than queueing them.
    private func mjpeg(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard write(client, "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                    + "Cache-Control: no-store\r\nConnection: close\r\n\r\n") else { return }
        lock.lock(); viewers += 1; lock.unlock()
        note("stream: viewer connected")
        defer {
            lock.lock(); viewers -= 1; lock.unlock()
            note("stream: viewer left")
        }
        var last = -1
        while true {
            lock.lock()
            // CGDisplayStream sends nothing while the screen is still, as the login window
            // mostly is: the last frame again each second, since some browsers draw a part only
            // once the next begins, and a viewer who left is noticed only on a send.
            if sequence == last { lock.wait(until: Date() + 1) }
            last = sequence
            let frame = jpeg
            lock.unlock()
            guard write(client, "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n"),
                  write(client, frame), write(client, "\r\n") else { return }
            lock.lock(); sent += 1; lock.unlock()
        }
    }

    private func write(_ client: Int32, _ text: String) -> Bool { write(client, Data(text.utf8)) }

    private func write(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = send(client, buffer.baseAddress! + offset, buffer.count - offset, 0)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    // MARK: Report

    /// Every 10 s: frames captured and sent, what a JPEG costs, how many are watching.
    private func report() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
            lock.lock()
            let line = String(format: "stream: %.1f fps captured, %.1f fps sent, %.0f ms per JPEG, %ld KB a frame, %ld watching",
                              Double(captured) / 10, Double(sent) / 10,
                              captured > 0 ? encodeTime / Double(captured) * 1000 : 0.0, jpeg.count / 1024, viewers)
            captured = 0; sent = 0; encodeTime = 0
            lock.unlock()
            note(line)
            report()
        }
    }

    private func addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return ["<this Mac>"] }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result.isEmpty ? ["<this Mac>"] : result
    }
}
