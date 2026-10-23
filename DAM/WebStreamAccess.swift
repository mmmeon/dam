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
//  for the Mac's names and addresses, made again when they change. A certificate authority
//  the devices already trust can be imported to sign in its place, or a server certificate
//  to be served as it is (from PEM files or a .p12 file).
//

import CryptoKit
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
/// Mac shows a QR code holding a key that works once, for a few minutes. One code at a time,
/// and its prompt only as often as `limits` let it come up.
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
        /// Whether the browser has had its cookie, once paired.
        var collected = false
    }

    /// How long a code or a QR key lasts.
    static let lifetime: TimeInterval = 300

    private(set) var request: Request?
    private var keys: [String: Date] = [:]
    /// Shared with Moonlight's pairing, so that the two together bring up no more prompts.
    var limits: PairingPromptLimits

    init(limits: PairingPromptLimits = PairingPromptLimits()) {
        self.limits = limits
    }

    /// Why a request can't begin now.
    enum Refusal: Error, Equatable {
        /// Another is waiting for its code, or for its browser to collect the cookie.
        case busy
        /// Prompts came to nothing too often; seconds to wait.
        case wait(TimeInterval)
    }

    /// A new request with its code, or why there can't be one now.
    func begin(address: String, name: String, now: Date = Date()) -> Result<Request, Refusal> {
        if let request, !request.declined, request.device == nil || !request.collected,
           now.timeIntervalSince(request.started) < Self.lifetime {
            return .failure(.busy)
        }
        if let wait = limits.wait(for: address, now: now) { return .failure(.wait(wait)) }
        let code = String(format: "%04d", Int.random(in: 0...9999))
        let request = Request(id: UUID().uuidString, code: code, address: address, name: name, started: now)
        self.request = request
        return .success(request)
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
            limits.ended(request.address, declined: true, now: now)
            return false
        }
        limits.ended(request.address, declined: false, now: now)
        let device = WebStreamDevice(name: request.name, kind: .browser)
        add(device)
        request.device = device
        self.request = request
        return true
    }

    /// Request `id`'s browser has had its cookie: another may begin.
    func collected(id: String) {
        guard request?.id == id, request?.device != nil else { return }
        request?.collected = true
    }

    /// Whether request `id` still waits for its code to be typed, for a prompt shown later.
    func isWaiting(id: String, now: Date = Date()) -> Bool {
        guard let request = request(id: id, now: now) else { return false }
        return request.device == nil && !request.declined
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

/// The certificates of the HTTPS port: a certificate authority and the server certificate it
/// signs for the Mac's names and addresses, or a server certificate imported to be served as
/// it is. The authority is DAM's own, or one imported in its place (`ImportedCertificate`).
final class WebStreamCertificates {
    /// Where the certificate served comes from.
    enum Source: Equatable {
        case own
        /// An imported certificate authority, by name, signs DAM's server certificate.
        case importedAuthority(name: String, until: Date?)
        /// An imported server certificate is served as it is, for these names and addresses.
        case importedServer(names: [String], until: Date?)
    }

    /// The certificate authority a device trusts the server through, when DAM has it: an
    /// imported server certificate may come without its issuer's.
    let authority: Data?
    let server: Data
    let identity: SecIdentity
    /// The certificates sent after the server's: its authority's, and any above that.
    let chain: [Data]
    let source: Source
    /// The names the server certificate is for, in lower case, wildcards among them.
    let names: [String]

    private let directory: URL

    /// What a server certificate lasts; Apple's platforms refuse ones that last over 825 days.
    static let serverDays = 800

    /// Loads them, or makes them: the authority once, the server certificate again when it
    /// is near its end, the Mac's names or addresses have changed, or another authority signs.
    /// An import that can't be used is passed over for DAM's own.
    init(directory: URL, names: [String] = WebStreamCertificates.hostNames(),
         addresses: [[UInt8]] = WebStreamCertificates.hostAddresses(), now: Date = Date()) throws {
        self.directory = directory
        let imported = ImportedCertificate.load(from: directory)
        if let imported, imported.kind == .server {
            if let key = try? MoonlightCrypto.importPrivateKey(imported.key, kind: imported.keyKind),
               let certificate = SecCertificateCreateWithData(nil, imported.certificates[0] as CFData),
               let identity = MoonlightHost.makeIdentity(certificate, key) {
                server = imported.certificates[0]
                chain = Array(imported.certificates.dropFirst())
                authority = chain.last.flatMap { DER.certificate($0)?.isAuthority == true ? $0 : nil }
                self.identity = identity
                let facts = DER.certificate(server)
                source = .importedServer(names: (facts?.names ?? []) + (facts?.addresses ?? []).map(Self.addressText),
                                         until: Self.notAfter(of: certificate))
                self.names = (facts?.names ?? []).map { $0.lowercased() }
                return
            }
            waLog.error("the imported server certificate can't be used; serving DAM's own")
        }

        let authorityKeyURL = directory.appendingPathComponent("authority-key.der")
        let authorityURL = directory.appendingPathComponent("authority.der")
        let serverKeyURL = directory.appendingPathComponent("server-key.der")
        let serverURL = directory.appendingPathComponent("server.der")
        let coversURL = directory.appendingPathComponent("server-covers.json")

        // Who signs: an imported authority, by its own subject and key identifier, or DAM's.
        var signer: (certificate: Data, key: SecKey, name: Data?, keyIdentifier: Data?, above: [Data])?
        if let imported, imported.kind == .authority {
            if let key = try? MoonlightCrypto.importPrivateKey(imported.key, kind: imported.keyKind),
               let facts = DER.certificate(imported.certificates[0]) {
                signer = (imported.certificates[0], key, facts.subject, facts.keyIdentifier,
                          Array(imported.certificates.dropFirst()))
            } else {
                waLog.error("the imported certificate authority can't be used; signing with DAM's own")
            }
        }
        let authorityName = "\(AppIdentity.name) Browser Stream (\(Self.localHostName ?? "Mac"))"
        if signer == nil {
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
            signer = (authority, authorityKey, nil, nil, [])
        }
        guard let signer else { throw MoonlightCryptoError.badCertificate }
        let authority = signer.certificate
        let authorityCertificate = SecCertificateCreateWithData(nil, authority as CFData)
        // A server certificate can't usefully outlast the authority it is signed by.
        let authorityEnds = authorityCertificate.flatMap(Self.notAfter)
        let days = max(1, min(Self.serverDays, authorityEnds.map { Int($0.timeIntervalSince(now) / (24 * 3600)) - 1 } ?? Self.serverDays))

        let covers = Covers(names: names, addresses: addresses.map { $0.map { String($0) }.joined(separator: ".") },
                            authority: MoonlightCrypto.hex(MoonlightCrypto.sha256(authority)))
        let storedCovers = (try? Data(contentsOf: coversURL)).flatMap { try? JSONDecoder().decode(Covers.self, from: $0) }
        let server: Data
        if let keyData = try? Data(contentsOf: serverKeyURL), (try? MoonlightCrypto.importPrivateKey(keyData)) != nil,
           let stored = try? Data(contentsOf: serverURL), let certificate = SecCertificateCreateWithData(nil, stored as CFData),
           storedCovers == covers, let ends = Self.notAfter(of: certificate),
           ends.timeIntervalSince(now) > Double(min(30, days / 2)) * 24 * 3600,
           // One some browsers refuse is made again; nothing else depends on it.
           DER.hasMinimalSerial(stored) {
            server = stored
        } else {
            waLog.debug("making the browser stream's server certificate for \(names, privacy: .public)")
            let key = try MoonlightCrypto.generatePrivateKey()
            var extensions = DER.serverExtensions(names: names, addresses: addresses)
            if let keyIdentifier = signer.keyIdentifier { extensions.append(DER.authorityKeyIdentifier(keyIdentifier)) }
            server = try MoonlightCrypto.certificate(
                key: key, subject: names.first ?? "localhost", issuer: Self.commonName(of: authority) ?? authorityName,
                issuerName: signer.name, issuerKey: signer.key, days: days, extensions: extensions, now: now)
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
        chain = [authority] + signer.above
        source = signer.name == nil ? .own
            : .importedAuthority(name: Self.commonName(of: authority) ?? "Imported authority", until: authorityEnds)
        self.names = names.map { $0.lowercased() }
    }

    /// Whether the server certificate is for the name `host`, given in lower case: one of
    /// its names, or under one of its wildcards by one label.
    func covers(_ host: String) -> Bool {
        let parts = host.split(separator: ".", maxSplits: 1)
        return names.contains { name in
            name.hasPrefix("*.") ? parts.count == 2 && "*." + parts[1] == name : name == host
        }
    }

    private struct Covers: Codable, Equatable {
        let names: [String]
        let addresses: [String]
        /// The SHA-256 of the authority that signed it; nil in files from before imports.
        var authority: String?
    }

    /// The authority as PEM, for players' --tls-ca-file; nil when DAM has none.
    var authorityPEM: String? { authority.map { MoonlightCrypto.pem(certificate: $0) } }

    /// The SHA-256 fingerprint of the authority, or of the server certificate when there is
    /// no authority, in pairs of hex digits.
    var fingerprint: String {
        let hex = MoonlightCrypto.hex(MoonlightCrypto.sha256(authority ?? server))
        return stride(from: 0, to: hex.count, by: 2).map {
            String(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)])
        }.joined(separator: ":")
    }

    /// `preferred` if the server certificate is for it, else a name it is for: an imported
    /// one may be for none of the Mac's own names.
    func host(preferring preferred: String) -> String {
        guard case .importedServer(let names, _) = source, !names.isEmpty else { return preferred }
        let wanted = preferred.lowercased()
        let covered = names.contains { name in
            let name = name.lowercased()
            if name.hasPrefix("*.") { return wanted.split(separator: ".", maxSplits: 1).last.map { "*." + $0 } == name }
            return name == wanted
        }
        return covered ? preferred : names.first { !$0.hasPrefix("*.") } ?? preferred
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

    static func commonName(of der: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        return name as String?
    }

    static func notAfter(of certificate: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil)
                as? [CFString: [CFString: Any]],
              let value = values[kSecOIDX509V1ValidityNotAfter]?[kSecPropertyKeyValue] else { return nil }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return value as? Date
    }

    /// An IP address as text: dotted for IPv4, groups of hex for IPv6.
    static func addressText(_ bytes: [UInt8]) -> String {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        return stride(from: 0, to: bytes.count - 1, by: 2)
            .map { String(Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]), radix: 16) }.joined(separator: ":")
    }
}

