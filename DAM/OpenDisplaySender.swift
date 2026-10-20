//
//  OpenDisplaySender.swift
//  DAM
//
//  DAM as an OpenDisplay sender: it dials the receivers turned on in Settings, over WiFi
//  (Bonjour) or a cable (usbmuxd), makes a display at the size each one's hello asks for,
//  and streams it to that receiver, taking its touches and scrolls as the mouse. A receiver
//  serves one sender at a time and takes the newest, so DAM dials only receivers turned on.
//

import AppKit
import CoreMedia
import Network

final class OpenDisplaySender {

    /// A receiver DAM knows of: found now, turned on, or both.
    struct Receiver: Equatable {
        /// Its ID from Bonjour or its hello, or "usb:" and its UDID until its hello gives one.
        let key: String
        var name: String
        var transports: [OpenDisplayTransport]
        var isOn: Bool
        var status: String
    }

    // MARK: Settings

    private static let enabledKey = "\(AppIdentity.shortID).opendisplay.enabled"
    private static let receiversKey = "\(AppIdentity.shortID).opendisplay.receivers"
    private static let namesKey = "\(AppIdentity.shortID).opendisplay.names"
    private static let usbIDsKey = "\(AppIdentity.shortID).opendisplay.usbIDs"
    private static let bonjourIDsKey = "\(AppIdentity.shortID).opendisplay.bonjourIDs"
    private static let bitrateKey = "\(AppIdentity.shortID).opendisplay.bitrateKbps"

    /// Whether DAM sends to receivers at all.
    static var isEnabled: Bool {
        get { UserDefaults.dam.bool(forKey: enabledKey) }
        set { UserDefaults.dam.set(newValue, forKey: enabledKey) }
    }

    static var bitrateKbps: Int {
        let set = UserDefaults.dam.integer(forKey: bitrateKey)
        return set > 0 ? set : 20_000
    }

    /// The receivers turned on, by key.
    private var turnedOn: Set<String> {
        get { Set(UserDefaults.dam.stringArray(forKey: Self.receiversKey) ?? []) }
        set { UserDefaults.dam.set(newValue.sorted(), forKey: Self.receiversKey) }
    }

