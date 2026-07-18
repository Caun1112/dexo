import Foundation
import Network
import WebKit

/// Applies the app's DoH preference to WKWebView on iOS 17 and later.
/// WebKit loads a loopback HTTP origin, while the in-process gateway forwards
/// requests to the real HTTPS origin through URLSession. WebKit never performs
/// TLS against a locally-generated certificate.
enum WebViewDoHConfigurator {
    private static let preloadedOrigins = [
        URL(string: "https://challenges.cloudflare.com")!,
    ]
    private static let wildcardHostSuffixes: Set<String> = [
        "*",
    ]

    static func configure(
        _ configuration: WKWebViewConfiguration,
        originURL: URL
    ) async throws -> AnyObject? {
        guard #available(iOS 17.0, *) else { return nil }

        let dataStore = WKWebsiteDataStore.default()
        configuration.websiteDataStore = dataStore
        dataStore.proxyConfigurations = []

        guard AppSettings.shared.dohEnabled else { return nil }
        return try await WebViewDoHProxy.shared.acquire(
            originURL: originURL,
            additionalOrigins: preloadedOrigins,
            wildcardHostSuffixes: wildcardHostSuffixes
        )
    }

    static func proxiedURL(_ remoteURL: URL, lease: AnyObject?) -> URL {
        guard #available(iOS 17.0, *),
              let lease = lease as? WebViewDoHProxy.Lease
        else {
            return remoteURL
        }
        return lease.localURL(for: remoteURL) ?? remoteURL
    }

    static func originalURL(_ localURL: URL?, lease: AnyObject?) -> URL? {
        guard let localURL else { return nil }
        guard #available(iOS 17.0, *),
              let lease = lease as? WebViewDoHProxy.Lease
        else {
            return localURL
        }
        return lease.remoteURL(for: localURL) ?? localURL
    }

    static func cookies(lease: AnyObject?) -> [HTTPCookie] {
        guard #available(iOS 17.0, *),
              let lease = lease as? WebViewDoHProxy.Lease
        else {
            return []
        }
        return lease.cookies
    }
}

@available(iOS 17.0, *)
final class WebViewDoHProxy {
    static let shared = WebViewDoHProxy()

    final class Lease {
        fileprivate private(set) var routes: [WebViewReverseProxyRoute]
        fileprivate let routeTable: WebViewReverseProxyRouteTable

        fileprivate init(
            routes: [WebViewReverseProxyRoute],
            wildcardHostSuffixes: Set<String>
        ) {
            self.routes = routes
            routeTable = WebViewReverseProxyRouteTable(
                routes: routes,
                wildcardHostSuffixes: wildcardHostSuffixes
            )
        }

        fileprivate var cookies: [HTTPCookie] {
            routes.flatMap { $0.cookieJar.allCookies() }
        }

        fileprivate func localURL(for remoteURL: URL) -> URL? {
            routeTable.localURL(for: remoteURL)
        }

        fileprivate func remoteURL(for localURL: URL) -> URL? {
            routeTable.remoteURL(for: localURL)
        }

        fileprivate func add(_ route: WebViewReverseProxyRoute) {
            guard !routes.contains(where: { Self.sameOrigin($0.remoteOrigin, route.remoteOrigin) }) else {
                return
            }
            routes.append(route)
            routeTable.add(route)
        }

