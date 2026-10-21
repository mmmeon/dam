//
//  WebStreamAccess.swift
//
//  Who may watch the browser stream, from where, and the certificates of its HTTPS port.
//  Each device has a token of its own: a player gets it in a link (`?token=`), a browser
//  in a cookie once it has paired, by a code the user types on the Mac or by scanning a QR
//  code the Mac shows. Each can be forgotten on its own. Where requests may come from is
//  a setting of its own, the Mac's own networks by default.
//
//  HTTPS uses a certificate authority DAM makes for itself, which a device trusts once (a
//  player by --tls-ca-file, an iPhone by installing it), and a server certificate it signs
//  for the Mac's names and addresses, made again when they change.
//

import Foundation
import Network
import Security
import SystemConfiguration
import os.log

private let waLog = Logger(subsystem: AppIdentity.bundleID, category: "WebStreamAccess")

// MARK: - Reach

/// Where requests may come from.
enum WebStreamReach: String, CaseIterable {
    case thisMac
    case thisNetwork
    case anywhere

    var title: String {
        switch self {
        case .thisMac: return "This Mac Only"
        case .thisNetwork: return "This Mac's Networks"
        case .anywhere: return "Anywhere"
        }
    }

    var summary: String {
        switch self {
        case .thisMac: return "Only browsers and players on this Mac."
        case .thisNetwork: return "Devices on this Mac's own networks, and over a USB or Thunderbolt cable."
        case .anywhere: return "Any address that reaches this Mac, as over a VPN or a forwarded port."
        }
    }

    private static let key = "\(AppIdentity.shortID).browser.reach"

    static var current: WebStreamReach {
        get { UserDefaults.dam.string(forKey: key).flatMap(WebStreamReach.init(rawValue:)) ?? .thisNetwork }
        set { UserDefaults.dam.set(newValue.rawValue, forKey: key) }
    }

    func allows(_ peer: NWEndpoint?) -> Bool {
        switch self {
        case .thisMac:
            guard case .hostPort(let host, _) = peer else { return false }
            switch host {
            case .ipv4(let address): return address.isLoopback
            case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
            default: return false
            }
        case .thisNetwork: return LocalNetwork.contains(peer)
        case .anywhere: return true
        }
    }
}

// MARK: - Devices

/// A device that may watch: a player's link, or a browser that paired.
struct WebStreamDevice: Codable, Equatable {
    enum Kind: String, Codable {
        /// A link, for players and anything else that takes an address.
        case link
        /// A browser that paired, holding the token in a cookie.
        case browser
    }

    let id: String
    var name: String
    let kind: Kind
    let token: String
    let added: Date

    init(name: String, kind: Kind, added: Date = Date()) {
        id = UUID().uuidString
        self.name = name
        self.kind = kind
        token = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16)).lowercased()
        self.added = added
    }

    /// Kept for a link from before devices had tokens of their own.
    init(name: String, token: String) {
        id = UUID().uuidString
        self.name = name
        kind = .link
        self.token = token
        added = Date()
    }
}

/// The devices that may watch, kept readable by the user alone.
final class WebStreamDevices {
    private let url: URL
    private(set) var all: [WebStreamDevice] = []
    /// The link Open in Browser uses.
    static let thisMacName = "This Mac"