    /// The names receivers were last seen with, by key, for those not found now.
    private var names: [String: String] {
        get { UserDefaults.dam.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:] }
        set { UserDefaults.dam.set(newValue, forKey: Self.namesKey) }
    }

    /// Receivers' IDs by the UDID of the device they run on, learned from their hellos.
    private var usbIDs: [String: String] {
        get { UserDefaults.dam.dictionary(forKey: Self.usbIDsKey) as? [String: String] ?? [:] }
        set { UserDefaults.dam.set(newValue, forKey: Self.usbIDsKey) }
    }

    /// Receivers' IDs by their Bonjour name, from TXT records and hellos, for when a
    /// result comes without its TXT record.
    private var bonjourIDs: [String: String] {
        get { UserDefaults.dam.dictionary(forKey: Self.bonjourIDsKey) as? [String: String] ?? [:] }
        set { UserDefaults.dam.set(newValue, forKey: Self.bonjourIDsKey) }
    }

    // MARK: Hooks

    var makeDisplay: ((StreamingDisplayModes.Mode, VideoManager.StreamingIdentity,
                       @escaping (CGDirectDisplayID?) -> Void) -> Void)?
    var removeDisplay: ((CGDirectDisplayID) -> Void)?
    var resizeDisplay: ((CGDirectDisplayID, StreamingDisplayModes.Mode, @escaping (Bool) -> Void) -> Void)?
    /// Called on the main queue when the receivers or their sessions change.
    var onChange: (() -> Void)?

    // MARK: State

    private(set) var isRunning = false
    private var browser: NWBrowser?
    /// Receivers advertising on the network, by key.
    private var wifi: [String: (name: String, endpoint: NWEndpoint)] = [:]
    private let usbWatcher = Usbmuxd.Watcher()
    private var usbDevices: [Usbmuxd.Device] = []
    private var sessions: [String: OpenDisplaySession] = [:]
    /// When each key may be dialed again, after a dial that failed.
    private var retryAt: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var lastErrors: [String: String] = [:]
    /// Until when a receiver whose cable keeps failing is dialed over WiFi instead.
    private var preferWiFiUntil: [String: Date] = [:]
    private var dialTimer: Timer?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: OpenDisplayWire.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { odLog.error("browse: \(error.localizedDescription, privacy: .public)") }
        }
        browser.start(queue: .main)
        self.browser = browser
        usbWatcher.changed = { [weak self] devices in
            guard let self, self.usbDevices != devices else { return }
            self.usbDevices = devices
            odLog.debug("usb: \(devices.map(\.serial), privacy: .public)")
            self.dialWhatIsOn()
            self.onChange?()
        }
        usbWatcher.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.dialWhatIsOn() }
        RunLoop.main.add(timer, forMode: .common)
        dialTimer = timer
        odLog.debug("sending to OpenDisplay receivers")
        onChange?()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        browser?.cancel()
        browser = nil
        usbWatcher.stop()
        dialTimer?.invalidate()
        dialTimer = nil
        for session in sessions.values { session.end(reason: "sending stopped") }
        sessions = [:]
        wifi = [:]
        usbDevices = []
        onChange?()
    }

    /// Every receiver found now or turned on, by name.
    var receivers: [Receiver] {
        let on = turnedOn
        var keys = on.union(wifi.keys)
        for device in usbDevices { keys.insert(key(for: device)) }
        return keys.map { key in
            var transports: [OpenDisplayTransport] = []
            if usbDevices.contains(where: { self.key(for: $0) == key }) { transports.append(.usb) }
            if wifi[key] != nil { transports.append(.wifi) }
            return Receiver(key: key, name: name(of: key), transports: transports, isOn: on.contains(key),
                            status: status(of: key, on: on.contains(key), found: !transports.isEmpty))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setOn(_ on: Bool, key: String) {
        var set = turnedOn
        if on { set.insert(key) } else { set.remove(key) }
        turnedOn = set
        if on {
            retryAt[key] = nil
            failures[key] = nil
            dialWhatIsOn()
        } else if let session = sessions.removeValue(forKey: key) {
            session.end(reason: "turned off")
        }
        onChange?()
    }

    /// Forgets a receiver turned off and not found, so it leaves the list.
    func forget(key: String) {
        setOn(false, key: key)
        names[key] = nil
        usbIDs = usbIDs.filter { $0.value != key }
        onChange?()
    }

    // MARK: Finding

    private func key(for device: Usbmuxd.Device) -> String { usbIDs[device.serial] ?? "usb:\(device.serial)" }

    private func name(of key: String) -> String {
        if let found = wifi[key]?.name { return found }
        if let name = names[key] { return name }
        return key.hasPrefix("usb:") ? "iPhone or iPad on USB" : "Receiver"
    }

    private func status(of key: String, on: Bool, found: Bool) -> String {
        if let status = sessions[key]?.status { return status }
        if !on { return found ? "Off" : "Not found" }
        if let error = lastErrors[key] { return found ? "Waiting: \(error)" : "Not found" }
        return found ? "Connecting…" : "Not found"
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var found: [String: (name: String, endpoint: NWEndpoint)] = [:]
        var known = bonjourIDs
        // A receiver can be found once for each network it is on, not each with its TXT record.
        var byName: [String: (id: String?, endpoint: NWEndpoint)] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var id: String?
            if case let .bonjour(txt) = result.metadata { id = txt["id"].flatMap { $0.isEmpty ? nil : $0 } }
            if byName[name]?.id == nil || id != nil { byName[name] = (id ?? byName[name]?.id, result.endpoint) }
        }
        for (name, result) in byName {
            if let id = result.id { known[name] = id }
            // One with no ID (before pv 2) is known by its name until a hello gives one.
            found[result.id ?? known[name] ?? "bonjour:\(name)"] = (name, result.endpoint)
        }
        if known != bonjourIDs {
            bonjourIDs = known
            // A receiver turned on by its name is the same one by its ID.
            var on = turnedOn
            for (name, id) in known where on.remove("bonjour:\(name)") != nil { on.insert(id) }
            if on != turnedOn { turnedOn = on }
        }
        guard found.mapValues(\.name) != wifi.mapValues(\.name) || found.count != wifi.count else {
            wifi = found
            return
        }
        wifi = found
        var saved = names
        for (key, value) in found { saved[key] = value.name }
        names = saved
        odLog.debug("found: \(found.map { "\($0.value.name) (\($0.key))" }, privacy: .public)")
        dialWhatIsOn()
        onChange?()
    }

    // MARK: Dialing

    /// Dials each receiver turned on and found that has no live connection, by cable if it
    /// has one, as a cable is the better path and the receiver keeps the newest.
    private func dialWhatIsOn() {
        guard isRunning, Self.isEnabled else { return }
        let now = Date()
        for key in turnedOn {
            if let at = retryAt[key], at > now { continue }
            let device = usbDevices.first { self.key(for: $0) == key }
            let cable = device != nil && (preferWiFiUntil[key] ?? .distantPast) < now
            if let session = sessions[key] {
                if session.isDialing { continue }
                // A cable plugged in mid-session takes the stream over from WiFi.
                if session.hasLink && !(cable && session.transport == .wifi) { continue }
            }
            let channel: OpenDisplayChannel
            if cable, let device {
                channel = OpenDisplaySocketChannel { done in
                    DispatchQueue.global(qos: .userInitiated).async {
                        done(Result { try Usbmuxd.connect(to: device, port: OpenDisplayWire.port) })
                    }
                }
            } else if let endpoint = wifi[key]?.endpoint {
                channel = OpenDisplayTCPChannel(endpoint: endpoint)
            } else {
                continue
            }
            let session = sessions[key] ?? makeSession(key: key)
            odLog.debug("dialing \(self.name(of: key), privacy: .public) over \(channel.transport.rawValue, privacy: .public)")
            session.attach(channel)
        }
    }

    private func makeSession(key: String) -> OpenDisplaySession {
        let session = OpenDisplaySession(key: key, name: name(of: key), sender: self)
        sessions[key] = session
        return session
    }

    // MARK: From sessions

    fileprivate func sessionConnected(_ session: OpenDisplaySession) {
        failures[session.key] = nil
        retryAt[session.key] = nil
        lastErrors[session.key] = nil
        onChange?()
    }

    /// A dial or link that failed; dials come again after a second, then slower.
    fileprivate func sessionLostLink(_ session: OpenDisplaySession, reason: String, connected: Bool) {
        let count = connected ? 0 : (failures[session.key] ?? 0) + 1
        failures[session.key] = count
        if !connected, count >= 2, usbDevices.contains(where: { key(for: $0) == session.key }), wifi[session.key] != nil {
            preferWiFiUntil[session.key] = Date().addingTimeInterval(30)
        }
        retryAt[session.key] = Date().addingTimeInterval(count < 3 ? 1 : 5)
        lastErrors[session.key] = reason
        onChange?()
    }

    fileprivate func sessionEnded(_ session: OpenDisplaySession) {
        if sessions[session.key] === session { sessions[session.key] = nil }
        onChange?()
    }

    /// What a receiver's hello says of it: a USB device's receiver ID, which then keys it.
    fileprivate func session(_ session: OpenDisplaySession, saidID id: String?, device: String?) {
        if names[session.key] == nil, let device { names[session.key] = device }
        guard let id, session.key != id else { return }
        if session.key.hasPrefix("usb:") {
            var ids = usbIDs
            ids[String(session.key.dropFirst(4))] = id
            usbIDs = ids
        } else if session.key.hasPrefix("bonjour:") {
            var ids = bonjourIDs
            ids[String(session.key.dropFirst(8))] = id
            bonjourIDs = ids
            if let found = wifi.removeValue(forKey: session.key) { wifi[id] = found }
        } else {
            return
        }
        var on = turnedOn
        if on.remove(session.key) != nil { on.insert(id) }
        turnedOn = on
        var saved = names
        if saved[id] == nil { saved[id] = wifi[id]?.name ?? saved[session.key] }
        saved[session.key] = nil
        names = saved
        sessions[session.key] = nil
        sessions[id]?.end(reason: "the same receiver came over USB")
        session.rekey(id, name: name(of: id))
        sessions[id] = session
        onChange?()
    }

    fileprivate func changed() { onChange?() }

    fileprivate func holdDialing(_ key: String, for seconds: TimeInterval) {
        retryAt[key] = Date().addingTimeInterval(seconds)
    }
}

