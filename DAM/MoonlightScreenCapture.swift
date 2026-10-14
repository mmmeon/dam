//
//  MoonlightScreenCapture.swift
//
//  Captures one display for Moonlight with ScreenCaptureKit, at the stream's size and rate,
//  in the 4:2:0 format the encoder takes as is, and, when asked, what the Mac plays at
//  48 kHz stereo, DAM's own sounds left out. Each new frame and each piece of sound is
//  handed on the moment it arrives.
//

import CoreMedia
import Foundation
import ScreenCaptureKit
import os.log

private let scLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightCapture")

enum MoonlightCaptureError: Error {
    case noPermission
    case displayNotFound(CGDirectDisplayID)
    /// replayd, macOS's screen capture service, did not answer, even once restarted.
    case serviceNotAnswering
}

final class MoonlightScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    private let frame: (CVPixelBuffer, CMTime) -> Void
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.capture", qos: .userInteractive)
    private var stream: SCStream?
    private let lock = NSLock()
    private var stopped = false

    /// How long ScreenCaptureKit has to list the displays before replayd is taken to be stuck.
    /// replayd can lose track of an app replaced while it ran (a new build, say) and then
    /// never answer it; restarting replayd, which launchd does on demand, mends that.
    static var answerTimeout: TimeInterval = 2
    /// Lists what may be captured; replaced by tests.
    static var fetchContent: (@escaping (SCShareableContent?, Error?) -> Void) -> Void = {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false, completionHandler: $0)
    }
    /// Restarts replayd. It ignores SIGTERM and SIP keeps launchctl from restarting it, but
    /// it runs as the user, so DAM may kill it. Replaced by tests.
    static var restartService: () -> Void = {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-KILL", "replayd"]
        try? kill.run()
        kill.waitUntilExit()
    }

    /// Called on `audioQueue` with each piece of the Mac's sound; set before `start` to
    /// capture sound too.
    var audio: ((CMSampleBuffer) -> Void)?
    var audioQueue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.capture.audio", qos: .userInteractive)
    /// Called when capture stops on its own, as when the display goes away.
    var onStop: ((Error) -> Void)?

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
        fetchContent(restarted: false, completion: completion)
    }

    /// Asks ScreenCaptureKit for the display, restarting replayd once if it does not answer.
    private func fetchContent(restarted: Bool, completion: @escaping (Error?) -> Void) {
        let answerLock = NSLock()
        var answered = false
        let firstToAnswer: () -> Bool = {
            answerLock.lock(); defer { answerLock.unlock() }
            let first = !answered
            answered = true
            return first
        }
        // Asked of ScreenCaptureKit itself, which decides; the preflight can be wrong.
        Self.fetchContent { [weak self] content, error in
            guard firstToAnswer(), let self, !self.isStopped else { return }
            self.startStream(content: content, error: error, completion: completion)
        }
        queue.asyncAfter(deadline: .now() + Self.answerTimeout) { [weak self] in
            guard firstToAnswer(), let self, !self.isStopped else { return }
            guard !restarted else { return completion(MoonlightCaptureError.serviceNotAnswering) }
            scLog.error("ScreenCaptureKit did not answer; restarting replayd")
            Self.restartService()
            // launchd starts replayd again when it is next asked for.
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.fetchContent(restarted: true, completion: completion)
            }
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func startStream(content: SCShareableContent?, error: Error?, completion: @escaping (Error?) -> Void) {
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
        // The stream holds up to three frames at once (the last picture, the encoder's slot
        // and the one being encoded); with only that many, ScreenCaptureKit has nothing to
        // draw into and skips frames.
        configuration.queueDepth = 6
        configuration.showsCursor = true
        if self.audio != nil {
            configuration.capturesAudio = true
            configuration.sampleRate = MoonlightAudioEncoder.sampleRate
            configuration.channelCount = MoonlightAudioEncoder.channels
            configuration.excludesCurrentProcessAudio = true
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            if self.audio != nil {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
            }
        } catch {
            return completion(error)
        }
        self.stream = stream
        stream.startCapture { error in
            if let error { scLog.error("start: \(error.localizedDescription, privacy: .public)") }
            completion(error)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sample.isValid { audio?(sample) }
            return
        }
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
        if !isStopped { onStop?(error) }
    }
}
