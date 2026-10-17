//
//  MoonlightHost.swift
//
//  Lets Moonlight find this Mac, pair with it and list what it can stream, speaking the
//  GameStream protocol Moonlight expects of a host (as Sunshine does): Bonjour as
//  _nvstream._tcp, an HTTP server for discovery and pairing, and an HTTPS server, open only
//  to paired devices' certificates, for everything after. Each streaming display is an app;
//  launching one leads to the RTSP handshake (MoonlightRTSP) and the stream (MoonlightStream).
//  The HTTP server also serves the displays to browsers and players (WebStream).
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

    init(name: String, certificate: Data, paired: Date, lowLatency: Bool = true) {
        self.name = name
        self.certificate = certificate
        self.paired = paired
        self.lowLatency = lowLatency
    }

    // Saved under a key of its own since low-latency became the default, so that devices
    // saved with the old default (off) get it too; devices saved before either have none.
    private enum CodingKeys: String, CodingKey {
        case name, certificate, paired
        case lowLatency = "lowLatencyEncoding"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        certificate = try container.decode(Data.self, forKey: .certificate)
        paired = try container.decode(Date.self, forKey: .paired)
        lowLatency = try container.decodeIfPresent(Bool.self, forKey: .lowLatency) ?? true
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
    /// The codecs streams can use, as Moonlight's SCM_* bits: H.264 for now.
    static let codecModeSupport = 0x0001

    private static let enabledKey = "\(AppIdentity.shortID).moonlight.enabled"
    private static let uniqueIDKey = "\(AppIdentity.shortID).moonlight.uniqueID"

    /// Whether the user turned hosting on; it starts with the app then.
    static var isEnabled: Bool {
        get { UserDefaults.dam.bool(forKey: enabledKey) }
        set { UserDefaults.dam.set(newValue, forKey: enabledKey) }
    }

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
    /// Streams for browsers and players, on the HTTP port.
    let webStream = WebStreamServer()

    let httpPort: NWEndpoint.Port
    let httpsPort: NWEndpoint.Port
    let rtspPort: NWEndpoint.Port
    /// Where the host's key and certificate and the paired devices are kept.
    let directory: URL
    /// Whether it advertises itself over Bonjour.
    let advertises: Bool

    /// GameStream's ports by default, which Moonlight tries first.
    init(httpPort: NWEndpoint.Port = 47989, httpsPort: NWEndpoint.Port = 47984, rtspPort: NWEndpoint.Port = 48010,
         directory: URL = MoonlightHost.defaultDirectory, advertises: Bool = true) {
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.rtspPort = rtspPort
        self.directory = directory
        self.advertises = advertises
    }

    private var identity: (key: SecKey, certificate: Data, secIdentity: SecIdentity)?
    private var listeners: [NWListener] = []
    private var readyListeners: Set<ObjectIdentifier> = []
    /// Listeners of a stop still closing; the ports are theirs until they have.
    private var closingListeners = 0
    /// Whether to start once they have.
    private var startWhenClosed = false
    /// Connections being served, held until they end.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pairing: MoonlightPairing?
    private var pairingAddress = ""
    /// The first pairing request, answered once the user has typed the PIN.
    private var waitingForPIN: NWConnection?
    private let rtsp = MoonlightRTSP()
    /// The app Moonlight launched, until it cancels it; serverinfo shows the host busy.
    private(set) var launch: MoonlightLaunch?
    private var stream: MoonlightStream?
    /// Why the last stream ended, when it ended on its own.
    private(set) var lastStreamEnd: String?

    // MARK: - Starting and stopping

    /// Starts the servers and advertises the host. Runs on the main queue.
    func start() {
        guard !isRunning else { return }
        guard closingListeners == 0 else { startWhenClosed = true; return }
        do {
            let identity = try loadIdentity()
            self.identity = identity
            clients = loadClients()
            let http = NWParameters.tcp
            http.allowLocalEndpointReuse = true
            // Each frame goes out the moment it is ready, not held for an acknowledgement.
            (http.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
            let httpListener = try NWListener(using: http, on: httpPort)
            if advertises { httpListener.service = NWListener.Service(name: Self.hostName, type: Self.serviceType) }
            let httpsListener = try NWListener(using: tlsParameters(identity: identity.secIdentity), on: httpsPort)
            let rtspListener = try NWListener(using: http, on: rtspPort)
            listeners = [httpListener, httpsListener, rtspListener]
            webStream.apps = { [weak self] in self?.apps ?? [] }
            webStream.makeDisplay = { [weak self] width, height, fps, done in
                guard let self, let makeDisplay = self.makeDisplay else { return done(nil) }
                makeDisplay(width, height, fps, done)
            }
            webStream.removeDisplay = { [weak self] id in self?.removeDisplay?(id) }
            webStream.onChange = { [weak self] in self?.onChange?() }
            rtsp.launch = { [weak self] in self?.launch }
            rtsp.announce = { [weak self] launch, config in
                guard let self else { return "Stopped" }
                return self.startStream(launch, config)
            }
            rtspListener.newConnectionHandler = { [weak self] in self?.rtsp.accept($0) }
            for (listener, secure) in [(httpListener, false), (httpsListener, true), (rtspListener, false)] {
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
                if listener !== rtspListener {
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection, secure: secure)
                    }
                }
                listener.start(queue: .main)
            }
            isRunning = true
            lastError = nil
            mlLog.debug("hosting as \(Self.hostName, privacy: .public)")
        } catch {
            mlLog.error("start: \(String(describing: error), privacy: .public)")
            stop(error: "Could not start: \(error.localizedDescription)")
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
        readyListeners = []
        webStream.stopAll()
        connections.values.forEach { $0.cancel() }
        rtsp.closeAll()
        endLaunch()
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

    /// Unpairs `client`: it has to pair again to connect.
    func forget(_ client: MoonlightClient) {
        clients.removeAll { $0.certificate == client.certificate }
        saveClients()
        onChange?()
    }

    /// Sets whether `client`'s streams use low-latency rate control, from its next stream on.
    func setLowLatency(_ lowLatency: Bool, for client: MoonlightClient) {
        guard let index = clients.firstIndex(where: { $0.certificate == client.certificate }) else { return }
        clients[index].lowLatency = lowLatency
        saveClients()
        onChange?()
    }

    private static var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Where a browser on the network finds the player page.
    var watchURL: URL {
        URL(string: "http://\(ProcessInfo.processInfo.hostName):\(httpPort.rawValue)/watch")!
    }

    /// The player page on this Mac.
    var localWatchURL: URL {
        URL(string: "http://localhost:\(httpPort.rawValue)/watch")!
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error { return "Another app is using Moonlight's ports" }
        return "Stopped: \(error.localizedDescription)"
    }

    // MARK: - Connections

    private struct Request {
        let path: String
        let query: [String: String]
    }

    private func accept(_ connection: NWConnection, secure: Bool) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receive(on: connection, secure: secure, buffer: Data())
            case .failed:
                connection.cancel()
            case .cancelled:
                self.connections[ObjectIdentifier(connection)] = nil
                if self.waitingForPIN === connection { self.abandonPairing() }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection, secure: Bool, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                guard let request = Self.parse(head) else { return self.send(status: "400 Bad Request", to: connection) }
                let certificate = secure ? Self.peerCertificate(of: connection) : nil
                self.handle(request, on: connection, secure: secure, certificate: certificate)
                return
            }
            guard !isComplete, error == nil, buffer.count < 16384 else { return connection.cancel() }
            self.receive(on: connection, secure: secure, buffer: buffer)
        }
    }

    private static func parse(_ head: String) -> Request? {
        let parts = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: String(parts[1])) else { return nil }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        return Request(path: url.path, query: query)
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

    private static func address(_ endpoint: NWEndpoint?) -> String {
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
        if secure && !clients.contains(where: { $0.certificate == certificate }) {
            return reply(Self.xml(status: 401, message: "The client is not authorized. Certificate verification failed."),
                         to: connection)
        }
        if !secure, webStream.handle(path: request.path, query: request.query, on: connection) { return }
        switch request.path {
        case "/serverinfo":
            reply(serverInfo(paired: secure, localAddress: Self.address(connection.currentPath?.localEndpoint)),
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
            endLaunch()
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
    /// handshake Moonlight performs next, at the address it reached this host on.
    ///
    /// A streaming display the user made streams as it is. New Display, or a display that is
    /// gone (Moonlight keeps listing apps from before), gets a display made at the stream's
    /// size, which /cancel removes; a resume keeps streaming the display it had, changed in
    /// place to the size asked for now, which Moonlight's settings may have changed.
    private func launchApp(_ request: Request, resume: Bool, certificate: Data?, on connection: NWConnection) {
        guard let key = request.query["rikey"].flatMap(MoonlightCrypto.data(hex:)), key.count == 16 else {
            return reply(Self.xml(status: 400, message: "Missing key"), to: connection)
        }
        // Signed, as Moonlight prints it; the bits are what count.
        let keyID = UInt32(bitPattern: request.query["rikeyid"].flatMap { Int32($0) } ?? 0)
        let appID = request.query["appid"].flatMap(Int.init) ?? launch?.appID ?? Self.newDisplayAppID
        let address = Self.address(connection.currentPath?.localEndpoint)
        let lowLatency = clients.first { $0.certificate == certificate }?.lowLatency ?? true
        let answer = { [weak self] (launch: MoonlightLaunch) in
            guard let self else { return }
            var launch = launch
            launch.lowLatency = lowLatency
            self.endStream()
            self.launch = launch
            self.lastStreamEnd = nil
            self.onChange?()
            self.reply(Self.xml(["sessionUrl0": "rtsp://\(address):\(self.rtspPort.rawValue)",
                                 resume ? "resume" : "gamesession": "1"]), to: connection)
        }
        let mode = (request.query["mode"] ?? "").split(separator: "x").compactMap { Int($0) }
        let size = mode.count == 3 && mode[0] > 0 && mode[1] > 0 ? (mode[0], mode[1], max(mode[2], 30)) : nil
        let makeNew = { [weak self] in
            guard let self else { return }
            self.endLaunch()
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
        guard let current = launch, current.appID == appID || current.displayID == listed,
              DisplayArrangement.onlineDisplayIDs().contains(current.displayID) else { return makeNew() }
        mlLog.debug("\(resume ? "resume" : "launch", privacy: .public) on display \(current.displayID)")
        let reuse = {
            answer(MoonlightLaunch(appID: appID, displayID: current.displayID, key: key, keyID: keyID,
                                   ownsDisplay: current.ownsDisplay))
        }
        guard current.ownsDisplay, let (width, height, fps) = size, let resizeDisplay else { return reuse() }
        // Not captured while it changes size.
        endStream()
        resizeDisplay(current.displayID, width, height, fps) { resized in
            if resized { return reuse() }
            mlLog.debug("could not resize display \(current.displayID); making another")
            makeNew()
        }
    }

    /// Ends the launch: its stream, and the display made for it.
    private func endLaunch() {
        endStream()
        if let launch, launch.ownsDisplay { removeDisplay?(launch.displayID) }
        launch = nil
    }

    /// Starts the stream ANNOUNCE asked for; returns why it could not, or nil.
    private func startStream(_ launch: MoonlightLaunch, _ config: MoonlightStreamConfig) -> String? {
        endStream()
        var config = config
        config.lowLatency = launch.lowLatency
        do {
            let stream = try MoonlightStream(config: config, displayID: launch.displayID, key: launch.key,
                                             keyID: launch.keyID, pingPayload: launch.pingPayload,
                                             connectData: launch.connectData)
            stream.onEnd = { [weak self, weak stream] reason in
                guard let self, let stream, self.stream === stream else { return }
                self.stream = nil
                self.lastStreamEnd = reason
                self.onChange?()
            }
            self.stream = stream
            stream.start()
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func endStream() {
        stream?.stop()
        stream = nil
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

    private func serverInfo(paired: Bool, localAddress: String) -> String {
        Self.xml([
            "hostname": Self.hostName,
            "appversion": Self.appVersion,
            "GfeVersion": Self.gfeVersion,
            "uniqueid": Self.uniqueID,
            "HttpsPort": "\(httpsPort.rawValue)",
            "ExternalPort": "\(httpPort.rawValue)",
            "MaxLumaPixelsHEVC": "0",
            "mac": "00:00:00:00:00:00",
            "LocalIP": localAddress,
            "ServerCodecModeSupport": "\(Self.codecModeSupport)",
            "PairStatus": paired ? "1" : "0",
            "currentgame": "\(launch?.appID ?? 0)",
            "state": launch == nil ? "SUNSHINE_SERVER_FREE" : "SUNSHINE_SERVER_BUSY",
        ])
    }

    private func appList() -> String {
        let listed = self.apps + [MoonlightApp(id: Self.newDisplayAppID, title: "New Display", displayID: 0)]
        let apps = listed.map {
            "<App><IsHdrSupported>0</IsHdrSupported><AppTitle>\(Self.escape($0.title))</AppTitle><ID>\($0.id)</ID></App>"
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
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" +
                   "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
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
        } else {
            mlLog.debug("making the host's key and certificate")
            key = try MoonlightCrypto.generatePrivateKey()
            certificate = try MoonlightCrypto.selfSignedCertificate(key: key, commonName: "\(AppIdentity.name) GameStream Host")
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
