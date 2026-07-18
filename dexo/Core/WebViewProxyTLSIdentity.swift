import Foundation
import Security

/// A stable, pre-generated TLS identity used only by the loopback WebView
/// proxy. WKWebView accepts this identity for the lifetime of its navigation
/// delegate; it is never installed as a system trust anchor.
@available(iOS 17.0, *)
nonisolated final class WebViewProxyTLSIdentity: @unchecked Sendable {
    enum IdentityError: Error {
        case invalidArchive
        case importFailed(OSStatus)
        case missingIdentity
        case bridgeFailed
    }

    let securityIdentity: SecIdentity
    let networkIdentity: sec_identity_t
    let leafCertificateData: Data

    private init(
        securityIdentity: SecIdentity,
        networkIdentity: sec_identity_t,
        leafCertificateData: Data
    ) {
        self.securityIdentity = securityIdentity
        self.networkIdentity = networkIdentity
        self.leafCertificateData = leafCertificateData
    }

    static func load() throws -> WebViewProxyTLSIdentity {
        guard let archive = Data(base64Encoded: archiveBase64, options: .ignoreUnknownCharacters) else {
            throw IdentityError.invalidArchive
        }

        var importedItems: CFArray?
        let options = [kSecImportExportPassphrase as String: archivePassword] as CFDictionary
        let status = SecPKCS12Import(archive as CFData, options, &importedItems)
        guard status == errSecSuccess else {
            throw IdentityError.importFailed(status)
        }
        guard let items = importedItems as? [[String: Any]],
              let first = items.first,
              first[kSecImportItemIdentity as String] != nil
        else {
            throw IdentityError.missingIdentity
        }
        let identity = first[kSecImportItemIdentity as String] as! SecIdentity
        guard let networkIdentity = sec_identity_create(identity) else {
            throw IdentityError.bridgeFailed
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate
        else {
            throw IdentityError.missingIdentity
        }
        return WebViewProxyTLSIdentity(
            securityIdentity: identity,
            networkIdentity: networkIdentity,
            leafCertificateData: SecCertificateCopyData(certificate) as Data
        )
    }

    private static let archivePassword = "dexo-local-mitm-v1"

    // RSA-2048 leaf identity signed by a private app-local CA. The leaf has
    // SANs for linux.do and Cloudflare challenge hosts; other hosts are still
    // handled by the WebView's explicit server-trust challenge policy.
    private static let archiveBase64 = """
    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
    """
}
