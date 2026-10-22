//
//  MoonlightScreenCapture.swift
//
//  Captures one display for Moonlight with ScreenCaptureKit, at the stream's size and rate,
//  in the 4:2:0 format the encoder takes as is (for HDR, turned into HDR10's; see
//  HDR10Converter), and, when asked, what the Mac plays at
//  48 kHz stereo, DAM's own sounds left out. Each new frame and each piece of sound is
//  handed on the moment it arrives. A streaming display DAM has turned on its side is
//  captured that way up and each frame turned back, so the stream keeps its shape.
//

import CoreImage
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
    private let pixelFormat: OSType
    /// Turns frames into HDR10's, for an HDR stream; on `queue`.
    private let hdr10: HDR10Converter?
    private let frame: (CVPixelBuffer, CMTime) -> Void
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.capture", qos: .userInteractive)
    /// It and `rotationObserver` are under `lock`, with `stopped`.
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
    /// Whether frames show the pointer; set before `start`.
    var showsCursor = true
    /// Called when capture stops on its own, as when the display goes away.
    var onStop: ((Error) -> Void)?

    /// `frame` is called on the capture thread with each frame whose picture changed, in
    /// `pixelFormat`: the encoder's 4:2:0 unless asked for another, such as BGRA to show.
    /// With `hdr`, frames are HDR10's instead (see HDR10Converter), whatever `pixelFormat` says.
    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int,
         pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, hdr: Bool = false,
         frame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        // HDR as 10-bit RGB in PQ where it can be captured, else the picture as SDR is.
        self.pixelFormat = hdr && Self.capturesHDR ? kCVPixelFormatType_ARGB2101010LEPacked
            : hdr ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : pixelFormat
        // HDR capture's frames are in PQ already, SDR white where ScreenCaptureKit put it, so
        // they pass as they are; only frames captured as SDR are lifted to 203 nits.
        hdr10 = hdr ? HDR10Converter(width: width, height: height, gain: Self.capturesHDR ? 0 : nil) : nil
        self.frame = frame
    }

    /// Whether ScreenCaptureKit captures HDR (macOS 15 and later): its captureDynamicRange,
    /// set by name as this SDK predates it. Earlier, a display is captured as SDR.
    static let capturesHDR = SCStreamConfiguration().responds(to: NSSelectorFromString("setCaptureDynamicRange:"))
    /// The HDR10 metadata of what capture makes: SDR in HDR10 unless it captures HDR.
    static var hdrMetadata: MoonlightHDRMetadata { capturesHDR ? .canonical : .sdr }
    /// captureDynamicRange's HDR as a canonical HDR display would show it, rather than as the
    /// Mac's own would (1), as the stream is shown on another.
    static let canonicalHDR = 2

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
        // Under the lock with `stopped`, so a stop either finds the stream or keeps it from starting.
        lock.lock()
        let stopped = self.stopped
        if !stopped {
            self.stream = stream
            rotationObserver = NotificationCenter.default.addObserver(
                forName: StreamRotations.didChange, object: nil, queue: nil) { [weak self] _ in self?.rotationChanged() }
        }
        lock.unlock()
        guard !stopped else { return }
        stream.startCapture { [weak self] error in
            if let error { scLog.error("start: \(error.localizedDescription, privacy: .public)") }
            // Stopped while it started: stopping it then may not have taken.
            if error == nil, self?.isStopped ?? true { stream.stopCapture { _ in } }
            completion(error)
        }
    }

    /// What capture asks ScreenCaptureKit for, the display's own way up when it is turned.
    private func makeConfiguration(rotation: DisplayRotation) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        (configuration.width, configuration.height) = rotation.inverse.size(width: width, height: height)
        configuration.minimumFrameInterval = Self.minimumFrameInterval(
            fps: fps, refreshRate: CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0)
        configuration.pixelFormat = pixelFormat
        if hdr10 != nil, Self.capturesHDR {
            configuration.colorSpaceName = CGColorSpace.itur_2100_PQ
            configuration.setValue(Self.canonicalHDR, forKey: "captureDynamicRange")
        }
        // The stream holds up to three frames at once (the last picture, the encoder's slot
        // and the one being encoded); with only that many, ScreenCaptureKit has nothing to
        // draw into and skips frames.
        configuration.queueDepth = 6
        configuration.showsCursor = showsCursor
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
        let stream = self.stream
        self.stream = nil
        let rotationObserver = self.rotationObserver
        self.rotationObserver = nil
        lock.unlock()
        stream?.stopCapture { _ in }
        if let rotationObserver { NotificationCenter.default.removeObserver(rotationObserver) }
    }

    /// Follows the display being turned while it is captured: captures it the new way up
    /// and turns frames back by as much.
    private func rotationChanged() {
        let rotation = StreamRotations.shared.rotation(of: displayID)
        queue.async { [weak self] in
            guard let self, rotation != self.rotation else { return }
            self.lock.lock()
            let stream = self.stopped ? nil : self.stream
            self.lock.unlock()
            guard let stream else { return }
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
        rotator = rotation == .standard ? nil : FrameRotator(rotation: rotation, width: width, height: height,
                                                                    pixelFormat: pixelFormat)
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
            return hand(turned, time)
        }
        // Nor is one captured before it was turned back.
        guard width == height || CVPixelBufferGetWidth(buffer) != height || CVPixelBufferGetHeight(buffer) != width
        else { return }
        hand(buffer, time)
    }

    private func hand(_ buffer: CVPixelBuffer, _ time: CMTime) {
        guard let hdr10 else { return frame(buffer, time) }
        guard let converted = hdr10.convert(buffer) else { return scLog.error("could not turn a frame into HDR10") }
        frame(converted, time)
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

/// Turns captured frames into HDR10's: 10-bit 4:2:0 in BT.2020 with PQ, as the encoder takes
/// them as is. SDR white goes to 203 nits, BT.2408's reference white, where HDR10 players
/// show it (Moonlight's renderer included). Where Core Image puts it in PQ differs: 100 nits
/// on macOS 13, which looks dim there, 203 already on macOS 14 (GitHub's runners), so it is
/// found by turning a white frame into PQ (`measuredGain`). What is brighter than SDR white,
/// where capture has HDR, scales with it. On the GPU, about 6 ms a 1080p frame on the Intel
/// test Mac. On the capture queue.
final class HDR10Converter {
    /// The light PQ's `signal` (0...1) stands for, in nits (SMPTE ST 2084).
    static func pqNits(_ signal: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(max(signal, 0), 1 / m2)
        return 10_000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// The stops from where `context` puts SDR white in PQ to 203 nits: 1.02 on macOS 13, 0
    /// on 14, as a gain too small to see is none; nil when white can't be turned into PQ.
    /// White is measured as capture hands SDR over, BT.709 4:2:0, which Core Image may take
    /// differently from sRGB.
    static func measuredGain(in context: CIContext) -> Double? {
        guard let white = sdrWhite() else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(CIImage(cvPixelBuffer: white), toBitmap: &pixel, rowBytes: 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!)
        let nits = pqNits(Double(pixel[1]))
        guard nits > 20, nits < 1000 else { return nil }
        let gain = log2(203 / nits)
        return abs(gain) < 0.05 ? 0 : gain
    }

    /// A 2×2 white frame as capture hands SDR over: 8-bit 4:2:0 video range in BT.709.
    private static func sdrWhite() -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary,
                                  &made) == kCVReturnSuccess, let white = made else { return nil }
        CVPixelBufferLockBaseAddress(white, [])
        for (plane, value) in [(0, Int32(235)), (1, Int32(128))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(white, plane) else { continue }
            memset(base, value, CVPixelBufferGetBytesPerRowOfPlane(white, plane) * CVPixelBufferGetHeightOfPlane(white, plane))
        }
        CVPixelBufferUnlockBaseAddress(white, [])
        CVBufferSetAttachment(white, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(white, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(white, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return white
    }

    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                              .cacheIntermediates: false])
    private let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    private var pool: CVPixelBufferPool?
    private var gain = 0.0

    /// `gain` in stops; where this macOS puts SDR white unless given, measured with the
    /// context frames are turned with, or macOS 13's when it can't be.
    init?(width: Int, height: Int, gain: Double? = nil) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard pool != nil else { return nil }
        self.gain = gain ?? Self.measuredGain(in: context) ?? log2(203.0 / 100.0)
    }

    /// `buffer`, in any format Core Image reads and tagged with its colour, as HDR10, or nil
    /// when it could not be.
    func convert(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let out = made else { return nil }
        let picture = CIImage(cvPixelBuffer: buffer)
        let image = gain == 0 ? picture : picture.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: gain])
        context.render(image, to: out, bounds: image.extent, colorSpace: pq)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return out
    }
}

