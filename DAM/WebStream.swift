//
//  WebStream.swift
//
//  Streams a display to browsers and media players over plain HTTP, on the port Moonlight
//  finds this Mac on: one endless response of fragmented MP4 at /stream.mp4, which a page
//  at /watch plays through Media Source Extensions and mpv, ffplay or VLC play as it is.
//  The capture and encoder are Moonlight's; each stream has a profile that trades delay
//  for picture quality, from Interactive (as Moonlight gets it) to Viewing (frames out of
//  order, bigger bursts, regular keyframes, a second of buffer in the browser).
//
//  Viewers of one display with the same settings share a session: one capture, one
//  encoder, and each frame fragmented once. A viewer joining waits for a keyframe, and
//  one that cannot keep up (more than a second of the stream unsent) skips to the next
//  keyframe rather than fall ever further behind.
//

import CoreGraphics
import CoreMedia
import Foundation
import Network
import os.log

private let wsLog = Logger(subsystem: AppIdentity.bundleID, category: "WebStream")

// MARK: - Profiles

/// How a stream trades delay for picture quality.
enum StreamProfile: String, CaseIterable {
    case interactive
    case balanced
    case viewing

    var title: String {
        switch self {
        case .interactive: return "Interactive"
        case .balanced: return "Balanced"
        case .viewing: return "Viewing"
        }
    }

    var summary: String {
        switch self {
        case .interactive: return "Lowest delay, for working on the display: frames go out the moment they are encoded."
        case .balanced: return "A little buffer against Wi-Fi hiccups, and bigger keyframes."
        case .viewing: return "Best picture, about a second behind: frames out of order and regular keyframes."
        }
    }

    /// Kilobits per second unless the request says otherwise.
    var defaultBitrateKbps: Int {
        switch self {
        case .interactive: return 20_000
        case .balanced: return 30_000
        case .viewing: return 40_000
        }
    }

    /// Seconds of stream a browser keeps ahead of playback.
    var bufferSeconds: Double {
        switch self {
        case .interactive: return 0.05
        case .balanced: return 0.25
        case .viewing: return 1
        }
    }

    func encoderSettings(width: Int, height: Int, fps: Int, bitrateKbps: Int) -> MoonlightVideoEncoder.Settings {
        var settings = MoonlightVideoEncoder.Settings(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps)
        // The stream fills its grid itself, with repeats where the screen is still.
        settings.steady = true
        switch self {
        case .interactive:
            settings.prioritizeSpeed = true
        case .balanced:
            settings.rateLimitMultiple = 2
            settings.rateLimitWindow = 1
        case .viewing:
            settings.reordering = true
            settings.rateLimitMultiple = 3
            settings.rateLimitWindow = 2
            settings.keyFrameInterval = 2
        }
        return settings
    }

    private static let preferredKey = "\(AppIdentity.shortID).stream.profile"

    /// The profile streams get unless they ask for one; chosen in the menu.
    static var preferred: StreamProfile {
        get { UserDefaults.dam.string(forKey: preferredKey).flatMap(StreamProfile.init(rawValue:)) ?? .interactive }
        set { UserDefaults.dam.set(newValue.rawValue, forKey: preferredKey) }
    }
}

// MARK: - Requests

/// What a request for /stream.mp4 asks for, from its query.
struct WebStreamRequest: Equatable {
    /// The app (streaming display) as Moonlight lists it; nil for the first, or a new one.
    var app: Int?
    var profile: StreamProfile
    var bitrateKbps: Int
    /// Frames per second; nil for the display's rate.
    var fps: Int?
    /// The picture's size; nil for the display's pixels, within `maxPixels`.
    var width: Int?
    var height: Int?
    /// The size and rate of a display made for the stream when none is listed.
    var newDisplay = (width: 1920, height: 1080, fps: 60)
    /// Whether the stream carries sound. Without it, players show each frame as it lands;
    /// with it, they wait for the sound of the same moment, which comes a little later.
    var audio = true

    static func == (a: WebStreamRequest, b: WebStreamRequest) -> Bool {
        a.app == b.app && a.profile == b.profile && a.bitrateKbps == b.bitrateKbps && a.fps == b.fps
            && a.width == b.width && a.height == b.height && a.newDisplay == b.newDisplay && a.audio == b.audio
    }

    /// The most pixels a stream takes from a display: a HiDPI display is scaled down to fit.
    static let maxPixels = 2560 * 1600

    static func parse(_ query: [String: String], preferred: StreamProfile) -> WebStreamRequest {
        let profile = query["profile"].flatMap(StreamProfile.init(rawValue:)) ?? preferred
        var request = WebStreamRequest(app: query["app"].flatMap(Int.init), profile: profile,
                                       bitrateKbps: profile.defaultBitrateKbps)
        if let bitrate = query["bitrate"].flatMap(Int.init) { request.bitrateKbps = min(max(bitrate, 1000), 150_000) }
        if let fps = query["fps"].flatMap(Int.init) { request.fps = min(max(fps, 5), 120) }
        if let width = query["width"].flatMap(Int.init), let height = query["height"].flatMap(Int.init),
           width >= 160, height >= 90, width * height <= maxPixels {
            request.width = width & ~1
            request.height = height & ~1
        }
        let mode = (query["mode"] ?? "").split(separator: "x").compactMap { Int($0) }
        if mode.count == 3, mode[0] >= 640, mode[1] >= 360, mode[0] * mode[1] <= maxPixels, mode[2] >= 30 {
            request.newDisplay = (mode[0], mode[1], min(mode[2], 120))
        }
        if let audio = query["audio"]?.lowercased(), ["0", "false", "no", "off"].contains(audio) { request.audio = false }
        return request
    }
}

