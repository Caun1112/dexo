import Foundation

struct RFC8188Record: Sendable {
    static let headerLength = 21
    static let tagLength = 16

    let salt: Data
    let recordSize: UInt32
    let senderPublicKey: Data
    let encryptedRecord: Data

    init(data: Data, maximumBodySize: Int) throws {
        guard data.count <= maximumBodySize else { throw PushCryptoError.payloadTooLarge }
        guard data.count >= Self.headerLength + 1 + Self.tagLength else {
            throw PushCryptoError.truncatedRecord
        }

        salt = data.prefix(16)
        recordSize = data[16 ..< 20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard recordSize > Self.tagLength + 1 else { throw PushCryptoError.invalidRecordSize }

        let keyIdentifierLength = Int(data[20])
        guard keyIdentifierLength == 65 else { throw PushCryptoError.invalidKeyIdentifier }
        let keyStart = Self.headerLength
        let keyEnd = keyStart + keyIdentifierLength
        guard data.count >= keyEnd + Self.tagLength + 1 else {
            throw PushCryptoError.truncatedRecord
        }

        senderPublicKey = data[keyStart ..< keyEnd]
        guard senderPublicKey.first == 0x04 else { throw PushCryptoError.invalidPublicKey }
        encryptedRecord = data[keyEnd...]
        guard encryptedRecord.count <= Int(recordSize) else {
            throw PushCryptoError.invalidRecordSize
        }
    }
}