// MARK: - A session

/// One receiver's stream: its display, capture and encoder, and the connection to it,
/// which may drop and come back while the display waits.
final class OpenDisplaySession {
    private(set) var key: String
    private(set) var name: String
    private weak var sender: OpenDisplaySender?

    /// How long the display waits for a lost connection to come back.
    static let grace: TimeInterval = 10

    private var link: OpenDisplayChannel?
    private var linkReady = false
    private var deframer = OpenDisplayDeframer()
    private var lastHeard = Date()
    private var displayID: CGDirectDisplayID?
    private var desktop: OpenDisplayHello.Desktop?
    /// A hello waiting out the debounce, as the receiver turns.
    private var pendingHello: DispatchWorkItem?
    /// Whether the display is being made or resized; a hello meanwhile waits in `queued`.
    private var settingUp = false
    private var queued: OpenDisplayHello.Desktop?
    private var ended = false
    private var lostAt: Date?
    private var timers: [DispatchSourceTimer] = []
    private var injector: MoonlightInputInjector?
    private var capture: SharedScreenCapture.Subscription?
    private var cursor = OpenDisplayCursor()

    /// Shared with the encoder's and capture's threads.
    private let lock = NSLock()
    private var encoder: MoonlightVideoEncoder?
    private var sendLink: OpenDisplayChannel?
    private var needsKeyFrame = true
    private var keyFrames = MoonlightKeyFrameThrottle()
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime)?
    private var netDrops = 0
    private var captured = 0

    init(key: String, name: String, sender: OpenDisplaySender) {
        self.key = key
        self.name = name
        self.sender = sender
    }

    var hasLink: Bool { link != nil && linkReady }
    var isDialing: Bool { link != nil && !linkReady }

    /// What it is doing, or nil while it only dials.
    var status: String? {
        if let desktop, displayID != nil {
            if let link, linkReady { return "Streaming \(desktop.streamWidth)×\(desktop.streamHeight) over \(link.transport.rawValue)" }
            return "Waiting to reconnect"
        }
        return hasLink ? "Setting up…" : nil
    }

    var transport: OpenDisplayTransport? { linkReady ? link?.transport : nil }

    fileprivate func rekey(_ key: String, name: String) {
        self.key = key
        self.name = name
    }

    // MARK: Connection

    func attach(_ channel: OpenDisplayChannel) {
        guard !ended else { return }
        link?.close()
        link = channel
        linkReady = false
        deframer = OpenDisplayDeframer()
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel, self.link === channel else { return }
            self.linkReady = true
            self.lastHeard = Date()
            self.lostAt = nil
            odLog.debug("\(self.name, privacy: .public): connected over \(channel.transport.rawValue, privacy: .public)")
            self.sender?.sessionConnected(self)
        }
        channel.onReceive = { [weak self, weak channel] data in
            guard let self, let channel, self.link === channel else { return }
            self.lastHeard = Date()
            guard let payloads = self.deframer.append(data) else {
                return self.lose(channel, "the receiver broke the framing")
            }
            for payload in payloads {
                guard let message = OpenDisplayMessage.parse(payload) else { continue }
                self.handle(message)
                if self.link !== channel { return }
            }
        }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, let channel else { return }
            self.lose(channel, reason)
        }
        channel.start()
        if timers.isEmpty { startTimers() }
        // A dial to a Bonjour name that has gone never ends of itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dialTimeout) { [weak self, weak channel] in
            guard let self, let channel, self.link === channel, !self.linkReady else { return }
            if let tcp = channel as? OpenDisplayTCPChannel { odLog.debug("\(self.name, privacy: .public): dial stuck: \(tcp.pathDescription, privacy: .public)") }
            self.lose(channel, "no answer in \(Int(Self.dialTimeout)) s")
        }
    }

    static let dialTimeout: TimeInterval = 5

    private func lose(_ channel: OpenDisplayChannel, _ reason: String) {
        guard link === channel else { return }
        let wasReady = linkReady
        link = nil
        linkReady = false
        channel.close()
        lock.lock()
        sendLink = nil
        lock.unlock()
        injector?.releaseAll()
        odLog.debug("\(self.name, privacy: .public): \(wasReady ? "lost" : "dial failed", privacy: .public): \(reason, privacy: .public)")
        // A display on its way waits as one already made does.
        if displayID != nil || settingUp, lostAt == nil { lostAt = Date() }
        if displayID == nil && !settingUp {
            // Nothing to keep for it.
            stopTimers()
        }
        sender?.sessionLostLink(self, reason: reason, connected: wasReady)
    }

    /// Ends the session: closes the connection and removes the display.
    func end(reason: String) {
        guard !ended else { return }
        ended = true
        odLog.debug("\(self.name, privacy: .public): ended: \(reason, privacy: .public)")
        pendingHello?.cancel()
        link?.close()
        link = nil
        stopMedia()
        stopTimers()
        if let displayID { sender?.removeDisplay?(displayID) }
        displayID = nil
        desktop = nil
        sender?.sessionEnded(self)
    }

    // MARK: Messages

    private func handle(_ message: OpenDisplayMessage) {
        switch message {
        case .hello(let hello):
            send(OpenDisplayReply.welcome())
            sender?.session(self, saidID: hello.id, device: hello.device)
            guard let wanted = hello.desktop() else {
                odLog.error("\(self.name, privacy: .public): a hello with no size")
                return
            }
            pendingHello?.cancel()
            if displayID == nil && !settingUp {
                apply(wanted)
            } else {
                // Turning sends a flurry; the last one counts.
                let work = DispatchWorkItem { [weak self] in self?.apply(wanted) }
                pendingHello = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        case .ping(let t):
            send(OpenDisplayReply.pong(t: t))
        case .keyFrame:
            requestKeyFrame()
        case .touch, .pencil:
            injector?.handle(OpenDisplayTouches.events(for: message))
        case let .scroll(dx, dy):
            guard let desktop, let displayID else { return }
            // Video pixels to the display's points.
            let factor = CGDisplayBounds(displayID).width / CGFloat(max(desktop.streamWidth, 1))
            injector?.scrollPixels(dx: Int32((CGFloat(dx) * factor).rounded()), dy: Int32((CGFloat(dy) * factor).rounded()))
        case .sleeping, .closing:
            // It closes the connection next; dialing again at once would find it still there.
            sender?.holdDialing(key, for: 3)
            end(reason: message == .closing ? "the receiver app quit" : "the receiver went to sleep")
        case .stats(let text):
            odLog.debug("\(self.name, privacy: .public) stats: \(text, privacy: .public)")
        case .other:
            break
        }
    }

    private func send(_ data: Data?) {
        guard let data, let link, linkReady else { return }
        link.send(data)
    }

    // MARK: Display and stream

    /// Makes the display for `wanted`, or changes it to that, then streams it.
    private func apply(_ wanted: OpenDisplayHello.Desktop) {
        guard !ended, let sender else { return }
        // One change at a time; the newest asked for comes next.
        if settingUp { queued = wanted; return }
        if let displayID, let desktop {
            if desktop == wanted {
                // The same picture over a new connection: say how it comes, then a keyframe.
                startStream()
                return
            }
            settingUp = true
            stopMedia()
            sender.resizeDisplay?(displayID, wanted.mode) { [weak self] done in
                guard let self, !self.ended else { return }
                self.settingUp = false
                guard done else { return self.end(reason: "the display could not be resized") }
                self.desktop = wanted
                self.startMedia()
                self.applyQueued()
            }
            return
        }
        settingUp = true
        let identity = VideoManager.StreamingIdentity(name: name, seed: "opendisplay:\(key)")
        odLog.debug("\(self.name, privacy: .public): making a display \(wanted.mode.width)×\(wanted.mode.height)\(wanted.mode.hiDPI ? " HiDPI" : "") for a \(wanted.streamWidth)×\(wanted.streamHeight)@\(wanted.fps) stream")
        guard let makeDisplay = sender.makeDisplay else { return end(reason: "no displays") }
        makeDisplay(wanted.mode, identity) { [weak self] id in
            guard let self else { return }
            self.settingUp = false
            guard !self.ended else {
                if let id { self.sender?.removeDisplay?(id) }
                return
            }
            guard let id else { return self.end(reason: "no display could be made") }
            self.displayID = id
            self.desktop = wanted
            self.startMedia()
            self.sender?.changed()
            self.applyQueued()
        }
    }

    private func applyQueued() {
        guard let next = queued else { return }
        queued = nil
        apply(next)
    }

    private func startMedia() {
        guard let displayID, let desktop else { return }
        let encoder: MoonlightVideoEncoder
        do {
            encoder = try MoonlightVideoEncoder(settings: .init(width: desktop.streamWidth, height: desktop.streamHeight,
                                                                fps: desktop.fps, bitrateKbps: OpenDisplaySender.bitrateKbps)) {
                [weak self] frame in self?.took(frame)
            }
        } catch {
            return end(reason: "the encoder could not start")
        }
        injector = MoonlightInputInjector(displayID: displayID, streamWidth: desktop.streamWidth,
                                          streamHeight: desktop.streamHeight)
        lock.lock()
        self.encoder = encoder
        lock.unlock()
        let key = SharedScreenCapture.Key(displayID: displayID, width: desktop.streamWidth, height: desktop.streamHeight,
                                          fps: desktop.fps, showsCursor: false)
        capture = SharedScreenCapture.subscribe(key, frame: { [weak self] buffer, time in
            guard let self else { return }
            self.lock.lock()
            self.lastFrame = (buffer, time)
            self.captured += 1
            let encoder = self.encoder
            self.lock.unlock()
            encoder?.encode(buffer, at: time)
        }, audio: { _ in }, started: { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.end(reason: "capture failed: \(error.localizedDescription)")
            }
        })
        cursor = OpenDisplayCursor()
        startStream()
    }

    private func stopMedia() {
        capture?.cancel()
        capture = nil
        injector?.close()
        injector = nil
        lock.lock()
        encoder = nil
        lastFrame = nil
        lock.unlock()
    }

    /// Tells the receiver what the stream is and starts it from a keyframe.
    private func startStream() {
        guard let desktop, let link, linkReady else { return }
        send(OpenDisplayReply.streamConfig(width: desktop.streamWidth, height: desktop.streamHeight, fps: desktop.fps))
        cursor.reset()
        lock.lock()
        sendLink = link
        needsKeyFrame = true
        lock.unlock()
        requestKeyFrame()
        sender?.changed()
    }

    /// The next frame as a keyframe, from the last picture at once, as a still screen sends none.
    private func requestKeyFrame() {
        lock.lock()
        let decision = keyFrames.request(at: DispatchTime.now().uptimeNanoseconds)
        let encoder = self.encoder
        let last = lastFrame
        lock.unlock()
        switch decision {
        case .now:
            encoder?.requestKeyFrame()
            if let last { encoder?.encode(last.buffer, at: last.time) }
        case .later(let wait):
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [weak self] in self?.requestKeyFrame() }
        case .alreadyDue:
            break
        }
    }

    /// Sends an encoded frame, unless the connection is backed up: then frames wait for a
    /// keyframe once it has drained. On the encoder's thread.
    private func took(_ frame: MoonlightVideoEncoder.Frame) {
        lock.lock()
        guard let link = sendLink else { lock.unlock(); return }
        if needsKeyFrame && !frame.isKeyFrame {
            lock.unlock()
            return
        }
        // About half a second of video at the stream's rate.
        let backlog = max(OpenDisplaySender.bitrateKbps * 1000 / 8 / 2, 1_000_000)
        if link.pendingBytes > backlog {
            netDrops += 1
            needsKeyFrame = true
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.requestKeyFrameWhenDrained() }
            return
        }
        needsKeyFrame = false
        lock.unlock()
        let sent = OpenDisplayWire.nowMs()
        let age = Int64((DispatchTime.now().uptimeNanoseconds &- frame.submitted) / 1_000_000)
        link.send(OpenDisplayWire.video(frame.data, capturedMs: sent - age, sentMs: sent))
    }

    private func requestKeyFrameWhenDrained() {
        lock.lock()
        let pending = sendLink?.pendingBytes ?? 0
        lock.unlock()
        if pending > 64 * 1024 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.requestKeyFrameWhenDrained() }
        } else {
            requestKeyFrame()
        }
    }

    // MARK: Timers

    private func startTimers() {
        let ping = DispatchSource.makeTimerSource(queue: .main)
        ping.schedule(deadline: .now() + OpenDisplayWire.pingInterval, repeating: OpenDisplayWire.pingInterval)
        ping.setEventHandler { [weak self] in self?.tick() }
        ping.resume()
        let pointer = DispatchSource.makeTimerSource(queue: .main)
        pointer.schedule(deadline: .now() + 0.1, repeating: 1.0 / 60, leeway: .milliseconds(2))
        pointer.setEventHandler { [weak self] in self?.followPointer() }
        pointer.resume()
        timers = [ping, pointer]
    }

    private func stopTimers() {
        for timer in timers { timer.cancel() }
        timers = []
    }

    /// Every two seconds: a ping, and the checks for a link gone quiet and a wait run out.
    private func tick() {
        if let link, linkReady {
            if Date().timeIntervalSince(lastHeard) > OpenDisplayWire.silenceLimit {
                return lose(link, "nothing from the receiver for \(Int(OpenDisplayWire.silenceLimit)) s")
            }
            lock.lock()
            let drops = netDrops
            let frames = captured
            captured = 0
            lock.unlock()
            send(OpenDisplayReply.ping(capFps: Double(frames) / OpenDisplayWire.pingInterval, netDrops: drops))
        } else if let lostAt, Date().timeIntervalSince(lostAt) > Self.grace {
            end(reason: "the receiver didn't come back")
        }
    }

    private func followPointer() {
        guard let displayID, hasLink, desktop != nil else { return }
        for message in cursor.update(displayID: displayID) { send(message) }
    }
}