// MARK: - Importing

/// Why a certificate couldn't be imported, as the user is told.
enum CertificateImportError: LocalizedError, Equatable {
    case nothingReadable
    case noCertificate
    case noKey
    case severalKeys
    case encryptedKey
    case unsupportedKey
    case keyMatchesNoCertificate
    case authorityMayNotSign
    case expired(Date)
    case needsPassword
    case wrongPassword
    case unreadablePKCS12(String)

    var errorDescription: String? {
        switch self {
        case .nothingReadable:
            return "The files hold no certificate or key that DAM can read. It takes PEM files and .p12 files."
        case .noCertificate:
            return "There is no certificate in the files."
        case .noKey:
            return "There is no private key in the files. Choose the key's file together with the certificate's."
        case .severalKeys:
            return "The files hold more than one private key. Choose one certificate and its key."
        case .encryptedKey:
            return "The private key is encrypted. Decrypt it first, for example: openssl pkey -in key.pem -out key-plain.pem"
        case .unsupportedKey:
            return "DAM can't use this kind of private key. It takes RSA keys, and EC keys on the P-256, P-384 or P-521 curve."
        case .keyMatchesNoCertificate:
            return "The private key doesn't belong to any of the certificates."
        case .authorityMayNotSign:
            return "The certificate authority's key usage doesn't allow it to sign certificates."
        case .expired(let date):
            return "The certificate expired on \(date.formatted(date: .abbreviated, time: .omitted))."
        case .needsPassword:
            return "The .p12 file needs its password."
        case .wrongPassword:
            return "That password doesn't open the .p12 file."
        case .unreadablePKCS12(let reason):
            return "The .p12 file can't be read: \(reason)"
        }
    }
}

