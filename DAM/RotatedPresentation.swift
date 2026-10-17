//
//  RotatedPresentation.swift
//
//  Turns a display macOS can't turn, such as an AirPlay screen: a stand-in streaming display
//  of its size, turned, takes its place on the desktop, and a window covering the display's
//  own screen shows the stand-in captured, its frames turned back to the display's shape.
//  The pointer is kept off the covered screen, so it moves on the stand-in, which it sees.
//

import AppKit
import AVFoundation
import CoreMedia
import os.log

private let rpLog = Logger(subsystem: AppIdentity.bundleID, category: "RotatedPresentation")

final class RotatedPresentation {

    /// The name of the display shown on.
    let name: String
    /// The screen the window covers: the display's own, or the anchor it mirrors.
    let screenID: CGDirectDisplayID
    /// The stand-in, once placed.
    var standInID: CGDirectDisplayID = 0
    var rotation: DisplayRotation

    private let width: Int
    private let height: Int
    private let fps: Int
    private var window: NSWindow?
    private let layer = AVSampleBufferDisplayLayer()
    private var capture: MoonlightScreenCapture?
    private var fence: PointerFence?
    private var formatDescription: CMVideoFormatDescription?
    /// Called when the picture stops on its own, as when the stand-in or screen goes.
    var onStop: (() -> Void)?
    /// Whether main is being handed from the covered screen to the stand-in.
    var handingMainBack = false
    private var screensObserver: NSObjectProtocol?

    /// The picture is `width` × `height` pixels, the screen's own.
    init(name: String, screenID: CGDirectDisplayID, rotation: DisplayRotation, width: Int, height: Int, fps: Int) {
        self.name = name
        self.screenID = screenID
        self.rotation = rotation
        self.width = width
        self.height = height
        self.fps = fps
    }

    /// The mode the stand-in comes up in: the screen's, before the turn.
    var standInMode: StreamingDisplayModes.Mode {
        StreamingDisplayModes.forStream(width: width, height: height, fps: fps)
    }

    /// Covers the screen and shows the stand-in on it.
    func start() {
        guard standInID != 0, let screen = Self.screen(screenID) else {
            rpLog.error("no screen for \(self.screenID)")
            onStop?()
            return
        }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        // Over the menu bar and Dock that screen may have.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        // Nothing captures it, the stand-in's own capture least of all.
        window.sharingType = .none
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspect
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        // A window keeps its place when the displays move around it, as they do when the
        // stand-in takes the screen's place or main changes; it follows the screen instead.
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fitWindow()
            // AppKit can report the screens before the last move has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.fitWindow() }
        }

        fence = PointerFence(screenID: screenID)

        // In full colour: 4:2:0, as streams are sent, blurs text in colour.
        let capture = MoonlightScreenCapture(displayID: standInID, width: width, height: height, fps: fps,
                                             pixelFormat: kCVPixelFormatType_32BGRA) {
            [weak self] buffer, time in self?.show(buffer, at: time)
        }
        capture.onStop = { [weak self] error in
            rpLog.error("capture stopped: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { self?.onStop?() }
        }
        self.capture = capture
        capture.start { [weak self] error in
            guard let error else { return }
            rpLog.error("capture: \(String(describing: error), privacy: .public)")
            DispatchQueue.main.async { self?.onStop?() }
        }
        rpLog.debug("showing \(self.standInID) on \(self.screenID) at \(self.rotation.rawValue)")
    }

    /// Puts the window over the screen it covers, wherever that is now.
    private func fitWindow() {
        guard let window, let screen = Self.screen(screenID), window.frame != screen.frame else { return }
        rpLog.debug("window follows \(self.screenID) to \(NSStringFromRect(screen.frame), privacy: .public)")
        window.setFrame(screen.frame, display: true)
    }

    func stop() {
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
        capture?.stop()
        capture = nil
        fence = nil
        window?.orderOut(nil)
        window = nil
        layer.flushAndRemoveImage()
    }

    /// On the capture queue.
    private func show(_ buffer: CVPixelBuffer, at time: CMTime) {
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) ?? true {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                         formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: formatDescription,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }

    static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }
}

/// Keeps the pointer off a screen: a move onto it puts the pointer back where it was.
final class PointerFence {
    private let screenID: CGDirectDisplayID
    private var monitors: [Any] = []
    private var lastOutside: CGPoint?

    init(screenID: CGDirectDisplayID) {
        self.screenID = screenID
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.check() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.check()
            return event
        }) {
            monitors.append(local)
        }
        check()
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func check() {
        // CoreGraphics coordinates: from the top left of the main display.
        guard let location = CGEvent(source: nil)?.location else { return }
        let fenced = CGDisplayBounds(screenID)
        guard fenced.contains(location) else {
            lastOutside = location
            return
        }
        let back = lastOutside ?? Self.nearestOutside(location, of: fenced)
        CGWarpMouseCursorPosition(back)
        // Without this, the pointer stalls for a moment after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The point just past the nearest edge of `rect` from `point`, inside it.
    static func nearestOutside(_ point: CGPoint, of rect: CGRect) -> CGPoint {
        let distances = [(point.x - rect.minX, CGPoint(x: rect.minX - 1, y: point.y)),
                         (rect.maxX - point.x, CGPoint(x: rect.maxX + 1, y: point.y)),
                         (point.y - rect.minY, CGPoint(x: point.x, y: rect.minY - 1)),
                         (rect.maxY - point.y, CGPoint(x: point.x, y: rect.maxY + 1))]
        return distances.min { $0.0 < $1.0 }!.1
    }
}