// MARK: - Server

/// Answers the stream's requests on the Moonlight host's HTTP port and keeps the sessions.
final class WebStreamServer {

    /// The displays Moonlight lists, as the stream lists them too.
    var apps: () -> [MoonlightApp] = { [] }
    /// Makes and removes a display for streams when none is listed; as MoonlightHost's.
    var makeDisplay: ((_ width: Int, _ height: Int, _ fps: Int, _ done: @escaping (CGDirectDisplayID?) -> Void) -> Void)?
    var removeDisplay: ((CGDirectDisplayID) -> Void)?
    var preferredProfile: () -> StreamProfile = { .preferred }
    /// The number watching changed; on the main queue.
    var onChange: (() -> Void)?

    private var sessions: [WebStreamSession.Key: WebStreamSession] = [:]
    /// A display made for streams, removed once no session uses it.
    private var ownedDisplay: CGDirectDisplayID?
    /// Requests waiting for the display being made.
    private var waitingForDisplay: [(WebStreamRequest, NWConnection)] = []

    var viewerCount: Int { sessions.values.reduce(0) { $0 + $1.viewerCount } }

    /// Answers `path` if it is the stream's; returns whether it was. On the main queue.
    func handle(path: String, query: [String: String], on connection: NWConnection) -> Bool {
        switch path {
        case "/", "/watch":
            send(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(WebStreamPage.html.utf8), to: connection)
        case "/apps.json":
            send(status: "200 OK", contentType: "application/json", body: appsJSON(), to: connection)
        case "/stream.mp4":
            serve(WebStreamRequest.parse(query, preferred: preferredProfile()), on: connection)
        default:
            return false
        }
        return true
    }

    /// Ends every session; their viewers' connections are closed.
    func stopAll() {
        for session in sessions.values { session.stop() }
        sessions = [:]
        for (_, connection) in waitingForDisplay { connection.cancel() }
        waitingForDisplay = []
        if let ownedDisplay {
            removeDisplay?(ownedDisplay)
            self.ownedDisplay = nil
        }
    }

