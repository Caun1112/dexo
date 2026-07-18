import Foundation
import Security

@available(iOS 17.0, *)
nonisolated final class WebViewProxyTLSIdentity: @unchecked Sendable {
    let host: String
    let networkIdentity: sec_identity_t
    let leafCertificateData: Data

    init(host: String, networkIdentity: sec_identity_t, leafCertificateData: Data) {
        self.host = host
        self.networkIdentity = networkIdentity
        self.leafCertificateData = leafCertificateData
    }
}

/// App-local certificate authority for the WKWebView DoH proxy. A leaf
/// certificate with an exact SAN is generated and signed for every CONNECT
/// hostname. Nothing is installed into the system trust store.
@available(iOS 17.0, *)
nonisolated final class WebViewProxyCertificateAuthority: @unchecked Sendable {
    enum AuthorityError: Error {
        case invalidArchive
        case importFailed(OSStatus)
        case missingIdentity
        case missingPrivateKey(OSStatus)
        case leafPrivateKeyGenerationFailed(CFError?)
        case missingLeafPublicKey
        case publicKeyExportFailed(CFError?)
        case certificateGenerationFailed(CFError?)
        case invalidCertificate
        case certificateAddFailed(OSStatus)
        case identityLookupFailed(OSStatus)
        case identityCertificateMismatch
        case identityBridgeFailed
    }

    let certificate: SecCertificate

    private struct KeychainMaterial {
        let keyTag: Data
        let certificateLabel: String
    }

    private let caPrivateKey: SecKey
    private let sessionID = UUID().uuidString
    private let lock = NSLock()
    private var identities: [String: WebViewProxyTLSIdentity] = [:]
    private var keychainMaterials: [KeychainMaterial] = []

    private init(
        caPrivateKey: SecKey,
        certificate: SecCertificate
    ) {
        self.caPrivateKey = caPrivateKey
        self.certificate = certificate
    }

    static func load() throws -> WebViewProxyCertificateAuthority {
        guard let archive = Data(
            base64Encoded: archiveBase64,
            options: .ignoreUnknownCharacters
        ) else {
            throw AuthorityError.invalidArchive
        }

        var importedItems: CFArray?
        let options = [kSecImportExportPassphrase as String: archivePassword] as CFDictionary
        let status = SecPKCS12Import(archive as CFData, options, &importedItems)
        guard status == errSecSuccess else {
            throw AuthorityError.importFailed(status)
        }
        guard let items = importedItems as? [[String: Any]],
              let first = items.first,
              let identity = first[kSecImportItemIdentity as String] as! SecIdentity?
        else {
            throw AuthorityError.missingIdentity
        }

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate
        else {
            throw AuthorityError.missingIdentity
        }

        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, let privateKey else {
            throw AuthorityError.missingPrivateKey(keyStatus)
        }
        return WebViewProxyCertificateAuthority(
            caPrivateKey: privateKey,
            certificate: certificate
        )
    }

    func identity(for rawHost: String) throws -> WebViewProxyTLSIdentity {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        lock.lock()
        defer { lock.unlock() }
        if let cached = identities[host] {
            return cached
        }

        let keyTag = Data("com.eilgnaw.dexo.webview-mitm.\(sessionID).\(UUID().uuidString)".utf8)
        let certificateLabel = "Dexo WebView MITM \(sessionID) \(host)"
        var shouldCleanUp = true
        defer {
            if shouldCleanUp {
                Self.deleteKeychainMaterial(
                    KeychainMaterial(
                        keyTag: keyTag,
                        certificateLabel: certificateLabel
                    )
                )
            }
        }

        var keyError: Unmanaged<CFError>?
        let leafKeyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ],
        ]
        guard let leafPrivateKey = SecKeyCreateRandomKey(
            leafKeyAttributes as CFDictionary,
            &keyError
        ) else {
            throw AuthorityError.leafPrivateKeyGenerationFailed(
                keyError?.takeRetainedValue()
            )
        }
        guard let leafPublicKey = SecKeyCopyPublicKey(leafPrivateKey) else {
            throw AuthorityError.missingLeafPublicKey
        }
        var exportError: Unmanaged<CFError>?
        guard let leafPublicKeyData = SecKeyCopyExternalRepresentation(
            leafPublicKey,
            &exportError
        ) else {
            throw AuthorityError.publicKeyExportFailed(exportError?.takeRetainedValue())
        }

        let tbsCertificate = try WebViewProxyX509Builder.makeTBSCertificate(
            host: host,
            publicKeyBytes: leafPublicKeyData as Data
        )
        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            caPrivateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signatureError
        ) else {
            throw AuthorityError.certificateGenerationFailed(
                signatureError?.takeRetainedValue()
            )
        }
        let certificateData = WebViewProxyX509Builder.makeCertificate(
            tbsCertificate: tbsCertificate,
            signature: signature as Data
        )
        guard let leafCertificate = SecCertificateCreateWithData(
            nil,
            certificateData as CFData
        ) else {
            throw AuthorityError.invalidCertificate
        }

        let addCertificateStatus = SecItemAdd(
            [
                kSecValueRef as String: leafCertificate,
                kSecAttrLabel as String: certificateLabel,
            ] as CFDictionary,
            nil
        )
        guard addCertificateStatus == errSecSuccess else {
            throw AuthorityError.certificateAddFailed(addCertificateStatus)
        }

        var identityResult: CFTypeRef?
        let identityStatus = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: certificateLabel,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary,
            &identityResult
        )
        guard identityStatus == errSecSuccess, let identityResult else {
            throw AuthorityError.identityLookupFailed(identityStatus)
        }
        let leafSecurityIdentity = identityResult as! SecIdentity

        var identityCertificate: SecCertificate?
        guard SecIdentityCopyCertificate(
            leafSecurityIdentity,
            &identityCertificate
        ) == errSecSuccess,
            let identityCertificate,
            SecCertificateCopyData(identityCertificate) as Data == certificateData
        else {
            throw AuthorityError.identityCertificateMismatch
        }

        // The SecIdentity already contributes the dynamic leaf. The explicit
        // certificate array contains only the additional issuer certificate;
        // including the leaf here duplicates it in the TLS Certificate list.
        guard let networkIdentity = sec_identity_create_with_certificates(
            leafSecurityIdentity,
            [certificate] as CFArray
        ) else {
            throw AuthorityError.identityBridgeFailed
        }

        let generated = WebViewProxyTLSIdentity(
            host: host,
            networkIdentity: networkIdentity,
            leafCertificateData: certificateData
        )
        identities[host] = generated
        keychainMaterials.append(
            KeychainMaterial(
                keyTag: keyTag,
                certificateLabel: certificateLabel
            )
        )
        shouldCleanUp = false
        return generated
    }

    func removeGeneratedIdentities() {
        lock.lock()
        let materials = keychainMaterials
        keychainMaterials.removeAll()
        identities.removeAll()
        lock.unlock()

        materials.forEach(Self.deleteKeychainMaterial)
    }

    deinit {
        removeGeneratedIdentities()
    }

    private static func deleteKeychainMaterial(_ material: KeychainMaterial) {
        SecItemDelete(
            [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: material.certificateLabel,
            ] as CFDictionary
        )
        SecItemDelete(
            [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: material.keyTag,
            ] as CFDictionary
        )
    }

    private static let archivePassword = "dexo-debug-mitm-ca-v1"

    private static let archiveBase64 = """
    MIIEyQIBAzCCBHcGCSqGSIb3DQEHAaCCBGgEggRkMIIEYDCCAtoGCSqGSIb3DQEHBqCCAsswggLHAgEAMIICwAYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBS
    MDEGCSqGSIb3DQEFDDAkBBDyGnq6NrsnhYPX2lOinyugAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQgbiGHxe3Zt45vIN32twln4CCAlDM/Q1r
    Rr/mdmJO7WVfdteSkvgwMQrEsRAsoqVU0KkOjwQR+dUqQBOzkyuLT3h3wQNDynwzXpX8V9tfNS0kYYDHtULkZgQiWKfOo5akQgSSso0VLvkVwMsGNy6s2491
    mq3x+ztNDuq8sfBjKv58WiSJg1ZKvaBdrGE5w0sqMgrE1pqUbXZwfcVZDHuknL1bhMRj4c/LQmtW5bUzWw5g3ThXDQ7/Ft/WFlTwZaiqaEdyYF4UPj7z/J+H
    6Oto4Z12qr6+FArn8VKg3UQeNqFLVwqMJy8Vzr2zWlKiLGUTz6q0KmaYu+/Nl8GDOwMaJYPIgm8FDHlQgYGP6eYBAB/yN1JYYXAi/5nx8l09bP6eG9FDGXzz
    6L0jZ+OTkYXWZ8L0qKf2qsMlHKsteaMNHz4AlnAPtVVYooo3LGfvABv3beKotPndDx6f8O30HZx7EQuquqt1cBJ2n6fSUGofGRGU1E7yX+qLClESysKW8ufS
    UzlQ+W7Kjg1yqCJnQK4Wgyao36xONUxoGBa47skhjRIdR5tqu7voZYSOnlejpF3BYEjUuaOTqrZQAoYycyt8HFsHA0Tgx9R/8weJzXxI2JcCa2TcMO/oNHPR
    ZunoNPR5AEVah3U7b5e7AkmQ6wtXTHcaD3s2U+p24c/cYSKXKt3zEvPXCJ5HJgjmlrswKNj22D/E7NjHmT8lCrMfh4vOwtboHIYX3IgHuT3xdkf2QvSC6T0r
    SouPTsdYFS3DTv1xI6EyCSGq93uadZgZJR18QbGOHZNAtK+z8iE64Q2mcELttpwZMIIBfgYJKoZIhvcNAQcBoIIBbwSCAWswggFnMIIBYwYLKoZIhvcNAQwK
    AQKggfcwgfQwXwYJKoZIhvcNAQUNMFIwMQYJKoZIhvcNAQUMMCQEEPiz1r3qzf6eCpLtPPTwOGgCAggAMAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBCE
    WjHeUolE2NnFL/hMTcERBIGQktk0M8tfjG/uq4kOS8X/CapDuxHeEYrRpXfekV/R02smmxz1EktkdnAudvPa6TaManO0N037J8EKZdaJnuwuwVhPhezd4RsY
    z4DKpGJyeoGTXHmZuZwBf+Cz8jUadgD9XVCvD7+GOqj+PD9uHcKabsUCP4o+cgVNqTQ6SYllZn6zjls6TgK+i/HrVrRt/8imMVowIwYJKoZIhvcNAQkVMRYE
    FF6ZrxYFUd47z13ja2HBwxPaNtiRMDMGCSqGSIb3DQEJFDEmHiQARABlAHgAbwAgAEQAZQBiAHUAZwAgAE0ASQBUAE0AIABDAEEwSTAxMA0GCWCGSAFlAwQC
    AQUABCAGm/nZnbVe7Z/SKpfVOrCPidD8A4PwN/43kdFUEe29EAQQN66BHi/J/iN3mpnJVVcKwgICCAA=
    """
}
