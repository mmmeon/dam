//
//  MoonlightScreenCapture.swift
//
//  Captures one display for Moonlight with ScreenCaptureKit, at the stream's size and rate,
//  in the 4:2:0 format the encoder takes as is. Each new frame is handed on the moment it
//  arrives; capture holds no more frames than ScreenCaptureKit's minimum.
//

import CoreMedia
import Foundation
import ScreenCaptureKit
import os.log

private let scLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightCapture")

enum MoonlightCaptureError: Error {
    case noPermission
    case displayNotFound(CGDirectDisplayID)
}

final class MoonlightScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    private let frame: (CVPixelBuffer, CMTime) -> Void
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.capture", qos: .userInteractive)
    private var stream: SCStream?

    /// `frame` is called on the capture thread with each frame whose picture changed.
    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int,
         frame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.frame = frame
    }

    /// Whether DAM may record the screen, as far as macOS says ahead of trying.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS to let DAM record the screen, unless it may already. macOS asks the user
    /// once and lists this copy of DAM under Screen Recording; permission is tied to the
    /// app's signature, so another copy's does not count.
    static func requestPermission() {
        // Never from tests, where macOS's prompt would come up in front of the user.
        guard !hasPermission, NSClassFromString("XCTestCase") == nil else { return }
        DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
    }

    func start(completion: @escaping (Error?) -> Void) {
        // Asked of ScreenCaptureKit itself, which decides; the preflight can be wrong.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            if let error, (error as NSError).domain == SCStreamErrorDomain,
               (error as NSError).code == SCStreamError.userDeclined.rawValue {
                Self.requestPermission()
                return completion(MoonlightCaptureError.noPermission)
            }
            guard let display = content?.displays.first(where: { $0.displayID == self.displayID }) else {
                return completion(error ?? MoonlightCaptureError.displayNotFound(self.displayID))
            }
            let configuration = SCStreamConfiguration()
            configuration.width = self.width
            configuration.height = self.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.fps))
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.queueDepth = 3
            configuration.showsCursor = true
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                return completion(error)
            }
            self.stream = stream
            stream.startCapture { error in
                if let error { scLog.error("start: \(error.localizedDescription, privacy: .public)") }
                completion(error)
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        frame(buffer, CMSampleBufferGetPresentationTimeStamp(sample))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        scLog.error("stopped: \(error.localizedDescription, privacy: .public)")
    }
}