    private func appsJSON() -> Data {
        let apps = self.apps().map { ["id": $0.id, "title": $0.title] as [String: Any] }
        let bitrates = Dictionary(uniqueKeysWithValues: StreamProfile.allCases.map { ($0.rawValue, $0.defaultBitrateKbps) })
        let buffers = Dictionary(uniqueKeysWithValues: StreamProfile.allCases.map { ($0.rawValue, $0.bufferSeconds) })
        let object: [String: Any] = ["apps": apps, "profile": preferredProfile().rawValue,
                                     "bitrates": bitrates, "buffers": buffers]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private func serve(_ request: WebStreamRequest, on connection: NWConnection) {
        let apps = self.apps()
        let displayID: CGDirectDisplayID
        if let app = request.app {
            guard let listed = apps.first(where: { $0.id == app }) else {
                return send(status: "404 Not Found", body: Data("No such display\n".utf8), to: connection)
            }
            displayID = listed.displayID
        } else if let first = apps.first {
            displayID = first.displayID
        } else if let ownedDisplay, DisplayArrangement.onlineDisplayIDs().contains(ownedDisplay) {
            displayID = ownedDisplay
        } else {
            guard let makeDisplay else {
                return send(status: "503 Service Unavailable", body: Data("No display to stream\n".utf8), to: connection)
            }
            waitingForDisplay.append((request, connection))
            guard waitingForDisplay.count == 1 else { return }
            let (width, height, fps) = request.newDisplay
            wsLog.debug("making a \(width)×\(height)@\(fps) display to stream")
            makeDisplay(width, height, fps) { [weak self] id in
                guard let self else { return }
                let waiting = self.waitingForDisplay
                self.waitingForDisplay = []
                guard let id else {
                    for (_, connection) in waiting {
                        self.send(status: "503 Service Unavailable",
                                  body: Data("\(AppIdentity.name) could not make a display\n".utf8), to: connection)
                    }
                    return
                }
                self.ownedDisplay = id
                for (request, connection) in waiting { self.serve(request, on: connection) }
            }
            return
        }
        guard let size = Self.pictureSize(of: displayID, request: request) else {
            return send(status: "503 Service Unavailable", body: Data("The display is not on\n".utf8), to: connection)
        }
        let key = WebStreamSession.Key(displayID: displayID, profile: request.profile, bitrateKbps: request.bitrateKbps,
                                       fps: size.fps, width: size.width, height: size.height)
        let session: WebStreamSession
        if let running = sessions[key] {
            session = running
        } else {
            do {
                session = try WebStreamSession(key: key)
            } catch {
                wsLog.error("session: \(String(describing: error), privacy: .public)")
                return send(status: "503 Service Unavailable", body: Data("The encoder could not start\n".utf8), to: connection)
            }
            session.onEnd = { [weak self] ended in self?.ended(ended) }
            session.onChange = { [weak self] in self?.onChange?() }
            sessions[key] = session
            session.start()
        }
        let viewer = WebStreamViewer(connection: connection, maxInFlight: request.bitrateKbps * 125, audio: request.audio)
        session.add(viewer)
    }

    /// The stream's size and rate for `displayID`: what the request asks, else the display's
    /// pixels, scaled to fit `maxPixels`, at its refresh rate; nil if it is off.
    static func pictureSize(of displayID: CGDirectDisplayID, request: WebStreamRequest) -> (width: Int, height: Int, fps: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        var width = mode.pixelWidth
        var height = mode.pixelHeight
        guard width > 0, height > 0 else { return nil }
        let rate = Int(mode.refreshRate.rounded())
        let fps = request.fps ?? (rate > 0 ? rate : 60)
        if let w = request.width, let h = request.height {
            return (w, h, fps)
        }
        if width * height > WebStreamRequest.maxPixels {
            let scale = (Double(WebStreamRequest.maxPixels) / Double(width * height)).squareRoot()
            width = Int(Double(width) * scale) & ~1
            height = Int(Double(height) * scale) & ~1
        }
        return (width, height, fps)
    }

    private func ended(_ session: WebStreamSession) {
        guard sessions[session.key] === session else { return }
        sessions[session.key] = nil
        if let ownedDisplay, !sessions.keys.contains(where: { $0.displayID == ownedDisplay }) {
            removeDisplay?(ownedDisplay)
            self.ownedDisplay = nil
        }
        onChange?()
    }

    private func send(status: String, contentType: String = "text/plain", body: Data, to connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" +
                   "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Session

/// One display captured and encoded for the viewers of one stream.
final class WebStreamSession {

    struct Key: Hashable {
        let displayID: CGDirectDisplayID
        let profile: StreamProfile
        let bitrateKbps: Int
        let fps: Int
        let width: Int
        let height: Int
    }

    let key: Key
    /// Called on the main queue once the session ends on its own: its last viewer left, or
    /// capture stopped.
    var onEnd: ((WebStreamSession) -> Void)?
    var onChange: (() -> Void)?

    /// Everything after capture happens here: encoding sound, fragmenting, handing out.
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).webstream.session", qos: .userInteractive)
    private let fragmenter = MP4Fragmenter()
    private var encoder: MoonlightVideoEncoder?
    /// Whether the encoder sends frames out of order (B-frames).
    private let reorders: Bool
    private var capture: MoonlightScreenCapture?
    private var aac: MoonlightAudioEncoder?
    private var viewers: [WebStreamViewer] = []
    private var ended = false
    /// Whether the last viewer has left and the session ends unless one comes.
    private var closing = false
    private let lock = NSLock()
    /// The last picture captured, its slot on the grid, and when it came.
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime, at: UInt64)?
    /// Frames' slots; on `queue`.
    private var grid: FrameGrid
    private var repeater: DispatchSourceTimer?
    private var keyFrames = MoonlightKeyFrameThrottle()
    /// Keyframes for viewers that fell behind come rarer: each costs everyone.
    private var catchUpKeyFrames = MoonlightKeyFrameThrottle(interval: 2_000_000_000)
    private var activity: NSObjectProtocol?
    private var statsTimer: DispatchSourceTimer?
    private let stats = MoonlightStreamStats()
    /// Nanoseconds frames spent in the encoder, and how many; under `lock`.
    private var encodeTime: (total: UInt64, frames: Int) = (0, 0)
    /// Frames given to the encoder: captured, and repeats filling the grid; under `lock`.
    private var given: (real: Int, repeats: Int) = (0, 0)

    // The stream's clock, on `queue`: the first frame's time is its zero.
    private var anchor: CMTime?
    /// The init segment and codecs for viewers with sound and without.
    private var initSegment: (sound: Data, silent: Data)?
    private var codecs = (sound: "", silent: "")
    /// Where sound's samples stand on the stream's clock, in 48 kHz units: the time of the
    /// first sample given to the encoder, and how many followed it.
    private var audioStart: Int64?
    private var audioFed = 0
    private var audioPackets = 0
    private var aacPending: [Data] = []
    private var silenceTimer: DispatchSourceTimer?
    /// Samples the AAC encoder puts before the first real one.
    static let aacPriming = 2112

    var viewerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return viewers.count
    }