/// Turns frames by a rotation into buffers of the stream's size, in the capture's format.
/// On the capture queue.
final class FrameRotator {
    private let session: VTPixelRotationSession
    private var pool: CVPixelBufferPool?

    /// Frames come in on their side for a quarter turn and leave `width` × `height`.
    init?(rotation: DisplayRotation, width: Int, height: Int,
          pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
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
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
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

/// One capture of a display, picture and sound, shared by every Moonlight stream that asks
/// for it at the same size, rate and pointer setting: two devices on one display cost one
/// capture, and each encodes for itself. Started by the first to subscribe, stopped once the
/// last cancels. A stream joining a running capture gets its last picture at once, as a
/// still screen sends no more.
final class SharedScreenCapture {
    struct Key: Hashable {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let fps: Int
        let showsCursor: Bool
        var hdr = false
    }

    /// One stream's part: cancel it when the stream ends.
    final class Subscription {
        fileprivate weak var capture: SharedScreenCapture?
        fileprivate let frame: (CVPixelBuffer, CMTime) -> Void
        fileprivate let audio: (CMSampleBuffer) -> Void
        fileprivate let stopped: (Error) -> Void

        fileprivate init(frame: @escaping (CVPixelBuffer, CMTime) -> Void, audio: @escaping (CMSampleBuffer) -> Void,
                         stopped: @escaping (Error) -> Void) {
            self.frame = frame
            self.audio = audio
            self.stopped = stopped
        }

        func cancel() { capture?.remove(self) }
    }

    private static let registryLock = NSLock()
    private static var running: [Key: SharedScreenCapture] = [:]

    /// How many captures run; for tests.
    static var count: Int {
        registryLock.lock(); defer { registryLock.unlock() }
        return running.count
    }

    /// Makes the capture behind a subscription; replaced by tests.
    static var makeCapture: (Key, @escaping (CVPixelBuffer, CMTime) -> Void) -> MoonlightScreenCapture = { key, frame in
        MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height, fps: key.fps,
                               hdr: key.hdr, frame: frame)
    }
    /// Starts it; replaced by tests.
    static var startCapture: (MoonlightScreenCapture, @escaping (Error?) -> Void) -> Void = { $0.start(completion: $1) }

    /// Joins the capture for `key`, starting it if none runs. `frame` is called on the capture
    /// thread, `audio` on a queue of the capture's own; `started` once, with whether capture
    /// started; `stopped` if capture stops on its own once started, as when replayd dies or
    /// the display goes away. The capture is let go then, and the next to subscribe starts
    /// another.
    static func subscribe(_ key: Key, frame: @escaping (CVPixelBuffer, CMTime) -> Void,
                          audio: @escaping (CMSampleBuffer) -> Void,
                          started: @escaping (Error?) -> Void,
                          stopped: @escaping (Error) -> Void = { _ in }) -> Subscription {
        let subscription = Subscription(frame: frame, audio: audio, stopped: stopped)
        registryLock.lock()
        let shared: SharedScreenCapture
        let isNew: Bool
        if let existing = running[key] {
            shared = existing
            isNew = false
        } else {
            shared = SharedScreenCapture(key: key)
            running[key] = shared
            isNew = true
        }
        shared.add(subscription, started: started)
        registryLock.unlock()
        if isNew { shared.start() }
        return subscription
    }

    let key: Key
    private var capture: MoonlightScreenCapture?
    private let lock = NSLock()
    private var subscriptions: [Subscription] = []
    private var last: (buffer: CVPixelBuffer, time: CMTime)?
    /// How starting went, once it has; until then, who waits to hear.
    private var outcome: Result<Void, Error>?
    private var waiting: [(Error?) -> Void] = []
    private var stopped = false

    private init(key: Key) {
        self.key = key
    }

    private func start() {
        let capture = Self.makeCapture(key) { [weak self] buffer, time in self?.took(buffer, time) }
        capture.showsCursor = key.showsCursor
        capture.audio = { [weak self] sample in self?.took(sample) }
        capture.onStop = { [weak self] error in self?.stoppedOnItsOwn(error) }
        lock.lock()
        self.capture = capture
        lock.unlock()
        Self.startCapture(capture) { [weak self] error in self?.started(error) }
    }

    /// Lets the capture go, so no stream joins it, and tells those on it.
    private func stoppedOnItsOwn(_ error: Error) {
        stop()
        lock.lock()
        let subscriptions = self.subscriptions
        lock.unlock()
        subscriptions.forEach { $0.stopped(error) }
    }

    private func add(_ subscription: Subscription, started: @escaping (Error?) -> Void) {
        subscription.capture = self
        lock.lock()
        subscriptions.append(subscription)
        let outcome = self.outcome
        if outcome == nil { waiting.append(started) }
        let last = self.last
        lock.unlock()
        guard let outcome else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            if case .failure(let error) = outcome { return started(error) }
            started(nil)
            if let last { subscription.frame(last.buffer, last.time) }
        }
    }

