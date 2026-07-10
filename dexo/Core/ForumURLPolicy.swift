import Foundation

/// Validation and normalization rules for forum base URLs.
enum ForumURLPolicy {
    enum ValidationError: Error, Equatable {
        case empty
        case invalidURL
        case insecureScheme
        case credentialsNotAllowed
        case queryNotAllowed
        case fragmentNotAllowed
    }

    /// Returns a canonical HTTPS base URL without a trailing slash.
    ///
    /// A missing scheme is interpreted as HTTPS for convenience. Explicit
    /// schemes other than HTTPS are rejected.
    static func normalize(_ rawValue: String) throws -> String {
        let components = try prepare(rawValue, defaultingToHTTPS: true)
        guard components.scheme?.lowercased() == "https" else {
            throw ValidationError.insecureScheme
        }
        return try canonicalString(from: components)
    }

    static func isSecure(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == rawValue,
              trimmed.range(of: "://") != nil,
              let components = try? prepare(trimmed, defaultingToHTTPS: false),
              components.scheme?.lowercased() == "https"
        else { return false }
        return (try? canonicalString(from: components)) != nil
    }

    /// Allows requests to the saved forum origin. linux.do's dedicated
    /// MessageBus host is the only intentional cross-origin exception; API
    /// credentials continue to be attached there exactly as before.
    static func allowsRequest(_ requestURL: URL, for baseURL: String) -> Bool {
        guard isSecure(baseURL),
              let base = URL(string: baseURL),
              requestURL.scheme?.lowercased() == "https",
              requestURL.user == nil,
              requestURL.password == nil
        else { return false }

        if hasSameOrigin(base, requestURL) {
            return true
        }

        return base.host?.lowercased() == "linux.do"
            && effectivePort(base) == 443
            && requestURL.host?.lowercased() == "ping.ldstatic.com"
            && effectivePort(requestURL) == 443
    }

    /// Builds the HTTPS equivalent of a valid, previously saved HTTP URL.
    /// No network request is performed here.
    static func httpsUpgradeCandidate(from rawValue: String) throws -> String {
        var components = try prepare(rawValue, defaultingToHTTPS: false)
        guard components.scheme?.lowercased() == "http" else {
            throw ValidationError.invalidURL
        }

        components.scheme = "https"
        guard let value = components.string else {
            throw ValidationError.invalidURL
        }
        return try normalize(value)
    }

    static func canUpgradeToHTTPS(_ rawValue: String) -> Bool {
        (try? httpsUpgradeCandidate(from: rawValue)) != nil
    }

    private static func prepare(
        _ rawValue: String,
        defaultingToHTTPS: Bool
    ) throws -> URLComponents {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !trimmed.contains("\\")
        else {
            throw ValidationError.invalidURL
        }

        let value: String
        if trimmed.range(of: "://") != nil {
            value = trimmed
        } else if defaultingToHTTPS {
            // Do not reinterpret malformed HTTP(S) URLs such as `https:/host`
            // as a hostname.
            let lowercased = trimmed.lowercased()
            guard !lowercased.hasPrefix("http:"), !lowercased.hasPrefix("https:") else {
                throw ValidationError.invalidURL
            }
            value = "https://" + trimmed
        } else {
            value = trimmed
        }

        guard let components = URLComponents(string: value) else {
            throw ValidationError.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentialsNotAllowed
        }
        guard components.percentEncodedQuery == nil else {
            throw ValidationError.queryNotAllowed
        }
        guard components.percentEncodedFragment == nil else {
            throw ValidationError.fragmentNotAllowed
        }
        guard let host = components.host, !host.isEmpty,
              components.url?.host != nil
        else {
            throw ValidationError.invalidURL
        }
        if let port = components.port, !(1 ... 65_535).contains(port) {
            throw ValidationError.invalidURL
        }

        return components
    }

    private static func canonicalString(from source: URLComponents) throws -> String {
        var components = source
        components.scheme = "https"

        // URLComponents already performs host validation. Lowercasing keeps
        // logically identical forum addresses on the same credential key.
        if let host = components.host {
            components.host = host.lowercased()
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path

        guard let url = components.url,
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            throw ValidationError.invalidURL
        }
        return url.absoluteString
    }

    private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
