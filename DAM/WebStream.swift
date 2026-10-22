//
//  WebStream.swift
//
//  Streams a display to browsers and media players over plain HTTP, on a port of its own,
//  turned on and set up apart from Moonlight hosting: one endless response of fragmented
//  MP4 at /stream.mp4, which a page at /watch plays through Media Source Extensions and
//  mpv, ffplay or VLC play as it is, and on the port after it over HTTPS. Only devices DAM
//  knows may watch: a player by its link, a browser once it has paired (WebStreamAccess).
//  The capture and encoder are Moonlight's code; each stream has a profile that trades delay
//  for picture quality, from Interactive (as Moonlight gets it) to Viewing (frames out of
//  order, bigger bursts, regular keyframes, a second of buffer in the browser).
//
//  Viewers of one display with the same settings share a session: one capture, one
//  encoder, and each frame fragmented once. A viewer joining waits for a keyframe, and
//  one that cannot keep up (more than a second of the stream unsent) skips to a keyframe
//  once most of that has gone out, rather than fall ever further behind; one that stays
//  behind for 10 seconds is let go.
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

    func encoderSettings(width: Int, height: Int, fps: Int, bitrateKbps: Int,
                         lowLatency: Bool = false) -> MoonlightVideoEncoder.Settings {
        var settings = MoonlightVideoEncoder.Settings(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps)
        settings.lowLatency = lowLatency
        // The stream fills its grid itself, with repeats where the screen is still.
        settings.steady = true
        // A keyframe at least every 10 seconds: a browser can only let go of played video up
        // to a keyframe, and without one it has to keep it all (see the page's `pump`).
        settings.keyFrameInterval = 10
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

    /// Bytes a viewer may have unsent before it counts as behind: a second of the stream, or
    /// all the encoder may put out over its rate limit's window when that is more, so a
    /// scene change bursting to its limit leaves no one behind. At most 64 MB.
    func maxInFlight(bitrateKbps: Int) -> Int {
        let settings = encoderSettings(width: 0, height: 0, fps: 0, bitrateKbps: bitrateKbps)
        let seconds = max(1, settings.rateLimitMultiple * settings.rateLimitWindow)
        return min(Int(Double(bitrateKbps * 125) * seconds), 64 << 20)
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
    /// Whether the viewer's screen stands taller than wide, when the page says: a display
    /// made for the stream is made, or turned, to stand the same way.
    var portrait: Bool?
    /// Whether the stream carries sound. Without it, players show each frame as it lands;
    /// with it, they wait for the sound of the same moment, which comes a little later.
    var audio = true
    /// Whether the encoder uses low-latency rate control, a frame sooner (see
    /// MoonlightVideoEncoder). Not with the Viewing profile, whose frames come out of order.
    var lowLatency = false
    /// The id of the device asking, whose viewers forgetting it cuts off; not from the query.
    var device: String?

    static func == (a: WebStreamRequest, b: WebStreamRequest) -> Bool {
        a.app == b.app && a.profile == b.profile && a.bitrateKbps == b.bitrateKbps && a.fps == b.fps
            && a.width == b.width && a.height == b.height && a.newDisplay == b.newDisplay && a.audio == b.audio
            && a.lowLatency == b.lowLatency && a.portrait == b.portrait
    }

    /// The most pixels a stream takes from a display: a HiDPI display is scaled down to fit.
    static let maxPixels = 2560 * 1600

    static func parse(_ query: [String: String], preferred: StreamProfile) -> WebStreamRequest {
        let profile = query["profile"].flatMap(StreamProfile.init(rawValue:)) ?? preferred
        var request = WebStreamRequest(app: query["app"].flatMap(Int.init), profile: profile,
                                       bitrateKbps: profile.defaultBitrateKbps)
        if let bitrate = query["bitrate"].flatMap(Int.init) { request.bitrateKbps = min(max(bitrate, 1000), 150_000) }
        if let fps = query["fps"].flatMap(Int.init) { request.fps = min(max(fps, 5), 120) }
        // Sides checked one at a time: any number may come, and a product could overflow.
        if let width = query["width"].flatMap(Int.init), let height = query["height"].flatMap(Int.init),
           width >= 160, height >= 90, width <= maxPixels / height {
            request.width = width & ~1
            request.height = height & ~1
        }
        let mode = (query["mode"] ?? "").split(separator: "x").compactMap { Int($0) }
        if mode.count == 3, mode[0] >= 640, mode[1] >= 360, mode[0] <= maxPixels / mode[1], mode[2] >= 30 {
            request.newDisplay = (mode[0], mode[1], min(mode[2], 120))
        }
        switch query["orientation"]?.lowercased() {
        case "portrait":  request.portrait = true
        case "landscape": request.portrait = false
        default:          break
        }
        if let portrait = request.portrait, portrait != (request.newDisplay.height > request.newDisplay.width) {
            request.newDisplay = (request.newDisplay.height, request.newDisplay.width, request.newDisplay.fps)
        }
        if let audio = query["audio"]?.lowercased(), ["0", "false", "no", "off"].contains(audio) { request.audio = false }
        if let lowLatency = query["lowlatency"]?.lowercased(), ["1", "true", "yes", "on"].contains(lowLatency) {
            request.lowLatency = profile != .viewing
        }
        return request
    }
}

// MARK: - Server

/// Serves the stream on its own HTTP port and keeps the sessions.
final class WebStreamServer {

    private static let enabledKey = "\(AppIdentity.shortID).browser.enabled"
    private static let showsPointerKey = "\(AppIdentity.shortID).browser.showsPointer"

    /// Whether the user turned the browser stream on; it starts with the app then.
    static var isEnabled: Bool {
        get { UserDefaults.dam.bool(forKey: enabledKey) }
        set { UserDefaults.dam.set(newValue, forKey: enabledKey) }
    }

    /// Whether streams show the pointer; from the next stream.
    static var showsPointer: Bool {
        get { UserDefaults.dam.object(forKey: showsPointerKey) as? Bool ?? true }
        set { UserDefaults.dam.set(newValue, forKey: showsPointerKey) }
    }

    /// Off GameStream's ports and Sunshine's (47990 is its web page).
    static let defaultPort: NWEndpoint.Port = 47995

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("Browser", isDirectory: true)
    }

    let port: NWEndpoint.Port
    /// Where the devices, the certificates and their keys are kept.
    let directory: URL

    init(port: NWEndpoint.Port = WebStreamServer.defaultPort, directory: URL = WebStreamServer.defaultDirectory) {
        self.port = port
        self.directory = directory
    }

    /// The streaming displays, which viewers pick from.
    var apps: () -> [MoonlightApp] = { [] }
    /// Makes and removes a display for streams when none is listed.
    var makeDisplay: ((_ width: Int, _ height: Int, _ fps: Int, _ done: @escaping (CGDirectDisplayID?) -> Void) -> Void)?
    var removeDisplay: ((CGDirectDisplayID) -> Void)?
    var resizeDisplay: ((_ id: CGDirectDisplayID, _ width: Int, _ height: Int, _ fps: Int,
                         _ done: @escaping (Bool) -> Void) -> Void)?
    var preferredProfile: () -> StreamProfile = { .preferred }
    /// The number watching changed, or the server started or stopped; on the main queue.
    var onChange: (() -> Void)?

    // MARK: Serving

    private var listeners: [NWListener] = []
    private var readyListeners: Set<ObjectIdentifier> = []
    private let restarts = MoonlightListenerRestarts()
    /// Whether it serves, or is to once the ports are free.
    private(set) var isRunning = false
    /// Whether both ports are accepting connections.
    var isListening: Bool { !listeners.isEmpty && readyListeners.count == listeners.count }
    /// Why it stopped, when it did on its own.
    private(set) var lastError: String?

    /// The port for HTTPS, the one after `port`.
    var securePort: NWEndpoint.Port { NWEndpoint.Port(rawValue: port.rawValue + 1)! }

    /// The devices that may watch.
    private(set) lazy var devices = WebStreamDevices(directory: directory)
    let pairing = WebStreamPairing()
    /// The certificates of the HTTPS port, once it has started.
    private(set) var certificates: WebStreamCertificates?

    /// The certificate imported for HTTPS in place of DAM's own, if any.
    var importedCertificate: ImportedCertificate? { ImportedCertificate.load(from: directory) }

    /// Keeps `imported` for HTTPS from now on, in place of DAM's own or an earlier import;
    /// a running server starts again with it, which cuts off anyone watching.
    func useCertificate(_ imported: ImportedCertificate) throws {
        try imported.save(in: directory)
        restartForCertificates()
    }

    /// Goes back to DAM's own certificates for HTTPS.
    func useOwnCertificate() {
        ImportedCertificate.remove(from: directory)
        restartForCertificates()
    }

    private func restartForCertificates() {
        guard isRunning else { onChange?(); return }
        stop()
        start()
    }

    /// Asks the user to type the code a browser at `address` shows; `answer` is nil when
    /// they decline. On the main queue.
    var requestCode: ((_ address: String, _ name: String, _ answer: @escaping (String?) -> Void) -> Void)?

    private static let allowsPairingKey = "\(AppIdentity.shortID).browser.allowsPairing"

    /// Whether a browser not yet paired may ask to.
    static var allowsPairing: Bool {
        get { UserDefaults.dam.object(forKey: allowsPairingKey) as? Bool ?? true }
        set { UserDefaults.dam.set(newValue, forKey: allowsPairingKey) }
    }

    /// Starts serving, HTTP on `port` and HTTPS on the one after, once the ports of a stop
    /// just before are free. Runs on the main queue.
    func start() {
        guard !isRunning else { return }
        do {
            certificates = try WebStreamCertificates(directory: directory)
        } catch {
            return stop(error: error.localizedDescription)
        }
        isRunning = true
        lastError = nil
        restarts.open { [weak self] in self?.listen() }
        onChange?()
    }

    /// Opens the listeners.
    private func listen() {
        guard isRunning, let certificates else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Each fragment goes out the moment it is ready, not held for an acknowledgement.
            (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            let tls = NWProtocolTLS.Options()
            let chain = certificates.chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            if let identity = sec_identity_create_with_certificates(certificates.identity, chain as CFArray) {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let secure = NWParameters(tls: tls, tcp: tcp)
            secure.allowLocalEndpointReuse = true
            listeners = [try NWListener(using: parameters, on: port), try NWListener(using: secure, on: securePort)]
            for (listener, isSecure) in zip(listeners, [false, true]) {
                listener.newConnectionHandler = { [weak self] in self?.accept($0, secure: isSecure) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listeners.contains(where: { $0 === listener }) else { return }
                    switch state {
                    case .ready:
                        self.readyListeners.insert(ObjectIdentifier(listener))
                        self.onChange?()
                    case .failed(let error):
                        wsLog.error("listener failed: \(String(describing: error), privacy: .public)")
                        let port = listener.port?.rawValue ?? self.port.rawValue
                        if self.restarts.retries(error, closing: self.listeners, open: { [weak self] in self?.listen() }) {
                            self.listeners = []
                            self.readyListeners = []
                            // Those a sibling took meanwhile go with it; browsers try again.
                            self.http.closeAll()
                        } else if case .posix(.EADDRINUSE) = error {
                            self.stop(error: "Another app is using port \(port)")
                        } else {
                            self.stop(error: error.localizedDescription)
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: .main)
            }
        } catch {
            stop(error: error.localizedDescription)
        }
    }

    /// Stops serving; those watching are cut off.
    func stop() { stop(error: nil) }

    private func stop(error: String?) {
        restarts.stop(listeners, failed: error != nil)
        listeners = []
        readyListeners = []
        http.closeAll()
        stopAll()
        isRunning = false
        lastError = error
        onChange?()
    }

    /// Seconds a connection has to send a whole request head, from when it is accepted.
    static var requestTimeout: TimeInterval = 10

    /// The connections being served, as many and from one address as the host's may be.
    private lazy var http: MoonlightHTTPConnections = {
        let http = MoonlightHTTPConnections(limits: MoonlightConnectionLimits(deadline: Self.requestTimeout))
        http.onRequest = { [weak self] head, connection, secure in
            guard let self else { return }
            guard let request = Request.parse(head, secure: secure,
                                              peer: connection.currentPath?.remoteEndpoint ?? connection.endpoint) else {
                return self.send(status: "400 Bad Request", body: Data(), to: connection)
            }
            self.handle(request, on: connection)
        }
        return http
    }()

    private func accept(_ connection: NWConnection, secure: Bool) {
        http.accept(connection, secure: secure)
    }

    /// One GET request: its path, query and headers, and where it came from.
    struct Request {
        let path: String
        let query: [String: String]
        /// Header names in lower case.
        let headers: [String: String]
        let secure: Bool
        let peer: NWEndpoint?

        /// The value of cookie `name`.
        func cookie(_ name: String) -> String? {
            for part in (headers["cookie"] ?? "").split(separator: ";") {
                let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0] == name { return String(pair[1]) }
            }
            return nil
        }

        /// The peer's address, without its port.
        var address: String { MoonlightHost.address(peer) }

        static func parse(_ head: String, secure: Bool, peer: NWEndpoint?) -> Request? {
            guard let parsed = MoonlightHTTPConnections.parse(head) else { return nil }
            return Request(path: parsed.path, query: parsed.query, headers: parsed.headers, secure: secure, peer: peer)
        }
    }

    // MARK: Addresses

    /// The Mac's name on the network, as browsers find it.
    private var hostName: String {
        WebStreamCertificates.localHostName.map { "\($0).local" } ?? ProcessInfo.processInfo.hostName
    }

    /// The player page on the network; a browser pairs there.
    var watchURL: URL { URL(string: "http://\(hostName):\(port.rawValue)/watch")! }

    /// The player page over HTTPS, for a browser that trusts DAM's certificate authority.
    var secureWatchURL: URL {
        URL(string: "https://\(certificates?.host(preferring: hostName) ?? hostName):\(securePort.rawValue)/watch")!
    }

    /// Where a device installs the certificate authority from.
    var authorityURL: URL { URL(string: "http://\(hostName):\(port.rawValue)/ca.cer")! }

    /// The player page on this Mac, with This Mac's link.
    var localWatchURL: URL { URL(string: "http://localhost:\(port.rawValue)/watch?token=\(devices.thisMac.token)")! }

    /// A link device's addresses: the page, and the stream for players.
    func links(for device: WebStreamDevice) -> (page: URL, stream: URL) {
        (URL(string: "http://\(hostName):\(port.rawValue)/watch?token=\(device.token)")!,
         URL(string: "http://\(hostName):\(port.rawValue)/stream.mp4?token=\(device.token)")!)
    }

    /// The address a QR code holds: it pairs whoever opens it once, for a few minutes.
    func makeQRLink() -> URL {
        URL(string: "http://\(hostName):\(port.rawValue)/watch?pair=\(pairing.makeKey())")!
    }

    /// Adds a link for a player, named `name`.
    @discardableResult
    func addLink(named name: String) -> WebStreamDevice {
        let device = devices.add(WebStreamDevice(name: name, kind: .link))
        onChange?()
        return device
    }

    /// Forgets a device: its link or cookie stops working, and if it is watching, it is cut
    /// off; other viewers watch on.
    func forget(_ device: WebStreamDevice) {
        devices.remove(id: device.id)
        for session in sessions.values { session.cut(device: device.id) }
        for (request, connection) in waitingForDisplay where request.device == device.id { connection.cancel() }
        waitingForDisplay.removeAll { $0.0.device == device.id }
        onChange?()
    }

    // MARK: Requests

    private var sessions: [WebStreamSession.Key: WebStreamSession] = [:]
    /// A display made for streams, removed once no session uses it.
    private var ownedDisplay: CGDirectDisplayID?
    /// Requests waiting for the display being made.
    private var waitingForDisplay: [(WebStreamRequest, NWConnection)] = []
    private var makingDisplay = false
    /// Counts `stopAll`s, so a request that waited on a display through one is let go.
    private var generation = 0

    var viewerCount: Int { sessions.values.reduce(0) { $0 + $1.viewerCount } }

    static let cookieName = "dam_watch"

    /// Answers `request`. On the main queue.
    func handle(_ request: Request, on connection: NWConnection) {
        guard WebStreamReach.current.allows(request.peer) else {
            wsLog.debug("refused \(request.address, privacy: .public): out of reach")
            return send(status: "403 Forbidden", body: Data("\(AppIdentity.name) does not stream to \(request.address).\n".utf8),
                        to: connection)
        }
        switch request.path {
        case "/", "/watch":
            if let key = request.query["pair"] {
                guard pairing.use(key: key) else {
                    return send(status: "403 Forbidden", body: Data("This QR code was used already, or is too old.\n".utf8),
                                to: connection)
                }
                let device = devices.add(WebStreamDevice(
                    name: WebStreamPairing.name(userAgent: request.headers["user-agent"], address: request.address), kind: .browser))
                wsLog.debug("paired \(device.name, privacy: .public) by QR code")
                onChange?()
                return send(status: "303 See Other", headers: ["Location: /watch", cookie(for: device, secure: request.secure)],
                            body: Data(), to: connection)
            }
            send(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(WebStreamPage.html.utf8), to: connection)
        case "/ca.cer":
            guard let authority = certificates?.authority else { return send(status: "404 Not Found", body: Data(), to: connection) }
            send(status: "200 OK", contentType: "application/x-x509-ca-cert",
                 headers: ["Content-Disposition: attachment; filename=\"\(AppIdentity.name) Browser Stream.cer\""],
                 body: authority, to: connection)
        case "/time":
            // The Mac's clock, for the page to set its own against.
            send(status: "200 OK", contentType: "text/plain",
                 body: Data(String(format: "%.1f", Date().timeIntervalSince1970 * 1000).utf8), to: connection)
        case "/pair/begin":
            beginPairing(request, on: connection)
        case "/pair/wait":
            guard let id = request.query["id"], let pending = pairing.request(id: id) else {
                return sendJSON(["state": "expired"], to: connection)
            }
            if let device = pending.device {
                return sendJSON(["state": "paired"], headers: [cookie(for: device, secure: request.secure)], to: connection)
            }
            sendJSON(["state": pending.declined ? "declined" : "waiting"], to: connection)
        case "/apps.json", "/stream.mp4":
            guard let device = devices.device(token: request.query["token"])
                               ?? devices.device(token: request.cookie(Self.cookieName))
            else {
                return send(status: "401 Unauthorized", body: Data("Pair this browser, or use a link from \(AppIdentity.name).\n".utf8),
                            to: connection)
            }
            if request.path == "/apps.json" {
                send(status: "200 OK", contentType: "application/json", body: appsJSON(), to: connection)
            } else {
                var stream = WebStreamRequest.parse(request.query, preferred: preferredProfile())
                stream.device = device.id
                serve(stream, on: connection)
            }
        default:
            send(status: "404 Not Found", body: Data(), to: connection)
        }
    }

    private func beginPairing(_ request: Request, on connection: NWConnection) {
        guard Self.allowsPairing else {
            return sendJSON(["state": "refused", "message": "\(AppIdentity.name) is not taking new browsers."], to: connection)
        }
        let name = WebStreamPairing.name(userAgent: request.headers["user-agent"], address: request.address)
        guard let pending = pairing.begin(address: request.address, name: name) else {
            return sendJSON(["state": "busy", "message": "Another browser is pairing. Try again in a few minutes."],
                            to: connection)
        }
        wsLog.debug("pairing requested by \(name, privacy: .public)")
        sendJSON(["state": "waiting", "id": pending.id, "code": pending.code], to: connection)
        guard let requestCode else { return }
        requestCode(request.address, name) { [weak self] code in
            guard let self else { return }
            let paired = self.pairing.answer(id: pending.id, code: code) { self.devices.add($0) }
            wsLog.debug("pairing \(name, privacy: .public): \(paired ? "paired" : "refused", privacy: .public)")
            if paired { self.onChange?() }
        }
    }

    /// The header that gives a browser its device's token, for a year.
    private func cookie(for device: WebStreamDevice, secure: Bool) -> String {
        "Set-Cookie: \(Self.cookieName)=\(device.token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict"
            + (secure ? "; Secure" : "")
    }

    private func sendJSON(_ object: [String: String], headers: [String] = [], to connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(status: "200 OK", contentType: "application/json", headers: headers, body: body, to: connection)
    }

    /// Whether `given` is `token`, taking as long whatever the first difference.
    static func matches(_ given: String?, _ token: String) -> Bool {
        let a = Array((given ?? "").utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Ends every session; their viewers' connections are closed.
    func stopAll() {
        generation += 1
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
        // Forgotten while it waited for a display.
        if let device = request.device, !devices.all.contains(where: { $0.id == device }) { return connection.cancel() }
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
            // One display at a time: requests while it is made wait for it, even those
            // after a stop.
            waitingForDisplay.append((request, connection))
            guard !makingDisplay else { return }
            makingDisplay = true
            let (width, height, fps) = request.newDisplay
            wsLog.debug("making a \(width)×\(height)@\(fps) display to stream")
            makeDisplay(width, height, fps) { [weak self] id in
                guard let self else { return }
                self.makingDisplay = false
                let waiting = self.waitingForDisplay
                self.waitingForDisplay = []
                guard let id else {
                    for (_, connection) in waiting {
                        self.send(status: "503 Service Unavailable",
                                  body: Data("\(AppIdentity.name) could not make a display\n".utf8), to: connection)
                    }
                    return
                }
                // Everyone who asked for it was stopped meanwhile.
                guard !waiting.isEmpty else {
                    self.removeDisplay?(id)
                    return
                }
                if let old = self.ownedDisplay, old != id { self.removeDisplay?(old) }
                self.ownedDisplay = id
                for (request, connection) in waiting { self.serve(request, on: connection) }
            }
            return
        }
        // A display made for the stream follows the viewer's screen when it is turned; the
        // page asks again when it is.
        if displayID == ownedDisplay, let resizeDisplay, let wanted = Self.turnedSize(of: displayID, for: request) {
            wsLog.debug("turning display \(displayID) to \(wanted.width)×\(wanted.height) for the viewer")
            let generation = self.generation
            return resizeDisplay(displayID, wanted.width, wanted.height, wanted.fps) { [weak self] _ in
                // Stopped meanwhile: the request goes with everything else.
                guard let self, self.generation == generation else { return connection.cancel() }
                var request = request
                request.portrait = nil
                self.serve(request, on: connection)
            }
        }
        guard let size = Self.pictureSize(of: displayID, request: request) else {
            return send(status: "503 Service Unavailable", body: Data("The display is not on\n".utf8), to: connection)
        }
        let key = WebStreamSession.Key(displayID: displayID, profile: request.profile, bitrateKbps: request.bitrateKbps,
                                       fps: size.fps, width: size.width, height: size.height,
                                       lowLatency: request.lowLatency)
        let viewer = WebStreamViewer(connection: connection,
                                     maxInFlight: request.profile.maxInFlight(bitrateKbps: request.bitrateKbps),
                                     audio: request.audio, device: request.device)
        // A session that has just ended, and is still to be let go here, takes no one.
        if let running = sessions[key], running.add(viewer) { return }
        let session: WebStreamSession
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
        session.add(viewer)
    }

    /// The size and rate to make `displayID` for a request whose screen stands the other way
    /// from the stream the display gives now, or nil when they stand the same way.
    static func turnedSize(of displayID: CGDirectDisplayID, for request: WebStreamRequest,
                           rotation: DisplayRotation? = nil) -> (width: Int, height: Int, fps: Int)? {
        guard let portrait = request.portrait, let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let rotation = rotation ?? StreamRotations.shared.rotation(of: displayID)
        let (width, height) = rotation.inverse.size(width: mode.pixelWidth, height: mode.pixelHeight)
        guard width != height, portrait != (height > width) else { return nil }
        let rate = Int(mode.refreshRate.rounded())
        return (height, width, rate > 0 ? rate : request.newDisplay.fps)
    }

    /// The stream's size and rate for `displayID`: what the request asks, else the display's
    /// pixels, scaled to fit `maxPixels`, at its refresh rate; nil if it is off. A display DAM
    /// turned on its side gives a stream the way up it had before, as its captures turn their
    /// frames back.
    static func pictureSize(of displayID: CGDirectDisplayID, request: WebStreamRequest,
                            rotation: DisplayRotation? = nil) -> (width: Int, height: Int, fps: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let rotation = rotation ?? StreamRotations.shared.rotation(of: displayID)
        var (width, height) = rotation.inverse.size(width: mode.pixelWidth, height: mode.pixelHeight)
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

    private func send(status: String, contentType: String = "text/plain", headers: [String] = [], body: Data,
                      to connection: NWConnection) {
        MoonlightHTTPConnections.send(status: status, contentType: contentType, headers: headers + ["Cache-Control: no-store"],
                                      body: body, to: connection)
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
        let lowLatency: Bool
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
    /// The last picture captured, and when it came.
    private var lastFrame: (buffer: CVPixelBuffer, at: UInt64)?
    /// Frames' slots; on `queue`.
    private var grid: FrameGrid
    /// Fills the grid's empty slots. It, `silenceTimer`, `statsTimer` and `activity` are
    /// under `lock`.
    private var repeater: DispatchSourceTimer?
    /// On `queue`.
    private lazy var keyFrames = MoonlightKeyFrameRequester(retryingOn: queue)
    private var activity: NSObjectProtocol?
    private var statsTimer: DispatchSourceTimer?
    private let stats = MoonlightStreamStats()
    /// Nanoseconds frames spent in the encoder, and how many; under `lock`.
    private var encodeTime: (total: UInt64, frames: Int) = (0, 0)
    /// Frames given to the encoder: captured, and repeats filling the grid; under `lock`.
    private var given: (real: Int, repeats: Int) = (0, 0)

    // The stream's clock, on `queue`: the first frame's time is its zero.
    private var anchor: CMTime?
    /// When the stream's zero was, in milliseconds since 1970 on the Mac's clock, for the
    /// page to tell how long a frame took from the screen to it; on `queue`.
    private var epoch: Double?
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
                                                   bitrateKbps: key.bitrateKbps, lowLatency: key.lowLatency)
        reorders = settings.reordering
        encoder = try MoonlightVideoEncoder(settings: settings) { [weak self] frame in
            self?.queue.async { self?.took(frame) }
        }
        aac = try MoonlightAudioEncoder(codec: .aac, bitrate: 192_000) { [weak self] packet in
            self?.aacPending.append(packet)
        }
    }

    func start() {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Streaming a display")
        let capture = MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height,
                                             fps: key.fps) { [weak self] buffer, time in
            guard let self else { return }
            let at = DispatchTime.now().uptimeNanoseconds
            self.queue.async { self.encode(buffer, captured: time, at: at) }
        }
        capture.showsCursor = WebStreamServer.showsPointer
        capture.audioQueue = queue
        capture.audio = { [weak self] sample in self?.took(audio: sample) }
        capture.onStop = { [weak self] error in self?.end("capture stopped: \(error.localizedDescription)") }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1 / Double(key.fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.repeatIfStill() }
        let silence = DispatchSource.makeTimerSource(queue: queue)
        silence.schedule(deadline: .now() + 0.1, repeating: 0.02, leeway: .milliseconds(5))
        silence.setEventHandler { [weak self] in self?.padSilence() }
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
        // Under the lock, as `stop` may come from any thread, and before capture starts,
        // which can end the session on its own.
        lock.lock()
        self.activity = activity
        self.capture = capture
        (repeater, silenceTimer, self.statsTimer) = (timer, silence, statsTimer)
        lock.unlock()
        [timer, silence, statsTimer].forEach { $0.resume() }
        capture.start { [weak self] error in
            guard let error else { return }
            self?.end("capture: \(error.localizedDescription)")
        }
        // Capture can start and still send nothing; end then rather than leave the page
        // connecting, and the Mac kept awake, for ever. Allows for capture restarting replayd.
        queue.asyncAfter(deadline: .now() + 5 + MoonlightScreenCapture.answerTimeout + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let captured = self.lastFrame != nil
            self.lock.unlock()
            if !captured { self.end("capture did not start") }
        }
        wsLog.debug("session \(self.key.width)×\(self.key.height)@\(self.key.fps) \(self.key.profile.rawValue, privacy: .public) \(self.key.bitrateKbps) kbps from display \(self.key.displayID)")
    }

    /// Takes `viewer` in; it gets the stream from the next keyframe. False, and the viewer
    /// left alone, once the session has ended.
    @discardableResult
    func add(_ viewer: WebStreamViewer) -> Bool {
        lock.lock()
        guard !ended else { lock.unlock(); return false }
        viewers.append(viewer)
        closing = false
        lock.unlock()
        viewer.onClose = { [weak self, weak viewer] in
            guard let self, let viewer else { return }
            self.remove(viewer)
        }
        viewer.watch()
        wsLog.debug("viewer joined: \(self.viewerCount) watching")
        queue.async { [weak self] in self?.requestKeyFrame() }
        DispatchQueue.main.async { self.onChange?() }
        return true
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

    /// Closes the connections of `device`'s viewers; the session ends as when they leave.
    func cut(device: String) {
        lock.lock()
        let leaving = viewers.filter { $0.device == device }
        lock.unlock()
        leaving.forEach { $0.close() }
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
        let timers = [repeater, silenceTimer, statsTimer]
        (repeater, silenceTimer, statsTimer) = (nil, nil, nil)
        let activity = self.activity
        self.activity = nil
        lock.unlock()
        capture?.stop()
        for viewer in viewers {
            viewer.onClose = nil
            viewer.close()
        }
        timers.forEach { $0?.cancel() }
        queue.async { [self] in aac = nil }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func end(_ reason: String) {
        lock.lock()
        let first = !ended
        ended = true
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
    /// is given comes through `queue`, so frames reach it in the order of their slots. A
    /// frame whose slot is still to come, from a display faster than the stream, is only
    /// kept as the last picture, for the grid's next empty slot.
    ///
    /// Slots the frame jumps over get the picture before it first. The repeater gives up on
    /// a slot only a frame's time after it, so a screen changing at 30 Hz brings each frame
    /// before the slot between is filled, and the track had a hole every other frame. WebKit
    /// drops every frame after such a hole until the next keyframe, which may never come.
    private func encode(_ buffer: CVPixelBuffer, captured time: CMTime, at: UInt64) {
        lock.lock()
        let previous = lastFrame
        let encoder = self.encoder
        lock.unlock()
        let skipped = previous == nil ? [] : grid.slotsBefore(time, limit: 4)
        for slot in skipped { encoder?.encode(previous!.buffer, at: slot) }
        let slot = grid.snap(time, now: CMClockGetTime(CMClockGetHostTimeClock()))
        lock.lock()
        lastFrame = (buffer, at)
        if slot != nil { given.real += 1 }
        given.repeats += skipped.count
        lock.unlock()
        if let slot { encoder?.encode(buffer, at: slot) }
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
        if anchor == nil {
            let zero = CMTimeMinimum(decodeTime, frame.time)
            anchor = zero
            let since = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), zero))
            epoch = (Date().timeIntervalSince1970 - since) * 1000
        }
        guard let anchor else { return }
        let sample = frame.avcc
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
        // A viewer still sending what it held asks for none: one that has stalled (a tab in
        // the background) would otherwise have every viewer's picture made of keyframes. Once
        // it has sent most of it, it resumes at a keyframe as soon as one can be had.
        var waiting = false
        for viewer in viewers {
            switch viewer.take(video: fragment, keyFrame: frame.isKeyFrame,
                               codecs: viewer.audio ? codecs.sound : codecs.silent,
                               initSegment: viewer.audio ? initSegment.sound : initSegment.silent, epoch: epoch) {
            case .taken, .behind: break
            case .waitingForKeyFrame, .catchingUp: waiting = true
            }
        }
        // Those who asked for it have it: a request held for later now asks for no other.
        if frame.isKeyFrame { keyFrames.keyFrameSent() }
        if waiting { requestKeyFrame() }
        stats.video(packets: 1, bytes: fragment.count, refused: 0, keyFrame: frame.isKeyFrame)
    }

    /// The next frame as a keyframe, from the last picture at once if the screen is still;
    /// on `queue` (see MoonlightKeyFrameRequester).
    private func requestKeyFrame() {
        keyFrames.request { [weak self] in
            guard let self else { return (nil, nil) }
            self.lock.lock()
            let encoder = self.encoder
            let last = self.lastFrame
            self.lock.unlock()
            self.stats.keyFrameRequested()
            // A still screen gets its keyframe from the last picture at once; a moving one
            // from its next frame.
            guard let last, DispatchTime.now().uptimeNanoseconds - last.at > self.interval * 3 / 2 else {
                return (encoder, nil)
            }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            return (encoder, (last.buffer, self.grid.nextSlot(before: now) ?? self.grid.snap(now)))
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
    /// silence first, so each packet's time follows from how many samples came before it,
    /// and a piece that overlaps silence put in for it, as it came late, loses as much.
    private func took(audio sample: CMSampleBuffer) {
        guard let anchor else { return }
        let time = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), anchor)
        let actual = CMTimeConvertScale(time, timescale: Int32(MP4Fragmenter.audioTimescale), method: .default).value
        var skipped = 0
        if let start = audioStart {
            switch Self.alignment(gap: actual - (start + Int64(audioFed))) {
            case .asIs: break
            case .restart: audioStart = actual - Int64(audioFed)
            case .silence(let samples): feedSilence(samples: samples)
            case .drop(let samples): skipped = min(samples, CMSampleBufferGetNumSamples(sample))
            }
        } else {
            audioStart = max(actual, 0)
        }
        let kept = CMSampleBufferGetNumSamples(sample) - skipped
        guard kept > 0 else { return }
        audioFed += kept
        aac?.encode(sample, skipping: skipped)
        flushAAC()
    }

    enum SoundAlignment: Equatable {
        case asIs
        /// So far off that the track starts again from here.
        case restart
        /// This many samples of silence first, for a gap.
        case silence(Int)
        /// This many of the piece's samples left out, for an overlap.
        case drop(Int)
    }

    /// What a piece of sound needs that arrives `gap` samples after where the track
    /// stands; a few milliseconds either way are let be.
    static func alignment(gap: Int64) -> SoundAlignment {
        if gap > 2 * Int64(MP4Fragmenter.audioTimescale) { return .restart }
        if gap > 1920 { return .silence(Int(gap)) }
        if gap < -Int64(MP4Fragmenter.aacFrameLength) { return .drop(Int(-gap)) }
        return .asIs
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

    /// As `snap`, unless that slot is more than a slot's time after `now`: then nil, and no
    /// slot is taken. Frames coming faster than the grid would otherwise run its times ever
    /// further ahead of the clock.
    mutating func snap(_ time: CMTime, now: CMTime) -> CMTime? {
        if let origin {
            let seconds = CMTimeGetSeconds(CMTimeSubtract(time, origin))
            let slot = max(Int64((seconds * Double(fps)).rounded(.down)), lastSlot + 1)
            let limit = CMTimeAdd(now, CMTime(value: 1, timescale: CMTimeScale(fps)))
            guard CMTimeAdd(origin, CMTime(value: slot, timescale: CMTimeScale(fps))) <= limit else { return nil }
        }
        return snap(time)
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

    /// Takes the empty slots before the one `time` falls in, at most `limit` of them: the
    /// slots a frame at `time` would jump over, leaving a hole in the track.
    mutating func slotsBefore(_ time: CMTime, limit: Int) -> [CMTime] {
        let previous = CMTimeSubtract(time, CMTime(value: 1, timescale: CMTimeScale(fps)))
        var slots: [CMTime] = []
        while slots.count < limit, let slot = nextSlot(before: previous) { slots.append(slot) }
        return slots
    }
}

// MARK: - Viewer

/// One client's connection, given the stream from a keyframe on.
final class WebStreamViewer {

    enum Outcome {
        case taken
        /// Not yet watching: the next keyframe starts it.
        case waitingForKeyFrame
        /// Fell behind, by more than `maxInFlight`, and still has most of that to send: a
        /// keyframe now would only queue behind it.
        case behind
        /// Fell behind and has since sent most of what it held: the next keyframe resumes it.
        case catchingUp
    }

    private let connection: NWConnection
    /// Bytes handed to the connection and not yet taken by the network.
    private let maxInFlight: Int
    /// Seconds a viewer may stay behind before it is let go, as a tab in the background
    /// that takes nothing would forever.
    private let patience: TimeInterval
    /// Whether the viewer takes the sound track.
    let audio: Bool
    /// The id of the device watching.
    let device: String?
    private let lock = NSLock()
    private var inFlight = 0
    private var closed = false
    private var started = false
    private var waitingForKeyFrame = true
    /// When it fell behind, while it skips to a keyframe.
    private var behindSince: UInt64?
    private var closeHandler: (() -> Void)?

    /// Called once, from any thread, when the client has gone.
    var onClose: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closeHandler }
        set { lock.lock(); closeHandler = newValue; lock.unlock() }
    }

    init(connection: NWConnection, maxInFlight: Int, audio: Bool = true, device: String? = nil,
         patience: TimeInterval = 10) {
        self.connection = connection
        self.maxInFlight = max(maxInFlight, 256 * 1024)
        self.audio = audio
        self.device = device
        self.patience = patience
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

    func take(video fragment: Data, keyFrame: Bool, codecs: String, initSegment: Data, epoch: Double? = nil) -> Outcome {
        lock.lock()
        guard !closed else { lock.unlock(); return .taken }
        if let behindSince {
            // Skipping: resumed at a keyframe once most of what it held has gone out.
            if DispatchTime.now().uptimeNanoseconds - behindSince > UInt64(patience * 1e9) {
                lock.unlock()
                wsLog.debug("viewer behind for \(self.patience, format: .fixed(precision: 1)) s; letting it go")
                close()
                return .taken
            }
            guard inFlight <= maxInFlight / 2 else { lock.unlock(); return .behind }
            guard keyFrame else { lock.unlock(); return .catchingUp }
            self.behindSince = nil
            waitingForKeyFrame = false
            lock.unlock()
        } else if waitingForKeyFrame {
            guard keyFrame else { lock.unlock(); return .waitingForKeyFrame }
            waitingForKeyFrame = false
            started = true
            lock.unlock()
            send(Data(Self.head(codecs: codecs, epoch: epoch).utf8))
            send(initSegment)
        } else if inFlight > maxInFlight {
            waitingForKeyFrame = true
            behindSince = DispatchTime.now().uptimeNanoseconds
            lock.unlock()
            wsLog.debug("viewer behind by \(self.inFlight) bytes; waiting for a keyframe")
            return .behind
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

    /// The response's head: a body of unknown length that ends with the connection. With
    /// it, when the stream's zero was on the Mac's clock (see WebStreamSession.epoch).
    static func head(codecs: String, epoch: Double? = nil) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nCache-Control: no-store\r\nConnection: close\r\n" +
        "Access-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: X-Codecs, X-Stream-Epoch\r\n" +
        "X-Codecs: \(codecs)\r\n" + (epoch.map { "X-Stream-Epoch: \(String(format: "%.1f", $0))\r\n" } ?? "") + "\r\n"
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
        let onClose = closeHandler
        closeHandler = nil
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
      #v, #c { display: block; width: 100vw; height: 100vh; object-fit: contain; background: #000; }
      #v[hidden], #c[hidden] { display: none; }
      #bar { position: fixed; left: 0; right: 0; bottom: 0; display: flex; flex-wrap: wrap; gap: 10px 16px; align-items: center;
             padding: 10px 14px; background: rgba(20,20,20,.85); backdrop-filter: blur(10px); transition: opacity .3s; }
      body.idle #bar { opacity: 0; pointer-events: none; }
      label { display: flex; align-items: center; gap: 6px; white-space: nowrap; }
      label[hidden] { display: none; }
      select, input[type=number], button { font: inherit; color: inherit; background: #333; border: 0; border-radius: 6px; padding: 4px 8px; }
      input[type=range] { width: 140px; }
      #stats { margin-left: auto; opacity: .7; font-variant-numeric: tabular-nums; }
      #msg { position: fixed; inset: 0; display: grid; place-items: center; text-align: center; padding: 20px; }
      #msg[hidden] { display: none; }
      #msg .code { font: 600 56px ui-monospace, Menlo, monospace; letter-spacing: 0.15em; margin: 12px 0; }
      #msg .small { opacity: 0.7; font-size: 13px; }
      code { user-select: all; }
      #hint { position: fixed; top: 12px; left: 50%; transform: translateX(-50%); max-width: min(560px, calc(100vw - 32px));
              box-sizing: border-box; padding: 10px 36px 10px 14px; border-radius: 8px; background: rgba(20,20,20,.9); line-height: 1.4; }
      #hint[hidden] { display: none; }
      #hint button { position: absolute; top: 6px; right: 6px; padding: 2px 8px; background: none; }
    </style>
    </head>
    <body>
    <video id="v" muted playsinline></video>
    <canvas id="c" hidden></canvas>
    <div id="msg" hidden></div>
    <div id="hint" hidden><span></span><button aria-label="Close">×</button></div>
    <div id="bar">
      <label>Display <select id="app"></select></label>
      <label>Profile <select id="profile">
        <option value="interactive">Interactive</option>
        <option value="balanced">Balanced</option>
        <option value="viewing">Viewing</option>
      </select></label>
      <label>Decode <select id="decoder">
        <option value="auto">Auto</option>
        <option value="direct">Directly</option>
        <option value="mse">Media Source</option>
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
      let buffer = params.get('buffer'), lowlatency = params.get('lowlatency');
      let decoder = ['direct', 'mse'].includes(params.get('decoder')) ? params.get('decoder') : 'auto';
      const token = params.get('token') || '';
      let abort = null, source = null, sb = null, queue = [], bytes = 0, held = true, stalls = 0, cutOff = false;
      // Whether a stream has played on this page; when the stream started; the reconnects
      // of the last five minutes; what the watchdog saw last; the screen's wake lock.
      let played = false, startedAt = 0, retries = [], retryTimer = null, watch = null, wake = null;
      // What this browser needs in hand on top of `buffer`, learned from its stalls and kept
      // for its next stream, and when that last changed: WebKit runs dry with less than about
      // 100 ms ahead, and a target under that only stalls, every frame, without coming closer.
      // Stalls in a stream's first 2 seconds are the decoder starting, and teach nothing.
      let extra = 0, extraChanged = 0, playingSince = 0;
      try { extra = Math.min(Math.max(+localStorage.getItem('extraBuffer') || 0, 0), 0.5); } catch (e) {}
      // When the stream's zero was on the Mac's clock (from its response), the Mac's clock
      // less this one's, and how long the frames shown in the last second took from the Mac's
      // screen to this one.
      let epoch = null, offset = null, clock = [], delays = [];
      // When the last bytes came, and when the gaps between them began that were long
      // enough to show.
      let lastBytes = 0, gaps = [], hinted = false;
      // Whether this stream is decoded directly (WebCodecs), not through Media Source; its
      // decoder, the newest picture not yet drawn, and how many were drawn. Direct decoding
      // that failed in this browser isn't tried again on the page.
      let direct = false, decoding = null, picture = null, drawn = 0, directFailed = false;
      const canvas = $('c'), context = canvas.getContext('2d');
      function setExtra(seconds) {
        extra = seconds; extraChanged = performance.now();
        try { localStorage.setItem('extraBuffer', String(extra)); } catch (e) {}
      }

      const MS = window.ManagedMediaSource || window.MediaSource;
      const canDecode = !!(window.VideoDecoder && window.EncodedVideoChunk);
      if (!MS && !canDecode) { $('msg').hidden = false; $('msg').textContent = 'This browser cannot play streams (no Media Source Extensions).'; return; }
      // Direct decoding draws each picture the moment it is decoded, with nothing held in
      // between. Auto takes it for Interactive without sound (sound needs Media Source to
      // keep it in time), where the browser can show a canvas full screen: an iPhone can
      // show only a video so.
      function decodesDirectly() {
        if (!canDecode || directFailed || !video.muted) return false;
        return decoder === 'direct' || !MS || (decoder === 'auto' && profile === 'interactive' && !!canvas.requestFullscreen);
      }

      // Sound comes only when wanted: with it, each frame waits for the sound of its moment.
      function url() {
        const q = new URLSearchParams(token ? { token } : {});
        if (app) q.set('app', app);
        q.set('profile', profile);
        q.set('bitrate', Math.round(bitrate * 1000));
        if (video.muted) q.set('audio', '0');
        if (lowlatency) q.set('lowlatency', lowlatency);
        q.set('orientation', portrait.matches ? 'portrait' : 'landscape');
        return '/stream.mp4?' + q;
      }
      // A display made for the stream stands the way this screen does; ask again when it turns.
      const portrait = matchMedia('(orientation: portrait)');
      portrait.addEventListener('change', () => { if (source) start(); });
      // A tab in the background stops reading, and DAM lets a viewer go that falls far
      // behind; back in front, it starts again.
      document.addEventListener('visibilitychange', () => { if (document.hidden) return; if (cutOff) start(); else keepAwake(); });

      function start(text) {
        stop();
        queue = []; bytes = 0; held = true; stalls = 0; cutOff = false; watch = null; startedAt = performance.now(); playingSince = 0;
        epoch = null; delays = []; lastBytes = 0; gaps = [];
        direct = decodesDirectly(); drawn = 0;
        video.hidden = direct; canvas.hidden = !direct; $('buffer').disabled = direct;
        if (direct) {
          const stream = source = {};
          video.removeAttribute('src'); video.load();
          openDirect(stream);
        } else {
          const ms = source = new MS();
          video.disableRemotePlayback = true;
          video.src = URL.createObjectURL(ms);
          ms.addEventListener('sourceopen', () => open(ms), { once: true });
        }
        history.replaceState(null, '', '?' + new URLSearchParams({ ...(token ? { token } : {}), ...(app ? { app } : {}), profile, bitrate: Math.round(bitrate * 1000), buffer: Math.round(buffer * 1000), ...(lowlatency ? { lowlatency } : {}), ...(decoder !== 'auto' ? { decoder } : {}) }));
        // Making a display for the stream can take a while.
        $('msg').hidden = false; $('msg').textContent = text || 'Connecting…';
      }

      function stop() {
        clearTimeout(retryTimer);
        if (abort) abort.abort();
        abort = null; sb = null;
        if (source && source.readyState === 'open') try { source.endOfStream(); } catch (e) {}
        source = null;
        if (decoding && decoding.state !== 'closed') try { decoding.close(); } catch (e) {}
        decoding = null;
        if (picture) { picture.close(); picture = null; }
      }

      // Each stream has its own controller: one replaced by a restart (a turn, a new
      // setting) was stopped on purpose, and leaves the stream that took its place alone.
      async function open(ms) {
        if (ms !== source) return;
        const ctl = new AbortController();
        abort = ctl;
        const gone = () => ctl.signal.aborted || ms !== source;
        if (ms.duration !== Infinity) try { ms.duration = Infinity; } catch (e) {}
        let response;
        try {
          response = await fetch(url(), { signal: ctl.signal, cache: 'no-store' });
        } catch (e) { if (!gone()) (played ? retry : fail)('Could not reach the stream.'); return; }
        if (gone()) return;
        if (!response.ok) { const text = await response.text().catch(() => ''); if (!gone()) fail(text); return; }
        const codecs = response.headers.get('X-Codecs') || 'avc1.640028,mp4a.40.2';
        epoch = +response.headers.get('X-Stream-Epoch') || null;
        if (epoch) for (let i = 0; i < 4; i++) setTimeout(setClock, i * 300);
        const mime = 'video/mp4; codecs="' + codecs + '"';
        if (!MS.isTypeSupported(mime)) return fail('This browser cannot decode ' + codecs + '.');
        sb = ms.addSourceBuffer(mime);
        sb.mode = 'segments';
        sb.addEventListener('updateend', pump);
        sb.addEventListener('updateend', follow);
        const reader = response.body.getReader();
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (gone()) return;
            if (done) break;
            $('msg').hidden = true; played = true;
            arrived(performance.now());
            queue.push(value); bytes += value.length;
            pump();
          }
          retry('The stream ended.');
        } catch (e) { if (!gone()) retry('The stream broke off.'); }
      }

      // The stream decoded directly: its fragmented MP4 split into the H.264 samples it
      // carries, each handed to a WebCodecs decoder as it lands, and each picture drawn on
      // the next screen refresh, only the newest when several are waiting.
      async function openDirect(stream) {
        const ctl = new AbortController();
        abort = ctl;
        const gone = () => ctl.signal.aborted || stream !== source;
        let response;
        try {
          response = await fetch(url(), { signal: ctl.signal, cache: 'no-store' });
        } catch (e) { if (!gone()) (played ? retry : fail)('Could not reach the stream.'); return; }
        if (gone()) return;
        if (!response.ok) { const text = await response.text().catch(() => ''); if (!gone()) fail(text); return; }
        const codec = (response.headers.get('X-Codecs') || 'avc1.640028').split(',')[0];
        epoch = +response.headers.get('X-Stream-Epoch') || null;
        if (epoch) for (let i = 0; i < 4; i++) setTimeout(setClock, i * 300);
        const failed = e => {
          if (gone()) return;
          // Media Source plays it from here on.
          directFailed = true; decoder = 'mse'; $('decoder').value = 'mse';
          start('Decoding directly failed (' + (e && e.message || e) + '); trying Media Source…');
        };
        decoding = new VideoDecoder({
          output: frame => { if (gone()) return frame.close(); if (picture) picture.close(); picture = frame; },
          error: failed,
        });
        const mp4 = new FragmentReader();
        const reader = response.body.getReader();
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (gone()) return;
            if (done) break;
            $('msg').hidden = true; played = true;
            arrived(performance.now());
            bytes += value.length;
            for (const item of mp4.push(value)) {
              if (item.description) {
                // WebKit fails every frame without the size.
                decoding.configure({ codec, description: item.description, codedWidth: item.width, codedHeight: item.height,
                                     optimizeForLatency: true });
              } else if (decoding.state === 'configured') {
                decoding.decode(new EncodedVideoChunk(item));
              }
            }
          }
          retry('The stream ended.');
        } catch (e) { if (!gone()) { if (decoding && decoding.state === 'closed') failed(e); else retry('The stream broke off.'); } }
      }

      // Draws the newest picture decoded, at the screen's pace, and times it as `shown` does.
      function draw(now) {
        requestAnimationFrame(draw);
        if (!picture) return;
        const frame = picture; picture = null;
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth; canvas.height = frame.displayHeight;
        }
        context.drawImage(frame, 0, 0, canvas.width, canvas.height);
        if (epoch && offset !== null) {
          delays.push({ now, ms: performance.timeOrigin + now + offset - (epoch + frame.timestamp / 1000) });
          while (now - delays[0].now > 1000) delays.shift();
        }
        frame.close();
        if (!drawn++) { held = false; keepAwake(); }
      }
      requestAnimationFrame(draw);

      // A stream of fragmented MP4 cut into what a decoder takes: the video track's avcC and
      // size from the init segment, and from each fragment, its samples with their times in
      // microseconds and whether each is a keyframe.
      function FragmentReader() {
        // Where the samples of the last fragment start in its mdat, and their sizes and times.
        let pending = new Uint8Array(0), track = 0, scale = 90000, samples = [], start = 0;
        const u32 = (b, at) => ((b[at] << 24) >>> 0) + (b[at + 1] << 16) + (b[at + 2] << 8) + b[at + 3];
        const type = (b, at) => String.fromCharCode(b[at + 4], b[at + 5], b[at + 6], b[at + 7]);
        function* boxes(b, from, to) {
          for (let at = from; at + 8 <= to;) {
            let size = u32(b, at), head = 8;
            if (size === 1) { size = u32(b, at + 8) * 2 ** 32 + u32(b, at + 12); head = 16; }
            if (size < head || at + size > to) return;
            yield { type: type(b, at), at, body: at + head, end: at + size };
            at += size;
          }
        }
        const find = (b, box, path) => {
          for (const name of path) {
            const inner = [...boxes(b, box.body, box.end)].find(x => x.type === name);
            if (!inner) return null;
            box = inner;
          }
          return box;
        };
        function moov(b, box, out) {
          for (const trak of boxes(b, box.body, box.end)) {
            if (trak.type !== 'trak') continue;
            const stsd = find(b, trak, ['mdia', 'minf', 'stbl', 'stsd']);
            const avc1 = stsd && [...boxes(b, stsd.body + 8, stsd.end)].find(x => x.type === 'avc1');
            if (!avc1) continue;
            const avcC = [...boxes(b, avc1.body + 78, avc1.end)].find(x => x.type === 'avcC');
            const tkhd = find(b, trak, ['tkhd']), mdhd = find(b, trak, ['mdia', 'mdhd']);
            if (!avcC || !tkhd || !mdhd) continue;
            track = u32(b, tkhd.body + (b[tkhd.body] === 1 ? 20 : 12));
            scale = u32(b, mdhd.body + (b[mdhd.body] === 1 ? 20 : 12));
            const u16 = at => b[at] << 8 | b[at + 1];
            out.push({ description: b.slice(avcC.body, avcC.end), width: u16(avc1.body + 24), height: u16(avc1.body + 26) });
          }
        }
        function moof(b, box) {
          samples = [];
          for (const traf of boxes(b, box.body, box.end)) {
            if (traf.type !== 'traf') continue;
            const tfhd = find(b, traf, ['tfhd']), tfdt = find(b, traf, ['tfdt']), trun = find(b, traf, ['trun']);
            if (!tfhd || !tfdt || !trun || u32(b, tfhd.body + 4) !== track) continue;
            let time = b[tfdt.body] === 1 ? u32(b, tfdt.body + 4) * 2 ** 32 + u32(b, tfdt.body + 8) : u32(b, tfdt.body + 4);
            const flags = u32(b, trun.body) & 0xFFFFFF, count = u32(b, trun.body + 4);
            // The data offset counts from the moof's start; the mdat follows it.
            start = flags & 1 ? (u32(b, trun.body + 8) | 0) - (box.end - box.at) - 8 : 0;
            let at = trun.body + 8 + (flags & 1 ? 4 : 0) + (flags & 4 ? 4 : 0);
            for (let i = 0; i < count; i++) {
              const duration = flags & 0x100 ? u32(b, (at += 4) - 4) : 0;
              const size = flags & 0x200 ? u32(b, (at += 4) - 4) : 0;
              const sampleFlags = flags & 0x400 ? u32(b, (at += 4) - 4) : 0;
              const shift = flags & 0x800 ? (u32(b, (at += 4) - 4) | 0) : 0;
              samples.push({ size, key: !(sampleFlags & 0x10000), timestamp: Math.round((time + shift) * 1e6 / scale), duration: Math.round(duration * 1e6 / scale) });
              time += duration;
            }
          }
        }
        // Takes the next bytes; gives back what they complete.
        this.push = bytes => {
          const joined = new Uint8Array(pending.length + bytes.length);
          joined.set(pending); joined.set(bytes, pending.length);
          const out = [];
          let used = 0;
          for (const box of boxes(joined, 0, joined.length)) {
            if (box.type === 'moov') moov(joined, box, out);
            else if (box.type === 'moof') moof(joined, box);
            else if (box.type === 'mdat') {
              let at = box.body + start;
              for (const sample of samples) {
                out.push({ type: sample.key ? 'key' : 'delta', timestamp: sample.timestamp, duration: sample.duration,
                           data: joined.slice(at, at + sample.size) });
                at += sample.size;
              }
              samples = [];
            }
            used = box.end;
          }
          pending = joined.slice(used);
          return out;
        };
      }

      // A stream that played and broke off starts again after 1, 2, 4… seconds; the first
      // try comes back before DAM lets the display go. Not from a tab in the background (it
      // starts again once in front), and at most five times in five minutes.
      function retry(text) {
        const now = performance.now();
        retries = retries.filter(t => now - t < 300000);
        if (document.hidden || retries.length >= 5) { cutOff = true; return fail(document.hidden ? text : text + ' Reload to try again.'); }
        retries.push(now);
        stop();
        $('msg').hidden = false; $('msg').textContent = 'Reconnecting…';
        retryTimer = setTimeout(() => start('Reconnecting…'), 1000 * 2 ** (retries.length - 1));
      }

      // DAM sends every frame of a still screen too, so seconds without a byte mean the link
      // is gone, and bytes coming while the picture stands still mean a stuck decoder: both
      // start the stream again. One that never answers gives up after 30 seconds (making a
      // display takes up to about 15).
      function watchdog() {
        const now = performance.now();
        if (!source || document.hidden || (!direct && video.seeking)) { watch = null; return; }
        if (!bytes) { if (now - startedAt > 30000) (played ? retry : fail)('The Mac did not answer.'); return; }
        const q = !direct && video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null;
        const time = direct ? drawn : video.currentTime, frames = direct ? drawn : q ? q.totalVideoFrames : 0;
        if (!watch) { watch = { bytes, time, frames, fed: now, moved: now, counts: false }; return; }
        if (bytes !== watch.bytes) { watch.bytes = bytes; watch.fed = now; }
        // A browser that counts frames is trusted to: time running on without them is a
        // frozen picture too.
        if (frames !== watch.frames) watch.counts = true;
        if (held || (time !== watch.time && (frames !== watch.frames || !watch.counts))) watch.moved = now;
        watch.time = time; watch.frames = frames;
        if (now - watch.fed > 5000) retry('The stream stopped coming.');
        else if (now - watch.moved > 3000) retry('The picture froze.');
      }

      // The screen stays on while the stream plays, as a display's should. The browser lets
      // go of the lock when the tab is hidden, so it is asked for again on the way back.
      // Only over HTTPS.
      function keepAwake() {
        if (wake || !navigator.wakeLock || document.hidden || !source) return;
        const asked = wake = navigator.wakeLock.request('screen').then(lock => {
          lock.addEventListener('release', () => { if (wake === asked) wake = null; });
          return lock;
        }, () => { if (wake === asked) wake = null; });
      }
      function letSleep() { const asked = wake; wake = null; if (asked) asked.then(lock => lock && lock.release().catch(() => {})); }

      // The Mac's clock against this one: the middle of the quickest of the last few asks
      // for its time, a few as a stream starts and then every 10 seconds.
      function setClock() {
        if (document.hidden || !source) return;
        const sent = performance.now();
        fetch('/time', { cache: 'no-store' }).then(r => r.text()).then(text => {
          const back = performance.now(), mac = +text;
          if (!mac) return;
          clock.push({ rtt: back - sent, offset: mac - (performance.timeOrigin + (sent + back) / 2) });
          if (clock.length > 8) clock.shift();
          offset = clock.reduce((a, b) => b.rtt < a.rtt ? b : a).offset;
        }).catch(() => {});
      }
      setInterval(() => { if (epoch) setClock(); }, 10000);

      // Each frame as it is shown: when, on the Mac's clock, less when it was captured. The
      // capture is its slot on the stream's grid, up to a frame before. WebKit on macOS 13
      // gives a media time of 0 and an expected display time hours off for every frame
      // from Media Source; there the time playback stands at, and the callback's own time,
      // stand in for them.
      function shown(now, frame) {
        if (epoch && offset !== null) {
          const when = Math.abs(frame.expectedDisplayTime - now) < 1000 ? frame.expectedDisplayTime : now;
          const media = frame.mediaTime || video.currentTime;
          delays.push({ now, ms: performance.timeOrigin + when + offset - (epoch + media * 1000) });
          while (now - delays[0].now > 1000) delays.shift();
        }
        video.requestVideoFrameCallback(shown);
      }
      if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(shown);
      function delay() {
        if (!delays.length || performance.now() - delays[delays.length - 1].now > 1000) return null;
        const sorted = delays.map(d => d.ms).sort((a, b) => a - b);
        return Math.round(sorted[sorted.length >> 1]);
      }

      // Wi-Fi shared with AirDrop, Handoff or AirPlay (AWDL) leaves for the devices around
      // at a steady beat, a few times a second, and nothing comes meanwhile; a busy network
      // stops at random. Gaps too long for the buffer to cover, six or more in 15 seconds,
      // most of them the same time apart, between a quarter of a second and 1.2, bring a hint.
      // Not in a stream's first 2 seconds, when the decoder starts.
      function arrived(now) {
        const gap = now - lastBytes, began = lastBytes;
        lastBytes = now;
        if (hinted || !began || !playingSince || now - playingSince < 2000) return;
        if (gap < Math.max(50, (buffer + extra) * 1000)) return;
        gaps = gaps.filter(t => now - t < 15000);
        gaps.push(began);
        if (gaps.length < 6) return;
        const apart = gaps.slice(1).map((t, i) => t - gaps[i]);
        const median = apart.slice().sort((a, b) => a - b)[apart.length >> 1];
        if (median < 250 || median > 1200) return;
        if (apart.filter(d => Math.abs(d - median) <= median * 0.15).length < apart.length * 0.7) return;
        hinted = true;
        $('hint').querySelector('span').textContent = 'The picture stops every ' + (median / 1000).toFixed(1)
          + ' s, as Wi-Fi does while AirDrop, Handoff or AirPlay look for devices nearby. Turning off AirDrop, '
          + 'on this device or the Mac, should stop it.';
        $('hint').hidden = false;
      }
      $('hint').querySelector('button').onclick = () => { $('hint').hidden = true; };

      function pump() {
        if (!sb || sb.updating || !queue.length) return;
        // Trim what has been played, so memory stays put. Removing video takes with it every
        // frame up to the next keyframe, as they depend on it: DAM sends one at least every
        // 10 s, so a cut 25 s back never reaches what plays now.
        const t = video.currentTime;
        if (sb.buffered.length && sb.buffered.start(0) < t - 40) { sb.remove(0, t - 25); return; }
        let chunk;
        if (queue.length === 1) { chunk = queue[0]; } else {
          chunk = new Uint8Array(queue.reduce((n, c) => n + c.length, 0));
          let at = 0; for (const c of queue) { chunk.set(c, at); at += c.length; }
        }
        queue = [];
        try { sb.appendBuffer(chunk); } catch (e) { fail('Playback failed: ' + e.message); }
      }

      function fail(text) { stop(); letSleep(); $('msg').hidden = false; $('msg').textContent = text; }

      // Keeps playback `buffer` seconds (and what the browser needs on top) behind the latest
      // frame: a jump when far off, a slightly faster or slower rate when a little, over any
      // gap the still screen left, and, when the picture runs dry, a hold until the buffer is
      // back. Half a minute without a stall gives back 5 ms of the extra.
      function follow() {
        if (direct) return showStats(null);
        if (!sb || !sb.buffered.length) return;
        const now = performance.now();
        if (extra > 0 && !held && now - extraChanged > 30000) setExtra(Math.max(extra - 0.005, 0));
        const target = buffer + extra;
        const b = sb.buffered, end = b.end(b.length - 1), t = video.currentTime;
        let inside = false, next = null;
        for (let i = 0; i < b.length; i++) {
          if (t >= b.start(i) - 0.05 && t <= b.end(i) + 0.05) inside = true;
          else if (b.start(i) > t && next === null) next = b.start(i);
        }
        let lag = end - t;
        if (!inside && next !== null) { video.currentTime = Math.max(next, end - target); lag = end - video.currentTime; }
        else if (lag > target + 0.3) { video.currentTime = Math.max(end - target, 0); lag = end - video.currentTime; }
        // Held near the target: a touch faster past it, faster still well past it, slower short of it.
        video.playbackRate = lag > target + 0.12 ? 1.15 : lag > target + 0.025 ? 1.05 : lag < target - 0.08 ? 0.95 : 1;
        // A stream's first play waits for 100 ms more, which the decoder starting eats.
        if (held && lag >= target + (playingSince ? 0 : 0.1)) held = false;
        if (!held && video.paused) video.play().catch(() => {});
        const q = video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null;
        showStats(lag, q);
      }

      // What the stats line says: the picture's size, how long frames take from the Mac,
      // and for Media Source, what is buffered, stalls and frames dropped.
      function showStats(lag, q) {
        const ms = delay();
        const width = direct ? canvas.width : video.videoWidth, height = direct ? canvas.height : video.videoHeight;
        $('stats').textContent = (width && (!direct || drawn) ? width + '×' + height + ' · ' : '')
          + (ms !== null ? ms + ' ms from the Mac · ' : '')
          + (direct ? 'decoded directly' + (decoding ? ' · ' + decoding.decodeQueueSize + ' waiting' : '')
                    : Math.round(Math.max(lag, 0) * 1000) + ' ms buffered'
                      + (extra ? ' (+' + Math.round(extra * 1000) + ' ms for this browser)' : '')
                      + (stalls ? ' · ' + stalls + ' stall' + (stalls > 1 ? 's' : '') : '')
                      + (q ? ' · ' + q.droppedVideoFrames + ' dropped' : ''));
      }
      setInterval(() => { follow(); watchdog(); }, 100);
      // Out of picture: hold until the target is in hand again, rather than play each frame
      // the moment it lands and stutter; and aim 10 ms further back, at most every 300 ms.
      video.addEventListener('waiting', () => {
        if (!held && !video.seeking) {
          held = true; stalls++; video.pause();
          const now = performance.now();
          if (playingSince && now - playingSince > 2000 && now - extraChanged > 300) setExtra(Math.min(extra + 0.01, 0.5));
        }
        follow();
      });
      video.addEventListener('playing', () => { if (!playingSince) playingSince = performance.now(); follow(); keepAwake(); });

      // Controls.
      function setBuffer(seconds) { buffer = seconds; $('buffer').value = Math.round(seconds * 1000); $('bufferText').textContent = Math.round(seconds * 1000) + ' ms'; }
      $('profile').onchange = () => { profile = $('profile').value; bitrate = (info.bitrates[profile] || 20000) / 1000; $('bitrate').value = bitrate; setBuffer(info.buffers[profile] || 0.05); start(); };
      $('bitrate').onchange = () => { bitrate = +$('bitrate').value || 20; start(); };
      $('app').onchange = () => { app = $('app').value || null; start(); };
      $('decoder').value = decoder;
      $('decoder').parentElement.hidden = !canDecode || !MS;
      $('decoder').onchange = () => { decoder = $('decoder').value; directFailed = false; start(); };
      $('buffer').oninput = () => setBuffer(+$('buffer').value / 1000);
      $('mute').onclick = () => { video.muted = !video.muted; $('mute').textContent = video.muted ? 'Unmute' : 'Mute'; start(); };
      $('full').onclick = () => { const shown = direct ? canvas : video; (shown.requestFullscreen || shown.webkitEnterFullscreen || (() => {})).call(shown); };
      let idle; function awake() { document.body.classList.remove('idle'); clearTimeout(idle); keepAwake(); idle = setTimeout(() => document.body.classList.add('idle'), 3000); }
      ['mousemove', 'touchstart', 'keydown'].forEach(e => addEventListener(e, awake)); awake();

      // A browser without a link pairs: it shows a code, which the user types on the Mac,
      // and gets a cookie of its own once it is right.
      function pair() {
        $('msg').hidden = false; $('msg').textContent = 'Asking the Mac…';
        fetch('/pair/begin', { cache: 'no-store' }).then(r => r.json()).then(j => {
          if (j.state !== 'waiting') { $('msg').textContent = j.message || 'This browser cannot pair now.'; return; }
          $('msg').textContent = '';
          const box = document.createElement('div');
          box.innerHTML = '<p>To watch, type this code on the Mac:</p><p class="code"></p><p class="small">It works for five minutes.</p>';
          box.querySelector('.code').textContent = j.code;
          $('msg').append(box);
          const poll = () => fetch('/pair/wait?id=' + encodeURIComponent(j.id), { cache: 'no-store' }).then(r => r.json()).then(w => {
            if (w.state === 'paired') { $('msg').hidden = true; return load(); }
            if (w.state === 'waiting') return setTimeout(poll, 1000);
            $('msg').textContent = w.state === 'declined' ? 'Not paired: the code was wrong, or the Mac said no. Reload to try again.'
                                                          : 'The code ran out. Reload to try again.';
          }).catch(() => setTimeout(poll, 2000));
          poll();
        }).catch(() => fail('Could not reach the host.'));
      }

      function load() {
      fetch('/apps.json?' + new URLSearchParams(token ? { token } : {}), { cache: 'no-store' }).then(r => {
        if (r.status === 401) { if (token) fail('This link no longer works. Ask for a new one.'); else pair(); return null; }
        if (!r.ok) return r.text().then(t => { fail(t); return null; });
        return r.json();
      }).then(j => {
        if (!j) return;
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
      }
      load();
    })();
    </script>
    </body>
    </html>
    """#
}