        deinit {
            let ids = routes.map(\.id)
            Task { @MainActor in
                ids.forEach { WebViewDoHProxy.shared.release($0) }
            }
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

    enum ProxyError: Error {
        case invalidOrigin
        case listenerStopped
        case unavailablePort
    }

    private final class Gateway {
        let id: UUID
        let origin: URL
        let listener: NWListener
        let cookieJar: WebViewReverseProxyCookieJar
        var continuation: CheckedContinuation<WebViewReverseProxyRoute, Error>?
        weak var lease: Lease?
        var tunnels: [UUID: HTTPURLSessionReverseProxyTunnel] = [:]

        init(
            id: UUID,
            origin: URL,
            listener: NWListener,
            cookieJar: WebViewReverseProxyCookieJar,
            continuation: CheckedContinuation<WebViewReverseProxyRoute, Error>
        ) {
            self.id = id
            self.origin = origin
            self.listener = listener
            self.cookieJar = cookieJar
            self.continuation = continuation
        }
    }

    private let queue = DispatchQueue(label: "xyz.47258.dexo.webview-doh-proxy")
    private var gateways: [UUID: Gateway] = [:]

    private init() {}

    func acquire(
        originURL: URL,
        additionalOrigins: [URL] = [],
        wildcardHostSuffixes: Set<String> = []
    ) async throws -> Lease {
        let requestedOrigins = [originURL] + additionalOrigins
        var origins: [URL] = []
        for requestedOrigin in requestedOrigins {
            guard let origin = Self.normalizedOrigin(from: requestedOrigin) else {
                if requestedOrigin == originURL { throw ProxyError.invalidOrigin }
                continue
            }
            if !origins.contains(where: { Self.sameOrigin($0, origin) }) {
                origins.append(origin)
            }
        }
        guard !origins.isEmpty else {
            throw ProxyError.invalidOrigin
        }

        var routes: [WebViewReverseProxyRoute] = []
        do {
            for origin in origins {
                routes.append(try await acquireRoute(origin: origin))
            }
        } catch {
            routes.forEach { release($0.id) }
            throw error
        }

        let lease = Lease(
            routes: routes,
            wildcardHostSuffixes: wildcardHostSuffixes
        )
        routes.forEach { gateways[$0.id]?.lease = lease }
        return lease
    }

    private func acquireRoute(origin: URL) async throws -> WebViewReverseProxyRoute {
        let acquireID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try startGateway(
                        id: acquireID,
                        origin: origin,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor in
                WebViewDoHProxy.shared.cancelAcquire(acquireID)
            }
        }
    }

    func stop() {
        WKWebsiteDataStore.default().proxyConfigurations = []
        let ids = Array(gateways.keys)
        ids.forEach { stopGateway(id: $0, error: ProxyError.listenerStopped) }
    }

