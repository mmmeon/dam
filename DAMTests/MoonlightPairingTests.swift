import XCTest
import Security
@testable import DAM

final class MoonlightPairingTests: XCTestCase {

    // MARK: - A client pairing as Moonlight does

    private struct Party {
        let key: SecKey
        let certificate: Data

        static func make(_ name: String) throws -> Party {
            let key = try MoonlightCrypto.generatePrivateKey()
            return Party(key: key, certificate: try MoonlightCrypto.certificate(key: key, subject: name, days: 20 * 365))
        }
    }

    private struct Outcome {
        /// Moonlight's check that the host knew the PIN.
        let clientSawRightPIN: Bool
        /// Moonlight's check that the host holds its certificate's key.
        let clientVerifiedHost: Bool
        /// The host's check of the client, which decides the pairing.
        let hostVerifiedClient: Bool
    }

    /// Runs Moonlight's side of the four HTTP steps against `MoonlightPairing`, as
    /// moonlight-qt's NvPairingManager::pair does with a GameStream 7 host (SHA-256).
    private func pair(clientPIN: String, hostPIN: String) throws -> Outcome {
        let client = try Party.make("NVIDIA GameStream Client")
        let host = try Party.make("DAM GameStream Host")
        let salt = MoonlightPairing.randomBytes(16)
        let key = MoonlightCrypto.pairingKey(salt: salt, pin: clientPIN)

        // getservercert
        let pairing = try MoonlightPairing(clientCertificatePEM: MoonlightCrypto.pem(certificate: client.certificate),
                                           salt: salt, serverCertificate: host.certificate, serverKey: host.key)
        pairing.enterPIN(hostPIN)

        // clientchallenge
        let challenge = MoonlightPairing.randomBytes(16)
        let response = try MoonlightCrypto.aesECB(
            try pairing.respond(toClientChallenge: try MoonlightCrypto.aesECB(challenge, key: key, encrypt: true)),
            key: key, encrypt: false)
        XCTAssertEqual(response.count, 48)
        let hostHash = response.prefix(32)
        let hostChallenge = response.dropFirst(32).prefix(16)

        // serverchallengeresp
        let clientSecret = MoonlightPairing.randomBytes(16)
        let clientHash = MoonlightCrypto.sha256(Data(hostChallenge)
            + (try MoonlightCrypto.signature(ofCertificate: client.certificate)) + clientSecret)
        let pairingSecret = try pairing.pairingSecret(
            forServerChallengeResponse: try MoonlightCrypto.aesECB(clientHash, key: key, encrypt: true))
        let hostSecret = pairingSecret.prefix(16)
        let hostSignature = pairingSecret.dropFirst(16)
        let clientVerifiedHost = MoonlightCrypto.verify(Data(hostSignature), of: Data(hostSecret),
                                                        certificateDER: host.certificate)
        let expected = MoonlightCrypto.sha256(challenge
            + (try MoonlightCrypto.signature(ofCertificate: host.certificate)) + hostSecret)

        // clientpairingsecret
        let hostVerifiedClient = try pairing.verify(
            clientPairingSecret: clientSecret + (try MoonlightCrypto.sign(clientSecret, with: client.key)))
        return Outcome(clientSawRightPIN: expected == hostHash, clientVerifiedHost: clientVerifiedHost,
                       hostVerifiedClient: hostVerifiedClient)
    }

    func testPairsWithTheRightPIN() throws {
        let outcome = try pair(clientPIN: "4821", hostPIN: "4821")
        XCTAssertTrue(outcome.clientSawRightPIN)
        XCTAssertTrue(outcome.clientVerifiedHost)
        XCTAssertTrue(outcome.hostVerifiedClient)
    }

    func testRefusesAWrongPIN() throws {
        let outcome = try pair(clientPIN: "4821", hostPIN: "4812")
        XCTAssertFalse(outcome.clientSawRightPIN)
        XCTAssertFalse(outcome.hostVerifiedClient)
    }

    func testRefusesStepsOutOfOrder() throws {
        let client = try Party.make("client")
        let host = try Party.make("host")
        let pairing = try MoonlightPairing(clientCertificatePEM: MoonlightCrypto.pem(certificate: client.certificate),
                                           salt: Data(count: 16), serverCertificate: host.certificate,
                                           serverKey: host.key)
        // No PIN yet.
        XCTAssertThrowsError(try pairing.respond(toClientChallenge: Data(count: 16))) {
            XCTAssertEqual($0 as? MoonlightPairing.Failure, .outOfOrder)
        }
        pairing.enterPIN("0000")
        XCTAssertThrowsError(try pairing.pairingSecret(forServerChallengeResponse: Data(count: 32)))
        XCTAssertThrowsError(try pairing.verify(clientPairingSecret: Data(count: 32)))
    }

    func testRefusesASaltOfTheWrongSize() throws {
        let party = try Party.make("p")
        XCTAssertThrowsError(try MoonlightPairing(clientCertificatePEM: MoonlightCrypto.pem(certificate: party.certificate),
                                                  salt: Data(count: 8), serverCertificate: party.certificate,
                                                  serverKey: party.key))
    }

    // MARK: - Certificates

    func testCertificateIsSignedByItsOwnKey() throws {
        let party = try Party.make("DAM GameStream Host")
        XCTAssertNotNil(SecCertificateCreateWithData(nil, party.certificate as CFData))
        let bytes = [UInt8](party.certificate)
        let outer = try XCTUnwrap(DER.read(bytes, at: 0))
        let tbs = try XCTUnwrap(DER.read(bytes, at: outer.content.lowerBound))
        let signed = Data(bytes[outer.content.lowerBound..<tbs.next])
        XCTAssertTrue(MoonlightCrypto.verify(try MoonlightCrypto.signature(ofCertificate: party.certificate),
                                             of: signed, certificateDER: party.certificate))
    }

