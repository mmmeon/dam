//
//  MoonlightHost.swift
//
//  Lets Moonlight find this Mac, pair with it and list what it can stream, speaking the
//  GameStream protocol Moonlight expects of a host (as Sunshine does): Bonjour as
//  _nvstream._tcp, an HTTP server for discovery and pairing, and an HTTPS server, open only
//  to paired devices' certificates, for everything after. Each streaming display is an app;
//  launching one leads to the RTSP handshake (MoonlightRTSP) and the stream (MoonlightStream).
//  Each paired device has a session of its own, up to `maxSessions` at once, with its own
//  RTSP and UDP ports: devices stream side by side, and each sees only its own as running.
//

import Foundation
import Network
import Security
import os.log

private let mlLog = Logger(subsystem: AppIdentity.bundleID, category: "Moonlight")

/// A device paired with the host, known by its certificate.
struct MoonlightClient: Codable, Equatable {
    /// Where it paired from; Moonlight sends no name of its own.
    let name: String
    let certificate: Data
    let paired: Date
    /// Whether its streams use low-latency rate control; see MoonlightVideoEncoder.
    var lowLatency = true
    /// Whether its mouse, keyboard and text reach the Mac; see MoonlightInputInjector.
    var allowsInput = true

    init(name: String, certificate: Data, paired: Date, lowLatency: Bool = true, allowsInput: Bool = true) {
        self.name = name
        self.certificate = certificate
        self.paired = paired
        self.lowLatency = lowLatency
        self.allowsInput = allowsInput
    }

    // Saved under a key of its own since low-latency became the default, so that devices
    // saved with the old default (off) get it too; devices saved before either have none.
    private enum CodingKeys: String, CodingKey {
        case name, certificate, paired, allowsInput
        case lowLatency = "lowLatencyEncoding"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        certificate = try container.decode(Data.self, forKey: .certificate)
        paired = try container.decode(Date.self, forKey: .paired)
        lowLatency = try container.decodeIfPresent(Bool.self, forKey: .lowLatency) ?? true
        allowsInput = try container.decodeIfPresent(Bool.self, forKey: .allowsInput) ?? true
    }
}

/// When HEVC is offered, where this Mac encodes it in hardware.
enum MoonlightHEVCOffer: String, CaseIterable {
    case automatic
    case on
    case off

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    var summary: String {
        switch self {
        case .automatic:
            return "Offers HEVC to a device only where this Mac encodes it as quickly as H.264 for that device: " +
                   "holding back no more frames, at least half as many a second."
        case .on: return "Offers HEVC to every device; Moonlight streams it wherever the device decodes it in hardware."
        case .off: return "Streams H.264 only."
        }
    }
}

/// An app Moonlight lists.
struct MoonlightApp: Equatable {
    let id: Int
    let title: String
    /// The display it streams.
    let displayID: CGDirectDisplayID
}

final class MoonlightHost {

    static let serviceType = "_nvstream._tcp"
    /// The versions Sunshine reports. Moonlight picks the pairing hash by the first number
    /// (7 and up: SHA-256) and checks the GameStream version against ones it knows to fail.
    static let appVersion = "7.1.431.-1"
    static let gfeVersion = "3.23.0.74"
    /// The codecs offered to a device with low-latency encoding on or off: H.264, and HEVC
    /// where this Mac encodes it in hardware, as `offer` says. Moonlight takes HEVC whenever
    /// it is offered and the device decodes it in hardware, and HEVC may be the slower codec
    /// to encode: on the Intel test Mac it encodes about 40 frames a second at 1080p (H.264:
    /// 165), holds each frame two frames' time, and has no low-latency rate control.
    static func codecs(lowLatency: Bool, offer: MoonlightHEVCOffer = MoonlightHost.hevcOffer,
                       support: [VideoCodec: VideoCodec.Support] = VideoCodec.support,
                       performance: @autoclosure () -> [VideoCodec: VideoCodec.Performance] = VideoCodec.performance)
        -> [VideoCodec] {
        guard support[.hevc]?.hardware == true else { return [.h264] }
        switch offer {
        case .on: return [.h264, .hevc]
        case .off: return [.h264]
        case .automatic:
            return hevcKeepsUp(lowLatency: lowLatency, support: support, performance: performance()) ? [.h264, .hevc] : [.h264]
        }
    }

    /// Whether HEVC streams to a device at least as quickly as H.264 would: its encoder
    /// holds back no more frames (none with low-latency rate control, which hands each back
    /// as it is encoded), and encodes at least half as many a second.
    static func hevcKeepsUp(lowLatency: Bool, support: [VideoCodec: VideoCodec.Support],
                            performance: [VideoCodec: VideoCodec.Performance]) -> Bool {
        guard let hevc = performance[.hevc], let h264 = performance[.h264] else { return false }
        func held(_ codec: VideoCodec, _ measured: VideoCodec.Performance) -> Int {
            lowLatency && support[codec]?.lowLatency == true ? 0 : measured.heldFrames
        }
        return held(.hevc, hevc) <= held(.h264, h264) && hevc.framesPerSecond >= h264.framesPerSecond / 2
    }

    /// Whether HDR10 is offered: HEVC Main10, which this Mac must make in hardware, unless
    /// HEVC is off. Only a launch that asks for HDR (Moonlight's own setting, which it sends
    /// as hdrMode) gets HEVC for it, whatever Automatic says, so serverinfo offers HEVC and
    /// Main10 then and DESCRIBE decides; without HDR the launch is offered `codecs`.
    static func offersHDR(offer: MoonlightHEVCOffer = MoonlightHost.hevcOffer,
                          support: [VideoCodec: VideoCodec.Support] = VideoCodec.support) -> Bool {
        offer != .off && support[.hevc].map { $0.hardware && $0.main10 } == true
    }

