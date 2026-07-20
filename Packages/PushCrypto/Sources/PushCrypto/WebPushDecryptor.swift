import CryptoKit
import Foundation

public enum WebPushDecryptor {
    public static func decrypt(
        body: Data,
        keyMaterial: WebPushKeyMaterial,
        maximumBodySize: Int = 4096
    ) throws -> Data {
        let record = try RFC8188Record(data: body, maximumBodySize: maximumBodySize)

        let receiverPrivateKey: P256.KeyAgreement.PrivateKey
        let senderPublicKey: P256.KeyAgreement.PublicKey
        do {
            receiverPrivateKey = try P256.KeyAgreement.PrivateKey(
                rawRepresentation: keyMaterial.privateKey
            )
            senderPublicKey = try P256.KeyAgreement.PublicKey(
                x963Representation: record.senderPublicKey
            )
        } catch {
            throw PushCryptoError.invalidPublicKey
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try receiverPrivateKey.sharedSecretFromKeyAgreement(
                with: senderPublicKey
            )
        } catch {
            throw PushCryptoError.invalidPublicKey
        }
        let ecdhSecret = sharedSecret.withUnsafeBytes { Data($0) }

        let keyPRK = hmacSHA256(
            key: keyMaterial.authenticationSecret,
            message: ecdhSecret
        )
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(keyMaterial.publicKey)
        keyInfo.append(record.senderPublicKey)
        let inputKeyMaterial = hkdfExpand(prk: keyPRK, info: keyInfo, count: 32)

        let contentPRK = hmacSHA256(key: record.salt, message: inputKeyMaterial)
        var contentEncryptionKeyInfo = Data("Content-Encoding: aes128gcm".utf8)
        contentEncryptionKeyInfo.append(0)
        let contentEncryptionKey = hkdfExpand(
            prk: contentPRK,
            info: contentEncryptionKeyInfo,
            count: 16
        )

        var nonceInfo = Data("Content-Encoding: nonce".utf8)
        nonceInfo.append(0)
        let nonceData = hkdfExpand(prk: contentPRK, info: nonceInfo, count: 12)

        let ciphertext = record.encryptedRecord.dropLast(RFC8188Record.tagLength)
        let tag = record.encryptedRecord.suffix(RFC8188Record.tagLength)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: contentEncryptionKey)
            )
            return try removeFinalRecordPadding(plaintext)
        } catch let error as PushCryptoError {
            throw error
        } catch {
            throw PushCryptoError.authenticationFailed
        }
    }

    private static func removeFinalRecordPadding(_ plaintext: Data) throws -> Data {
        guard !plaintext.isEmpty else { throw PushCryptoError.invalidPaddingDelimiter }
        var delimiterIndex = plaintext.endIndex
        while delimiterIndex > plaintext.startIndex {
            let candidate = plaintext.index(before: delimiterIndex)
            if plaintext[candidate] == 0 {
                delimiterIndex = candidate
                continue
            }
            guard plaintext[candidate] == 0x02 else {
                throw PushCryptoError.invalidPaddingDelimiter
            }
            return plaintext[..<candidate]
        }
        throw PushCryptoError.invalidPaddingDelimiter
    }

    private static func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        ))
    }

    private static func hkdfExpand(prk: Data, info: Data, count: Int) -> Data {
        precondition(count > 0 && count <= SHA256.Digest.byteCount * 255)
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < count {
            var message = previous
            message.append(info)
            message.append(counter)
            previous = hmacSHA256(key: prk, message: message)
            output.append(previous)
            counter &+= 1
        }
        return output.prefix(count)
    }
}
