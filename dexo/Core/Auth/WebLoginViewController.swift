import UIKit
import WebKit

/// Presents a WKWebView so users can log in to a Discourse forum via their browser.
/// Fires onSuccess once the Discourse session cookie `_t` is detected.
final class WebLoginViewController: BaseViewController {
    private let targetURL: URL
    private let onSuccess: ([HTTPCookie], String?) -> Void

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Polyfills for iOS < 16.4: CSS.supports override for browser detection,
        // API polyfills, and static{} block transpilation for Webpack chunks.
        if #unavailable(iOS 16.4) {
            let polyfillSource = Self.polyfillJS
            let script = WKUserScript(source: polyfillSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(script)
        }

        // Inject color-scheme hint so the page respects dark mode
        let darkModeCSS = WKUserScript(
            source: "document.documentElement.style.colorScheme = 'light dark';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(darkModeCSS)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = coordinator
        wv.uiDelegate = coordinator
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        wv.customUserAgent = Self.mobileSafariUserAgent
        wv.translatesAutoresizingMaskIntoConstraints = false
        return wv
    }()

    private lazy var coordinator = Coordinator(targetURL: targetURL, onCookiesReady: { [weak self] cookies in
        self?.handleCookiesReady(cookies)
    })

    private lazy var progressView: UIProgressView = {
        let pv = UIProgressView(progressViewStyle: .bar)
        pv.translatesAutoresizingMaskIntoConstraints = false
        return pv
    }()

    private var progressObservation: NSKeyValueObservation?

    init(targetURL: URL, onSuccess: @escaping ([HTTPCookie], String?) -> Void) {
        self.targetURL = targetURL
        self.onSuccess = onSuccess
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "weblogin.title")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "weblogin.done"), style: .done, target: self, action: #selector(doneTapped)
        )

        view.addSubview(webView)
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            self?.progressView.progress = Float(wv.estimatedProgress)
            self?.progressView.isHidden = wv.estimatedProgress >= 1.0
        }

        webView.load(URLRequest(url: targetURL))
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        coordinator.collectAndFire(from: webView)
    }

    private func handleCookiesReady(_ cookies: [HTTPCookie]) {
        Task { @MainActor in
            // Do not mutate the app-wide cookie store here. AuthManager first
            // persists the new auth marker, then installs these cookies. This
            // preserves the previous login if Keychain persistence fails.
            let evaluatedUserAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
            let userAgent = evaluatedUserAgent ?? webView.customUserAgent
            dismiss(animated: true) {
                self.onSuccess(cookies, userAgent)
            }
        }
    }

    // MARK: - User Agent

    /// Mobile Safari UA that tracks the device's actual iOS version + idiom
    /// so server-side feature detection (Discourse's browser gate, dark-mode
    /// hints, etc.) matches what real Safari would report. WebKit/Safari
    /// build numbers stay pinned — they aren't tied to the iOS version and
    /// real Safari rarely changes them within a major release.
    private static var mobileSafariUserAgent: String {
        let version = UIDevice.current.systemVersion          // e.g. "18.2.1"
        let parts = version.split(separator: ".")
        let major = parts.first.map(String.init) ?? "18"
        let minor = parts.count > 1 ? String(parts[1]) : "0"
        let osToken = "\(major)_\(minor)"                     // "18_2"
        let versionToken = "\(major).\(minor)"                // "18.2"
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return "Mozilla/5.0 (\(device); CPU \(device) OS \(osToken) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(versionToken) Mobile/15E148 Safari/604.1"
    }

    // MARK: - Polyfills (iOS < 16.4)

    private static let polyfillJS = """
    (function() {
        // CSS.supports override — Discourse browser detection
        var orig = CSS.supports.bind(CSS);
        CSS.supports = function() {
            var s = arguments.length === 1 ? arguments[0] : arguments[0] + ':' + arguments[1];
            if (s.indexOf('subgrid') !== -1 || s.indexOf('hsl(from') !== -1) return true;
            return orig.apply(CSS, arguments);
        };

        // structuredClone (iOS 15.4+)
        if (typeof globalThis.structuredClone === 'undefined') {
            globalThis.structuredClone = function(obj) { return JSON.parse(JSON.stringify(obj)); };
        }
        // Object.hasOwn (iOS 15.4+)
        if (!Object.hasOwn) {
            Object.hasOwn = function(obj, prop) { return Object.prototype.hasOwnProperty.call(obj, prop); };
        }
        // Array.prototype.at (iOS 15.4+)
        if (!Array.prototype.at) {
            Array.prototype.at = function(i) { var n = Math.trunc(i) || 0; if (n < 0) n += this.length; if (n < 0 || n >= this.length) return undefined; return this[n]; };
        }
        // String.prototype.at (iOS 15.4+)
        if (!String.prototype.at) {
            String.prototype.at = function(i) { var n = Math.trunc(i) || 0; if (n < 0) n += this.length; if (n < 0 || n >= this.length) return undefined; return this[n]; };
        }
        // crypto.randomUUID (iOS 15.4+)
        if (typeof crypto !== 'undefined' && !crypto.randomUUID) {
            crypto.randomUUID = function() {
                var a = new Uint8Array(16); crypto.getRandomValues(a);
                a[6] = (a[6] & 0x0f) | 0x40; a[8] = (a[8] & 0x3f) | 0x80;
                var h = Array.from(a, function(b) { return b.toString(16).padStart(2,'0'); }).join('');
                return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
            };
        }
    })();
    """

    // MARK: - Coordinator

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let targetHost: String
        private let onCookiesReady: ([HTTPCookie]) -> Void
        private(set) var didCallback = false

        init(targetURL: URL, onCookiesReady: @escaping ([HTTPCookie]) -> Void) {
            self.targetHost = targetURL.host?.lowercased() ?? ""
            self.onCookiesReady = onCookiesReady
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        {
            completionHandler(.performDefaultHandling, nil)
        }

        /// Collect cookies and fire the callback. Only invoked from the "Done" button tap —
        /// auto-dismiss on navigation finish / cookie change was intentionally removed so
        /// the user decides when to hand off to the app.
        func collectAndFire(from webView: WKWebView) {
            guard !didCallback else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.didCallback else { return }
                let relevant = cookies.filter {
                    WebCookieStore.cookieDomain($0.domain, matchesHost: self.targetHost)
                }
                self.didCallback = true
                DispatchQueue.main.async { self.onCookiesReady(relevant) }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
        {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
