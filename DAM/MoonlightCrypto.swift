//
//  MoonlightCrypto.swift
//
//  The cryptography Moonlight's pairing uses: a self-signed RSA certificate for the host,
//  AES-128-ECB under a key derived from the PIN, SHA-256, and RSA PKCS#1 v1.5 signatures.
//  Certificates are built and read with a minimal DER coder, as Security cannot create one.
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

enum MoonlightCryptoError: Error {
    case keyGeneration(String)
    case badCertificate
    case badKey
    case cipher(CCCryptorStatus)
    case signing(String)
}

enum MoonlightCrypto {

    // MARK: - Hashing and ciphers

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// The pairing key: the first 16 bytes of SHA-256 over the salt and the PIN's digits.
    static func pairingKey(salt: Data, pin: String) -> Data {
        sha256(salt + Data(pin.utf8)).prefix(16)
    }

    /// AES-128-ECB without padding; `data` must be a whole number of 16-byte blocks.
    static func aesECB(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), keyBuf.baseAddress, key.count, nil,
                            inBuf.baseAddress, data.count, outBuf.baseAddress, outCount, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw MoonlightCryptoError.cipher(status) }
        return out.prefix(moved)
    }

    // MARK: - Signatures

    static func sign(_ data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                    data as CFData, &error) else {
            throw MoonlightCryptoError.signing(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        return signature as Data
    }

    static func verify(_ signature: Data, of data: Data, certificateDER: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let key = SecCertificateCopyKey(certificate) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                     data as CFData, signature as CFData, nil)
    }

    // MARK: - Keys and certificates

    static func generatePrivateKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MoonlightCryptoError.keyGeneration(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        return key
    }

    /// An RSA private key in PKCS#1 form, as `exportPrivateKey` writes it.
    static func importPrivateKey(_ data: Data) throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                           kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil) else {
            throw MoonlightCryptoError.badKey
        }
        return key
    }

    static func exportPrivateKey(_ key: SecKey) throws -> Data {
        guard let data = SecKeyCopyExternalRepresentation(key, nil) else { throw MoonlightCryptoError.badKey }
        return data as Data
    }

    /// A self-signed X.509 v3 certificate for `key`, valid for 20 years from now.
    static func selfSignedCertificate(key: SecKey, commonName: String, now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw MoonlightCryptoError.badKey
        }
        let algorithm = DER.sequence(DER.oid(DER.sha256WithRSA), DER.null)
        let name = DER.sequence(DER.set(DER.sequence(DER.oid(DER.commonName), DER.utf8String(commonName))))
        let notAfter = now.addingTimeInterval(20 * 365 * 24 * 3600)
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(Data([2]))),
            DER.integer(serial),
            algorithm,
            name,
            DER.sequence(DER.utcTime(now.addingTimeInterval(-24 * 3600)), DER.utcTime(notAfter)),
            name,
            DER.sequence(DER.sequence(DER.oid(DER.rsaEncryption), DER.null), DER.bitString(publicKeyData))
        )
        return DER.sequence(tbs, algorithm, DER.bitString(try sign(tbs, with: key)))
    }

    /// The signature a certificate carries, which pairing hashes in as the certificate's
    /// fingerprint: the contents of its last field, a BIT STRING, after the unused-bits byte.
    static func signature(ofCertificate der: Data) throws -> Data {
        let bytes = [UInt8](der)
        guard let outer = DER.read(bytes, at: 0), outer.tag == 0x30,
              let tbs = DER.read(bytes, at: outer.content.lowerBound),
              let algorithm = DER.read(bytes, at: tbs.next),
              let signature = DER.read(bytes, at: algorithm.next), signature.tag == 0x03,
              signature.content.count > 1 else { throw MoonlightCryptoError.badCertificate }
        return Data(bytes[(signature.content.lowerBound + 1)..<signature.content.upperBound])
    }

    /// The certificate as PEM text.
    static func pem(certificate der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    /// The DER of the first certificate in PEM text.
    static func der(certificatePEM pem: String) throws -> Data {
        guard let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex),
              let der = Data(base64Encoded: String(pem[begin.upperBound..<end.lowerBound]),
                             options: .ignoreUnknownCharacters),
              SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw MoonlightCryptoError.badCertificate
        }
        return der
    }

    // MARK: - Hex

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// Just enough DER to write a self-signed certificate and read its signature back.
enum DER {
    static let sha256WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static let null = Data([0x05, 0x00])

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: Data...) -> Data { tlv(0x31, parts.reduce(Data(), +)) }
    static func oid(_ encoded: [UInt8]) -> Data { tlv(0x06, Data(encoded)) }
    static func utf8String(_ string: String) -> Data { tlv(0x0C, Data(string.utf8)) }
    static func bitString(_ data: Data) -> Data { tlv(0x03, Data([0]) + data) }
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xA0 | number, content) }

    /// A non-negative INTEGER from its big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        tlv(0x02, (bytes.first ?? 0) & 0x80 != 0 ? Data([0]) + bytes : bytes)
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }

    /// The element at `offset`: its tag, the range of its contents, and where the next begins.
    static func read(_ bytes: [UInt8], at offset: Int) -> (tag: UInt8, content: Range<Int>, next: Int)? {
        guard offset + 2 <= bytes.count else { return nil }
        var index = offset + 1
        var count = Int(bytes[index])
        index += 1
        if count & 0x80 != 0 {
            let width = count & 0x7F
            guard width > 0, width <= 4, index + width <= bytes.count else { return nil }
            count = bytes[index..<(index + width)].reduce(0) { $0 << 8 | Int($1) }
            index += width
        }
        guard index + count <= bytes.count else { return nil }
        return (bytes[offset], index..<(index + count), index + count)
    }
}
