//
//  MoonlightPairing.swift
//
//  The host's side of Moonlight's PIN pairing, one client at a time. Moonlight sends its
//  certificate and a salt; the user types the PIN Moonlight shows; then each side proves
//  it knows the PIN and holds its certificate's key over three challenge round trips, all
//  encrypted under a key derived from the salt and PIN. A wrong PIN shows up as a hash
//  that does not match, which Moonlight reports and the host refuses at the last step.
//

import Foundation
import Security

final class MoonlightPairing {

    enum Failure: Error, Equatable {
        /// A step arrived before the one it follows.
        case outOfOrder
        /// A parameter was missing or the wrong size.
        case badParameter
    }

    /// The certificate Moonlight pairs with, kept once pairing succeeds.
    let clientCertificate: Data
    private let clientSignature: Data
    private let salt: Data
    private let serverCertificate: Data
    private let serverSignature: Data
    private let serverKey: SecKey

    private var key: Data?
    private var serverSecret: Data?
    private var serverChallenge: Data?
    private var clientHash: Data?

    /// Starts pairing with the client whose PEM certificate and salt came in the first request.
    init(clientCertificatePEM: String, salt: Data, serverCertificate: Data, serverKey: SecKey) throws {
        guard salt.count == 16 else { throw Failure.badParameter }
        clientCertificate = try MoonlightCrypto.der(certificatePEM: clientCertificatePEM)
        clientSignature = try MoonlightCrypto.signature(ofCertificate: clientCertificate)
        self.salt = salt
        self.serverCertificate = serverCertificate
        serverSignature = try MoonlightCrypto.signature(ofCertificate: serverCertificate)
        self.serverKey = serverKey
    }

    /// Takes the PIN the user typed.
    func enterPIN(_ pin: String) {
        key = MoonlightCrypto.pairingKey(salt: salt, pin: pin)
    }

    /// Answers the client's encrypted challenge: a hash proving the host knows the PIN and
    /// its certificate, followed by the host's own challenge, encrypted.
    func respond(toClientChallenge encrypted: Data) throws -> Data {
        guard let key, serverSecret == nil else { throw Failure.outOfOrder }
        guard encrypted.count == 16 else { throw Failure.badParameter }
        let challenge = try MoonlightCrypto.aesECB(encrypted, key: key, encrypt: false)
        let secret = Self.randomBytes(16)
        let ownChallenge = Self.randomBytes(16)
        serverSecret = secret
        serverChallenge = ownChallenge
        let hash = MoonlightCrypto.sha256(challenge + serverSignature + secret)
        return try MoonlightCrypto.aesECB(hash + ownChallenge, key: key, encrypt: true)
    }

    /// Takes the client's encrypted answer to the host's challenge, checked in the last step,
    /// and returns the host's secret signed with its key.
    func pairingSecret(forServerChallengeResponse encrypted: Data) throws -> Data {
        guard let key, let serverSecret, clientHash == nil else { throw Failure.outOfOrder }
        guard encrypted.count == 32 else { throw Failure.badParameter }
        clientHash = try MoonlightCrypto.aesECB(encrypted, key: key, encrypt: false)
        return serverSecret + (try MoonlightCrypto.sign(serverSecret, with: serverKey))
    }

    /// Whether the client's secret and its signature prove it knew the PIN and holds the key
    /// of the certificate it sent.
    func verify(clientPairingSecret: Data) throws -> Bool {
        guard let serverChallenge, let clientHash else { throw Failure.outOfOrder }
        guard clientPairingSecret.count > 16 else { throw Failure.badParameter }
        let secret = clientPairingSecret.prefix(16)
        let signature = clientPairingSecret.dropFirst(16)
        return MoonlightCrypto.sha256(serverChallenge + clientSignature + secret) == clientHash
            && MoonlightCrypto.verify(Data(signature), of: Data(secret), certificateDER: clientCertificate)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }
}
