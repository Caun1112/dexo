import Foundation
import Network

final class EncryptedDNSManager {
    static let shared = EncryptedDNSManager()

    // The default privacy context is intentionally app-wide: enabling DoH
    // applies to DNS resolution for every forum, not a host allowlist.
    private let privacyContext = NWParameters.PrivacyContext.default

    private init() {}

    /// Applies the persisted preference before any URLSession-backed clients
    /// are created. Returns false only when an enabled endpoint is invalid.
    @discardableResult
    func applyCurrentSettings() -> Bool {
        let settings = AppSettings.shared
        guard !settings.dohEnabled || settings.defaultDoHServer != nil else {
            settings.dohEnabled = false
            return setEnabled(false, serverURLString: "")
        }
        return setEnabled(
            settings.dohEnabled,
            serverURLString: settings.defaultDoHServer?.urlString ?? ""
        )
    }

    /// Updates encrypted name resolution for subsequent connections across
    /// all forums and clears DNS/TLS state associated with the default context.
    @discardableResult
    func setEnabled(_ enabled: Bool, serverURLString: String) -> Bool {
        guard enabled else {
            privacyContext.requireEncryptedNameResolution(false, fallbackResolver: nil)
            privacyContext.flushCache()
            if #available(iOS 17.0, *) {
                WebViewDoHProxy.shared.stop()
            }
            return true
        }

        guard let serverURL = Self.normalizedServerURL(serverURLString) else {
            return false
        }

        if #available(iOS 17.0, *) {
            // Existing proxy sessions may keep resolved addresses and open
            // connections, so changing the resolver must rebuild them.
            WebViewDoHProxy.shared.stop()
        }

        let resolver = NWParameters.PrivacyContext.ResolverConfiguration.https(
            serverURL,
            serverAddresses: []
        )
        privacyContext.requireEncryptedNameResolution(true, fallbackResolver: resolver)
        privacyContext.flushCache()
        return true
    }

    static func normalizedServerURL(_ input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://") {
            value = "https://" + value
        }

        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url
        else {
            return nil
        }
        return url
    }
}
