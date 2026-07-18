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

    /// Configures the debug browser for a pure local MITM capture. This path
    /// intentionally ignores the DoH switch and uses normal URLSession
    /// networking upstream so certificate interception can be tested alone.
    static func configureDebugMITM(
        _ configuration: WKWebViewConfiguration
    ) async throws -> AnyObject? {
        guard #available(iOS 17.0, *) else { return nil }

        let dataStore = WKWebsiteDataStore.nonPersistent()
        configuration.websiteDataStore = dataStore
        dataStore.proxyConfigurations = []

        let lease = try await WebViewDoHProxy.shared.acquireForDebugCapture()
        dataStore.proxyConfigurations = [lease.proxyConfiguration]
        return lease
    }

    /// Configures an ordinary URLSession to use the same local CONNECT proxy
    /// as the WKWebView debug capture. Keeping this path separate makes it
    /// possible to isolate URLSession TLS behavior from WebKit.
    static func configureDebugMITM(
        _ configuration: URLSessionConfiguration
    ) async throws -> AnyObject? {
        guard #available(iOS 17.0, *) else { return nil }

        let lease = try await WebViewDoHProxy.shared.acquireForDebugCapture()
        configuration.proxyConfigurations = [lease.proxyConfiguration]
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

    static var caCertificateData: Data? {
        guard #available(iOS 17.0, *) else { return nil }
        return WebViewDoHProxy.shared.caCertificateData
    }

    static var proxyRunning: Bool {
        guard #available(iOS 17.0, *) else { return false }
        return WebViewDoHProxy.shared.isRunning
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
    private var certificateAuthority: WebViewProxyCertificateAuthority?
    private var leases = Set<UUID>()
    private var debugCaptureLeases = Set<UUID>()
    private var tunnels: [UUID: WebViewDoHMITMTunnel] = [:]
    private struct PendingAcquire {
        let isDebugCapture: Bool
        let continuation: CheckedContinuation<Lease, Error>
    }
    private var pendingAcquires: [PendingAcquire] = []

    private init() {}

    var caCertificateData: Data? {
        certificateAuthority.map { SecCertificateCopyData($0.certificate) as Data }
    }

    var isRunning: Bool {
        listenerPort != nil && listener != nil
    }

    func acquire() async throws -> Lease {
        guard AppSettings.shared.dohEnabled,
              EncryptedDNSManager.normalizedServerURL(AppSettings.shared.dohServerURL) != nil
        else {
            throw ProxyError.invalidDoHConfiguration
        }

        return try await acquire(isDebugCapture: false)
    }

    func acquireForDebugCapture() async throws -> Lease {
        try await acquire(isDebugCapture: true)
    }

    private func acquire(isDebugCapture: Bool) async throws -> Lease {
        if let listenerPort {
            return makeLease(port: listenerPort, isDebugCapture: isDebugCapture)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingAcquires.append(
                PendingAcquire(
                    isDebugCapture: isDebugCapture,
                    continuation: continuation
                )
            )
            guard listener == nil else { return }
            do {
                try startListener()
            } catch {
                failPendingAcquires(error)
            }
        }
    }

    func stop() {
        WKWebsiteDataStore.default().proxyConfigurations = []
        stopListener(error: ProxyError.listenerStopped)
    }

    private func startListener() throws {
        let certificateAuthority = try WebViewProxyCertificateAuthority.load()
        self.certificateAuthority = certificateAuthority

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let context = WebViewMITMFramerContext(certificateAuthority: certificateAuthority)
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
            continuations.forEach {
                $0.continuation.resume(
                    returning: makeLease(
                        port: port,
                        isDebugCapture: $0.isDebugCapture
                    )
                )
            }
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
        guard listener != nil,
              AppSettings.shared.dohEnabled || !debugCaptureLeases.isEmpty
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

    private func makeLease(port: NWEndpoint.Port, isDebugCapture: Bool) -> Lease {
        let id = UUID()
        leases.insert(id)
        if isDebugCapture {
            debugCaptureLeases.insert(id)
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        return Lease(
            id: id,
            proxyConfiguration: ProxyConfiguration(httpCONNECTProxy: endpoint)
        )
    }

    private func release(_ id: UUID) {
        leases.remove(id)
        debugCaptureLeases.remove(id)
        if leases.isEmpty, pendingAcquires.isEmpty {
            stopListener(error: nil)
        }
    }

    private func failPendingAcquires(_ error: Error) {
        let continuations = pendingAcquires
        pendingAcquires.removeAll()
        continuations.forEach { $0.continuation.resume(throwing: error) }
        listener?.cancel()
        listener = nil
        listenerPort = nil
        certificateAuthority = nil
    }

    private func stopListener(error: Error?) {
        let activeListener = listener
        listener = nil
        listenerPort = nil
        certificateAuthority = nil
        activeListener?.stateUpdateHandler = nil
        activeListener?.newConnectionHandler = nil
        activeListener?.cancel()

        let activeTunnels = Array(tunnels.values)
        tunnels.removeAll()
        activeTunnels.forEach { $0.cancel() }

        leases.removeAll()
        debugCaptureLeases.removeAll()
        if !pendingAcquires.isEmpty {
            failPendingAcquires(error ?? ProxyError.listenerStopped)
        }
    }
}
