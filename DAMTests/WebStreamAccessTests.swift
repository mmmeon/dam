import XCTest
import Network
import Security
@testable import DAM

final class WebStreamAccessTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Reach

    func testReachGoesFromThisMacToAnywhere() {
        let loopback = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        let mapped = NWEndpoint.hostPort(host: "::ffff:127.0.0.1", port: 1)
        let cable = NWEndpoint.hostPort(host: "169.254.3.4", port: 1)
        let far = NWEndpoint.hostPort(host: "8.8.8.8", port: 1)
        XCTAssertTrue(WebStreamReach.thisMac.allows(loopback))
        XCTAssertTrue(WebStreamReach.thisMac.allows(mapped))
        XCTAssertFalse(WebStreamReach.thisMac.allows(cable))
        XCTAssertTrue(WebStreamReach.thisNetwork.allows(cable))
        XCTAssertFalse(WebStreamReach.thisNetwork.allows(far))
        XCTAssertTrue(WebStreamReach.anywhere.allows(far))
    }

    // MARK: - Pairing

    func testACodeTypedRightPairsTheBrowser() throws {
        let pairing = WebStreamPairing()
        let request = try XCTUnwrap(pairing.begin(address: "10.0.0.5", name: "Safari on iPhone (10.0.0.5)"))
        XCTAssertEqual(request.code.count, 4)
        XCTAssertNil(pairing.begin(address: "10.0.0.6", name: "other"), "one at a time")
        var added: [WebStreamDevice] = []
        XCTAssertTrue(pairing.answer(id: request.id, code: " \(request.code) ") { added.append($0) })
        XCTAssertEqual(added.map(\.name), ["Safari on iPhone (10.0.0.5)"])
        XCTAssertEqual(added.first?.kind, .browser)
        XCTAssertEqual(pairing.request(id: request.id)?.device, added.first)
        XCTAssertNotNil(pairing.begin(address: "10.0.0.6", name: "other"), "free again")
    }

    func testAWrongCodeOrNoneDeclinesAndTheCodeRunsOut() throws {
        let pairing = WebStreamPairing()
        let start = Date()
        var request = try XCTUnwrap(pairing.begin(address: "a", name: "a", now: start))
        let wrong = request.code == "0000" ? "1111" : "0000"
        XCTAssertFalse(pairing.answer(id: request.id, code: wrong) { _ in XCTFail() })
        XCTAssertEqual(pairing.request(id: request.id)?.declined, true)
        XCTAssertFalse(pairing.answer(id: request.id, code: request.code) { _ in XCTFail() }, "no second try")

        request = try XCTUnwrap(pairing.begin(address: "b", name: "b", now: start))
        XCTAssertFalse(pairing.answer(id: request.id, code: nil) { _ in XCTFail() }, "the user said no")
        request = try XCTUnwrap(pairing.begin(address: "c", name: "c", now: start))
        let late = start.addingTimeInterval(WebStreamPairing.lifetime + 1)
        XCTAssertNil(pairing.request(id: request.id, now: late))
        XCTAssertFalse(pairing.answer(id: request.id, code: request.code, now: late) { _ in XCTFail() })
        XCTAssertNotNil(pairing.begin(address: "d", name: "d", now: late), "an old request holds nothing up")
    }

    func testAQRKeyWorksOnceAndNotForLong() {
        let pairing = WebStreamPairing()
        let start = Date()
        let key = pairing.makeKey(now: start)
        XCTAssertTrue(pairing.use(key: key, now: start.addingTimeInterval(10)))
        XCTAssertFalse(pairing.use(key: key, now: start.addingTimeInterval(11)), "once")
        let old = pairing.makeKey(now: start)
        XCTAssertFalse(pairing.use(key: old, now: start.addingTimeInterval(WebStreamPairing.lifetime + 1)))
        XCTAssertFalse(pairing.use(key: "nonsense"))
        XCTAssertFalse(pairing.use(key: nil))
    }

    func testBrowsersAreNamedFromTheirUserAgent() {
        let iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        XCTAssertEqual(WebStreamPairing.name(userAgent: iphone, address: "10.0.0.5"), "Safari on iPhone (10.0.0.5)")
        XCTAssertEqual(WebStreamPairing.name(userAgent: chrome, address: ""), "Chrome on Windows")
        XCTAssertEqual(WebStreamPairing.name(userAgent: nil, address: "::1"), "Browser (::1)")
    }

    // MARK: - Devices

    func testDevicesAreKeptAndTheOldLinkGoesOnWorking() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = String(repeating: "a", count: 32)
        try Data(old.utf8).write(to: directory.appendingPathComponent("token"))
        let devices = WebStreamDevices(directory: directory)
        XCTAssertEqual(devices.device(token: old)?.name, "Link from Before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("token").path))
        let phone = devices.add(WebStreamDevice(name: "Phone", kind: .browser))
        let thisMac = devices.thisMac
        XCTAssertEqual(devices.thisMac, thisMac, "made once")

        let again = WebStreamDevices(directory: directory)
        XCTAssertEqual(again.all.map(\.name), ["Link from Before", "Phone", WebStreamDevices.thisMacName])
        XCTAssertEqual(again.device(token: phone.token), phone)
        again.remove(id: phone.id)
        XCTAssertNil(WebStreamDevices(directory: directory).device(token: phone.token))
        XCTAssertNil(again.device(token: ""))
        XCTAssertNil(again.device(token: nil))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("devices.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Certificates

    private func trusts(_ server: Data, name: String, authority: Data) -> Bool {
        guard let leaf = SecCertificateCreateWithData(nil, server as CFData),
              let root = SecCertificateCreateWithData(nil, authority as CFData) else { return false }
        var trust: SecTrust?
        SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, name as CFString), &trust)
        guard let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        if let error { print("trust: \(error)") }
        return trusted
    }

    /// The server certificate passes Apple's checks for a TLS server under the authority,
    /// for each of its names; the authority is kept, and the server certificate made again
    /// when the names change.
    func testTheServerCertificateIsTrustedUnderTheAuthorityForItsNames() throws {
        let names = ["test-mac.local", "localhost"]
        let first = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        let authority = try XCTUnwrap(first.authority)
        XCTAssertEqual(first.chain, [authority])
        XCTAssertTrue(trusts(first.server, name: "test-mac.local", authority: authority))
        XCTAssertTrue(trusts(first.server, name: "localhost", authority: authority))
        XCTAssertTrue(trusts(first.server, name: "127.0.0.1", authority: authority))
        XCTAssertFalse(trusts(first.server, name: "other.local", authority: authority))
        XCTAssertEqual(first.authorityPEM?.hasPrefix("-----BEGIN CERTIFICATE-----"), true)
        XCTAssertEqual(first.fingerprint.count, 32 * 3 - 1)

        let kept = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        XCTAssertEqual(kept.server, first.server)
        XCTAssertEqual(kept.authority, first.authority)

        let renamed = try WebStreamCertificates(directory: directory, names: ["new-name.local"], addresses: [[127, 0, 0, 1]])
        XCTAssertEqual(renamed.authority, first.authority, "trusted once")
        XCTAssertNotEqual(renamed.server, first.server)
        XCTAssertTrue(trusts(renamed.server, name: "new-name.local", authority: authority))
    }

    // MARK: - Imported certificates

    /// Runs the system's openssl (LibreSSL) in the test's directory: the certificates and
    /// keys imported are made with it, as a user's would be.
    @discardableResult
    private func openssl(_ arguments: String...) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "openssl \(arguments.joined(separator: " ")): \(text)")
        return text
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func der(_ name: String) throws -> Data {
        try MoonlightCrypto.der(certificatePEM: String(contentsOf: file(name), encoding: .utf8))
    }

    /// A certificate authority named `name`, with its key in `key` (made by the caller, or RSA).
    private func makeAuthority(_ name: String, key: String = "ca.key", certificate: String = "ca.pem",
                               newRSA: Bool = true) throws {
        try openssl("req", "-x509", "-new", newRSA ? "-newkey" : "-key", newRSA ? "rsa:2048" : key,
                    "-nodes", "-keyout", key, "-out", certificate, "-days", "60",
                    "-subj", "/O=Home Lab/OU=Test/CN=\(name)",
                    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                    "-addext", "subjectKeyIdentifier=hash")
    }

    /// A server certificate for mac.example.test, signed by ca.pem.
    private func makeServer() throws {
        try openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.csr",
                    "-subj", "/CN=mac.example.test")
        try "subjectAltName=DNS:mac.example.test,IP:192.0.2.7\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n"
            .write(to: file("leaf.cnf"), atomically: true, encoding: .utf8)
        try openssl("x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                    "-out", "leaf.pem", "-days", "30", "-extfile", "leaf.cnf")
    }

    /// An imported authority signs the server certificate under its own name, which Apple's
    /// checks then trust through it alone; going back to DAM's own signs with that again.
    func testAnImportedAuthoritySignsTheServerCertificate() throws {
        let names = ["test-mac.local", "localhost"]
        let own = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        XCTAssertEqual(own.source, .own)
        try makeAuthority("Home Lab RSA CA")
        let imported = try ImportedCertificate.read(files: [file("ca.pem"), file("ca.key")], password: nil)
        XCTAssertEqual(imported.kind, .authority)
        XCTAssertEqual(imported.keyKind, .rsa)
        try imported.save(in: directory)

        let signed = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        let authority = try der("ca.pem")
        XCTAssertEqual(signed.authority, authority)
        XCTAssertEqual(signed.chain, [authority])
        guard case .importedAuthority("Home Lab RSA CA", let ends) = signed.source else {
            return XCTFail("source \(signed.source)")
        }
        XCTAssertNotNil(ends)
        XCTAssertEqual(DER.certificate(signed.server)?.issuer, DER.certificate(authority)?.subject, "the whole name, as it is")
        XCTAssertTrue(trusts(signed.server, name: "test-mac.local", authority: authority))
        XCTAssertTrue(trusts(signed.server, name: "127.0.0.1", authority: authority))
        XCTAssertFalse(trusts(signed.server, name: "test-mac.local", authority: own.authority!))
        let kept = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        XCTAssertEqual(kept.server, signed.server, "made once")

        ImportedCertificate.remove(from: directory)
        let back = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        XCTAssertEqual(back.source, .own)
        XCTAssertEqual(back.authority, own.authority, "DAM's own was kept")
        XCTAssertTrue(trusts(back.server, name: "test-mac.local", authority: own.authority!))
    }

    /// An EC authority signs with ECDSA, its key given in SEC1 or PKCS#8 form, on P-256 or P-384.
    func testAnImportedECAuthoritySigns() throws {
        for (curve, form) in [("prime256v1", "sec1"), ("prime256v1", "pkcs8"), ("secp384r1", "pkcs8")] {
            try? FileManager.default.removeItem(at: directory)
            try openssl("ecparam", "-name", curve, "-genkey", "-noout", "-out", "ec.key")
            if form == "pkcs8" {
                try openssl("pkcs8", "-topk8", "-nocrypt", "-in", "ec.key", "-out", "ec8.key")
                try FileManager.default.removeItem(at: file("ec.key"))
                try FileManager.default.moveItem(at: file("ec8.key"), to: file("ec.key"))
            }
            try makeAuthority("Home Lab EC CA", key: "ec.key", newRSA: false)
            let imported = try ImportedCertificate.read(files: [file("ca.pem"), file("ec.key")], password: nil)
            XCTAssertEqual(imported.keyKind, .ec, "\(curve) \(form)")
            try imported.save(in: directory)
            let signed = try WebStreamCertificates(directory: directory, names: ["test-mac.local"], addresses: [])
            XCTAssertTrue(trusts(signed.server, name: "test-mac.local", authority: try der("ca.pem")), "\(curve) \(form)")
        }
    }

    /// A server certificate is served as it is, with the chain that came with it, and links
    /// use a name it is for.
    func testAnImportedServerCertificateIsServedAsItIs() throws {
        try makeAuthority("Home Lab RSA CA")
        try makeServer()
        let imported = try ImportedCertificate.read(files: [file("leaf.pem"), file("leaf.key"), file("ca.pem")], password: nil)
        XCTAssertEqual(imported.kind, .server)
        XCTAssertEqual(imported.certificates, [try der("leaf.pem"), try der("ca.pem")], "its own first")
        try imported.save(in: directory)

        let served = try WebStreamCertificates(directory: directory, names: ["test-mac.local"], addresses: [])
        XCTAssertEqual(served.server, try der("leaf.pem"))
        XCTAssertEqual(served.chain, [try der("ca.pem")])
        XCTAssertEqual(served.authority, try der("ca.pem"), "the chain's top, an authority")
        guard case .importedServer(let names, _) = served.source else { return XCTFail("source \(served.source)") }
        XCTAssertEqual(names, ["mac.example.test", "192.0.2.7"])
        XCTAssertEqual(served.host(preferring: "test-mac.local"), "mac.example.test")
        XCTAssertTrue(trusts(served.server, name: "mac.example.test", authority: try der("ca.pem")))

        let alone = try ImportedCertificate.read(files: [file("leaf.pem"), file("leaf.key")], password: nil)
        try alone.save(in: directory)
        let bare = try WebStreamCertificates(directory: directory, names: ["test-mac.local"], addresses: [])
        XCTAssertNil(bare.authority, "nothing to hand out")
        XCTAssertTrue(bare.chain.isEmpty)
        XCTAssertEqual(bare.fingerprint.count, 32 * 3 - 1, "the server certificate's")
    }

    /// A .p12 file, old or new, opens with its password, and says when it is wrong or missing.
    func testAPKCS12FileOpensWithItsPassword() throws {
        try makeAuthority("Home Lab RSA CA")
        try openssl("pkcs12", "-export", "-in", "ca.pem", "-inkey", "ca.key", "-out", "aes.p12", "-passout", "pass:s3cret")
        try openssl("pkcs12", "-export", "-in", "ca.pem", "-inkey", "ca.key", "-out", "legacy.p12", "-passout", "pass:s3cret",
                    "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1")
        for name in ["aes.p12", "legacy.p12"] {
            let imported = try ImportedCertificate.read(files: [file(name)], password: "s3cret")
            XCTAssertEqual(imported.kind, .authority, name)
            XCTAssertEqual(imported.certificates.first, try der("ca.pem"), name)
            XCTAssertThrowsError(try ImportedCertificate.read(files: [file(name)], password: "wrong")) {
                XCTAssertEqual($0 as? CertificateImportError, .wrongPassword, name)
            }
            XCTAssertThrowsError(try ImportedCertificate.read(files: [file(name)], password: nil)) {
                XCTAssertEqual($0 as? CertificateImportError, .needsPassword, name)
            }
        }
    }

    /// curl's exit status and the HTTP status for `url`, trusting only `authority`. The run
    /// loop turns meanwhile, as the server answers on the main queue.
    private func curl(_ url: String, authority: URL, resolve: String? = nil) throws -> (exit: Int32, status: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "--cacert", authority.path]
            + (resolve.map { ["--resolve", $0] } ?? []) + [url]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        while process.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// A running server serves HTTPS under what is imported, from the moment it is, and under
    /// its own again after: curl trusting only the imported authority gets the page, then not.
    func testTheServerServesWhatIsImported() throws {
        try makeAuthority("Home Lab RSA CA")
        try makeServer()
        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 30000...39000) & ~1)!
        let server = WebStreamServer(port: port, directory: directory)
        defer { server.stop() }
        func started() {
            let deadline = Date().addingTimeInterval(5)
            while !server.isListening, server.lastError == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(server.isListening, server.lastError ?? "")
        }
        server.start()
        started()
        let secure = Int(port.rawValue) + 1
        let local = "https://localhost:\(secure)/watch"
        XCTAssertEqual(try curl(local, authority: file("ca.pem")).exit, 60, "not trusted before")

        try server.useCertificate(try ImportedCertificate.read(files: [file("ca.pem"), file("ca.key")], password: nil))
        started()
        XCTAssertNotNil(server.importedCertificate)
        let signed = try curl(local, authority: file("ca.pem"))
        XCTAssertEqual(signed.exit, 0)
        XCTAssertEqual(signed.status, "200")

        try server.useCertificate(try ImportedCertificate.read(files: [file("leaf.pem"), file("leaf.key"), file("ca.pem")],
                                                               password: nil))
        started()
        XCTAssertEqual(server.secureWatchURL.host, "mac.example.test")
        let served = try curl("https://mac.example.test:\(secure)/watch", authority: file("ca.pem"),
                              resolve: "mac.example.test:\(secure):127.0.0.1")
        XCTAssertEqual(served.exit, 0)
        XCTAssertEqual(served.status, "200")

        server.useOwnCertificate()
        started()
        XCTAssertNil(server.importedCertificate)
        XCTAssertEqual(try curl(local, authority: file("ca.pem")).exit, 60, "DAM's own again")
        try Data(XCTUnwrap(server.certificates?.authorityPEM).utf8).write(to: file("own.pem"))
        XCTAssertEqual(try curl(local, authority: file("own.pem")).status, "200")
    }

    /// What can't be imported is refused with the reason.
    func testWhatCannotBeImportedSaysWhy() throws {
        try makeAuthority("Home Lab RSA CA")
        try makeServer()
        func reason(_ names: String...) -> CertificateImportError? {
            do {
                _ = try ImportedCertificate.read(files: names.map(file), password: nil)
                return nil
            } catch {
                return error as? CertificateImportError
            }
        }
        XCTAssertEqual(reason("ca.pem"), .noKey)
        XCTAssertEqual(reason("ca.key"), .noCertificate)
        XCTAssertEqual(reason("ca.pem", "leaf.key"), .keyMatchesNoCertificate)
        XCTAssertEqual(reason("ca.pem", "ca.key", "leaf.key"), .severalKeys)
        try openssl("pkcs8", "-topk8", "-v2", "aes-256-cbc", "-in", "ca.key", "-out", "locked.key", "-passout", "pass:x")
        XCTAssertEqual(reason("ca.pem", "locked.key"), .encryptedKey)
        try "not a certificate".write(to: file("note.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(reason("note.txt"), .needsPassword, "anything not PEM nor DER is taken for a .p12 file")
        try "-----BEGIN NOTHING-----\n-----END NOTHING-----\n".write(to: file("empty.pem"), atomically: true, encoding: .utf8)
        XCTAssertEqual(reason("empty.pem"), .noCertificate)

        let key = try MoonlightCrypto.generatePrivateKey()
        let old = try MoonlightCrypto.certificate(key: key, subject: "old.example.test", days: 1,
                                                  now: Date().addingTimeInterval(-10 * 24 * 3600))
        let pem = MoonlightCrypto.pem(certificate: old) + "-----BEGIN RSA PRIVATE KEY-----\n" +
            (try MoonlightCrypto.exportPrivateKey(key)).base64EncodedString(options: .lineLength64Characters) +
            "\n-----END RSA PRIVATE KEY-----\n"
        XCTAssertThrowsError(try ImportedCertificate.read(pem: pem)) {
            guard case .expired = $0 as? CertificateImportError else { return XCTFail("\($0)") }
        }
    }
}