/// A certificate and its private key brought in for HTTPS, from PEM files or a PKCS#12 file.
/// A certificate authority signs DAM's server certificate in place of DAM's own; any other
/// certificate is served as it is. Kept beside DAM's own files, which stay for going back.
struct ImportedCertificate: Codable, Equatable {
    enum Kind: String, Codable {
        case authority
        case server
    }

    let kind: Kind
    /// The certificate the key belongs to, then the others that came with it, as given.
    let certificates: [Data]
    let keyKind: MoonlightCrypto.KeyKind
    /// The key as `MoonlightCrypto.importPrivateKey` takes it; kept in a file of its own.
    var key = Data()

    private enum CodingKeys: String, CodingKey {
        case kind, certificates, keyKind
    }

    /// Reads `files`: PEM text (certificates and a key, in one file or several), certificates
    /// in DER, or a PKCS#12 file, opened with `password`.
    static func read(files: [URL], password: String?, now: Date = Date()) throws -> ImportedCertificate {
        var text = ""
        for file in files {
            let data = try Data(contentsOf: file)
            if let string = String(data: data, encoding: .utf8), string.contains("-----BEGIN ") {
                text += string + "\n"
            } else if SecCertificateCreateWithData(nil, data as CFData) != nil {
                text += MoonlightCrypto.pem(certificate: data)
            } else {
                guard let password else { throw CertificateImportError.needsPassword }
                text += try pem(pkcs12: file, password: password)
            }
        }
        return try read(pem: text, now: now)
    }