    init(directory: URL) {
        url = directory.appendingPathComponent("devices.json")
        if let data = try? Data(contentsOf: url),
           let devices = try? JSONDecoder().decode([WebStreamDevice].self, from: data) {
            all = devices
        }
        // The one shared link from before goes on working, as a device of its own.
        let old = directory.appendingPathComponent("token")
        if let token = (try? String(contentsOf: old, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           token.count == 32 {
            all.append(WebStreamDevice(name: "Link from Before", token: token))
            save()
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// The device whose token this is.
    func device(token: String?) -> WebStreamDevice? {
        guard let token, !token.isEmpty else { return nil }
        return all.first { WebStreamServer.matches(token, $0.token) }
    }

    @discardableResult
    func add(_ device: WebStreamDevice) -> WebStreamDevice {
        all.append(device)
        save()
        return device
    }

    func remove(id: String) {
        all.removeAll { $0.id == id }
        save()
    }

    /// The link Open in Browser uses, made the first time.
    var thisMac: WebStreamDevice {
        if let device = all.first(where: { $0.kind == .link && $0.name == Self.thisMacName }) { return device }
        return add(WebStreamDevice(name: Self.thisMacName, kind: .link))
    }

    private func save() {
        do {
            try WebStreamFiles.writePrivately(try JSONEncoder().encode(all), to: url)
        } catch {
            waLog.error("saving devices: \(String(describing: error), privacy: .public)")
        }
    }
}

enum WebStreamFiles {
    /// Writes `data` readable by the user alone, as it holds keys or tokens.
    static func writePrivately(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Pairing

/// Browsers asking to pair. A browser shows a code and the user types it on the Mac; or the
/// Mac shows a QR code holding a key that works once, for a few minutes. One code at a time.
final class WebStreamPairing {
    struct Request {
        let id: String
        let code: String
        let address: String
        let name: String
        let started: Date
        /// The device made once the user typed the code; nil until then.
        var device: WebStreamDevice?
        var declined = false
    }

    /// How long a code or a QR key lasts.
    static let lifetime: TimeInterval = 300

    private(set) var request: Request?
    private var keys: [String: Date] = [:]

    /// A new request with its code, or nil while another is waiting.
    func begin(address: String, name: String, now: Date = Date()) -> Request? {
        if let request, request.device == nil, !request.declined, now.timeIntervalSince(request.started) < Self.lifetime {
            return nil
        }
        let code = String(format: "%04d", Int.random(in: 0...9999))
        let request = Request(id: UUID().uuidString, code: code, address: address, name: name, started: now)
        self.request = request
        return request
    }

    /// The request `id`, while it lasts.
    func request(id: String, now: Date = Date()) -> Request? {
        guard let request, request.id == id, now.timeIntervalSince(request.started) < Self.lifetime else { return nil }
        return request
    }

    /// Whether `code` is the one request `id` shows; makes its device if it is.
    func answer(id: String, code: String?, now: Date = Date(), add: (WebStreamDevice) -> Void) -> Bool {
        guard var request = request(id: id, now: now), request.device == nil, !request.declined else { return false }
        guard let code, code.trimmingCharacters(in: .whitespaces) == request.code else {
            request.declined = true
            self.request = request
            return false
        }
        let device = WebStreamDevice(name: request.name, kind: .browser)
        add(device)
        request.device = device
        self.request = request
        return true
    }

    /// A key for a QR code, which pairs whoever opens it once within `lifetime`.
    func makeKey(now: Date = Date()) -> String {
        keys = keys.filter { now.timeIntervalSince($0.value) < Self.lifetime }
        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16)).lowercased()
        keys[key] = now
        return key
    }

    /// Uses up `key`; whether it was good.
    func use(key: String?, now: Date = Date()) -> Bool {
        guard let key, let made = keys.removeValue(forKey: key) else { return false }
        return now.timeIntervalSince(made) < Self.lifetime
    }

    /// A name for a browser from its User-Agent and address, as "Safari on iPhone (10.0.0.5)".
    static func name(userAgent: String?, address: String) -> String {
        let agent = userAgent ?? ""
        let browser = agent.contains("Firefox/") ? "Firefox"
            : agent.contains("Edg/") ? "Edge"
            : agent.contains("Chrome/") || agent.contains("CriOS/") ? "Chrome"
            : agent.contains("Safari/") ? "Safari" : "Browser"
        let device = agent.contains("iPhone") ? "iPhone"
            : agent.contains("iPad") ? "iPad"
            : agent.contains("Android") ? "Android"
            : agent.contains("Macintosh") ? "Mac"
            : agent.contains("Windows") ? "Windows"
            : agent.contains("Linux") ? "Linux" : nil
        let what = device.map { "\(browser) on \($0)" } ?? browser
        return address.isEmpty ? what : "\(what) (\(address))"
    }
}

// MARK: - Certificates

/// The certificate authority DAM makes for the stream and the server certificate it signs.
final class WebStreamCertificates {
    let authority: Data
    let server: Data
    let identity: SecIdentity

    private let directory: URL

    /// What a server certificate lasts; Apple's platforms refuse ones that last over 825 days.
    static let serverDays = 800

    /// Loads them, or makes them: the authority once, the server certificate again when it
    /// is near its end or the Mac's names or addresses have changed.
    init(directory: URL, names: [String] = WebStreamCertificates.hostNames(),
         addresses: [[UInt8]] = WebStreamCertificates.hostAddresses(), now: Date = Date()) throws {
        self.directory = directory
        let authorityKeyURL = directory.appendingPathComponent("authority-key.der")
        let authorityURL = directory.appendingPathComponent("authority.der")
        let serverKeyURL = directory.appendingPathComponent("server-key.der")
        let serverURL = directory.appendingPathComponent("server.der")
        let coversURL = directory.appendingPathComponent("server-covers.json")

        let authorityName = "\(AppIdentity.name) Browser Stream (\(Self.localHostName ?? "Mac"))"
        let authorityKey: SecKey
        let authority: Data
        if let keyData = try? Data(contentsOf: authorityKeyURL), let key = try? MoonlightCrypto.importPrivateKey(keyData),
           let stored = try? Data(contentsOf: authorityURL), SecCertificateCreateWithData(nil, stored as CFData) != nil {
            authorityKey = key
            authority = stored
            // Kept even so: a new authority would have to be trusted again on every device.
            if !DER.hasMinimalSerial(stored) {
                waLog.error("the certificate authority's serial is not minimal DER; browsers using BoringSSL may refuse it")
            }
        } else {
            waLog.debug("making the browser stream's certificate authority")
            authorityKey = try MoonlightCrypto.generatePrivateKey()
            authority = try MoonlightCrypto.certificate(key: authorityKey, subject: authorityName, days: 20 * 365,
                                                        extensions: DER.authorityExtensions(), now: now)
            try WebStreamFiles.writePrivately(try MoonlightCrypto.exportPrivateKey(authorityKey), to: authorityKeyURL)
            try WebStreamFiles.writePrivately(authority, to: authorityURL)
            try? FileManager.default.removeItem(at: serverURL)
        }
        let issuer = Self.commonName(of: authority) ?? authorityName

        let covers = Covers(names: names, addresses: addresses.map { $0.map { String($0) }.joined(separator: ".") })
        let storedCovers = (try? Data(contentsOf: coversURL)).flatMap { try? JSONDecoder().decode(Covers.self, from: $0) }
        let server: Data
        if let keyData = try? Data(contentsOf: serverKeyURL), (try? MoonlightCrypto.importPrivateKey(keyData)) != nil,
           let stored = try? Data(contentsOf: serverURL), let certificate = SecCertificateCreateWithData(nil, stored as CFData),
           storedCovers == covers, let ends = Self.notAfter(of: certificate), ends.timeIntervalSince(now) > 30 * 24 * 3600,
           // One some browsers refuse is made again; nothing else depends on it.
           DER.hasMinimalSerial(stored) {
            server = stored
        } else {
            waLog.debug("making the browser stream's server certificate for \(names, privacy: .public)")
            let key = try MoonlightCrypto.generatePrivateKey()
            server = try MoonlightCrypto.certificate(
                key: key, subject: names.first ?? "localhost", issuer: issuer, issuerKey: authorityKey, days: Self.serverDays,
                extensions: DER.serverExtensions(names: names, addresses: addresses), now: now)
            try WebStreamFiles.writePrivately(try MoonlightCrypto.exportPrivateKey(key), to: serverKeyURL)
            try WebStreamFiles.writePrivately(server, to: serverURL)
            try WebStreamFiles.writePrivately(try JSONEncoder().encode(covers), to: coversURL)
        }
        guard let serverKeyData = try? Data(contentsOf: serverKeyURL),
              let serverKey = try? MoonlightCrypto.importPrivateKey(serverKeyData),
              let certificate = SecCertificateCreateWithData(nil, server as CFData),
              let identity = MoonlightHost.makeIdentity(certificate, serverKey) else {
            throw MoonlightCryptoError.badCertificate
        }
        self.authority = authority
        self.server = server
        self.identity = identity
    }

    private struct Covers: Codable, Equatable {
        let names: [String]
        let addresses: [String]
    }

    /// The authority as PEM, for players' --tls-ca-file.
    var authorityPEM: String { MoonlightCrypto.pem(certificate: authority) }

    /// The authority's SHA-256 fingerprint, in pairs of hex digits.
    var fingerprint: String {
        let hex = MoonlightCrypto.hex(MoonlightCrypto.sha256(authority))
        return stride(from: 0, to: hex.count, by: 2).map {
            String(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)])
        }.joined(separator: ":")
    }

    /// The Mac's Bonjour name, as "slab" for slab.local.
    static var localHostName: String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    /// The names the server certificate is for.
    static func hostNames() -> [String] {
        var names: [String] = []
        if let local = localHostName { names.append("\(local).local") }
        let host = ProcessInfo.processInfo.hostName
        if !host.isEmpty, !names.contains(host), IPv4Address(host) == nil, IPv6Address(host) == nil { names.append(host) }
        names.append("localhost")
        return names
    }

    /// The addresses it is for: loopback and the Mac's IPv4 addresses, link-local among them.
    static func hostAddresses() -> [[UInt8]] {
        let interfaces = LocalNetwork.interfaceSubnets().map(\.address).filter { $0.count == 4 && $0[0] != 127 }
        return [[127, 0, 0, 1]] + interfaces.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private static func commonName(of der: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        return name as String?
    }

    private static func notAfter(of certificate: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil)
                as? [CFString: [CFString: Any]],
              let value = values[kSecOIDX509V1ValidityNotAfter]?[kSecPropertyKeyValue] else { return nil }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return value as? Date
    }
}
