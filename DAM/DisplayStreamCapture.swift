//
//  DisplayStreamCapture.swift
//
//  Captures one display with CGDisplayStream rather than ScreenCaptureKit, for where
//  ScreenCaptureKit can't run: at the login window, as root, it crashes the process
//  (docs/root-and-login-window.md). Frames come at the stream's size and rate in the
//  encoder's 4:2:0, copied out of the stream's surfaces, which it reuses as soon as its
//  handler returns. No sound, SDR only, and a display turned on its side isn't followed:
//  the login window agent never turns one.
//

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import os.log

private let dsLog = Logger(subsystem: AppIdentity.bundleID, category: "DisplayStream")

enum DisplayStreamError: Error {
    /// CGDisplayStream stopped without being asked, as when the display goes away.
    case stopped
}

final class DisplayStreamCapture: ScreenCaptureSource {
    let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    private let frame: (CVPixelBuffer, CMTime) -> Void
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).displaystream", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: CGDisplayStream?
    private var stopped = false
    /// Where frames are copied to; on `queue`.
    private var pool: CVPixelBufferPool?

    var showsCursor = true
    /// Never called: CGDisplayStream has no sound.
    var audio: ((CMSampleBuffer) -> Void)?
    /// Changes nothing, for the same reason.
    var capturesAudio = false
    var onStop: ((Error) -> Void)?

    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// `frame` is called on the capture queue with each frame whose picture changed.
    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int,
         frame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.frame = frame
    }

    func start(completion: @escaping (Error?) -> Void) {
        // Without permission CGDisplayStream makes no stream; macOS is not asked here, as at the
        // login window nobody could answer. DAM's ScreenCaptureKit capture asks.
        guard CGPreflightScreenCaptureAccess() else { return completion(MoonlightCaptureError.noPermission) }
        let properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: 1 / Double(max(fps, 1)),
            CGDisplayStream.showCursor: showsCursor,
            CGDisplayStream.preserveAspectRatio: true,
            // As ScreenCaptureKit's: the encoder holds frames, and the stream skips without room.
            CGDisplayStream.queueDepth: 6,
        ]
        guard let stream = CGDisplayStream(dispatchQueueDisplay: displayID, outputWidth: width, outputHeight: height,
                                           pixelFormat: Int32(bitPattern: Self.pixelFormat),
                                           properties: properties as CFDictionary, queue: queue,
                                           handler: { [weak self] status, time, surface, _ in
            self?.handle(status, time, surface)
        }) else {
            return completion(MoonlightCaptureError.displayNotFound(displayID))
        }
        lock.lock()
        let wasStopped = stopped
        if !wasStopped { self.stream = stream }
        lock.unlock()
        guard !wasStopped else { return }
        let error = stream.start()
        guard error == .success else {
            dsLog.error("start: \(error.rawValue)")
            return completion(MoonlightCaptureError.displayNotFound(displayID))
        }
        dsLog.debug("capturing display \(self.displayID) at \(self.width)×\(self.height), \(self.fps) fps")
        completion(nil)
    }

    func stop() {
        lock.lock()
        stopped = true
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        _ = stream?.stop()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// On `queue`.
    private func handle(_ status: CGDisplayStreamFrameStatus, _ time: UInt64, _ surface: IOSurfaceRef?) {
        switch status {
        case .frameComplete:
            guard let surface, !isStopped, let copy = copy(surface) else { return }
            frame(copy, CMClockMakeHostTimeFromSystemUnits(time))
        case .stopped:
            guard !isStopped else { return }
            dsLog.error("display \(self.displayID): stopped on its own")
            onStop?(DisplayStreamError.stopped)
        default:
            break
        }
    }

    /// The surface's picture in a buffer of DAM's own, plane by plane. On `queue`, or a
    /// test's thread.
    func copy(_ surface: IOSurfaceRef) -> CVPixelBuffer? {
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        if pool == nil || width != self.width || height != self.height {
            pool = Self.makePool(width: width, height: height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        let planes = min(IOSurfaceGetPlaneCount(surface), CVPixelBufferGetPlaneCount(out))
        for plane in 0..<planes {
            let from = IOSurfaceGetBaseAddressOfPlane(surface, plane)
            guard let to = CVPixelBufferGetBaseAddressOfPlane(out, plane) else { return nil }
            Self.copyRows(from: from, fromStride: IOSurfaceGetBytesPerRowOfPlane(surface, plane),
                          to: to, toStride: CVPixelBufferGetBytesPerRowOfPlane(out, plane),
                          rows: min(IOSurfaceGetHeightOfPlane(surface, plane), CVPixelBufferGetHeightOfPlane(out, plane)))
        }
        return out
    }

    /// Copies `rows` rows between buffers whose rows may be padded differently.
    static func copyRows(from: UnsafeRawPointer, fromStride: Int, to: UnsafeMutableRawPointer, toStride: Int, rows: Int) {
        if fromStride == toStride { return to.copyMemory(from: from, byteCount: fromStride * rows) }
        let bytes = min(fromStride, toStride)
        for row in 0..<rows {
            (to + row * toStride).copyMemory(from: from + row * fromStride, byteCount: bytes)
        }
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