    func testCertificateNamesTheHost() throws {
        let party = try Party.make("DAM GameStream Host")
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, party.certificate as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "DAM GameStream Host")
    }

    func testPEMRoundTrips() throws {
        let party = try Party.make("p")
        XCTAssertEqual(try MoonlightCrypto.der(certificatePEM: MoonlightCrypto.pem(certificate: party.certificate)),
                       party.certificate)
    }

    func testPrivateKeyRoundTrips() throws {
        let party = try Party.make("p")
        let restored = try MoonlightCrypto.importPrivateKey(try MoonlightCrypto.exportPrivateKey(party.key))
        let message = Data("hello".utf8)
        XCTAssertTrue(MoonlightCrypto.verify(try MoonlightCrypto.sign(message, with: restored), of: message,
                                             certificateDER: party.certificate))
    }

    // MARK: - Primitives

    func testAESMatchesTheFIPS197Example() throws {
        let key = try XCTUnwrap(MoonlightCrypto.data(hex: "000102030405060708090A0B0C0D0E0F"))
        let plain = try XCTUnwrap(MoonlightCrypto.data(hex: "00112233445566778899AABBCCDDEEFF"))
        let cipher = try MoonlightCrypto.aesECB(plain, key: key, encrypt: true)
        XCTAssertEqual(MoonlightCrypto.hex(cipher), "69C4E0D86A7B0430D8CDB78070B4C55A")
        XCTAssertEqual(try MoonlightCrypto.aesECB(cipher, key: key, encrypt: false), plain)
    }

    func testHexRoundTripsAndRejectsJunk() {
        XCTAssertEqual(MoonlightCrypto.data(hex: "00ff10").map(MoonlightCrypto.hex), "00FF10")
        XCTAssertNil(MoonlightCrypto.data(hex: "abc"))
        XCTAssertNil(MoonlightCrypto.data(hex: "zz"))
    }

    func testDERLengthsUseTheLongFormPast127() {
        XCTAssertEqual(DER.length(127), Data([0x7F]))
        XCTAssertEqual(DER.length(128), Data([0x81, 0x80]))
        XCTAssertEqual(DER.length(300), Data([0x82, 0x01, 0x2C]))
    }

    func testDERIntegersTakeAsFewBytesAsTheyCan() {
        XCTAssertEqual(DER.integer(Data([2])), Data([0x02, 0x01, 0x02]))
        XCTAssertEqual(DER.integer(Data([0x00, 0x12, 0x34])), Data([0x02, 0x02, 0x12, 0x34]), "a zero it need not keep")
        XCTAssertEqual(DER.integer(Data([0x00, 0x00, 0x80])), Data([0x02, 0x02, 0x00, 0x80]), "one zero kept, for the sign")
        XCTAssertEqual(DER.integer(Data([0x80])), Data([0x02, 0x02, 0x00, 0x80]))
        XCTAssertEqual(DER.integer(Data([0x00, 0x00])), Data([0x02, 0x01, 0x00]))
        XCTAssertEqual(DER.integer(Data()), Data([0x02, 0x01, 0x00]))
    }

    func testASerialWithAZeroItNeedNotKeepIsFoundOut() throws {
        func certificate(serial: Data) -> Data {
            DER.sequence(DER.sequence(DER.explicit(0, DER.integer(Data([2]))), serial, DER.null))
        }
        XCTAssertFalse(DER.hasMinimalSerial(certificate(serial: DER.tlv(0x02, Data([0x00, 0x12, 0x34])))))
        XCTAssertTrue(DER.hasMinimalSerial(certificate(serial: DER.tlv(0x02, Data([0x00, 0x92, 0x34])))))
        XCTAssertTrue(DER.hasMinimalSerial(certificate(serial: DER.integer(Data([0x00, 0x12, 0x34])))))
        XCTAssertTrue(DER.hasMinimalSerial(try Party.make("p").certificate))
    }

    func testValidityPast2049IsAGeneralizedTime() throws {
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        XCTAssertEqual(DER.time(date("2049-12-31T23:59:59Z")), DER.tlv(0x17, Data("491231235959Z".utf8)))
        XCTAssertEqual(DER.time(date("2050-01-01T00:00:00Z")), DER.tlv(0x18, Data("20500101000000Z".utf8)))

        // A certificate made in 2035 for 20 years ends in 2055, not 1955.
        let key = try MoonlightCrypto.generatePrivateKey()
        let made = date("2035-06-01T00:00:00Z")
        let der = try MoonlightCrypto.certificate(key: key, subject: "p", days: 20 * 365, now: made)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let values = try XCTUnwrap(SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil)
                                       as? [CFString: [CFString: Any]])
        let notAfter = try XCTUnwrap(values[kSecOIDX509V1ValidityNotAfter]?[kSecPropertyKeyValue] as? NSNumber)
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: notAfter.doubleValue).timeIntervalSince(made),
                       Double(20 * 365 * 24 * 3600), accuracy: 1)
    }

    func testXMLEscapesText() {
        XCTAssertEqual(MoonlightHost.escape("A & <B>"), "A &amp; &lt;B&gt;")
        XCTAssertTrue(MoonlightHost.xml(["paired": "1"]).contains("<root status_code=\"200\"><paired>1</paired></root>"))
    }
}