    init(key: Key) throws {
        self.key = key
        grid = FrameGrid(fps: key.fps)
        let settings = key.profile.encoderSettings(width: key.width, height: key.height, fps: key.fps,
                                                   bitrateKbps: key.bitrateKbps)
        reorders = settings.reordering
        encoder = try MoonlightVideoEncoder(settings: settings) { [weak self] frame in
            self?.queue.async { self?.took(frame) }
        }
        aac = try MoonlightAudioEncoder(codec: .aac, bitrate: 192_000) { [weak self] packet in
            self?.aacPending.append(packet)
        }
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Streaming a display")
        let capture = MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height,
                                             fps: key.fps) { [weak self] buffer, time in
            guard let self else { return }
            let at = DispatchTime.now().uptimeNanoseconds
            self.queue.async { self.encode(buffer, captured: time, at: at) }
        }
        capture.audioQueue = queue
        capture.audio = { [weak self] sample in self?.took(audio: sample) }
        capture.onStop = { [weak self] error in self?.end("capture stopped: \(error.localizedDescription)") }
        lock.lock()
        self.capture = capture
        lock.unlock()
        capture.start { [weak self] error in
            guard let error else { return }
            self?.end("capture: \(error.localizedDescription)")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1 / Double(key.fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.repeatIfStill() }
        repeater = timer
        timer.resume()
        let silence = DispatchSource.makeTimerSource(queue: queue)
        silence.schedule(deadline: .now() + 0.1, repeating: 0.02, leeway: .milliseconds(5))
        silence.setEventHandler { [weak self] in self?.padSilence() }
        silenceTimer = silence
        silence.resume()
        let statsTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        statsTimer.schedule(deadline: .now() + 5, repeating: 5)
        statsTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let encode = self.encodeTime
            let given = self.given
            self.encodeTime = (0, 0)
            self.given = (0, 0)
            self.lock.unlock()
            let encodeMs = encode.frames > 0 ? Double(encode.total / UInt64(encode.frames)) / 1e6 : 0
            wsLog.debug("stats (\(self.viewerCount) watching): \(self.stats.take(seconds: 5), privacy: .public); given \(given.real) captured + \(given.repeats) repeats; encode \(encodeMs, format: .fixed(precision: 1)) ms")
        }
        self.statsTimer = statsTimer
        statsTimer.resume()
        wsLog.debug("session \(self.key.width)×\(self.key.height)@\(self.key.fps) \(self.key.profile.rawValue, privacy: .public) \(self.key.bitrateKbps) kbps from display \(self.key.displayID)")
    }

    /// Takes `viewer` in; it gets the stream from the next keyframe.
    func add(_ viewer: WebStreamViewer) {
        lock.lock()
        viewers.append(viewer)
        closing = false
        lock.unlock()
        viewer.onClose = { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            self.remove(viewer)
        }
        viewer.watch()
        wsLog.debug("viewer joined: \(self.viewerCount) watching")
        queue.async { [weak self] in self?.requestKeyFrame(catchingUp: false) }
        DispatchQueue.main.async { self.onChange?() }
    }

    private func remove(_ viewer: WebStreamViewer) {
        lock.lock()
        viewers.removeAll { $0 === viewer }
        let empty = viewers.isEmpty
        if empty { closing = true }
        lock.unlock()
        wsLog.debug("viewer left: \(self.viewerCount) watching")
        DispatchQueue.main.async { self.onChange?() }
        guard empty else { return }
        // A reload comes back within a moment; the capture is kept for it.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillEmpty = self.closing && self.viewers.isEmpty
            self.lock.unlock()
            if stillEmpty { self.end("last viewer left") }
        }
    }

    /// Stops capturing and closes every viewer's connection.
    func stop() {
        lock.lock()
        ended = true
        let capture = self.capture
        self.capture = nil
        self.encoder = nil
        let viewers = self.viewers
        self.viewers = []
        lock.unlock()
        capture?.stop()
        for viewer in viewers {
            viewer.onClose = nil
            viewer.close()
        }
        queue.async { [self] in
            repeater?.cancel(); repeater = nil
            silenceTimer?.cancel(); silenceTimer = nil
            aac = nil
        }
        statsTimer?.cancel()
        statsTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func end(_ reason: String) {
        lock.lock()
        let first = !ended
        lock.unlock()
        guard first else { return }
        wsLog.debug("session ended: \(reason, privacy: .public)")
        stop()
        DispatchQueue.main.async { self.onEnd?(self) }
    }

    // MARK: Video

    /// A frame's interval, in nanoseconds.
    private var interval: UInt64 { 1_000_000_000 / UInt64(key.fps) }

    /// Gives the encoder a fresh picture, in its slot on the grid. Everything the encoder
    /// is given comes through `queue`, so frames reach it in the order of their slots.
    private func encode(_ buffer: CVPixelBuffer, captured time: CMTime, at: UInt64) {
        let slot = grid.snap(time)
        lock.lock()
        lastFrame = (buffer, slot, at)
        given.real += 1
        let encoder = self.encoder
        lock.unlock()
        encoder?.encode(buffer, at: slot)
    }

    /// `time` on the stream's clock, in its timescale, snapped to the nearest slot.
    private func onGrid(_ time: CMTime, from anchor: CMTime) -> Int64 {
        let slot = Int64((CMTimeGetSeconds(CMTimeSubtract(time, anchor)) * Double(key.fps)).rounded())
        return slot * Int64(MP4Fragmenter.videoTimescale) / Int64(key.fps)
    }

    /// Fragments a frame and hands it to the viewers; on `queue`.
    private func took(_ frame: MoonlightVideoEncoder.Frame) {
        let decode = CMSampleBufferGetDecodeTimeStamp(frame.sample)
        // The encoder's decode times matter only when it reorders frames; otherwise they
        // are the presentation times, give or take its rounding.
        let decodeTime = reorders && decode.isValid ? decode : frame.time
        if anchor == nil { anchor = CMTimeMinimum(decodeTime, frame.time) }
        guard let anchor, let sample = MoonlightVideoEncoder.avcc(frame.sample) else { return }
        if frame.isKeyFrame, let (sets, _) = MoonlightVideoEncoder.parameterSets(frame.sample) {
            let sps = sets.filter { $0.first.map { $0 & 0x1F == 7 } ?? false }
            let pps = sets.filter { $0.first.map { $0 & 0x1F == 8 } ?? false }
            let video = MP4Fragmenter.VideoConfig(width: key.width, height: key.height, sps: sps, pps: pps)
            initSegment = (fragmenter.initSegment(video: video, audio: true), fragmenter.initSegment(video: video, audio: false))
            codecs = (MP4Fragmenter.codecs(sps: sps.first ?? Data(), audio: true),
                      MP4Fragmenter.codecs(sps: sps.first ?? Data(), audio: false))
        }
        guard let initSegment else { return }
        // Both times sit on the grid, whatever rounding the encoder did on the way.
        let dts = onGrid(decodeTime, from: anchor)
        let pts = onGrid(frame.time, from: anchor)
        let fragment = fragmenter.videoFragment(sample, decodeTime: dts, duration: MP4Fragmenter.videoTimescale / key.fps,
                                                compositionOffset: Int(pts - dts), keyFrame: frame.isKeyFrame)
        lock.lock()
        let viewers = self.viewers
        encodeTime.total += frame.encoded - frame.submitted
        encodeTime.frames += 1
        lock.unlock()
        var waiting = false, behind = false
        for viewer in viewers {
            switch viewer.take(video: fragment, keyFrame: frame.isKeyFrame,
                               codecs: viewer.audio ? codecs.sound : codecs.silent,
                               initSegment: viewer.audio ? initSegment.sound : initSegment.silent) {
            case .taken: break
            case .waitingForKeyFrame: waiting = true
            case .fellBehind: behind = true
            }
        }
        if waiting { requestKeyFrame(catchingUp: false) }
        if behind { requestKeyFrame(catchingUp: true) }
        stats.video(packets: 1, bytes: fragment.count, refused: 0, keyFrame: frame.isKeyFrame)
    }

    /// The next frame as a keyframe, from the last picture at once if the screen is still.
    private func requestKeyFrame(catchingUp: Bool) {
        lock.lock()
        let decision = catchingUp ? catchUpKeyFrames.request(at: DispatchTime.now().uptimeNanoseconds)
                                  : keyFrames.request(at: DispatchTime.now().uptimeNanoseconds)
        switch decision {
        case .now:
            break
        case .later(let wait):
            lock.unlock()
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [weak self] in
                self?.requestKeyFrame(catchingUp: catchingUp)
            }
            return
        case .alreadyDue:
            lock.unlock()
            return
        }
        let encoder = self.encoder
        let last = lastFrame
        lock.unlock()
        stats.keyFrameRequested()
        encoder?.requestKeyFrame()
        // A still screen gets its keyframe from the last picture at once; a moving one
        // from its next frame.
        if let last, DispatchTime.now().uptimeNanoseconds - last.at > interval * 3 / 2 {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            encoder?.encode(last.buffer, at: grid.nextSlot(before: now) ?? grid.snap(now))
        }
    }

    /// Gives the encoder the last picture again for each slot of the grid gone by with no
    /// frame of its own: every slot while the screen is still, the odd one the capture
    /// skipped while it moves. Players then get a frame every interval, as the stream
    /// promises them, and never wait on a gap; a still picture costs the encoder next to
    /// nothing. A slot is given up on a frame interval after its time, and a late firing
    /// fills every slot it missed. On `queue`.
    private func repeatIfStill() {
        lock.lock()
        let encoder = self.encoder
        let last = lastFrame
        lock.unlock()
        guard let last else { return }
        let upTo = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 1, timescale: CMTimeScale(key.fps)))
        var filled = 0
        while filled < 4, let slot = grid.nextSlot(before: upTo) {
            encoder?.encode(last.buffer, at: slot)
            filled += 1
        }
        if filled > 0 {
            lock.lock()
            given.repeats += filled
            lock.unlock()
        }
    }

    // MARK: Sound

    /// Encodes a piece of captured sound and hands the packets out; on `queue`. Sound is
    /// kept continuous on the stream's clock: a gap since the last piece is filled with
    /// silence first, so each packet's time follows from how many samples came before it.
    private func took(audio sample: CMSampleBuffer) {
        guard let anchor else { return }
        let time = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), anchor)
        let actual = CMTimeConvertScale(time, timescale: Int32(MP4Fragmenter.audioTimescale), method: .default).value
        if let start = audioStart {
            let gap = actual - (start + Int64(audioFed))
            if gap > 2 * Int64(MP4Fragmenter.audioTimescale) {
                audioStart = actual - Int64(audioFed)
            } else if gap > 1920 {
                feedSilence(samples: Int(gap))
            }
        } else {
            audioStart = max(actual, 0)
        }
        audioFed += CMSampleBufferGetNumSamples(sample)
        aac?.encode(sample)
        flushAAC()
    }

    /// Fills the sound up to 50 ms ago with silence when nothing is playing, so the sound
    /// track never falls far behind the picture; on `queue`, every 20 ms.
    private func padSilence() {
        guard let anchor, aac != nil else { return }
        let now = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), anchor)
        let actual = CMTimeConvertScale(now, timescale: Int32(MP4Fragmenter.audioTimescale), method: .default).value
        let upTo = actual - Int64(MP4Fragmenter.audioTimescale / 20)
        if audioStart == nil { audioStart = max(upTo, 0) }
        guard let start = audioStart else { return }
        let missing = upTo - (start + Int64(audioFed))
        guard missing >= Int64(MP4Fragmenter.aacFrameLength) else { return }
        feedSilence(samples: Int(min(missing, Int64(2 * MP4Fragmenter.audioTimescale))))
        flushAAC()
    }

    private func feedSilence(samples: Int) {
        guard let aac else { return }
        let silence = [Float](repeating: 0, count: samples * MoonlightAudioEncoder.channels)
        silence.withUnsafeBufferPointer { aac.encode(interleaved: $0) }
        audioFed += samples
    }

    /// Hands out the packets the encoder gave back since the last time.
    private func flushAAC() {
        guard !aacPending.isEmpty, let start = audioStart else { return }
        let packets = aacPending
        aacPending = []
        let first = audioPackets
        audioPackets += packets.count
        // A packet's time follows from its place in the stream, less the encoder's
        // priming; the packets wholly before the sound began are left out.
        var kept: [Data] = []
        var decodeTime: Int64?
        for (index, packet) in packets.enumerated() {
            let time = start + Int64((first + index) * MP4Fragmenter.aacFrameLength - Self.aacPriming)
            guard time > -Int64(MP4Fragmenter.aacFrameLength) else { continue }
            if decodeTime == nil { decodeTime = max(time, 0) }
            kept.append(packet)
        }
        guard let decodeTime, !kept.isEmpty else { return }
        let fragment = fragmenter.audioFragment(kept, decodeTime: decodeTime)
        lock.lock()
        let viewers = self.viewers
        lock.unlock()
        for viewer in viewers { viewer.take(audio: fragment) }
        stats.audio(packets: kept.count, refused: 0)
    }
}

