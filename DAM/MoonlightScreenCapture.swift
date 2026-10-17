//
//  MoonlightScreenCapture.swift
//
//  Captures one display for Moonlight with ScreenCaptureKit, at the stream's size and rate,
//  in the 4:2:0 format the encoder takes as is, and, when asked, what the Mac plays at
//  48 kHz stereo, DAM's own sounds left out. Each new frame and each piece of sound is
//  handed on the moment it arrives. A streaming display DAM has turned on its side is
//  captured that way up and each frame turned back, so the stream keeps its shape.
//

import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox
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
    /// How far frames are turned before they are handed on; on `queue` once capture runs.
    private var rotation: DisplayRotation = .standard
    private var rotator: FrameRotator?
    private var rotationObserver: NSObjectProtocol?

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
        // No frame comes before the stream starts, so this is set ahead of `queue`.
        let rotation = StreamRotations.shared.rotation(of: self.displayID)
        setRotation(rotation)
        let configuration = makeConfiguration(rotation: rotation)
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
        rotationObserver = NotificationCenter.default.addObserver(
            forName: StreamRotations.didChange, object: nil, queue: nil) { [weak self] _ in self?.rotationChanged() }
        stream.startCapture { error in
            if let error { scLog.error("start: \(error.localizedDescription, privacy: .public)") }
            completion(error)
        }
    }

    /// What capture asks ScreenCaptureKit for, the display's own way up when it is turned.
    private func makeConfiguration(rotation: DisplayRotation) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        (configuration.width, configuration.height) = rotation.inverse.size(width: width, height: height)
        configuration.minimumFrameInterval = Self.minimumFrameInterval(
            fps: fps, refreshRate: CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // The stream holds up to three frames at once (the last picture, the encoder's slot
        // and the one being encoded); with only that many, ScreenCaptureKit has nothing to
        // draw into and skips frames.
        configuration.queueDepth = 6
        configuration.showsCursor = true
        if audio != nil {
            configuration.capturesAudio = true
            configuration.sampleRate = MoonlightAudioEncoder.sampleRate
            configuration.channelCount = MoonlightAudioEncoder.channels
            configuration.excludesCurrentProcessAudio = true
        }
        return configuration
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        stream?.stopCapture { _ in }
        stream = nil
        if let rotationObserver { NotificationCenter.default.removeObserver(rotationObserver) }
        rotationObserver = nil
    }

    /// Follows the display being turned while it is captured: captures it the new way up
    /// and turns frames back by as much.
    private func rotationChanged() {
        let rotation = StreamRotations.shared.rotation(of: displayID)
        queue.async { [weak self] in
            guard let self, let stream = self.stream, rotation != self.rotation, !self.isStopped else { return }
            scLog.debug("display \(self.displayID) turned to \(rotation.rawValue)")
            self.setRotation(rotation)
            let configuration = self.makeConfiguration(rotation: rotation)
            stream.updateConfiguration(configuration) { error in
                if let error { scLog.error("turn: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// On `queue`.
    private func setRotation(_ rotation: DisplayRotation) {
        self.rotation = rotation
        rotator = rotation == .standard ? nil : FrameRotator(rotation: rotation, width: width, height: height)
        if rotation != .standard, rotator == nil { scLog.error("could not turn frames by \(rotation.rawValue)") }
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
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pacer.allows(time) else { return }
        if let rotator {
            // A frame captured before the display was turned is the other way up still.
            guard CVPixelBufferGetWidth(buffer) == rotation.inverse.size(width: width, height: height).width,
                  let turned = rotator.rotate(buffer) else { return }
            return frame(turned, time)
        }
        // Nor is one captured before it was turned back.
        guard width == height || CVPixelBufferGetWidth(buffer) != height || CVPixelBufferGetHeight(buffer) != width
        else { return }
        frame(buffer, time)
    }

    /// The shortest time ScreenCaptureKit is asked to leave between frames. Asked for exactly
    /// a frame time, it can skip frames that come a little early, which OpenDisplay measured
    /// as about 51 of 60 fps. Half a frame time avoids that, but only while the display can't
    /// show more frames than the stream wants; asked for 30 of a 60 Hz display, a loose limit
    /// lets 39 or more through. An unknown rate (0) keeps the exact limit.
    static func minimumFrameInterval(fps: Int, refreshRate: Double) -> CMTime {
        let loose = refreshRate > 0 && Int(refreshRate.rounded()) <= fps
        return CMTime(value: 1, timescale: CMTimeScale(loose ? 2 * fps : fps))
    }

    private lazy var pacer = FramePacer(fps: fps)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        scLog.error("stopped: \(error.localizedDescription, privacy: .public)")
        if !isStopped { onStop?(error) }
    }
}

/// Turns frames by a rotation into buffers of the stream's size, in the capture's format.
/// On the capture queue.
final class FrameRotator {
    private let session: VTPixelRotationSession
    private var pool: CVPixelBufferPool?

    /// Frames come in on their side for a quarter turn and leave `width` × `height`.
    init?(rotation: DisplayRotation, width: Int, height: Int) {
        var session: VTPixelRotationSession?
        guard VTPixelRotationSessionCreate(nil, &session) == noErr,
              let session else { return nil }
        let angle: CFString
        switch rotation {
        case .standard:      angle = kVTRotation_0
        case .quarter:       angle = kVTRotation_CW90
        case .half:          angle = kVTRotation_180
        case .threeQuarters: angle = kVTRotation_CCW90
        }
        VTSessionSetProperty(session, key: kVTPixelRotationPropertyKey_Rotation, value: angle)
        self.session = session
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard pool != nil else { return nil }
    }

    deinit { VTPixelRotationSessionInvalidate(session) }

    /// `buffer` turned, or nil when it could not be.
    func rotate(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              VTPixelRotationSessionRotateImage(session, buffer, out) == noErr
        else { return nil }
        CVBufferPropagateAttachments(buffer, out)
        return out
    }
}

/// Leaves out frames that come much sooner than the stream's rate allows. The display's rate
/// can rise after capture starts, with a mode chosen in System Settings, and a loose
/// `minimumFrameInterval` would then pass every refresh on to the encoder. On the capture
/// queue.
struct FramePacer {
    private let shortest: Double
    private var last: Double?

    init(fps: Int) { shortest = 0.75 / Double(fps) }

    mutating func allows(_ time: CMTime) -> Bool {
        let seconds = CMTimeGetSeconds(time)
        if let last, seconds - last < shortest, seconds >= last { return false }
        last = seconds
        return true
    }
}