    private func started(_ error: Error?) {
        lock.lock()
        outcome = error.map { .failure($0) } ?? .success(())
        let waiting = self.waiting
        self.waiting = []
        lock.unlock()
        // A capture that could not start is let go, so the next stream tries afresh.
        if error != nil { stop() }
        waiting.forEach { $0(error) }
    }

    private func took(_ buffer: CVPixelBuffer, _ time: CMTime) {
        lock.lock()
        last = (buffer, time)
        let subscriptions = self.subscriptions
        lock.unlock()
        for subscription in subscriptions { subscription.frame(buffer, time) }
    }

    private func took(_ sample: CMSampleBuffer) {
        lock.lock()
        let subscriptions = self.subscriptions
        lock.unlock()
        for subscription in subscriptions { subscription.audio(sample) }
    }

    private func remove(_ subscription: Subscription) {
        // Under the registry's lock, so no stream joins between the last leaving and the stop.
        Self.registryLock.lock()
        lock.lock()
        subscriptions.removeAll { $0 === subscription }
        let empty = subscriptions.isEmpty
        lock.unlock()
        if empty, Self.running[key] === self { Self.running[key] = nil }
        Self.registryLock.unlock()
        if empty { stopCapture() }
    }

    private func stop() {
        Self.registryLock.lock()
        if Self.running[key] === self { Self.running[key] = nil }
        Self.registryLock.unlock()
        stopCapture()
    }

    private func stopCapture() {
        lock.lock()
        let first = !stopped
        stopped = true
        let capture = self.capture
        self.capture = nil
        lock.unlock()
        if first { capture?.stop() }
    }
}