    /// ServerCodecModeSupport's bit for HEVC Main10 (SCM_HEVC_MAIN10).
    static let main10CodecMode = 0x0200

    /// What serverinfo offers: the device's codecs, and HEVC with Main10 where HDR is offered.
    static func codecModes(_ codecs: [VideoCodec], hdr: Bool) -> Int {
        codecs.reduce(0) { $0 | $1.moonlightCodecMode } | (hdr ? VideoCodec.hevc.moonlightCodecMode | main10CodecMode : 0)
    }

    /// When HEVC is offered; see `codecs`.
    static var hevcOffer: MoonlightHEVCOffer {
        get { UserDefaults.dam.string(forKey: hevcOfferKey).flatMap(MoonlightHEVCOffer.init(rawValue:)) ?? .automatic }
        set {
            UserDefaults.dam.set(newValue.rawValue, forKey: hevcOfferKey)
            if newValue == .automatic { measureEncoders() }
        }
    }
    private static let hevcOfferKey = "\(AppIdentity.shortID).moonlight.hevc"

    /// Finds what the encoders do before a device asks, off the main queue; measured only
    /// where Automatic needs it, and then only once for the Mac (see VideoCodec.performance).
    static func measureEncoders() {
        DispatchQueue.global(qos: .utility).async {
            if VideoCodec.support[.hevc]?.hardware == true, hevcOffer == .automatic { _ = VideoCodec.performance }
        }
    }

    private static let enabledKey = "\(AppIdentity.shortID).moonlight.enabled"
    private static let uniqueIDKey = "\(AppIdentity.shortID).moonlight.uniqueID"
    private static let allowsPairingKey = "\(AppIdentity.shortID).moonlight.allowsPairing"
    private static let isAdvertisedKey = "\(AppIdentity.shortID).moonlight.advertised"

    /// Whether the user turned hosting on; it starts with the app then.
    static var isEnabled: Bool {
        get { UserDefaults.dam.bool(forKey: enabledKey) }
        set { UserDefaults.dam.set(newValue, forKey: enabledKey) }
    }

    /// Whether an external Sunshine streams instead, with DAM's own host off so it can have
    /// the ports; DAM then makes and places displays for Sunshine's streams (RemoteSessions.swift).
    static var usesExternalSunshine: Bool {
        get { UserDefaults.dam.bool(forKey: externalSunshineKey) }
        set { UserDefaults.dam.set(newValue, forKey: externalSunshineKey) }
    }
    private static let externalSunshineKey = "\(AppIdentity.shortID).moonlight.externalSunshine"

    /// Whether a device not yet paired may ask to pair; when not, only paired devices connect.
    static var allowsPairing: Bool {
        get { UserDefaults.dam.object(forKey: allowsPairingKey) as? Bool ?? true }
        set { UserDefaults.dam.set(newValue, forKey: allowsPairingKey) }
    }

    /// Whether Moonlight finds the host by itself over Bonjour; when not, it is added by address.
    static var isAdvertised: Bool {
        get { UserDefaults.dam.object(forKey: isAdvertisedKey) as? Bool ?? true }
        set { UserDefaults.dam.set(newValue, forKey: isAdvertisedKey) }
    }

    /// Whether Moonlight also lists the Mac's own displays, not only DAM's streaming ones:
    /// the only ones that can show HDR, as macOS's virtual displays can't. Off unless turned
    /// on, as it lets every paired device watch and use the Mac's own screens.
    static var listsOwnDisplays: Bool {
        get { UserDefaults.dam.bool(forKey: listsOwnDisplaysKey) }
        set { UserDefaults.dam.set(newValue, forKey: listsOwnDisplaysKey) }
    }
    private static let listsOwnDisplaysKey = "\(AppIdentity.shortID).moonlight.ownDisplays"

    /// The app ID of one of the Mac's own displays, by its unit number, which stays with the
    /// display while the Mac's set of displays does; past streaming displays' and New Display's.
    static func ownDisplayAppID(_ id: CGDirectDisplayID) -> Int { 1000 + Int(CGDisplayUnitNumber(id)) }

    private(set) var isRunning = false
    /// Whether both servers are accepting connections.
    var isListening: Bool { !listeners.isEmpty && readyListeners.count == listeners.count }
    /// Why hosting stopped, when it did on its own.
    private(set) var lastError: String?
    private(set) var clients: [MoonlightClient] = []
    /// The streaming displays Moonlight lists, besides New Display.
    var apps: [MoonlightApp] = []
    /// The app that makes a display for the stream: New Display.
    static let newDisplayAppID = 100
    /// The most devices streaming at once, as many as there may be streaming displays.
    /// Each has an encoder of its own; on an Intel Mac a fourth slows the others' slowest frames.
    static let maxSessions = 4

    /// Makes a streaming display for a stream of the size and rate given, and calls back with
    /// its ID once placed, or nil if none could be made.
    var makeDisplay: ((_ width: Int, _ height: Int, _ fps: Int, _ done: @escaping (CGDirectDisplayID?) -> Void) -> Void)?
    /// Removes a streaming display made for a stream.
    var removeDisplay: ((CGDirectDisplayID) -> Void)?
    /// Changes a streaming display made for a stream to the size and rate given, in place, and
    /// calls back with whether it could.
    var resizeDisplay: ((_ id: CGDirectDisplayID, _ width: Int, _ height: Int, _ fps: Int,
                         _ done: @escaping (Bool) -> Void) -> Void)?

    /// Asks the user for the PIN Moonlight shows on the device at `address`. The answer is
    /// nil when they decline. Called on the main queue.
    var requestPIN: ((_ address: String, _ answer: @escaping (String?) -> Void) -> Void)?
    /// The device asking to pair gave up before the PIN was typed.
    var pairingAbandoned: (() -> Void)?
    /// Something the menu shows changed.
    var onChange: (() -> Void)?

