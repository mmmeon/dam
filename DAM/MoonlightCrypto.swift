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

    /// AES-128-CBC with PKCS#7 padding, as Moonlight's audio is encrypted.
    static func aesCBC(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBuf.baseAddress, key.count, ivBuf.baseAddress,
                                inBuf.baseAddress, data.count, outBuf.baseAddress, outCount, &moved)
                    }
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

    /// The kinds of private key DAM keeps: its own are RSA; one brought in may be either.
    enum KeyKind: String, Codable {
        case rsa
        case ec
    }

    static func generatePrivateKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MoonlightCryptoError.keyGeneration(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        return key
    }

    /// A private key as `exportPrivateKey` writes it: PKCS#1 for RSA, ANSI X9.63 for EC.
    static func importPrivateKey(_ data: Data, kind: KeyKind = .rsa) throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kind == .rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
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

    /// An X.509 v3 certificate for `key`'s public half (an RSA key), signed by `issuerKey`
    /// (`key` itself when nil), from a day ago for `days`, with `extensions` as made by
    /// `DER.extension`. The issuer is `issuerName`, an issuer certificate's subject as it is,
    /// or else the common name `issuer`; the signature is RSA or ECDSA, as `issuerKey` is.
    static func certificate(key: SecKey, subject: String, issuer: String? = nil, issuerName: Data? = nil,
                            issuerKey: SecKey? = nil, days: Int, extensions: [Data] = [],
                            now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw MoonlightCryptoError.badKey
        }
        let signer = issuerKey ?? key
        let (algorithm, signing) = certificateSignature(for: signer)
        func name(_ commonName: String) -> Data {
            DER.sequence(DER.set(DER.sequence(DER.oid(DER.commonName), DER.utf8String(commonName))))
        }
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F
        var fields = DER.explicit(0, DER.integer(Data([2]))) + DER.integer(serial) + algorithm
            + (issuerName ?? name(issuer ?? subject))
            + DER.sequence(DER.time(now.addingTimeInterval(-24 * 3600)),
                           DER.time(now.addingTimeInterval(Double(days) * 24 * 3600)))
            + name(subject)
            + DER.sequence(DER.sequence(DER.oid(DER.rsaEncryption), DER.null), DER.bitString(publicKeyData))
        if !extensions.isEmpty { fields += DER.explicit(3, DER.tlv(0x30, extensions.reduce(Data(), +))) }
        let tbs = DER.tlv(0x30, fields)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(signer, signing, tbs as CFData, &error) as Data? else {
            throw MoonlightCryptoError.signing(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        return DER.sequence(tbs, algorithm, DER.bitString(signature))
    }

    /// How `key` signs a certificate: the signature's AlgorithmIdentifier, and Security's
    /// name for it. SHA-256 with RSA; ECDSA with the hash that matches the curve.
    static func certificateSignature(for key: SecKey) -> (identifier: Data, algorithm: SecKeyAlgorithm) {
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        guard (attributes?[kSecAttrKeyType] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String) else {
            return (DER.sequence(DER.oid(DER.sha256WithRSA), DER.null), .rsaSignatureMessagePKCS1v15SHA256)
        }
        switch (attributes?[kSecAttrKeySizeInBits] as? Int) ?? 256 {
        case ...256: return (DER.sequence(DER.oid(DER.ecdsaWithSHA256)), .ecdsaSignatureMessageX962SHA256)
        case ...384: return (DER.sequence(DER.oid(DER.ecdsaWithSHA384)), .ecdsaSignatureMessageX962SHA384)
        default: return (DER.sequence(DER.oid(DER.ecdsaWithSHA512)), .ecdsaSignatureMessageX962SHA512)
        }
    }

    /// Whether `key` is the private half of `certificate`'s public key.
    static func key(_ key: SecKey, matches certificate: SecCertificate) -> Bool {
        guard let own = SecKeyCopyPublicKey(key).flatMap({ SecKeyCopyExternalRepresentation($0, nil) as Data? }),
              let theirs = SecCertificateCopyKey(certificate).flatMap({ SecKeyCopyExternalRepresentation($0, nil) as Data? })
        else { return false }
        return own == theirs
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

    /// The blocks of PEM text in order: each one's label ("CERTIFICATE", "PRIVATE KEY"…),
    /// its DER, and its text from BEGIN to END. What lies between blocks is skipped.
    static func pemBlocks(_ text: String) -> [(label: String, der: Data, text: String)] {
        var blocks: [(String, Data, String)] = []
        var rest = text[...]
        while let begin = rest.range(of: "-----BEGIN "),
              let labelEnd = rest.range(of: "-----", range: begin.upperBound..<rest.endIndex) {
            let label = String(rest[begin.upperBound..<labelEnd.lowerBound])
            guard let end = rest.range(of: "-----END \(label)-----", range: labelEnd.upperBound..<rest.endIndex) else { break }
            // Headers such as Proc-Type stand apart from the base64 by a blank line.
            let body = rest[labelEnd.upperBound..<end.lowerBound]
            let base64 = body.components(separatedBy: "\n").filter { !$0.contains(":") }.joined()
            if let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                blocks.append((label, der, String(rest[begin.lowerBound..<end.upperBound])))
            }
            rest = rest[end.upperBound...]
        }
        return blocks
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

/// Just enough DER to write a certificate, and to read back its signature and the fields
/// a certificate brought in is checked by.
enum DER {
    static let sha256WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    static let ecdsaWithSHA384: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03]
    static let ecdsaWithSHA512: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04]
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static let null = Data([0x05, 0x00])
    static let subjectAltName: [UInt8] = [0x55, 0x1D, 0x11]
    static let basicConstraints: [UInt8] = [0x55, 0x1D, 0x13]
    static let keyUsage: [UInt8] = [0x55, 0x1D, 0x0F]
    static let extendedKeyUsage: [UInt8] = [0x55, 0x1D, 0x25]
    static let subjectKeyIdentifier: [UInt8] = [0x55, 0x1D, 0x0E]
    static let authorityKeyIdentifier: [UInt8] = [0x55, 0x1D, 0x23]
    static let serverAuth: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]

    /// What a certificate says of itself, as far as DAM needs it.
    struct Certificate {
        /// The subject Name as it is written, to be another certificate's issuer.
        var subject = Data()
        var issuer = Data()
        /// Whether its basic constraints make it a certificate authority.
        var isAuthority = false
        /// Whether its key usage, if it has one, allows signing certificates.
        var maySignCertificates = true
        /// Its subject key identifier, or the SHA-1 of its public key as RFC 5280 suggests.
        var keyIdentifier = Data()
        /// Its alternative DNS names and IP addresses.
        var names: [String] = []
        var addresses: [[UInt8]] = []
    }

    /// Reads `der`'s subject, issuer, public key and extensions; nil if it isn't a certificate.
    static func certificate(_ der: Data) -> Certificate? {
        let bytes = [UInt8](der)
        guard let outer = read(bytes, at: 0), outer.tag == 0x30,
              let tbs = read(bytes, at: outer.content.lowerBound), tbs.tag == 0x30,
              var field = read(bytes, at: tbs.content.lowerBound) else { return nil }
        if field.tag == 0xA0 { guard let serial = read(bytes, at: field.next) else { return nil }; field = serial }
        // After the serial: the signature's algorithm, the issuer, validity, subject and key.
        var parts: [(tag: UInt8, content: Range<Int>, next: Int)] = []
        var at = field.next
        for _ in 0..<5 {
            guard let part = read(bytes, at: at) else { return nil }
            parts.append(part)
            at = part.next
        }
        let whole = { (part: (tag: UInt8, content: Range<Int>, next: Int), start: Int) in Data(bytes[start..<part.next]) }
        var certificate = Certificate()
        certificate.issuer = whole(parts[1], parts[0].next)
        certificate.subject = whole(parts[3], parts[2].next)
        let key = parts[4]
        if let algorithm = read(bytes, at: key.content.lowerBound), let bits = read(bytes, at: algorithm.next),
           bits.tag == 0x03, bits.content.count > 1 {
            certificate.keyIdentifier = Data(Insecure.SHA1.hash(data: bytes[(bits.content.lowerBound + 1)..<bits.content.upperBound]))
        }
        // Optional unique IDs, then the extensions, [3].
        while at < tbs.content.upperBound, let item = read(bytes, at: at) {
            at = item.next
            guard item.tag == 0xA3, let list = read(bytes, at: item.content.lowerBound) else { continue }
            var next = list.content.lowerBound
            while next < list.content.upperBound, let ext = read(bytes, at: next) {
                next = ext.next
                guard let id = read(bytes, at: ext.content.lowerBound), id.tag == 0x06 else { continue }
                var value = read(bytes, at: id.next)
                if value?.tag == 0x01, let after = value?.next { value = read(bytes, at: after) }
                guard let value, value.tag == 0x04, let inner = read(bytes, at: value.content.lowerBound) else { continue }
                let content = { (range: Range<Int>) in Array(bytes[range]) }
                switch content(id.content) {
                case basicConstraints:
                    if inner.tag == 0x30, !inner.content.isEmpty, let ca = read(bytes, at: inner.content.lowerBound), ca.tag == 0x01,
                       ca.content.count == 1 {
                        certificate.isAuthority = bytes[ca.content.lowerBound] != 0
                    }
                case keyUsage:
                    // keyCertSign is bit 5: 0x04 of the first byte after the unused-bits count.
                    if inner.tag == 0x03, inner.content.count > 1 {
                        certificate.maySignCertificates = bytes[inner.content.lowerBound + 1] & 0x04 != 0
                    }
                case subjectKeyIdentifier:
                    if inner.tag == 0x04 { certificate.keyIdentifier = Data(content(inner.content)) }
                case subjectAltName:
                    var name = inner.content.lowerBound
                    while name < inner.content.upperBound, let alternative = read(bytes, at: name) {
                        name = alternative.next
                        if alternative.tag == 0x82, let dns = String(bytes: content(alternative.content), encoding: .ascii) {
                            certificate.names.append(dns)
                        } else if alternative.tag == 0x87 {
                            certificate.addresses.append(content(alternative.content))
                        }
                    }
                default:
                    break
                }
            }
        }
        return certificate
    }

    /// An authority key identifier naming the issuer's key by its identifier.
    static func authorityKeyIdentifier(_ identifier: Data) -> Data {
        `extension`(authorityKeyIdentifier, sequence(tlv(0x80, identifier)))
    }

    /// A certificate extension: its OID, whether it is critical, and its value's DER.
    static func `extension`(_ oid: [UInt8], critical: Bool = false, _ value: Data) -> Data {
        sequence(DER.oid(oid) + (critical ? Data([0x01, 0x01, 0xFF]) : Data()) + tlv(0x04, value))
    }

    /// A certificate authority's: may sign certificates, and nothing else.
    static func authorityExtensions() -> [Data] {
        [`extension`(basicConstraints, critical: true, sequence(Data([0x01, 0x01, 0xFF]))),
         // keyCertSign and cRLSign: bits 5 and 6.
         `extension`(keyUsage, critical: true, Data([0x03, 0x02, 0x01, 0x06]))]
    }

    /// A TLS server's, for these host names and addresses (4 or 16 bytes each).
    static func serverExtensions(names: [String], addresses: [[UInt8]]) -> [Data] {
        let alternatives = names.map { tlv(0x82, Data($0.utf8)) } + addresses.map { tlv(0x87, Data($0)) }
        return [`extension`(basicConstraints, critical: true, sequence()),
                // digitalSignature and keyEncipherment: bits 0 and 2.
                `extension`(keyUsage, critical: true, Data([0x03, 0x02, 0x05, 0xA0])),
                `extension`(extendedKeyUsage, sequence(oid(serverAuth))),
                `extension`(subjectAltName, tlv(0x30, alternatives.reduce(Data(), +)))]
    }

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

    /// A non-negative INTEGER from its big-endian bytes, in as few as DER allows: leading
    /// zeros dropped, but for one where the top bit would otherwise read as a minus sign, or
    /// nothing would be left.
    /// OpenSSL and BoringSSL refuse a certificate whose serial keeps a zero it need not.
    static func integer(_ bytes: Data) -> Data {
        let trimmed = Data(bytes.drop { $0 == 0 })
        return tlv(0x02, (trimmed.first ?? 0x80) & 0x80 != 0 ? Data([0]) + trimmed : trimmed)
    }

    /// Whether a certificate's serial is written in as few bytes as DER allows; one made
    /// before `integer` saw to it may not be (about one in 256).
    static func hasMinimalSerial(_ certificate: Data) -> Bool {
        let bytes = [UInt8](certificate)
        guard let outer = read(bytes, at: 0), let tbs = read(bytes, at: outer.content.lowerBound),
              let version = read(bytes, at: tbs.content.lowerBound) else { return false }
        // The version is optional; the serial follows it if it is there.
        let serial = version.tag == 0xA0 ? read(bytes, at: version.next) : version
        guard let serial, serial.tag == 0x02, !serial.content.isEmpty else { return false }
        return serial.content.count == 1 || bytes[serial.content.lowerBound] != 0
            || bytes[serial.content.lowerBound + 1] & 0x80 != 0
    }

    /// A validity time as X.509 has it: UTCTime, with two digits of year, through 2049, and
    /// GeneralizedTime from 2050, which UTCTime would read as 1950.
    static func time(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let utc = (1950...2049).contains(calendar.component(.year, from: date))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = utc ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tlv(utc ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
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