// MARK: - Frame grid

/// Frames' times snapped to a steady grid of `fps` a second, each in a later slot than the
/// last. Browsers take the stream's word for each frame's duration and stall at any gap
/// between one frame and the next; on the grid, with a still screen's slots filled by
/// repeats, there are none.
struct FrameGrid {
    let fps: Int
    private var origin: CMTime?
    private(set) var lastSlot: Int64 = -1

    init(fps: Int) { self.fps = fps }

    /// The time of the slot `time` falls in, or of the one after the last if that one is
    /// taken already; the first time snapped is the grid's origin.
    mutating func snap(_ time: CMTime) -> CMTime {
        let origin = self.origin ?? time
        self.origin = origin
        let seconds = CMTimeGetSeconds(CMTimeSubtract(time, origin))
        let slot = max(Int64((seconds * Double(fps)).rounded(.down)), lastSlot + 1)
        lastSlot = slot
        return CMTimeAdd(origin, CMTime(value: slot, timescale: CMTimeScale(fps)))
    }

    /// Takes the slot after the last if its time is no later than `time`; nil if it is
    /// still to come, or nothing has been snapped yet.
    mutating func nextSlot(before time: CMTime) -> CMTime? {
        guard let origin else { return nil }
        let next = CMTimeAdd(origin, CMTime(value: lastSlot + 1, timescale: CMTimeScale(fps)))
        guard next <= time else { return nil }
        lastSlot += 1
        return next
    }
}