    let httpPort: NWEndpoint.Port
    let httpsPort: NWEndpoint.Port
    let rtspPort: NWEndpoint.Port
    /// Where the host's key and certificate and the paired devices are kept.
    let directory: URL
    /// Whether it advertises itself over Bonjour.
    let advertises: Bool
    /// How many connections may be open, and how long each may take to ask, across all ports.
    private let limits: MoonlightConnectionLimits

    /// GameStream's ports by default, which Moonlight tries first.
    init(httpPort: NWEndpoint.Port = 47989, httpsPort: NWEndpoint.Port = 47984, rtspPort: NWEndpoint.Port = 48010,
         directory: URL = MoonlightHost.defaultDirectory, advertises: Bool = true,
         limits: MoonlightConnectionLimits = MoonlightConnectionLimits()) {
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.rtspPort = rtspPort
        self.directory = directory
        self.advertises = advertises
        self.limits = limits
        http = MoonlightHTTPConnections(limits: limits)
        rtsps = (0..<Self.maxSessions).map { _ in MoonlightRTSP(limits: limits) }
        http.onRequest = { [weak self] head, connection, secure in self?.answer(head, on: connection, secure: secure) }
        http.onClose = { [weak self] connection in
            if let self, self.waitingForPIN === connection { self.abandonPairing() }
        }
    }

    private var identity: (key: SecKey, certificate: Data, secIdentity: SecIdentity)?
    private var listeners: [NWListener] = []
    /// The listener Bonjour advertises, while running.
    private var httpListener: NWListener?
    private var readyListeners: Set<ObjectIdentifier> = []
    /// Listeners of a stop still closing; the ports are theirs until they have.
    private var closingListeners = 0
    /// Whether to start once they have.
    private var startWhenClosed = false
    /// The HTTP and HTTPS connections being served.
    private let http: MoonlightHTTPConnections
    private var pairing: MoonlightPairing?
    private var pairingAddress = ""
    /// The first pairing request, answered once the user has typed the PIN.
    private var waitingForPIN: NWConnection?
    /// One handshake server per session, each on a port of its own: RTSP carries no token
    /// before SETUP to tell sessions apart by.
    private let rtsps: [MoonlightRTSP]

    /// One device's launch, from /launch or /resume until /cancel, and its stream.
    private final class Session {
        let certificate: Data
        var launch: MoonlightLaunch
        var stream: MoonlightStream?

        init(certificate: Data, launch: MoonlightLaunch) {
            self.certificate = certificate
            self.launch = launch
        }

        /// Stops its stream, if one is running.
        func endStream() {
            stream?.stop()
            stream = nil
        }
    }

    private var sessions: [Session] = []
    /// What the devices launched, oldest first; serverinfo shows each its own as running.
    var launches: [MoonlightLaunch] { sessions.map(\.launch) }
    /// Why the last stream ended, when it ended on its own.
    private(set) var lastStreamEnd: String?

    /// The paired devices with a launch, oldest first.
    var streamingClients: [MoonlightClient] {
        sessions.compactMap { client(for: $0.certificate) }
    }

    /// The RTSP port of session `slot`.
    func rtspPort(slot: Int) -> NWEndpoint.Port { NWEndpoint.Port(rawValue: rtspPort.rawValue + UInt16(slot))! }

    private func session(for certificate: Data?) -> Session? {
        sessions.first { $0.certificate == certificate }
    }

    /// The paired device with `certificate`, if there is one.
    private func client(for certificate: Data?) -> MoonlightClient? {
        clientIndex(for: certificate).map { clients[$0] }
    }

    private func clientIndex(for certificate: Data?) -> Int? {
        clients.firstIndex { $0.certificate == certificate }
    }

    // MARK: - Starting and stopping

