import Foundation
import WebKit

/// In-memory + persisted cookie store used for web-login sessions.
/// Cookies are keyed by "domain|name|path" for deduplication.
final class WebCookieStore {
    static let shared = WebCookieStore()

    private static let cloudflareCookieNames: Set<String> = [
        "cf_clearance",
        "__cf_bm",
        "__cflb",
        "__cfseq",
        "_cfuvid",
        "cf_ob_info",
        "cf_use_ob",
    ]

    private var jar: [String: HTTPCookie] = [:]
    private let lock = NSLock()
    private let filePath: URL

    /// The User-Agent captured from the WKWebView that completed login.
    var userAgent: String? {
        didSet { saveUserAgent() }
    }

    private let userAgentPath: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        filePath = dir.appendingPathComponent("dexo_web_cookies.json")
        userAgentPath = dir.appendingPathComponent("dexo_web_ua.txt")
        load()
        userAgent = loadUserAgent()
    }

    // MARK: - Read / Write

    func setCookies(_ cookies: [HTTPCookie]) {
        let now = Date()
        lock.lock()
        for c in cookies {
            // Drop already-expired cookies instead of letting them overwrite a still-valid entry.
            if let expires = c.expiresDate, expires <= now {
                jar.removeValue(forKey: key(for: c))
            } else {
                jar[key(for: c)] = c
            }
        }
        lock.unlock()
        save()
    }

    func cookies(for url: URL) -> [HTTPCookie] {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return jar.values.filter { cookie in
            // Skip expired cookies so a stale/expired `_t` left in the jar never gets sent.
            if let expires = cookie.expiresDate, expires <= now { return false }
            return Self.cookieDomain(cookie.domain, matchesHost: host)
                && path.hasPrefix(cookie.path)
        }
    }

    func cookieHeader(for url: URL) -> String {
        cookies(for: url).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 仅返回站点验证所需的 Cloudflare Cookie，避免 API Key 请求带上网页登录 `_t`。
    func cloudflareCookieHeader(for url: URL) -> String {
        Self.cloudflareCookieHeader(from: cookies(for: url))
    }

    static func cloudflareCookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { isCloudflareCookieName($0.name) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func isCloudflareCookieName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return cloudflareCookieNames.contains(normalized) || normalized.hasPrefix("cf_chl_")
    }

    func mergeResponseHeaders(_ headers: [AnyHashable: Any], for url: URL) {
        var stringHeaders: [String: String] = [:]
        for (k, v) in headers { stringHeaders["\(k)"] = "\(v)" }
        let newCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: url)
        if !newCookies.isEmpty { setCookies(newCookies) }
    }

    @MainActor
    func syncFromWebView(_ dataStore: WKWebsiteDataStore, for url: URL) async {
        let cookies = await withCheckedContinuation { cont in
            dataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        guard let host = url.host?.lowercased() else { return }

        // Treat WebKit as authoritative for this forum. A challenge may
        // delete or rotate cf_clearance without returning the expired cookie
        // from getAllCookies; merge-only syncing would leave that stale value
        // in the native jar and send it again on the next topic request.
        let now = Date()
        let currentForumCookies = cookies.filter {
            Self.cookieDomain($0.domain, matchesHost: host)
                && ($0.expiresDate.map { $0 > now } ?? true)
        }
        lock.lock()
        jar = jar.filter { _, cookie in
            !Self.cookieDomain(cookie.domain, matchesHost: host)
        }
        for cookie in currentForumCookies {
            jar[key(for: cookie)] = cookie
        }
        lock.unlock()
        save()
    }

    func clearAll() {
        lock.lock()
        jar.removeAll()
        lock.unlock()
        userAgent = nil
        try? FileManager.default.removeItem(at: filePath)
    }

    func clearCookies(for baseURL: String) {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        lock.lock()
        jar = jar.filter { _, cookie in
            !Self.cookieDomain(cookie.domain, matchesHost: host)
        }
        lock.unlock()
        save()
    }

    /// Returns whether a cookie's domain applies to a host. Domain cookies
    /// require a dot boundary, so `.example.com` matches `forum.example.com`
    /// but never `notexample.com`. Host-only cookies remain exact matches.
    static func cookieDomain(_ cookieDomain: String, matchesHost host: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let rawDomain = cookieDomain.lowercased()
        let normalizedDomain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty, !normalizedDomain.isEmpty else { return false }
        if normalizedHost == normalizedDomain { return true }
        return rawDomain.hasPrefix(".") && normalizedHost.hasSuffix("." + normalizedDomain)
    }

    // MARK: - Persistence

    private func key(for cookie: HTTPCookie) -> String {
        "\(cookie.domain)|\(cookie.name)|\(cookie.path)"
    }

    private func save() {
        let serializable: [[String: Any]] = jar.values.compactMap { cookie in
            guard let props = cookie.properties else { return nil }
            var dict: [String: Any] = [:]
            for (k, v) in props {
                if let date = v as? Date {
                    dict[k.rawValue] = date.timeIntervalSinceReferenceDate
                } else {
                    dict[k.rawValue] = v
                }
            }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: serializable) {
            try? data.write(to: filePath, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        let now = Date()
        let cookies: [HTTPCookie] = array.compactMap { dict in
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in dict {
                let key = HTTPCookiePropertyKey(k)
                if (key == .expires || key == HTTPCookiePropertyKey("Max-Age")),
                   let ti = v as? TimeInterval {
                    props[key] = Date(timeIntervalSinceReferenceDate: ti)
                } else {
                    props[key] = v
                }
            }
            return HTTPCookie(properties: props)
        }.filter {
            $0.expiresDate.map { $0 > now } ?? true
        }
        for c in cookies { jar[key(for: c)] = c }
    }

    private func saveUserAgent() {
        if let ua = userAgent {
            try? ua.write(to: userAgentPath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: userAgentPath)
        }
    }

    private func loadUserAgent() -> String? {
        try? String(contentsOf: userAgentPath, encoding: .utf8)
    }
}
