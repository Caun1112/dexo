import Foundation
import Network

@available(iOS 17.0, *)
nonisolated struct WebViewReverseProxyRoute: @unchecked Sendable {
    let id: UUID
    let remoteOrigin: URL
    let localOrigin: URL
    let cookieJar: WebViewReverseProxyCookieJar
}

/// Thread-safe origin map shared by every gateway that belongs to one
/// WKWebView. Wildcard hosts are discovered in textual responses before the
/// response reaches WebKit, allowing a separate loopback origin to be created
/// for each real HTTPS origin.
@available(iOS 17.0, *)
nonisolated final class WebViewReverseProxyRouteTable: @unchecked Sendable {
    private static let discoveryLimit = 4 * 1024 * 1024
    private static let httpsURLRegex = try! NSRegularExpression(
        pattern: #"(?:(?<!:)//|https://)([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?"#,
        options: [.caseInsensitive]
    )

    private let lock = NSLock()
    private var routes: [WebViewReverseProxyRoute]
    private let wildcardHostSuffixes: Set<String>

    init(routes: [WebViewReverseProxyRoute], wildcardHostSuffixes: Set<String>) {
        self.routes = routes
        self.wildcardHostSuffixes = Set(wildcardHostSuffixes.map { $0.lowercased() })
    }

    func add(_ route: WebViewReverseProxyRoute) {
        lock.lock()
        if !routes.contains(where: { Self.sameOrigin($0.remoteOrigin, route.remoteOrigin) }) {
            routes.append(route)
        }
        lock.unlock()
    }

    func localURL(for remoteURL: URL) -> URL? {
        lock.lock()
        let route = routes.first { Self.sameOrigin($0.remoteOrigin, remoteURL) }
        lock.unlock()
        guard let route else { return nil }
        return Self.replacingOrigin(of: remoteURL, with: route.localOrigin)
    }

    func remoteURL(for localURL: URL) -> URL? {
        lock.lock()
        let route = routes.first { Self.sameOrigin($0.localOrigin, localURL) }
        lock.unlock()
        guard let route else { return nil }
        return Self.replacingOrigin(of: localURL, with: route.remoteOrigin)
    }

    func rewriteToLocal(_ value: String) -> String {
        let snapshot = routeSnapshot()
        return snapshot.reduce(value) { output, route in
            Self.rewrite(
                output,
                from: route.remoteOrigin,
                to: route.localOrigin
            )
        }
    }

    func rewriteToRemote(_ value: String) -> String {
        let snapshot = routeSnapshot()
        return snapshot.reduce(value) { output, route in
            Self.rewrite(
                output,
                from: route.localOrigin,
                to: route.remoteOrigin
            )
        }
    }

    func missingWildcardOrigins(in values: [String]) -> [URL] {
        guard !wildcardHostSuffixes.isEmpty else { return [] }
        let normalized = values
            .joined(separator: "\n")
            .prefix(Self.discoveryLimit)
            .replacingOccurrences(of: "\\/", with: "/")
        let text = String(normalized)
        let range = NSRange(text.startIndex..., in: text)
        let matches = Self.httpsURLRegex.matches(in: text, range: range)

        var discovered: [URL] = []
        var keys = Set<String>()
        let proxiesAllHosts = wildcardHostSuffixes.contains("*")
        let existingKeys = Set(routeSnapshot().map { Self.originKey($0.remoteOrigin) })
        for match in matches.prefix(32) {
            guard let hostRange = Range(match.range(at: 1), in: text) else { continue }
            let host = String(text[hostRange]).lowercased()
            guard proxiesAllHosts || wildcardHostSuffixes.contains(where: { host.hasSuffix("." + $0) }) else {
                continue
            }

            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            if let portRange = Range(match.range(at: 2), in: text),
               let port = Int(text[portRange]),
               (1...65_535).contains(port)
            {
                components.port = port
            }
            guard let origin = components.url else { continue }
            let key = Self.originKey(origin)
            guard !existingKeys.contains(key), keys.insert(key).inserted else { continue }
            discovered.append(origin)
            if discovered.count == 8 { break }
        }
        return discovered
    }

    private func routeSnapshot() -> [WebViewReverseProxyRoute] {
        lock.lock()
        let snapshot = routes
        lock.unlock()
        return snapshot.sorted {
            $0.remoteOrigin.absoluteString.count > $1.remoteOrigin.absoluteString.count
        }
    }

    private static func replacingOrigin(of url: URL, with origin: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = origin.scheme
        components?.host = origin.host
        components?.port = origin.port
        components?.user = nil
        components?.password = nil
        return components?.url
    }

    private static func rewrite(_ value: String, from: URL, to: URL) -> String {
        guard let fromHost = from.host,
              let toHost = to.host
        else { return value }

        let fromBase = from.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let toBase = to.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fromAuthority = from.port.map { "\(fromHost):\($0)" } ?? fromHost
        let toAuthority = to.port.map { "\(toHost):\($0)" } ?? toHost
        return value
            .replacingOccurrences(
                of: fromBase.replacingOccurrences(of: "/", with: "\\/"),
                with: toBase.replacingOccurrences(of: "/", with: "\\/")
            )
            .replacingOccurrences(of: fromBase, with: toBase)
            .replacingOccurrences(of: "//\(fromAuthority)", with: "//\(toAuthority)")
    }

    private static func originKey(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(effectivePort(url) ?? 0)"
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

@available(iOS 17.0, *)
nonisolated final class WebViewReverseProxyCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [String: HTTPCookie] = [:]

    init(seedCookies: [HTTPCookie]) {
        seedCookies.forEach { cookies[Self.key(for: $0)] = $0 }
    }

    func cookieHeader(for url: URL) -> String? {
        let now = Date()
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let isSecure = url.scheme?.lowercased() == "https"

        lock.lock()
        defer { lock.unlock() }
        let values = cookies.values.filter { cookie in
            if let expiry = cookie.expiresDate, expiry <= now { return false }
            if cookie.isSecure && !isSecure { return false }
            return Self.domain(cookie.domain, matches: host) && path.hasPrefix(cookie.path)
        }
        guard !values.isEmpty else { return nil }
        return values.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func merge(responseHeaders: [AnyHashable: Any], for url: URL) {
        var fields: [String: String] = [:]
        responseHeaders.forEach { fields[String(describing: $0.key)] = String(describing: $0.value) }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !received.isEmpty else { return }

        let now = Date()
        lock.lock()
        for cookie in received {
            let key = Self.key(for: cookie)
            if let expiry = cookie.expiresDate, expiry <= now {
                cookies.removeValue(forKey: key)
            } else {
                cookies[key] = cookie
            }
        }
        lock.unlock()
    }

    func allCookies() -> [HTTPCookie] {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        return cookies.values.filter { $0.expiresDate.map { $0 > now } ?? true }
    }

    private static func key(for cookie: HTTPCookie) -> String {
        "\(cookie.domain.lowercased())|\(cookie.name)|\(cookie.path)"
    }

    private static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let normalizedDomain = cookieDomain.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedDomain.isEmpty else { return false }
        return host == normalizedDomain || host.hasSuffix("." + normalizedDomain)
    }
}

@available(iOS 17.0, *)
private nonisolated final class WebViewReverseProxyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Plain-loopback HTTP gateway for WKWebView. The real origin request is made
/// by URLSession, so WebKit never performs origin DNS or local MITM TLS.
@available(iOS 17.0, *)
nonisolated final class HTTPURLSessionReverseProxyTunnel: @unchecked Sendable {
    private static let receiveBufferSize = 64 * 1024
    private static let textContentTypes = [
        "text/html",
        "text/css",
        "text/javascript",
        "application/javascript",
        "application/json",
        "application/ld+json",
        "application/xml",
        "text/xml",
        "image/svg+xml",
    ]
    private static let hopByHopHeaders: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]
    private static let strippedSecurityHeaders: Set<String> = [
        "alt-svc",
        "clear-site-data",
        "content-security-policy",
        "content-security-policy-report-only",
        "cross-origin-embedder-policy",
        "cross-origin-opener-policy",
        "cross-origin-resource-policy",
        "nel",
        "origin-agent-cluster",
        "permissions-policy",
        "report-to",
        "strict-transport-security",
    ]

    private let id: UUID
    private let client: NWConnection
    private let queue: DispatchQueue
    private let origin: URL
    private let localOrigin: URL
    private let cookieJar: WebViewReverseProxyCookieJar
    private let routeTable: WebViewReverseProxyRouteTable
    private let routeProvisioner: @Sendable ([URL], @escaping @Sendable () -> Void) -> Void
    private let onStop: @Sendable () -> Void
    private let redirectDelegate = WebViewReverseProxyRedirectDelegate()
    private let session: URLSession

    private var parser = HTTPProxyRequestParser()
    private var activeTask: URLSessionDataTask?
    private var isStopped = false
    private var isForwarding = false
    private var receivedBytes = 0
    private var sentBytes = 0

    init(
        id: UUID,
        client: NWConnection,
        queue: DispatchQueue,
        origin: URL,
        localOrigin: URL,
        cookieJar: WebViewReverseProxyCookieJar,
        routeTable: WebViewReverseProxyRouteTable,
        routeProvisioner: @escaping @Sendable ([URL], @escaping @Sendable () -> Void) -> Void,
        onStop: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.client = client
        self.queue = queue
        self.origin = origin
        self.localOrigin = localOrigin
        self.cookieJar = cookieJar
        self.routeTable = routeTable
        self.routeProvisioner = routeProvisioner
        self.onStop = onStop

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("local HTTP ready; waiting for request")
                self.receiveRequestBytes()
            case .waiting(let error):
                self.log("local connection waiting: \(error)")
            case .failed(let error):
                self.log("local connection failed: \(error)")
                self.stop()
            case .cancelled:
                self.stop()
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    func cancel() {
        queue.async { [weak self] in self?.stop() }
    }

    private func receiveRequestBytes() {
        guard !isStopped, !isForwarding else { return }
        do {
            if let request = try parser.nextRequest() {
                forward(request)
                return
            }
        } catch {
            handleParserError(error)
            return
        }

        client.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveBufferSize) { [weak self] data, _, complete, error in
            guard let self, !self.isStopped else { return }
            guard error == nil else {
                self.log("HTTP receive failed: \(String(describing: error))")
                self.stop()
                return
            }
            if let data, !data.isEmpty {
                self.receivedBytes += data.count
                do {
                    try self.parser.append(data)
                } catch {
                    self.handleParserError(error)
                    return
                }
            }
            if complete {
                self.stop()
            } else {
                self.receiveRequestBytes()
            }
        }
    }

    private func forward(_ request: HTTPProxyRequestParser.Request) {
        guard !isStopped else { return }
        guard request.values(forHeader: "Upgrade").allSatisfy({ $0.isEmpty }) else {
            sendErrorResponse(statusCode: 501, reason: "Not Implemented")
            return
        }

        let forwarded: URLRequest
        do {
            forwarded = try makeURLRequest(from: request)
        } catch {
            log("request rejected: \(error)")
            sendErrorResponse(statusCode: 400, reason: "Bad Request")
            return
        }

        isForwarding = true
        let closeAfterResponse = request.values(forHeader: "Connection")
            .flatMap { $0.split(separator: ",") }
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "close" }

        log("\(request.method) \(forwarded.url?.absoluteString ?? request.target)")
        let task = session.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard !self.isStopped else { return }
                self.activeTask = nil
                guard error == nil, let response = response as? HTTPURLResponse else {
                    self.log("URLSession failed: \(String(describing: error))")
                    self.sendErrorResponse(statusCode: 502, reason: "Bad Gateway")
                    return
                }
                self.cookieJar.merge(responseHeaders: response.allHeaderFields, for: response.url ?? forwarded.url!)
                let body = data ?? Data()
                let discoveryValues = self.discoveryValues(body: body, response: response)
                let missingOrigins = self.routeTable.missingWildcardOrigins(in: discoveryValues)
                guard !missingOrigins.isEmpty else {
                    self.send(
                        response: response,
                        body: self.rewriteBody(body, response: response),
                        closeAfterResponse: closeAfterResponse
                    )
                    return
                }

                self.log("provisioning wildcard origins: \(missingOrigins.map(\.absoluteString).joined(separator: ", "))")
                self.routeProvisioner(missingOrigins) { [self] in
                    self.queue.async { [self] in
                        guard !self.isStopped else { return }
                        self.send(
                            response: response,
                            body: self.rewriteBody(body, response: response),
                            closeAfterResponse: closeAfterResponse
                        )
                    }
                }
            }
        }
        activeTask = task
        task.resume()
    }

    private func makeURLRequest(from request: HTTPProxyRequestParser.Request) throws -> URLRequest {
        enum RequestError: Error { case invalidTarget }

        let pathAndQuery: String
        if request.target.hasPrefix("/") {
            pathAndQuery = request.target
        } else if request.target == "*" {
            pathAndQuery = "/"
        } else if let absolute = URL(string: request.target),
                  let components = URLComponents(url: absolute, resolvingAgainstBaseURL: false)
        {
            var value = components.percentEncodedPath
            if value.isEmpty { value = "/" }
            if let query = components.percentEncodedQuery { value += "?" + query }
            pathAndQuery = value
        } else {
            throw RequestError.invalidTarget
        }

        guard let url = URL(string: pathAndQuery, relativeTo: origin)?.absoluteURL,
              url.scheme == "https",
              url.host?.lowercased() == origin.host?.lowercased()
        else {
            throw RequestError.invalidTarget
        }

        var forwarded = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        forwarded.httpMethod = request.method
        forwarded.httpBody = request.body.isEmpty ? nil : request.body
        forwarded.httpShouldHandleCookies = false

        let connectionNamedHeaders = Set(
            request.values(forHeader: "Connection")
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        for header in request.headers {
            let lowercaseName = header.name.lowercased()
            guard lowercaseName != "host",
                  lowercaseName != "cookie",
                  lowercaseName != "content-length",
                  lowercaseName != "accept-encoding",
                  !Self.hopByHopHeaders.contains(lowercaseName),
                  !connectionNamedHeaders.contains(lowercaseName)
            else {
                continue
            }

            let value: String
            if lowercaseName == "origin" || lowercaseName == "referer" {
                value = routeTable.rewriteToRemote(header.value)
            } else {
                value = header.value
            }
            forwarded.addValue(value, forHTTPHeaderField: header.name)
        }
        if let cookie = cookieJar.cookieHeader(for: url) {
            forwarded.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        forwarded.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return forwarded
    }

    private func send(response: HTTPURLResponse, body: Data, closeAfterResponse: Bool) {
        guard !isStopped else { return }
        var data = Data("HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(response.statusCode))\r\n".utf8)
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName)
            let lowercaseName = name.lowercased()
            guard !Self.hopByHopHeaders.contains(lowercaseName),
                  !Self.strippedSecurityHeaders.contains(lowercaseName),
                  lowercaseName != "content-length",
                  lowercaseName != "content-encoding",
                  lowercaseName != "set-cookie"
            else {
                continue
            }

            let values = (rawValue as? [String]) ?? [String(describing: rawValue)]
            for raw in values {
                let value: String
                switch lowercaseName {
                case "location", "refresh", "access-control-allow-origin":
                    value = routeTable.rewriteToLocal(raw)
                default:
                    value = raw
                }
                guard !name.contains("\r"), !name.contains("\n"),
                      !value.contains("\r"), !value.contains("\n")
                else { continue }
                data.append(Data("\(name): \(value)\r\n".utf8))
            }
        }
        data.append(Data("Content-Length: \(body.count)\r\n".utf8))
        data.append(Data("Connection: \(closeAfterResponse ? "close" : "keep-alive")\r\n\r\n".utf8))
        data.append(body)

        sentBytes += data.count
        client.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isStopped else { return }
            guard error == nil else {
                self.log("HTTP response send failed: \(String(describing: error))")
                self.stop()
                return
            }
            self.log("response \(response.statusCode), body=\(body.count) bytes")
            self.isForwarding = false
            closeAfterResponse ? self.stop() : self.receiveRequestBytes()
        })
    }

    private func rewriteBody(_ data: Data, response: HTTPURLResponse) -> Data {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              Self.textContentTypes.contains(where: contentType.hasPrefix),
              let string = String(data: data, encoding: .utf8)
        else {
            return data
        }
        return Data(routeTable.rewriteToLocal(string).utf8)
    }

    private func discoveryValues(body: Data, response: HTTPURLResponse) -> [String] {
        var values = response.allHeaderFields.compactMap { rawName, rawValue -> String? in
            let name = String(describing: rawName).lowercased()
            guard name == "location"
                    || name == "refresh"
                    || name == "access-control-allow-origin"
            else { return nil }
            return String(describing: rawValue)
        }
        if let text = String(data: body, encoding: .utf8) {
            values.append(text)
        }
        return values
    }

    private func handleParserError(_ error: Error) {
        log("HTTP parse failed: \(error)")
        switch error {
        case HTTPProxyRequestParser.ParseError.headerTooLarge,
             HTTPProxyRequestParser.ParseError.bodyTooLarge:
            sendErrorResponse(statusCode: 413, reason: "Content Too Large")
        case HTTPProxyRequestParser.ParseError.unsupportedTransferEncoding:
            sendErrorResponse(statusCode: 501, reason: "Not Implemented")
        default:
            sendErrorResponse(statusCode: 400, reason: "Bad Request")
        }
    }

    private func sendErrorResponse(statusCode: Int, reason: String) {
        guard !isStopped else { return }
        isForwarding = true
        let body = Data("\(statusCode) \(reason)\n".utf8)
        var response = Data("HTTP/1.1 \(statusCode) \(reason)\r\n".utf8)
        response.append(Data("Content-Type: text/plain; charset=utf-8\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
        response.append(body)
        client.send(content: response, completion: .contentProcessed { [weak self] _ in self?.stop() })
    }

    private func stop() {
        guard !isStopped else { return }
        isStopped = true
        activeTask?.cancel()
        activeTask = nil
        session.invalidateAndCancel()
        client.stateUpdateHandler = nil
        client.cancel()
        log("stopping; received=\(receivedBytes), sent=\(sentBytes)")
        onStop()
    }

    private static func reasonPhrase(_ statusCode: Int) -> String {
        switch statusCode {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Content Too Large"
        case 416: "Range Not Satisfiable"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Response"
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[WebViewDoHGateway \(id.uuidString.prefix(8))] \(message)")
        #endif
    }
}