    /// Starts the servers and advertises the host. Runs on the main queue.
    func start() {
        guard !isRunning else { return }
        guard closingListeners == 0 else { startWhenClosed = true; return }
        do {
            let identity = try loadIdentity()
            self.identity = identity
            clients = loadClients()
            Self.measureEncoders()
            let http = NWParameters.tcp
            http.allowLocalEndpointReuse = true
            // Each frame goes out the moment it is ready, not held for an acknowledgement.
            (http.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            let httpListener = try NWListener(using: http, on: httpPort)
            httpListener.service = service
            self.httpListener = httpListener
            let httpsListener = try NWListener(using: tlsParameters(identity: identity.secIdentity), on: httpsPort)
            let rtspListeners = try (0..<Self.maxSessions).map { try NWListener(using: http, on: rtspPort(slot: $0)) }
            listeners = [httpListener, httpsListener] + rtspListeners
            for (slot, rtsp) in rtsps.enumerated() {
                rtsp.launch = { [weak self] in self?.sessions.first { $0.launch.slot == slot }?.launch }
                rtsp.announce = { [weak self] launch, config in
                    guard let self else { return "Stopped" }
                    return self.startStream(launch, config)
                }
                rtspListeners[slot].newConnectionHandler = { [weak rtsp] in rtsp?.accept($0) }
            }
            for listener in listeners {
                let secure = listener === httpsListener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener else { return }
                    switch state {
                    case .ready:
                        self.readyListeners.insert(ObjectIdentifier(listener))
                    case .failed(let error):
                        mlLog.error("listener failed: \(String(describing: error), privacy: .public)")
                        self.stop(error: Self.describe(error))
                    default:
                        break
                    }
                }
                if listener === httpListener || listener === httpsListener {
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.http.accept(connection, secure: secure)
                    }
                }
                listener.start(queue: .main)
            }
            isRunning = true
            lastError = nil
            mlLog.debug("hosting as \(Self.hostName, privacy: .public)")
        } catch {
            mlLog.error("start: \(String(describing: error), privacy: .public)")
            stop(error: Spoken.moonlightCouldNotStart(error.localizedDescription))
            return
        }
        onChange?()
    }

    func stop() { stop(error: nil) }

    private func stop(error: String?) {
        startWhenClosed = false
        for listener in listeners {
            closingListeners += 1
            listener.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state, let self else { return }
                self.closingListeners -= 1
                if self.closingListeners == 0, self.startWhenClosed {
                    self.startWhenClosed = false
                    self.start()
                }
            }
            listener.cancel()
        }
        listeners = []
        httpListener = nil
        readyListeners = []
        http.closeAll()
        rtsps.forEach { $0.closeAll() }
        for session in sessions { endLaunch(of: session.certificate) }
        if let waiting = waitingForPIN {
            waitingForPIN = nil
            waiting.cancel()
            pairingAbandoned?()
        }
        pairing = nil
        isRunning = false
        lastError = error
        onChange?()
    }

    /// What Bonjour advertises: the host, unless it is not to be.
    private var service: NWListener.Service? {
        advertises && Self.isAdvertised ? NWListener.Service(name: Self.hostName, type: Self.serviceType) : nil
    }

    /// Advertises the host, or stops, as `isAdvertised` now says; streams carry on.
    func updateAdvertising() {
        httpListener?.service = service
    }

    /// Unpairs `client`: it has to pair again to connect.
    func forget(_ client: MoonlightClient) {
        endLaunch(of: client.certificate)
        clients.removeAll { $0.certificate == client.certificate }
        saveClients()
        onChange?()
    }

    /// Sets whether `client`'s streams use low-latency rate control, from its next stream on.
    func setLowLatency(_ lowLatency: Bool, for client: MoonlightClient) {
        guard let index = clientIndex(for: client.certificate) else { return }
        clients[index].lowLatency = lowLatency
        saveClients()
        onChange?()
    }

    /// Sets whether `client`'s mouse, keyboard and text reach the Mac, its stream's at once.
    func setAllowsInput(_ allowsInput: Bool, for client: MoonlightClient) {
        guard let index = clientIndex(for: client.certificate) else { return }
        clients[index].allowsInput = allowsInput
        session(for: client.certificate)?.stream?.allowsInput = allowsInput
        saveClients()
        onChange?()
    }

    private static var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error { return Spoken.moonlightPortsInUse }
        return Spoken.moonlightStopped(error.localizedDescription)
    }

    // MARK: - Connections

    private struct Request {
        let path: String
        let query: [String: String]
    }

    /// Answers a request's head.
    private func answer(_ head: String, on connection: NWConnection, secure: Bool) {
        guard let parsed = MoonlightHTTPConnections.parse(head) else { return send(status: "400 Bad Request", to: connection) }
        let certificate = secure ? Self.peerCertificate(of: connection) : nil
        handle(Request(path: parsed.path, query: parsed.query), on: connection, secure: secure, certificate: certificate)
    }

    private static func peerCertificate(of connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        var leaf: Data?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leaf == nil { leaf = SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data }
        }
        return leaf
    }

    /// The IP address of `endpoint`, IPv4 written as IPv6 as plain IPv4, without a zone.
    static func address(_ endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:") { text.removeFirst("::ffff:".count) }
        return text
    }

    // MARK: - Requests

    private func handle(_ request: Request, on connection: NWConnection, secure: Bool, certificate: Data?) {
        mlLog.debug("\(secure ? "https" : "http", privacy: .public) \(request.path, privacy: .public)")
        // Over HTTPS, only paired devices. Moonlight takes a 401 to mean unpaired and asks
        // again over HTTP.
        if secure && client(for: certificate) == nil {
            return reply(Self.xml(status: 401, message: "The client is not authorized. Certificate verification failed."),
                         to: connection)
        }
        switch request.path {
        case "/serverinfo":
            reply(serverInfo(paired: secure, launch: secure ? session(for: certificate)?.launch : nil,
                             codecs: Self.codecs(lowLatency: client(for: certificate)?.lowLatency ?? true),
                             hdr: Self.offersHDR(),
                             localAddress: Self.address(connection.currentPath?.localEndpoint)),
                  to: connection)
        case "/pair" where secure:
            // The last step: the device reached the HTTPS server with the paired certificate.
            reply(Self.xml(["paired": "1"]), to: connection)
        case "/pair":
            handlePair(request.query, on: connection)
        case "/unpair" where !secure:
            // Moonlight sends this when pairing fails on its side, a wrong PIN among others.
            pairing = nil
            reply(Self.xml([:]), to: connection)
        case "/applist" where secure:
            reply(appList(), to: connection)
        case "/launch" where secure, "/resume" where secure:
            launchApp(request, resume: request.path == "/resume", certificate: certificate, on: connection)
        case "/cancel" where secure:
            // Free before answering: Moonlight asks for serverinfo next and expects it so.
            if let certificate { endLaunch(of: certificate) }
            onChange?()
            reply(Self.xml(["cancel": "1"]), to: connection)
        default:
            send(status: "404 Not Found", to: connection)
        }
    }

    private func handlePair(_ query: [String: String], on connection: NWConnection) {
        do {
            if query["phrase"] == "getservercert" {
                try beginPairing(query, on: connection)
            } else if let challenge = query["clientchallenge"].flatMap(MoonlightCrypto.data(hex:)) {
                let response = try currentPairing().respond(toClientChallenge: challenge)
                reply(Self.xml(["paired": "1", "challengeresponse": MoonlightCrypto.hex(response)]), to: connection)
            } else if let response = query["serverchallengeresp"].flatMap(MoonlightCrypto.data(hex:)) {
                let secret = try currentPairing().pairingSecret(forServerChallengeResponse: response)
                reply(Self.xml(["paired": "1", "pairingsecret": MoonlightCrypto.hex(secret)]), to: connection)
            } else if let secret = query["clientpairingsecret"].flatMap(MoonlightCrypto.data(hex:)) {
                let session = try currentPairing()
                pairing = nil
                let verified = try session.verify(clientPairingSecret: secret)
                if verified { addClient(session.clientCertificate) }
                mlLog.debug("pairing with \(self.pairingAddress, privacy: .public): \(verified ? "paired" : "refused", privacy: .public)")
                reply(Self.xml(["paired": verified ? "1" : "0"]), to: connection)
            } else {
                throw MoonlightPairing.Failure.badParameter
            }
        } catch {
            mlLog.error("pair: \(String(describing: error), privacy: .public)")
            pairing = nil
            reply(Self.xml(status: 400, message: "Pairing failed", fields: ["paired": "0"]), to: connection)
        }
    }

    // MARK: - Streaming

    /// Starts (or, on resume, restarts) the app Moonlight picked; the stream follows the RTSP
    /// handshake Moonlight performs next, at the address it reached this host on and the
    /// RTSP port of the device's session.
    ///
    /// A streaming display the user made streams as it is. New Display, or a display that is
    /// gone (Moonlight keeps listing apps from before), gets a display made at the stream's
    /// size, which /cancel removes; a resume keeps streaming the display it had, changed in
    /// place to the size asked for now, which Moonlight's settings may have changed. Each
    /// device's launch is its own: another device's goes on streaming.
    private func launchApp(_ request: Request, resume: Bool, certificate: Data?, on connection: NWConnection) {
        guard let certificate else { return reply(Self.xml(status: 401, message: "No certificate"), to: connection) }
        guard let key = request.query["rikey"].flatMap(MoonlightCrypto.data(hex:)), key.count == 16 else {
            return reply(Self.xml(status: 400, message: "Missing key"), to: connection)
        }
        guard session(for: certificate) != nil || sessions.count < Self.maxSessions else {
            mlLog.debug("launch refused: \(Self.maxSessions) devices streaming")
            return reply(Self.xml(status: 503, message: "\(AppIdentity.name) is already streaming to \(Self.maxSessions) devices."),
                         to: connection)
        }
        // Signed, as Moonlight prints it; the bits are what count.
        let keyID = UInt32(bitPattern: request.query["rikeyid"].flatMap { Int32($0) } ?? 0)
        let current = session(for: certificate)?.launch
        let appID = request.query["appid"].flatMap(Int.init) ?? current?.appID ?? Self.newDisplayAppID
        let address = Self.address(connection.currentPath?.localEndpoint)
        let peer = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        let lowLatency = client(for: certificate)?.lowLatency ?? true
        // Moonlight asks for HDR with its own setting on and a decoder for it.
        let hdr = request.query["hdrMode"] == "1" && Self.offersHDR()
        let encryption = MoonlightStream.videoEncryption
        let answer = { [weak self] (launch: MoonlightLaunch) in
            guard let self else { return }
            // Hosting stopped, or the device was unpaired, while a display was made for it.
            guard self.isRunning, self.client(for: certificate) != nil else {
                if launch.ownsDisplay, !self.sessions.contains(where: { $0.launch.displayID == launch.displayID }) {
                    self.removeDisplay?(launch.displayID)
                }
                return self.reply(Self.xml(status: 503, message: "\(AppIdentity.name) is not hosting."), to: connection)
            }
            var launch = launch
            launch.lowLatency = lowLatency
            launch.codecs = Self.codecs(lowLatency: lowLatency)
            if hdr && !launch.codecs.contains(.hevc) { launch.codecs.append(.hevc) }
            launch.offersHDR = hdr
            launch.offersEncryptedVideo = encryption.offers(to: peer)
            launch.requiresEncryptedVideo = encryption == .always
            launch.clientAddress = Self.address(peer)
            if let session = self.session(for: certificate) {
                session.endStream()
                // Another launch of the device's, answered first, may have made a display.
                if session.launch.displayID != launch.displayID { self.letGo(of: session.launch, by: session) }
                launch.slot = session.launch.slot
                session.launch = launch
            } else {
                // Another device may have taken the last session while a display was made.
                let taken = Set(self.sessions.map(\.launch.slot))
                guard let slot = (0..<Self.maxSessions).first(where: { !taken.contains($0) }) else {
                    if launch.ownsDisplay { self.removeDisplay?(launch.displayID) }
                    return self.reply(Self.xml(status: 503, message: "\(AppIdentity.name) is already streaming to \(Self.maxSessions) devices."),
                                      to: connection)
                }
                launch.slot = slot
                self.sessions.append(Session(certificate: certificate, launch: launch))
            }
            self.lastStreamEnd = nil
            self.onChange?()
            self.reply(Self.xml(["sessionUrl0": "rtsp://\(address):\(self.rtspPort(slot: launch.slot).rawValue)",
                                 resume ? "resume" : "gamesession": "1"]), to: connection)
        }
        let mode = (request.query["mode"] ?? "").split(separator: "x").compactMap { Int($0) }
        let sizes = MoonlightStreamConfig.sizes
        let size = mode.count == 3 && sizes.contains(mode[0]) && sizes.contains(mode[1])
            ? (mode[0], mode[1], min(max(mode[2], 30), MoonlightStreamConfig.rates.upperBound)) : nil
        let makeNew = { [weak self] in
            guard let self else { return }
            self.endLaunch(of: certificate)
            if appID != Self.newDisplayAppID, let app = self.apps.first(where: { $0.id == appID }) {
                mlLog.debug("launch \(app.title, privacy: .public)")
                return answer(MoonlightLaunch(appID: appID, displayID: app.displayID, key: key, keyID: keyID))
            }
            guard let (width, height, fps) = size, let makeDisplay = self.makeDisplay else {
                return self.reply(Self.xml(status: 400, message: "Missing the stream's size"), to: connection)
            }
            mlLog.debug("launch: making a \(width)×\(height)@\(fps) display")
            makeDisplay(width, height, fps) { [weak self] id in
                guard let self else { return }
                guard let id else {
                    return self.reply(Self.xml(status: 503, message: "\(AppIdentity.name) could not make a display."),
                                      to: connection)
                }
                answer(MoonlightLaunch(appID: appID, displayID: id, key: key, keyID: keyID, ownsDisplay: true))
            }
        }
        let listed = appID == Self.newDisplayAppID ? nil : apps.first(where: { $0.id == appID })?.displayID
        guard let current, current.appID == appID || current.displayID == listed,
              DisplayArrangement.onlineDisplayIDs().contains(current.displayID) else { return makeNew() }
        mlLog.debug("\(resume ? "resume" : "launch", privacy: .public) on display \(current.displayID)")
        let reuse = { [weak self] in
            guard let self else { return }
            // Ended while the display changed size, and the display with it.
            guard let session = self.session(for: certificate) else {
                return self.reply(Self.xml(status: 503, message: "The stream ended."), to: connection)
            }
            // Owned by now, should another device's launch have handed it on.
            answer(MoonlightLaunch(appID: appID, displayID: current.displayID, key: key, keyID: keyID,
                                   ownsDisplay: session.launch.ownsDisplay))
        }
        // A display another device is streaming keeps its size.
        let shared = sessions.contains { $0.certificate != certificate && $0.launch.displayID == current.displayID }
        guard current.ownsDisplay, !shared, let (width, height, fps) = size, let resizeDisplay else { return reuse() }
        // Not captured while it changes size.
        endStream(of: certificate)
        resizeDisplay(current.displayID, width, height, fps) { resized in
            if resized { return reuse() }
            mlLog.debug("could not resize display \(current.displayID); making another")
            makeNew()
        }
    }

    /// Ends a device's launch: its stream, and the display made for it, unless another
    /// device streams that display too, which then has it.
    func endLaunch(of certificate: Data) {
        guard let index = sessions.firstIndex(where: { $0.certificate == certificate }) else { return }
        let session = sessions.remove(at: index)
        session.endStream()
        letGo(of: session.launch, by: session)
    }

    /// Lets go of the display `launch` was made for, as `session` no longer streams it:
    /// another device streaming it has it next, or it is removed.
    private func letGo(of launch: MoonlightLaunch, by session: Session) {
        guard launch.ownsDisplay else { return }
        if let heir = sessions.first(where: { $0 !== session && $0.launch.displayID == launch.displayID }) {
            heir.launch.ownsDisplay = true
        } else {
            removeDisplay?(launch.displayID)
        }
    }

    /// Starts the stream ANNOUNCE asked for, in the launch's session; returns why it could
    /// not, or nil.
    private func startStream(_ launch: MoonlightLaunch, _ config: MoonlightStreamConfig) -> String? {
        guard let session = sessions.first(where: { $0.launch.sessionID == launch.sessionID }) else { return "No launch" }
        guard !session.launch.announced else { return "Already started" }
        session.endStream()
        var config = config
        config.lowLatency = launch.lowLatency
        do {
            let stream = try MoonlightStream(config: config, displayID: launch.displayID, key: launch.key,
                                             keyID: launch.keyID, pingPayload: launch.pingPayload,
                                             connectData: launch.connectData, clientAddress: launch.clientAddress,
                                             ports: launch.ports,
                                             allowsInput: client(for: session.certificate)?.allowsInput ?? true)
            stream.onEnd = { [weak self, weak session, weak stream] reason in
                guard let self, let session, let stream, session.stream === stream else { return }
                session.stream = nil
                self.lastStreamEnd = reason
                self.onChange?()
            }
            session.stream = stream
            session.launch.announced = true
            stream.start()
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func endStream(of certificate: Data) {
        session(for: certificate)?.endStream()
    }

    private func currentPairing() throws -> MoonlightPairing {
        guard let pairing, waitingForPIN == nil else { throw MoonlightPairing.Failure.outOfOrder }
        return pairing
    }

    /// Starts pairing and asks the user for the PIN; the request is answered once they have.
    private func beginPairing(_ query: [String: String], on connection: NWConnection) throws {
        guard let identity else { throw MoonlightPairing.Failure.outOfOrder }
        guard waitingForPIN == nil else {
            return reply(Self.xml(status: 409, message: "Already pairing", fields: ["paired": "0"]), to: connection)
        }
        guard Self.allowsPairing else {
            mlLog.debug("pairing refused: new devices may not pair")
            return reply(Self.xml(status: 403, message: "\(AppIdentity.name) is not accepting new devices",
                                  fields: ["paired": "0"]), to: connection)
        }
        guard let salt = query["salt"].flatMap({ MoonlightCrypto.data(hex: String($0.prefix(32))) }),
              let pem = query["clientcert"].flatMap(MoonlightCrypto.data(hex:)) else {
            throw MoonlightPairing.Failure.badParameter
        }
        let session = try MoonlightPairing(clientCertificatePEM: String(decoding: pem, as: UTF8.self), salt: salt,
                                           serverCertificate: identity.certificate, serverKey: identity.key)
        let address = Self.address(connection.endpoint)
        pairing = session
        pairingAddress = address
        waitingForPIN = connection
        watchForHangUp(connection)
        mlLog.debug("pairing requested from \(address, privacy: .public)")
        requestPIN?(address) { [weak self] pin in
            guard let self, self.waitingForPIN === connection else { return }
            self.waitingForPIN = nil
            let digits = pin?.trimmingCharacters(in: .whitespaces) ?? ""
            guard digits.count == 4, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else {
                self.pairing = nil
                return self.reply(Self.xml(["paired": "0"]), to: connection)
            }
            session.enterPIN(digits)
            self.reply(Self.xml(["paired": "1",
                                 "plaincert": MoonlightCrypto.hex(Data(MoonlightCrypto.pem(certificate: identity.certificate).utf8))]),
                       to: connection)
        }
    }

    /// Notices the device closing the connection while the PIN is being typed, as when the
    /// user cancels pairing in Moonlight.
    private func watchForHangUp(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self, self.waitingForPIN === connection else { return }
            if isComplete || error != nil {
                self.abandonPairing()
            } else {
                self.watchForHangUp(connection)
            }
        }
    }

    private func abandonPairing() {
        mlLog.debug("pairing abandoned by \(self.pairingAddress, privacy: .public)")
        waitingForPIN?.cancel()
        waitingForPIN = nil
        pairing = nil
        pairingAbandoned?()
    }

    private func addClient(_ certificate: Data) {
        clients.removeAll { $0.certificate == certificate }
        clients.append(MoonlightClient(name: pairingAddress.isEmpty ? "Moonlight" : pairingAddress,
                                       certificate: certificate, paired: Date()))
        saveClients()
        onChange?()
    }

    // MARK: - Responses

    /// The host as `launch`'s device sees it: busy with its own launch, if it has one, and
    /// free otherwise, whatever other devices stream.
    /// Moonlight takes HEVC from `codecs` only with a MaxLumaPixelsHEVC, which is Sunshine's.
    private func serverInfo(paired: Bool, launch: MoonlightLaunch?, codecs: [VideoCodec], hdr: Bool,
                            localAddress: String) -> String {
        let modes = Self.codecModes(codecs, hdr: hdr)
        return Self.xml([
            "hostname": Self.hostName,
            "appversion": Self.appVersion,
            "GfeVersion": Self.gfeVersion,
            "uniqueid": Self.uniqueID,
            "HttpsPort": "\(httpsPort.rawValue)",
            "ExternalPort": "\(httpPort.rawValue)",
            "MaxLumaPixelsHEVC": modes & VideoCodec.hevc.moonlightCodecMode != 0 ? "1869449984" : "0",
            "mac": "00:00:00:00:00:00",
            "LocalIP": localAddress,
            "ServerCodecModeSupport": "\(modes)",
            "PairStatus": paired ? "1" : "0",
            "currentgame": "\(launch?.appID ?? 0)",
            "state": launch == nil ? "SUNSHINE_SERVER_FREE" : "SUNSHINE_SERVER_BUSY",
        ])
    }

    private func appList() -> String {
        let hdr = Self.offersHDR()
        let listed = self.apps + [MoonlightApp(id: Self.newDisplayAppID, title: "New Display", displayID: 0)]
        let apps = listed.map {
            "<App><IsHdrSupported>\(hdr ? 1 : 0)</IsHdrSupported><AppTitle>\(Self.escape($0.title))</AppTitle><ID>\($0.id)</ID></App>"
        }
        return Self.document("<root status_code=\"200\">\(apps.joined())</root>")
    }

    /// A response document: `fields` as elements of `root`, in the order given.
    static func xml(_ fields: KeyValuePairs<String, String>) -> String {
        xml(status: 200, message: nil, fields: fields)
    }

    static func xml(status: Int, message: String?, fields: KeyValuePairs<String, String> = [:]) -> String {
        let attributes = "status_code=\"\(status)\"" + (message.map { " status_message=\"\(escape($0))\"" } ?? "")
        let body = fields.map { "<\($0.key)>\(escape($0.value))</\($0.key)>" }.joined()
        return document("<root \(attributes)>\(body)</root>")
    }

    private static func document(_ root: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\(root)\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Answers with HTTP 200; Moonlight reads the outcome from the document's status_code.
    private func reply(_ body: String, to connection: NWConnection) {
        send(status: "200 OK", contentType: "application/xml", body: Data(body.utf8), to: connection)
    }

    private func send(status: String, contentType: String = "text/plain", body: Data = Data(),
                      to connection: NWConnection) {
        MoonlightHTTPConnections.send(status: status, contentType: contentType, body: body, to: connection)
    }

    // MARK: - Identity and storage

    /// The host's ID, which Moonlight keeps it by.
    private static var uniqueID: String {
        if let id = UserDefaults.dam.string(forKey: uniqueIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.dam.set(id, forKey: uniqueIDKey)
        return id
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("Moonlight", isDirectory: true)
    }

    private var keyURL: URL { directory.appendingPathComponent("host-key.der") }
    private var certificateURL: URL { directory.appendingPathComponent("host-certificate.der") }
    private var clientsURL: URL { directory.appendingPathComponent("paired-clients.json") }

    /// The host's key and certificate, made on first use and kept, as Moonlight pins the
    /// certificate it paired with. A new one unpairs every device.
    private func loadIdentity() throws -> (key: SecKey, certificate: Data, secIdentity: SecIdentity) {
        let key: SecKey
        let certificate: Data
        if let keyData = try? Data(contentsOf: keyURL),
           let stored = try? Data(contentsOf: certificateURL),
           let imported = try? MoonlightCrypto.importPrivateKey(keyData),
           SecCertificateCreateWithData(nil, stored as CFData) != nil {
            key = imported
            certificate = stored
            // Kept even so, as a new one unpairs every device.
            if !DER.hasMinimalSerial(stored) {
                mlLog.error("the host certificate's serial is not minimal DER; some Moonlight clients may refuse it")
            }
        } else {
            mlLog.debug("making the host's key and certificate")
            key = try MoonlightCrypto.generatePrivateKey()
            // Self-signed, for 20 years.
            certificate = try MoonlightCrypto.certificate(key: key, subject: "\(AppIdentity.name) GameStream Host",
                                                          days: 20 * 365)
            try writePrivately(try MoonlightCrypto.exportPrivateKey(key), to: keyURL)
            try writePrivately(certificate, to: certificateURL)
            try? FileManager.default.removeItem(at: clientsURL)
        }
        guard let secCertificate = SecCertificateCreateWithData(nil, certificate as CFData),
              let identity = Self.makeIdentity(secCertificate, key) else {
            throw MoonlightCryptoError.badCertificate
        }
        return (key, certificate, identity)
    }

    /// A TLS identity from a certificate and key held in memory, rather than in a keychain,
    /// through Security's SecIdentityCreate.
    static func makeIdentity(_ certificate: SecCertificate, _ key: SecKey) -> SecIdentity? {
        typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "SecIdentityCreate") else { return nil }
        return unsafeBitCast(symbol, to: Create.self)(nil, certificate, key)?.takeRetainedValue()
    }

    private func tlsParameters(identity: SecIdentity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let local = sec_identity_create(identity) { sec_protocol_options_set_local_identity(options, local) }
        // Every device must show its certificate; whether it is paired is checked per request.
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) }, .main)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func loadClients() -> [MoonlightClient] {
        guard let data = try? Data(contentsOf: clientsURL) else { return [] }
        return (try? JSONDecoder().decode([MoonlightClient].self, from: data)) ?? []
    }

    private func saveClients() {
        do {
            try writePrivately(try JSONEncoder().encode(clients), to: clientsURL)
        } catch {
            mlLog.error("saving paired devices: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes `data` readable by the user alone, as it holds the host's key or who may connect.
    private func writePrivately(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The HTTP both of DAM's web servers speak, the host's and the browser stream's: each
/// connection admitted under `limits`, its request's head read and handed on, and answered
/// once with `send`, which closes it. Used on the main queue.
final class MoonlightHTTPConnections {
    /// Called with a request's head, up to the blank line that ends it, and the connection
    /// to answer on.
    var onRequest: ((_ head: String, _ connection: NWConnection, _ secure: Bool) -> Void)?
    /// Called once a connection has closed, answered or not.
    var onClose: ((NWConnection) -> Void)?

    let limits: MoonlightConnectionLimits
    /// Connections open, held until they close.
    private var open: [ObjectIdentifier: NWConnection] = [:]

    init(limits: MoonlightConnectionLimits) {
        self.limits = limits
    }

    func accept(_ connection: NWConnection, secure: Bool) {
        guard limits.admit(connection) else { return }
        open[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receive(on: connection, secure: secure, buffer: Data())
            case .failed:
                connection.cancel()
            case .cancelled:
                self.open[ObjectIdentifier(connection)] = nil
                self.limits.closed(connection)
                self.onClose?(connection)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// Closes every connection still open, answered or not.
    func closeAll() {
        open.values.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection, secure: Bool, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.limits.received(connection)
                self.onRequest?(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), connection, secure)
                return
            }
            guard !isComplete, error == nil, buffer.count < 16384 else { return connection.cancel() }
            self.receive(on: connection, secure: secure, buffer: buffer)
        }
    }

    /// A GET request's path, its query (the first value of each name) and its headers (by
    /// name in lower case); nil for anything else.
    static func parse(_ head: String) -> (path: String, query: [String: String], headers: [String: String])? {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: String(parts[1])) else { return nil }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (url.path, query, headers)
    }

    /// Answers `connection` and closes it once the answer is out; `headers` are whole lines
    /// without their ends, after the content's type and length.
    static func send(status: String, contentType: String, headers: [String] = [], body: Data,
                     to connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" +
                   headers.map { "\($0)\r\n" }.joined() +
                   "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Keeps the host's TCP connections few and short: at most `maxTotal` open at once and
/// `maxPerAddress` from one address, each closed unless its whole request has come within
/// `deadline`. Only the wait for the request is timed; answering may take longer, as while
/// the user types a PIN or a display is made. Used on the main queue.
final class MoonlightConnectionLimits {
    let maxTotal: Int
    let maxPerAddress: Int
    let deadline: TimeInterval
    /// Each open connection's address, and which of them have yet to ask.
    private var open: [ObjectIdentifier: String] = [:]
    private var waiting: Set<ObjectIdentifier> = []

    init(maxTotal: Int = 64, maxPerAddress: Int = 16, deadline: TimeInterval = 10) {
        self.maxTotal = maxTotal
        self.maxPerAddress = maxPerAddress
        self.deadline = deadline
    }

    /// Whether `connection` may be served; it is cancelled if not. One that may counts
    /// until `closed`.
    func admit(_ connection: NWConnection) -> Bool {
        let address = MoonlightHost.address(connection.endpoint)
        guard open.count < maxTotal, open.values.filter({ $0 == address }).count < maxPerAddress else {
            mlLog.error("connection from \(address, privacy: .public) refused: too many open")
            connection.cancel()
            return false
        }
        let id = ObjectIdentifier(connection)
        open[id] = address
        waiting.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self, weak connection] in
            guard let self, let connection, self.waiting.contains(ObjectIdentifier(connection)) else { return }
            mlLog.debug("connection from \(address, privacy: .public) closed: no request in time")
            connection.cancel()
        }
        return true
    }

    /// `connection`'s request has come.
    func received(_ connection: NWConnection) {
        waiting.remove(ObjectIdentifier(connection))
    }

    func closed(_ connection: NWConnection) {
        open[ObjectIdentifier(connection)] = nil
        waiting.remove(ObjectIdentifier(connection))
    }
}
