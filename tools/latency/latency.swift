//
//  latency.swift
//
//  Measures how far one screen lags another, for any way of getting a picture onto it
//  (AirPlay, Sidecar, Moonlight, a cable). Independent of DAM.
//
//    swiftc -O -o latency tools/latency/latency.swift
//    ./latency show [display-id ...] [--seconds N]   a time code on each screen (all by
//                                                     default) for N seconds (60)
//    ./latency analyze <video> [--reference <display-id>] [--csv <file>]
//
//  `show` puts a QR code on each screen holding the Mac's clock, in milliseconds, for the
//  refresh it is drawn for. Film the screen under test together with a reference screen
//  (best a built-in panel or a wired display) with any camera, then `analyze` the video:
//  in every frame where both codes can be read, the reference's time minus the other's is
//  how far the other lags. Camera delay cancels out, since both codes are in the same
//  frame; what is left is the reference's own lag and about a frame of jitter on each side.
//

import AppKit
import AVFoundation
import CoreImage
import QuartzCore
import Vision

/// What each code holds: "LP1 <display-id> <milliseconds>".
let payloadPrefix = "LP1"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("latency: \(message)\n".utf8))
    exit(1)
}

/// Host time in milliseconds on the clock the display links report in.
func milliseconds(hostTime: UInt64) -> Int64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Int64(hostTime * UInt64(info.numer) / UInt64(info.denom) / 1_000_000)
}

// MARK: - show

/// One screen's code, redrawn for every refresh of that screen.
final class CodeWindow {
    let displayID: CGDirectDisplayID
    let window: NSWindow
    let codeLayer = CALayer()
    let textLayer = CATextLayer()
    var link: CVDisplayLink?
    let context = CIContext()

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        // A window of its own in the screen's top-right corner, above other windows but not
        // over the menu bar or the Dock: the code, with a quiet zone, the time in digits below.
        let area = screen.visibleFrame
        let side = (min(area.width, area.height) * 0.45).rounded()
        let caption = (side * 0.12).rounded()
        let size = CGSize(width: side + 40, height: side + caption + 40)
        let frame = CGRect(x: area.maxX - size.width, y: area.maxY - size.height,
                           width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered,
                          defer: false, screen: screen)
        window.level = .floating
        window.backgroundColor = .white
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let root = CALayer()
        root.backgroundColor = NSColor.white.cgColor
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(frame, display: true)