// MARK: - The pointer

/// The pointer as the receiver draws it: its place on the display, when it moves, and its
/// picture, when that changes.
struct OpenDisplayCursor {
    private var last: CGPoint??
    private var lastImage: Data?
    private var checkedImage = Date.distantPast

    mutating func reset() {
        last = nil
        lastImage = nil
        checkedImage = .distantPast
    }

    mutating func update(displayID: CGDirectDisplayID) -> [Data?] {
        var out: [Data?] = []
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return out }
        if Date().timeIntervalSince(checkedImage) > 0.25 {
            checkedImage = Date()
            if let (png, size, hotSpot) = Self.picture(), png != lastImage {
                lastImage = png
                out.append(OpenDisplayReply.cursorImage(
                    png: png, size: CGSize(width: size.width / bounds.width, height: size.height / bounds.height),
                    hotSpot: CGPoint(x: hotSpot.x / max(size.width, 1), y: hotSpot.y / max(size.height, 1))))
            }
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        let point: CGPoint? = bounds.contains(location)
            ? CGPoint(x: (location.x - bounds.minX) / bounds.width, y: (location.y - bounds.minY) / bounds.height)
            : nil
        let moved: Bool
        switch (last, point) {
        case (nil, _): moved = true
        case let (.some(was?), now?): moved = abs(was.x - now.x) > 0.0002 || abs(was.y - now.y) > 0.0002
        case (.some(nil), nil): moved = false
        default: moved = true
        }
        if moved {
            last = .some(point)
            out.append(OpenDisplayReply.cursor(at: point))
        }
        return out
    }

    /// The pointer's picture as a PNG at twice its size, small enough to send, with its size
    /// and hot spot in points.
    private static func picture() -> (Data, CGSize, CGPoint)? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        for scale in [2.0, 1.0] {
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]), png.count <= 24000 {
                return (png, size, cursor.hotSpot)
            }
        }
        return nil
    }
}
