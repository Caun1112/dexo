import Foundation

public enum PushCryptoError: Error, Equatable, Sendable {
    case invalidBase64URL
    case invalidPrivateKey
    case invalidPublicKey
    case invalidAuthenticationSecret
    case truncatedRecord
    case invalidRecordSize
    case invalidKeyIdentifier
    case authenticationFailed
    case invalidPaddingDelimiter
    case payloadTooLarge
}