// MARK: - Viewer

/// One client's connection, given the stream from a keyframe on.
final class WebStreamViewer {

    enum Outcome {
        case taken
        /// Not yet watching, or skipping ahead: the next keyframe starts it.
        case waitingForKeyFrame
        /// Just fell behind, by more than `maxInFlight`: skipping to the next keyframe.
        case fellBehind
    }

    private let connection: NWConnection
    /// Bytes handed to the connection and not yet taken by the network.
    private let maxInFlight: Int
    /// Whether the viewer takes the sound track.
    let audio: Bool
    private let lock = NSLock()
    private var inFlight = 0
    private var closed = false
    private var started = false
    private var waitingForKeyFrame = true
    /// Called once, from any thread, when the client has gone.
    var onClose: (() -> Void)?

    init(connection: NWConnection, maxInFlight: Int, audio: Bool = true) {
        self.connection = connection
        self.maxInFlight = max(maxInFlight, 256 * 1024)
        self.audio = audio
    }

    /// Notices the client closing the connection.
    func watch() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.close()
            } else {
                self.watch()
            }
        }
    }

    func take(video fragment: Data, keyFrame: Bool, codecs: String, initSegment: Data) -> Outcome {
        lock.lock()
        guard !closed else { lock.unlock(); return .taken }
        if waitingForKeyFrame {
            guard keyFrame else { lock.unlock(); return .waitingForKeyFrame }
            waitingForKeyFrame = false
            if !started {
                started = true
                lock.unlock()
                send(Data(Self.head(codecs: codecs).utf8))
                send(initSegment)
            } else {
                lock.unlock()
            }
        } else if inFlight > maxInFlight {
            waitingForKeyFrame = true
            lock.unlock()
            wsLog.debug("viewer behind by \(self.inFlight) bytes; waiting for a keyframe")
            return .fellBehind
        } else {
            lock.unlock()
        }
        send(fragment)
        return .taken
    }

    func take(audio fragment: Data) {
        guard audio else { return }
        lock.lock()
        let streaming = started && !waitingForKeyFrame && !closed
        lock.unlock()
        if streaming { send(fragment) }
    }

    /// The response's head: a body of unknown length that ends with the connection.
    static func head(codecs: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nCache-Control: no-store\r\nConnection: close\r\n" +
        "Access-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: X-Codecs\r\nX-Codecs: \(codecs)\r\n\r\n"
    }

    private func send(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        inFlight += data.count
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.inFlight -= data.count
            self.lock.unlock()
            if error != nil { self.close() }
        })
    }

    func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        connection.cancel()
        onClose?()
    }
}