    private func startGateway(
        id: UUID,
        origin: URL,
        continuation: CheckedContinuation<WebViewReverseProxyRoute, Error>
    ) throws {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionLimit = 128
        let cookieJar = WebViewReverseProxyCookieJar(
            seedCookies: WebCookieStore.shared.cookies(for: origin)
        )
        let gateway = Gateway(
            id: id,
            origin: origin,
            listener: listener,
            cookieJar: cookieJar,
            continuation: continuation
        )
        gateways[id] = gateway

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state, gatewayID: id)
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection, gatewayID: id)
            }
        }
        listener.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State, gatewayID: UUID) {
        guard let gateway = gateways[gatewayID] else { return }
        switch state {
        case .ready:
            guard let port = gateway.listener.port,
                  let localOrigin = URL(string: "http://127.0.0.1:\(port.rawValue)")
            else {
                stopGateway(id: gatewayID, error: ProxyError.unavailablePort)
                return
            }
            #if DEBUG
            print("[WebViewDoHGateway] ready \(localOrigin.absoluteString) -> \(gateway.origin.absoluteString)")
            #endif
            gateway.continuation?.resume(returning: WebViewReverseProxyRoute(
                id: gatewayID,
                remoteOrigin: gateway.origin,
                localOrigin: localOrigin,
                cookieJar: gateway.cookieJar
            ))
            gateway.continuation = nil
        case .failed(let error):
            stopGateway(id: gatewayID, error: error)
        case .cancelled:
            if gateway.continuation != nil {
                stopGateway(id: gatewayID, error: ProxyError.listenerStopped)
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, gatewayID: UUID) {
        guard AppSettings.shared.dohEnabled,
              EncryptedDNSManager.normalizedServerURL(AppSettings.shared.dohServerURL) != nil,
              let gateway = gateways[gatewayID],
              let lease = gateway.lease,
              let port = gateway.listener.port,
              let localOrigin = URL(string: "http://127.0.0.1:\(port.rawValue)")
        else {
            connection.cancel()
            return
        }

        let id = UUID()
        let tunnel = HTTPURLSessionReverseProxyTunnel(
            id: id,
            client: connection,
            queue: queue,
            origin: gateway.origin,
            localOrigin: localOrigin,
            cookieJar: gateway.cookieJar,
            routeTable: lease.routeTable,
            routeProvisioner: { origins, completion in
                Task { @MainActor in
                    await WebViewDoHProxy.shared.provision(
                        origins: origins,
                        forGatewayID: gatewayID
                    )
                    completion()
                }
            },
            onStop: {
                Task { @MainActor in
                    WebViewDoHProxy.shared.removeTunnel(id, gatewayID: gatewayID)
                }
            }
        )
        gateway.tunnels[id] = tunnel
        tunnel.start()
    }

    private func removeTunnel(_ id: UUID, gatewayID: UUID) {
        gateways[gatewayID]?.tunnels.removeValue(forKey: id)
    }

    private func provision(origins: [URL], forGatewayID gatewayID: UUID) async {
        guard let lease = gateways[gatewayID]?.lease else { return }
        for requestedOrigin in origins {
            guard let origin = Self.normalizedOrigin(from: requestedOrigin),
                  lease.routeTable.localURL(for: origin) == nil
            else { continue }

            do {
                let route = try await acquireRoute(origin: origin)
                guard gateways[gatewayID]?.lease === lease else {
                    release(route.id)
                    continue
                }
                lease.add(route)
                gateways[route.id]?.lease = lease
                #if DEBUG
                print("[WebViewDoHGateway] wildcard route added \(route.remoteOrigin.absoluteString)")
                #endif
            } catch {
                #if DEBUG
                print("[WebViewDoHGateway] wildcard route failed \(origin.absoluteString): \(error)")
                #endif
            }
        }
    }

    private func release(_ id: UUID) {
        guard let gateway = gateways[id] else { return }
        WebCookieStore.shared.setCookies(gateway.cookieJar.allCookies())
        stopGateway(id: id, error: nil)
    }

    private func cancelAcquire(_ id: UUID) {
        stopGateway(id: id, error: CancellationError())
    }

    private func stopGateway(id: UUID, error: Error?) {
        guard let gateway = gateways.removeValue(forKey: id) else { return }
        gateway.listener.stateUpdateHandler = nil
        gateway.listener.newConnectionHandler = nil
        gateway.listener.cancel()
        let tunnels = Array(gateway.tunnels.values)
        gateway.tunnels.removeAll()
        tunnels.forEach { $0.cancel() }
        if let continuation = gateway.continuation {
            continuation.resume(throwing: error ?? ProxyError.listenerStopped)
            gateway.continuation = nil
        }
    }

    private static func normalizedOrigin(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        components.path = ""
        return components.url
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

nonisolated enum HTTPConnectRequestParser {
    struct Request: Equatable {
        let host: String
        let port: UInt16
    }

    enum ParseError: Error, Equatable {
        case malformedRequest
        case unsupportedMethod
        case invalidAuthority
    }

    static func parse(_ headerData: Data) throws -> Request {
        guard let header = String(data: headerData, encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first
        else {
            throw ParseError.malformedRequest
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1"
        else {
            throw ParseError.malformedRequest
        }
        guard parts[0].uppercased() == "CONNECT" else {
            throw ParseError.unsupportedMethod
        }

        return try parseAuthority(String(parts[1]))
    }

    private static func parseAuthority(_ authority: String) throws -> Request {
        let host: String
        let portString: String

        if authority.hasPrefix("[") {
            guard let closingBracket = authority.firstIndex(of: "]"),
                  authority.index(after: closingBracket) < authority.endIndex,
                  authority[authority.index(after: closingBracket)] == ":"
            else {
                throw ParseError.invalidAuthority
            }
            host = String(authority[authority.index(after: authority.startIndex)..<closingBracket])
            portString = String(authority[authority.index(closingBracket, offsetBy: 2)...])
        } else {
            guard let colon = authority.lastIndex(of: ":"),
                  !authority[..<colon].contains(":")
            else {
                throw ParseError.invalidAuthority
            }
            host = String(authority[..<colon])
            portString = String(authority[authority.index(after: colon)...])
        }

        guard !host.isEmpty,
              host.count <= 253,
              !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "/" }),
              let port = UInt16(portString),
              port > 0
        else {
            throw ParseError.invalidAuthority
        }
        return Request(host: host, port: port)
    }
}
