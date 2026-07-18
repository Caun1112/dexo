import Foundation
import Security

@available(iOS 17.0, *)
nonisolated enum WebViewProxyX509Builder {
    enum BuilderError: Error {
        case invalidHost
        case randomGenerationFailed(OSStatus)
        case invalidPublicKey
    }

    private static let commonNameOID = Data([0x06, 0x03, 0x55, 0x04, 0x03])
    private static let organizationNameOID = Data([0x06, 0x03, 0x55, 0x04, 0x0A])
    private static let countryNameOID = Data([0x06, 0x03, 0x55, 0x04, 0x06])
    private static let ecdsaWithSHA256OID = Data([
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02,
    ])
    private static let ecPublicKeyOID = Data([
        0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    ])
    private static let prime256v1OID = Data([
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
    ])
    private static let basicConstraintsOID = Data([0x06, 0x03, 0x55, 0x1D, 0x13])
    private static let keyUsageOID = Data([0x06, 0x03, 0x55, 0x1D, 0x0F])
    private static let extendedKeyUsageOID = Data([0x06, 0x03, 0x55, 0x1D, 0x25])
    private static let subjectAlternativeNameOID = Data([0x06, 0x03, 0x55, 0x1D, 0x11])
    private static let serverAuthenticationOID = Data([
        0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01,
    ])

    static func makeTBSCertificate(host: String, publicKeyBytes: Data) throws -> Data {
        guard !host.isEmpty,
              host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
              publicKeyBytes.count == 65,
              publicKeyBytes.first == 0x04
        else {
            if publicKeyBytes.count != 65 || publicKeyBytes.first != 0x04 {
                throw BuilderError.invalidPublicKey
            }
            throw BuilderError.invalidHost
        }

        var serial = Data(count: 16)
        let randomStatus = serial.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw BuilderError.randomGenerationFailed(randomStatus)
        }
        serial[serial.startIndex] &= 0x7F
        if serial.allSatisfy({ $0 == 0 }) {
            serial[serial.index(before: serial.endIndex)] = 1
        }

        let now = Date()
        let notBefore = now.addingTimeInterval(-24 * 60 * 60)
        let notAfter = now.addingTimeInterval(365 * 24 * 60 * 60)

        let version = explicit(tag: 0, integer(Data([0x02])))
        let signatureAlgorithm = sequence([ecdsaWithSHA256OID])
        let issuer = distinguishedName([
            (commonNameOID, "DOH Proxy CA"),
            (organizationNameOID, "DOH Proxy"),
            (countryNameOID, "CN"),
        ])
        let validity = sequence([utcTime(notBefore), utcTime(notAfter)])
        let subject = distinguishedName([(commonNameOID, host)])
        let subjectPublicKeyInfo = sequence([
            sequence([ecPublicKeyOID, prime256v1OID]),
            bitString(publicKeyBytes),
        ])

        let basicConstraints = extensionValue(
            oid: basicConstraintsOID,
            critical: true,
            value: sequence([])
        )
        let keyUsage = extensionValue(
            oid: keyUsageOID,
            critical: true,
            value: bitString(Data([0xA0]), unusedBits: 5)
        )
        let extendedKeyUsage = extensionValue(
            oid: extendedKeyUsageOID,
            critical: false,
            value: sequence([serverAuthenticationOID])
        )
        let subjectAlternativeName = extensionValue(
            oid: subjectAlternativeNameOID,
            critical: false,
            value: sequence([tagged(tag: 0x82, content: Data(host.utf8))])
        )
        let extensions = explicit(
            tag: 3,
            sequence([basicConstraints, keyUsage, extendedKeyUsage, subjectAlternativeName])
        )

        return sequence([
            version,
            integer(serial),
            signatureAlgorithm,
            issuer,
            validity,
            subject,
            subjectPublicKeyInfo,
            extensions,
        ])
    }

    static func makeCertificate(tbsCertificate: Data, signature: Data) -> Data {
        sequence([
            tbsCertificate,
            sequence([ecdsaWithSHA256OID]),
            bitString(signature),
        ])
    }

    private static func distinguishedName(_ attributes: [(Data, String)]) -> Data {
        sequence(attributes.map { oid, value in
            set([sequence([oid, utf8String(value)])])
        })
    }

    private static func extensionValue(
        oid: Data,
        critical: Bool,
        value: Data
    ) -> Data {
        var fields = [oid]
        if critical {
            fields.append(Data([0x01, 0x01, 0xFF]))
        }
        fields.append(tagged(tag: 0x04, content: value))
        return sequence(fields)
    }

    private static func sequence(_ values: [Data]) -> Data {
        tagged(tag: 0x30, content: values.reduce(into: Data()) { $0.append($1) })
    }

    private static func set(_ values: [Data]) -> Data {
        tagged(tag: 0x31, content: values.reduce(into: Data()) { $0.append($1) })
    }

    private static func explicit(tag: UInt8, _ value: Data) -> Data {
        tagged(tag: 0xA0 | tag, content: value)
    }

    private static func integer(_ bytes: Data) -> Data {
        var normalized = bytes
        while normalized.count > 1, normalized.first == 0 {
            normalized.removeFirst()
        }
        if let first = normalized.first, first & 0x80 != 0 {
            normalized.insert(0, at: normalized.startIndex)
        }
        return tagged(tag: 0x02, content: normalized)
    }

    private static func utf8String(_ value: String) -> Data {
        tagged(tag: 0x0C, content: Data(value.utf8))
    }

    private static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(tag: 0x17, content: Data(formatter.string(from: date).utf8))
    }

    private static func bitString(_ bytes: Data, unusedBits: UInt8 = 0) -> Data {
        var content = Data([unusedBits])
        content.append(bytes)
        return tagged(tag: 0x03, content: content)
    }

    private static func tagged(tag: UInt8, content: Data) -> Data {
        var data = Data([tag])
        data.append(encodedLength(content.count))
        data.append(content)
        return data
    }

    private static func encodedLength(_ length: Int) -> Data {
        precondition(length >= 0)
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