// MARK: - Page

/// The player page: fetches /stream.mp4 and feeds it to a video element through Media
/// Source Extensions, keeping playback a chosen distance behind the latest frame.
enum WebStreamPage {
    static let html = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>DAM Stream</title>
    <style>
      :root { color-scheme: dark; }
      body { margin: 0; background: #000; color: #ddd; font: 14px -apple-system, system-ui, sans-serif; }
      #v { display: block; width: 100vw; height: 100vh; object-fit: contain; background: #000; }
      #bar { position: fixed; left: 0; right: 0; bottom: 0; display: flex; flex-wrap: wrap; gap: 10px 16px; align-items: center;
             padding: 10px 14px; background: rgba(20,20,20,.85); backdrop-filter: blur(10px); transition: opacity .3s; }
      body.idle #bar { opacity: 0; pointer-events: none; }
      label { display: flex; align-items: center; gap: 6px; white-space: nowrap; }
      select, input[type=number], button { font: inherit; color: inherit; background: #333; border: 0; border-radius: 6px; padding: 4px 8px; }
      input[type=range] { width: 140px; }
      #stats { margin-left: auto; opacity: .7; font-variant-numeric: tabular-nums; }
      #msg { position: fixed; inset: 0; display: grid; place-items: center; text-align: center; padding: 20px; }
      #msg[hidden] { display: none; }
      code { user-select: all; }
    </style>
    </head>
    <body>
    <video id="v" muted playsinline></video>
    <div id="msg" hidden></div>
    <div id="bar">
      <label>Display <select id="app"></select></label>
      <label>Profile <select id="profile">
        <option value="interactive">Interactive</option>
        <option value="balanced">Balanced</option>
        <option value="viewing">Viewing</option>
      </select></label>
      <label>Buffer <input id="buffer" type="range" min="0" max="2000" step="10"> <span id="bufferText"></span></label>
      <label>Mbit/s <input id="bitrate" type="number" min="1" max="150" step="1" style="width:4em"></label>
      <button id="mute">Unmute</button>
      <button id="full">Full Screen</button>
      <span id="stats"></span>
    </div>
    <script>
    (() => {
      const $ = id => document.getElementById(id);
      const video = $('v'), params = new URLSearchParams(location.search);
      let info = { apps: [], profile: 'interactive', bitrates: {}, buffers: {} };
      let profile = params.get('profile'), bitrate = params.get('bitrate'), app = params.get('app');
      let buffer = params.get('buffer');
      let abort = null, source = null, sb = null, queue = [], bytes = 0, held = true, stalls = 0;

      const MS = window.ManagedMediaSource || window.MediaSource;
      if (!MS) { $('msg').hidden = false; $('msg').textContent = 'This browser cannot play streams (no Media Source Extensions).'; return; }

      // Sound comes only when wanted: with it, each frame waits for the sound of its moment.
      function url() {
        const q = new URLSearchParams();
        if (app) q.set('app', app);
        q.set('profile', profile);
        q.set('bitrate', Math.round(bitrate * 1000));
        if (video.muted) q.set('audio', '0');
        return '/stream.mp4?' + q;
      }

      function start() {
        stop();
        queue = []; bytes = 0; held = true; stalls = 0;
        source = new MS();
        video.disableRemotePlayback = true;
        video.src = URL.createObjectURL(source);
        source.addEventListener('sourceopen', open, { once: true });
        history.replaceState(null, '', '?' + new URLSearchParams({ ...(app ? { app } : {}), profile, bitrate: Math.round(bitrate * 1000), buffer: Math.round(buffer * 1000) }));
        // Making a display for the stream can take a while.
        $('msg').hidden = false; $('msg').textContent = 'Connecting…';
      }

      function stop() {
        if (abort) abort.abort();
        abort = null; sb = null;
        if (source && source.readyState === 'open') try { source.endOfStream(); } catch (e) {}
        source = null;
      }

      async function open() {
        if (source.duration !== Infinity) try { source.duration = Infinity; } catch (e) {}
        abort = new AbortController();
        let response;
        try {
          response = await fetch(url(), { signal: abort.signal, cache: 'no-store' });
        } catch (e) { return fail('Could not reach the stream.'); }
        if (!response.ok) return fail(await response.text());
        const codecs = response.headers.get('X-Codecs') || 'avc1.640028,mp4a.40.2';
        const mime = 'video/mp4; codecs="' + codecs + '"';
        if (!MS.isTypeSupported(mime)) return fail('This browser cannot decode ' + codecs + '.');
        sb = source.addSourceBuffer(mime);
        sb.mode = 'segments';
        sb.addEventListener('updateend', pump);
        sb.addEventListener('updateend', follow);
        const reader = response.body.getReader();
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            $('msg').hidden = true;
            queue.push(value); bytes += value.length;
            pump();
          }
          fail('The stream ended.');
        } catch (e) { if (!abort || !abort.signal.aborted) fail('The stream broke off.'); }
      }

      function pump() {
        if (!sb || sb.updating || !queue.length) return;
        // Trim what has been played, so memory stays put.
        const t = video.currentTime;
        if (sb.buffered.length && sb.buffered.start(0) < t - 20) { sb.remove(0, t - 10); return; }
        let chunk;
        if (queue.length === 1) { chunk = queue[0]; } else {
          chunk = new Uint8Array(queue.reduce((n, c) => n + c.length, 0));
          let at = 0; for (const c of queue) { chunk.set(c, at); at += c.length; }
        }
        queue = [];
        try { sb.appendBuffer(chunk); } catch (e) { fail('Playback failed: ' + e.message); }
      }

      function fail(text) { stop(); $('msg').hidden = false; $('msg').textContent = text; }

      // Keeps playback `buffer` seconds behind the latest frame: a jump when far off, a
      // slightly faster or slower rate when a little, over any gap the still screen left,
      // and, when the picture runs dry, a hold until the buffer is back.
      function follow() {
        if (!sb || !sb.buffered.length) return;
        const b = sb.buffered, end = b.end(b.length - 1), t = video.currentTime;
        let inside = false, next = null;
        for (let i = 0; i < b.length; i++) {
          if (t >= b.start(i) - 0.05 && t <= b.end(i) + 0.05) inside = true;
          else if (b.start(i) > t && next === null) next = b.start(i);
        }
        let lag = end - t;
        if (!inside && next !== null) { video.currentTime = Math.max(next, end - buffer); lag = end - video.currentTime; }
        else if (lag > buffer + 0.3) { video.currentTime = Math.max(end - buffer, 0); lag = end - video.currentTime; }
        // Held near the target: a touch faster past it, faster still well past it, slower short of it.
        video.playbackRate = lag > buffer + 0.12 ? 1.15 : lag > buffer + 0.025 ? 1.05 : lag < buffer - 0.08 ? 0.95 : 1;
        if (held && lag >= buffer) held = false;
        if (!held && video.paused) video.play().catch(() => {});
        const q = video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null;
        $('stats').textContent = (video.videoWidth ? video.videoWidth + '×' + video.videoHeight + ' · ' : '')
          + Math.round(Math.max(lag, 0) * 1000) + ' ms behind'
          + (stalls ? ' · ' + stalls + ' stall' + (stalls > 1 ? 's' : '') : '')
          + (q ? ' · ' + q.droppedVideoFrames + ' dropped' : '');
      }
      setInterval(follow, 100);
      // Out of picture: hold until `buffer` seconds are in hand again, rather than play each
      // frame the moment it lands and stutter.
      video.addEventListener('waiting', () => { if (!held && !video.seeking) { held = true; stalls++; video.pause(); } follow(); });
      video.addEventListener('playing', follow);

      // Controls.
      function setBuffer(seconds) { buffer = seconds; $('buffer').value = Math.round(seconds * 1000); $('bufferText').textContent = Math.round(seconds * 1000) + ' ms'; }
      $('profile').onchange = () => { profile = $('profile').value; bitrate = (info.bitrates[profile] || 20000) / 1000; $('bitrate').value = bitrate; setBuffer(info.buffers[profile] || 0.05); start(); };
      $('bitrate').onchange = () => { bitrate = +$('bitrate').value || 20; start(); };
      $('app').onchange = () => { app = $('app').value || null; start(); };
      $('buffer').oninput = () => setBuffer(+$('buffer').value / 1000);
      $('mute').onclick = () => { video.muted = !video.muted; $('mute').textContent = video.muted ? 'Unmute' : 'Mute'; start(); };
      $('full').onclick = () => { (video.requestFullscreen || video.webkitEnterFullscreen || (() => {})).call(video); };
      let idle; function awake() { document.body.classList.remove('idle'); clearTimeout(idle); idle = setTimeout(() => document.body.classList.add('idle'), 3000); }
      ['mousemove', 'touchstart', 'keydown'].forEach(e => addEventListener(e, awake)); awake();

      fetch('/apps.json').then(r => r.json()).then(j => {
        info = j;
        for (const a of j.apps) { const o = document.createElement('option'); o.value = a.id; o.textContent = a.title; $('app').append(o); }
        if (!j.apps.length) { const o = document.createElement('option'); o.value = ''; o.textContent = 'New Display'; $('app').append(o); }
        if (!profile || !j.bitrates[profile]) profile = j.profile;
        if (app) $('app').value = app;
        $('profile').value = profile;
        if (!bitrate) bitrate = (j.bitrates[profile] || 20000) / 1000; else bitrate = +bitrate / 1000;
        $('bitrate').value = bitrate;
        setBuffer(buffer ? +buffer / 1000 : (j.buffers[profile] || 0.05));
        start();
      }).catch(() => fail('Could not reach the host.'));
    })();
    </script>
    </body>
    </html>
    """#
}