        codeLayer.frame = CGRect(x: 20, y: caption + 20, width: side, height: side)
        codeLayer.magnificationFilter = .nearest
        textLayer.frame = CGRect(x: 0, y: 10, width: size.width, height: caption)
        textLayer.fontSize = caption * 0.7
        textLayer.foregroundColor = NSColor.black.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = screen.backingScaleFactor
        root.addSublayer(codeLayer)
        root.addSublayer(textLayer)
        window.orderFrontRegardless()
    }

    func start() {
        CVDisplayLinkCreateWithCGDisplay(displayID, &link)
        guard let link else { fail("no display link for display \(displayID)") }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, output, _, _ in
            // The time the refresh being prepared reaches the screen.
            let ms = milliseconds(hostTime: output.pointee.hostTime)
            DispatchQueue.main.async { self?.draw(ms) }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    func draw(_ ms: Int64) {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(Data("\(payloadPrefix) \(displayID) \(ms)".utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = context.createCGImage(image, from: image.extent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        codeLayer.contents = cg
        textLayer.string = "\(displayID)  \(ms % 100_000)"
        CATransaction.commit()
    }
}

func show(_ arguments: [String]) {
    setlinebuf(stdout)
    var seconds = 60.0
    var ids: Set<CGDirectDisplayID> = []
    var i = 0
    while i < arguments.count {
        if arguments[i] == "--seconds" {
            i += 1
            guard i < arguments.count, let value = Double(arguments[i]), value > 0 else { fail("--seconds needs a number") }
            seconds = value
        } else if let id = CGDirectDisplayID(arguments[i]) {
            ids.insert(id)
        } else {
            fail("unknown argument \(arguments[i])")
        }
        i += 1
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var windows: [CodeWindow] = []
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { continue }
        let id = CGDirectDisplayID(number.uint32Value)
        guard ids.isEmpty || ids.contains(id) else { continue }
        let window = CodeWindow(screen: screen, displayID: id)
        window.start()
        windows.append(window)
        print("showing on display \(id) (\(screen.localizedName), \(Int(screen.frame.width))×\(Int(screen.frame.height)))")
    }
    if windows.isEmpty { fail("no matching screen; ids: \(NSScreen.screens.map { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]! })") }

    // Ends on its own, or on a click on a code, Esc, or Ctrl-C.
    print("film the screens; stops in \(Int(seconds)) s, or click a code or press Esc")
    signal(SIGINT) { _ in exit(0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
        if event.type == .leftMouseDown || event.keyCode == 53 { exit(0) }
        return event
    }
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { if $0.keyCode == 53 { exit(0) } }
    withExtendedLifetime(windows) { app.run() }
}

// MARK: - analyze

/// The codes read in one image: display ID → milliseconds.
func readCodes(in image: CGImage) -> [UInt32: Int64] {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try? VNImageRequestHandler(cgImage: image).perform([request])
    var codes: [UInt32: Int64] = [:]
    for result in request.results ?? [] {
        let parts = (result.payloadStringValue ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == payloadPrefix,
              let id = UInt32(parts[1]), let ms = Int64(parts[2]) else { continue }
        // A frame caught mid-refresh can hold two codes of one screen; keep the older.
        codes[id] = min(codes[id] ?? .max, ms)
    }
    return codes
}

/// Every frame of a video, or the image itself, as (time in the video in seconds, image).
func frames(of path: String, _ body: (Double, CGImage) -> Void) {
    let url = URL(fileURLWithPath: path)
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       CGImageSourceGetCount(source) > 0, CGImageSourceGetType(source) != nil,
       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        return body(0, image)
    }
    let asset = AVAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first,
          let reader = try? AVAssetReader(asset: asset) else { fail("can't read \(path)") }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    let context = CIContext()
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        var image = CIImage(cvPixelBuffer: buffer)
        // Phone videos are often stored sideways with a rotation to apply.
        image = image.transformed(by: track.preferredTransform)
        guard let cg = context.createCGImage(image, from: image.extent) else { continue }
        body(CMSampleBufferGetPresentationTimeStamp(sample).seconds, cg)
    }
}

func percentile(_ sorted: [Int64], _ p: Double) -> Int64 {
    sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

func analyze(_ arguments: [String]) {
    var path: String?
    var reference: UInt32?
    var csvPath: String?
    var i = 0
    while i < arguments.count {
        switch arguments[i] {
        case "--reference": i += 1; reference = arguments.count > i ? UInt32(arguments[i]) : nil
        case "--csv": i += 1; csvPath = arguments.count > i ? arguments[i] : nil
        default: path = arguments[i]
        }
        i += 1
    }
    guard let path else { fail("analyze needs a video or image") }

    var rows: [(time: Double, codes: [UInt32: Int64])] = []
    var total = 0
    frames(of: path) { time, image in
        total += 1
        let codes = readCodes(in: image)
        if !codes.isEmpty { rows.append((time, codes)) }
    }
    let ids = Set(rows.flatMap(\.codes.keys)).sorted()
    print("\(total) frames, codes read in \(rows.count); displays seen: \(ids.map(String.init).joined(separator: ", "))")
    for id in ids { print("  \(id): in \(rows.filter { $0.codes[id] != nil }.count) frames") }
    let paired = rows.filter { $0.codes.count >= 2 }
    guard !paired.isEmpty else { fail("no frame shows two screens' codes at once") }

    // Unless told, the reference is the screen that is ahead most often: the one with least lag.
    let ref = reference ?? ids.max { a, b in
        paired.filter { ($0.codes[a] ?? .min) == $0.codes.values.max() }.count
            < paired.filter { ($0.codes[b] ?? .min) == $0.codes.values.max() }.count
    }!
    print("reference: \(ref)\(reference == nil ? " (ahead most often)" : "")")

    var csv = "video_seconds,display,reference_ms,display_ms,lag_ms\n"
    for id in ids where id != ref {
        let lags = paired.compactMap { row -> Int64? in
            guard let r = row.codes[ref], let d = row.codes[id] else { return nil }
            csv += String(format: "%.3f", row.time) + ",\(id),\(r),\(d),\(r - d)\n"
            return r - d
        }.sorted()
        guard !lags.isEmpty else { print("  \(id): never seen together with \(ref)"); continue }
        let mean = Double(lags.reduce(0, +)) / Double(lags.count)
        print("  \(id) lags \(ref) by: median \(percentile(lags, 0.5)) ms, mean \(Int(mean.rounded())) ms, "
              + "p10 \(percentile(lags, 0.1)) ms, p90 \(percentile(lags, 0.9)) ms, "
              + "min \(lags.first!) ms, max \(lags.last!) ms (\(lags.count) frames)")
    }
    if let csvPath {
        do { try csv.write(toFile: csvPath, atomically: true, encoding: .utf8) }
        catch { fail("can't write \(csvPath): \(error.localizedDescription)") }
        print("wrote \(csvPath)")
    }
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "show": show(Array(arguments.dropFirst()))
case "analyze": analyze(Array(arguments.dropFirst()))
default:
    print("""
    usage: latency show [display-id ...] [--seconds N]
           latency analyze <video-or-image> [--reference <display-id>] [--csv <file>]
    """)
    exit(arguments.isEmpty ? 0 : 1)
}