    /// Reads PEM text: one private key, the certificate it belongs to, and any others.
    static func read(pem text: String, now: Date = Date()) throws -> ImportedCertificate {
        let blocks = MoonlightCrypto.pemBlocks(text)
        guard !blocks.isEmpty else { throw CertificateImportError.nothingReadable }
        var certificates: [Data] = []
        for block in blocks where block.label == "CERTIFICATE" && !certificates.contains(block.der)
            && SecCertificateCreateWithData(nil, block.der as CFData) != nil {
            certificates.append(block.der)
        }
        let keys = try blocks.filter { $0.label.hasSuffix("PRIVATE KEY") }.map(privateKey)
        guard !certificates.isEmpty else { throw CertificateImportError.noCertificate }
        guard let (keyKind, keyData) = keys.first else { throw CertificateImportError.noKey }
        guard keys.count == 1 else { throw CertificateImportError.severalKeys }
        guard let key = try? MoonlightCrypto.importPrivateKey(keyData, kind: keyKind) else {
            throw CertificateImportError.unsupportedKey
        }
        guard let index = certificates.firstIndex(where: {
            SecCertificateCreateWithData(nil, $0 as CFData).map { MoonlightCrypto.key(key, matches: $0) } ?? false
        }) else { throw CertificateImportError.keyMatchesNoCertificate }
        let own = certificates.remove(at: index)
        guard let certificate = SecCertificateCreateWithData(nil, own as CFData), let facts = DER.certificate(own),
              MoonlightHost.makeIdentity(certificate, key) != nil else {
            throw CertificateImportError.keyMatchesNoCertificate
        }
        if let ends = WebStreamCertificates.notAfter(of: certificate), ends < now {
            throw CertificateImportError.expired(ends)
        }
        if facts.isAuthority, !facts.maySignCertificates { throw CertificateImportError.authorityMayNotSign }
        return ImportedCertificate(kind: facts.isAuthority ? .authority : .server, certificates: [own] + certificates,
                                   keyKind: keyKind, key: keyData)
    }

