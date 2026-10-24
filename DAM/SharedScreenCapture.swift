//
//  SharedScreenCapture.swift
//
//  One capture of a display at a size, shared by every stream of it (Moonlight's, the
//  browser's, OpenDisplay's), made with ScreenCaptureKit (MoonlightScreenCapture.swift) or,
//  where that can't run, CGDisplayStream (DisplayStreamCapture.swift).
//

import CoreMedia
import CoreVideo
import Foundation

enum MoonlightCaptureError: Error {
    case noPermission
    case displayNotFound(CGDirectDisplayID)
    /// replayd, macOS's screen capture service, did not answer, even once restarted.
    case serviceNotAnswering
}

/// What SharedScreenCapture needs of a capture: ScreenCaptureKit's or CGDisplayStream's.
protocol ScreenCaptureSource: AnyObject {
    /// Whether frames show the pointer; set before `start`.
    var showsCursor: Bool { get set }
    /// Called with each piece of the Mac's sound, where the capture has sound; set before `start`.
    var audio: ((CMSampleBuffer) -> Void)? { get set }
    /// Called when capture stops on its own, as when the display goes away.
    var onStop: ((Error) -> Void)? { get set }
    func start(completion: @escaping (Error?) -> Void)
    func stop()
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
        /// Frames are handed over under it, one at a time, with `hasFrame`.
        private let delivery = NSLock()
        private var hasFrame = false

        fileprivate init(frame: @escaping (CVPixelBuffer, CMTime) -> Void, audio: @escaping (CMSampleBuffer) -> Void,
                         stopped: @escaping (Error) -> Void) {
            self.frame = frame
            self.audio = audio
            self.stopped = stopped
        }

        func cancel() { capture?.remove(self) }

        /// Hands over a frame as it is captured.
        fileprivate func deliver(_ buffer: CVPixelBuffer, _ time: CMTime) {
            delivery.lock(); defer { delivery.unlock() }
            hasFrame = true
            frame(buffer, time)
        }

        /// Hands over the capture's last picture on joining, unless a newer came first.
        fileprivate func deliverLast(_ buffer: CVPixelBuffer, _ time: CMTime) {
            delivery.lock(); defer { delivery.unlock() }
            guard !hasFrame else { return }
            hasFrame = true
            frame(buffer, time)
        }
    }

    private static let registryLock = NSLock()
    private static var running: [Key: SharedScreenCapture] = [:]

    /// How many captures run; for tests.
    static var count: Int {
        registryLock.lock(); defer { registryLock.unlock() }
        return running.count
    }

    /// Whether captures use CGDisplayStream rather than ScreenCaptureKit: in the login window
    /// agent, where ScreenCaptureKit can't run, or when DAM's debug setting asks for it.
    static var usesDisplayStream = UserDefaults.dam.bool(forKey: "\(AppIdentity.shortID).capture.displayStream")

    /// The HDR10 metadata of what capture makes; SDR in the login window agent, whose
    /// CGDisplayStream capture is SDR only.
    static var hdrMetadata: MoonlightHDRMetadata {
        #if LOGIN_AGENT
        return .sdr
        #else
        return MoonlightScreenCapture.hdrMetadata
        #endif
    }

    /// How long capture may wait for macOS's capture service to answer before it starts;
    /// CGDisplayStream, the agent's, waits for none.
    static var answerTimeout: TimeInterval {
        #if LOGIN_AGENT
        return 0
        #else
        return MoonlightScreenCapture.answerTimeout
        #endif
    }

    /// Makes the capture behind a subscription; replaced by tests.
    static var makeCapture: (Key, @escaping (CVPixelBuffer, CMTime) -> Void) -> ScreenCaptureSource = { key, frame in
        #if LOGIN_AGENT
        // ScreenCaptureKit isn't even built into the agent.
        return DisplayStreamCapture(displayID: key.displayID, width: key.width, height: key.height, fps: key.fps,
                                    frame: frame)
        #else
        if usesDisplayStream {
            return DisplayStreamCapture(displayID: key.displayID, width: key.width, height: key.height, fps: key.fps,
                                        frame: frame)
        }
        return MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height, fps: key.fps,
                                      hdr: key.hdr, frame: frame)
        #endif
    }
    /// Starts it; replaced by tests.
    static var startCapture: (ScreenCaptureSource, @escaping (Error?) -> Void) -> Void = { $0.start(completion: $1) }

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
    private var capture: ScreenCaptureSource?
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
            if let last { subscription.deliverLast(last.buffer, last.time) }
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
        for subscription in subscriptions { subscription.deliver(buffer, time) }
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
