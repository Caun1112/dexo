import CryptoKit
import Foundation
import Security

public struct WebPushKeyMaterial: Codable, Equatable, Sendable {
    public let privateKey: Data
    public let publicKey: Data
    public let authenticationSecret: Data

    public init(privateKey: Data, publicKey: Data, authenticationSecret: Data) throws {
        guard privateKey.count == 32 else { throw PushCryptoError.invalidPrivateKey }
        guard publicKey.count == 65, publicKey.first == 0x04 else {
            throw PushCryptoError.invalidPublicKey
        }
        guard authenticationSecret.count == 16 else {
            throw PushCryptoError.invalidAuthenticationSecret
        }
        let privateKeyObject: P256.KeyAgreement.PrivateKey
        let publicKeyObject: P256.KeyAgreement.PublicKey
        do {
            privateKeyObject = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            publicKeyObject = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        } catch {
            throw PushCryptoError.invalidPublicKey
        }
        guard privateKeyObject.publicKey.x963Representation == publicKeyObject.x963Representation else {
            throw PushCryptoError.invalidPublicKey
        }
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.authenticationSecret = authenticationSecret
    }

    public static func generate() throws -> WebPushKeyMaterial {
        let privateKey = P256.KeyAgreement.PrivateKey()
        var authenticationSecret = Data(count: 16)
        let result = authenticationSecret.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw PushCryptoError.invalidAuthenticationSecret
        }
        return try WebPushKeyMaterial(
            privateKey: privateKey.rawRepresentation,
            publicKey: privateKey.publicKey.x963Representation,
            authenticationSecret: authenticationSecret
        )
    }

    public var p256dh: String { Base64URL.encode(publicKey) }
    public var auth: String { Base64URL.encode(authenticationSecret) }
}