    /// A private key from its PEM block, as `MoonlightCrypto.importPrivateKey` takes it.
    private static func privateKey(_ block: (label: String, der: Data, text: String)) throws
        -> (MoonlightCrypto.KeyKind, Data) {
        if block.label.hasPrefix("ENCRYPTED") || block.text.contains("Proc-Type: 4,ENCRYPTED") {
            throw CertificateImportError.encryptedKey
        }
        switch block.label {
        case "RSA PRIVATE KEY":
            return (.rsa, block.der)
        case "EC PRIVATE KEY":
            return (.ec, try ecKey(pem: block.text))
        case "PRIVATE KEY":
            // PKCS#8: a version, the key's algorithm, and the key itself in an OCTET STRING.
            let bytes = [UInt8](block.der)
            guard let outer = DER.read(bytes, at: 0), let version = DER.read(bytes, at: outer.content.lowerBound),
                  let algorithm = DER.read(bytes, at: version.next),
                  let oid = DER.read(bytes, at: algorithm.content.lowerBound), oid.tag == 0x06,
                  let key = DER.read(bytes, at: algorithm.next), key.tag == 0x04 else {
                throw CertificateImportError.unsupportedKey
            }
            switch Array(bytes[oid.content]) {
            case DER.rsaEncryption: return (.rsa, Data(bytes[key.content]))
            case DER.ecPublicKey: return (.ec, try ecKey(pem: block.text))
            default: throw CertificateImportError.unsupportedKey
            }
        default:
            throw CertificateImportError.unsupportedKey
        }
    }

    /// An EC key in ANSI X9.63 form, which Security takes, from PEM in SEC1 or PKCS#8 form.
    private static func ecKey(pem: String) throws -> Data {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) { return key.x963Representation }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: pem) { return key.x963Representation }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: pem) { return key.x963Representation }
        throw CertificateImportError.unsupportedKey
    }

    /// The PEM in a PKCS#12 file, key and all, as the system's openssl (LibreSSL) writes it
    /// out. Security on macOS 13 can't read the AES files OpenSSL 3 makes, and gives the key
    /// of the older ones only into a keychain.
    static func pem(pkcs12 file: URL, password: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["pkcs12", "-in", file.path, "-nodes", "-passin", "stdin"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw CertificateImportError.unreadablePKCS12(error.localizedDescription)
        }
        input.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let pem = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if message.contains("invalid password") || message.contains("verify error") {
            throw CertificateImportError.wrongPassword
        }
        guard process.terminationStatus == 0, let text = String(data: pem, encoding: .utf8), text.contains("-----BEGIN ") else {
            let reason = message.split(separator: "\n").first.map(String.init) ?? "openssl ended with \(process.terminationStatus)"
            throw CertificateImportError.unreadablePKCS12(reason)
        }
        return text
    }

    private static func files(in directory: URL) -> (record: URL, key: URL) {
        (directory.appendingPathComponent("imported.json"), directory.appendingPathComponent("imported-key.der"))
    }

    func save(in directory: URL) throws {
        let (record, keyURL) = Self.files(in: directory)
        try WebStreamFiles.writePrivately(key, to: keyURL)
        try WebStreamFiles.writePrivately(try JSONEncoder().encode(self), to: record)
    }

    /// The import kept in `directory`; nil when there is none, or it can't be read.
    static func load(from directory: URL) -> ImportedCertificate? {
        let (record, keyURL) = files(in: directory)
        guard let data = try? Data(contentsOf: record) else { return nil }
        guard var imported = try? JSONDecoder().decode(ImportedCertificate.self, from: data),
              !imported.certificates.isEmpty, let key = try? Data(contentsOf: keyURL) else {
            waLog.error("the imported certificate can't be read")
            return nil
        }
        imported.key = key
        return imported
    }

    static func remove(from directory: URL) {
        let (record, keyURL) = files(in: directory)
        try? FileManager.default.removeItem(at: record)
        try? FileManager.default.removeItem(at: keyURL)
    }
}
