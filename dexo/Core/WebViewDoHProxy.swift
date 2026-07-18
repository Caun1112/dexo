import Foundation
import Network
import Security
import WebKit

/// Applies the app's DoH preference to WKWebView on iOS 17 and later. WebKit
/// keeps the original HTTPS URL and connects through a loopback CONNECT proxy.
/// The proxy terminates local TLS, while URLSession performs upstream TLS with
/// the app's encrypted resolver configuration.
enum WebViewDoHConfigurator {
    static func configure(
        _ configuration: WKWebViewConfiguration,
        originURL: URL
    ) async throws -> AnyObject? {
        guard #available(iOS 17.0, *) else { return nil }

        let dataStore = WKWebsiteDataStore.default()
        configuration.websiteDataStore = dataStore
        dataStore.proxyConfigurations = []

        guard AppSettings.shared.dohEnabled else { return nil }
        let lease = try await WebViewDoHProxy.shared.acquire()
        dataStore.proxyConfigurations = [lease.proxyConfiguration]
        return lease
    }

    static func proxiedURL(_ remoteURL: URL, lease: AnyObject?) -> URL {
        remoteURL
    }

    static func originalURL(_ url: URL?, lease: AnyObject?) -> URL? {
        url
    }

    static func cookies(lease: AnyObject?) -> [HTTPCookie] {
        []
    }

    static func credentialForLocalProxyChallenge(
        _ challenge: URLAuthenticationChallenge
    ) -> URLCredential? {
        guard #available(iOS 17.0, *) else { return nil }
        return WebViewDoHProxy.shared.credential(for: challenge)
    }
}

@available(iOS 17.0, *)
final class WebViewDoHProxy {
    static let shared = WebViewDoHProxy()

    final class Lease {
        fileprivate let id: UUID
        let proxyConfiguration: ProxyConfiguration

        fileprivate init(id: UUID, proxyConfiguration: ProxyConfiguration) {
            self.id = id
            self.proxyConfiguration = proxyConfiguration
        }

        deinit {
            let id = id
            Task { @MainActor in
                WebViewDoHProxy.shared.release(id)
            }
        }
    }

    enum ProxyError: Error {
        case listenerStopped
        case unavailablePort
        case invalidDoHConfiguration
    }

    private let queue = DispatchQueue(label: "xyz.47258.dexo.webview-native-mitm")
    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var identity: WebViewProxyTLSIdentity?
    private var leases = Set<UUID>()
    private var tunnels: [UUID: WebViewDoHMITMTunnel] = [:]
    private var pendingAcquires: [CheckedContinuation<Lease, Error>] = []

    private init() {}

    func acquire() async throws -> Lease {
        guard AppSettings.shared.dohEnabled,
              EncryptedDNSManager.normalizedServerURL(AppSettings.shared.dohServerURL) != nil
        else {
            throw ProxyError.invalidDoHConfiguration
        }

        if let listenerPort {
            return makeLease(port: listenerPort)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingAcquires.append(continuation)
            guard listener == nil else { return }
            do {
                try startListener()
            } catch {
                failPendingAcquires(error)
            }
        }
    }

    func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let identity,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              SecCertificateCopyData(leaf) as Data == identity.leafCertificateData
        else {
            return nil
        }

        #if DEBUG
        print("[WebViewDoHProxy] accepted bundled local TLS identity for \(challenge.protectionSpace.host)")
        #endif
        return URLCredential(trust: trust)
    }

    func stop() {
        WKWebsiteDataStore.default().proxyConfigurations = []
        stopListener(error: ProxyError.listenerStopped)
    }

    private func startListener() throws {
        let identity = try WebViewProxyTLSIdentity.load()
        self.identity = identity

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let context = WebViewMITMFramerContext(identity: identity)
        parameters.defaultProtocolStack.applicationProtocols.insert(
            HTTPConnectMITMFramer.options(context: context),
            at: 0
        )

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionLimit = 128
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port else {
                stopListener(error: ProxyError.unavailablePort)
                return
            }
            listenerPort = port
            #if DEBUG
            print("[WebViewDoHProxy] native MITM ready on 127.0.0.1:\(port.rawValue)")
            #endif
            let continuations = pendingAcquires
            pendingAcquires.removeAll()
            continuations.forEach { $0.resume(returning: makeLease(port: port)) }
        case .failed(let error):
            stopListener(error: error)
        case .cancelled:
            if !pendingAcquires.isEmpty {
                stopListener(error: ProxyError.listenerStopped)
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard AppSettings.shared.dohEnabled,
              listener != nil
        else {
            connection.cancel()
            return
        }

        let id = UUID()
        let tunnel = WebViewDoHMITMTunnel(
            id: id,
            client: connection,
            queue: queue,
            onStop: {
                Task { @MainActor in
                    WebViewDoHProxy.shared.tunnels.removeValue(forKey: id)
                }
            }
        )
        tunnels[id] = tunnel
        tunnel.start()
    }

    private func makeLease(port: NWEndpoint.Port) -> Lease {
        let id = UUID()
        leases.insert(id)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        return Lease(
            id: id,
            proxyConfiguration: ProxyConfiguration(httpCONNECTProxy: endpoint)
        )
    }

    private func release(_ id: UUID) {
        leases.remove(id)
        if leases.isEmpty, pendingAcquires.isEmpty {
            stopListener(error: nil)
        }
    }

    private func failPendingAcquires(_ error: Error) {
        let continuations = pendingAcquires
        pendingAcquires.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        listener?.cancel()
        listener = nil
        listenerPort = nil
        identity = nil
    }

    private func stopListener(error: Error?) {
        let activeListener = listener
        listener = nil
        listenerPort = nil
        identity = nil
        activeListener?.stateUpdateHandler = nil
        activeListener?.newConnectionHandler = nil
        activeListener?.cancel()

        let activeTunnels = Array(tunnels.values)
        tunnels.removeAll()
        activeTunnels.forEach { $0.cancel() }

        leases.removeAll()
        if !pendingAcquires.isEmpty {
            failPendingAcquires(error ?? ProxyError.listenerStopped)
        }
    }
}
