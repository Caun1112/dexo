import UIKit
import WebKit

extension UIViewController {
    /// True when this controller is a challenge page, or a navigation stack
    /// hosting one — used to avoid stacking a second challenge on the first.
    var containsChallengeViewController: Bool {
        if self is ChallengeViewController { return true }
        if let nav = self as? UINavigationController {
            return nav.viewControllers.contains { $0 is ChallengeViewController }
        }
        return false
    }

    /// Presents the shared Cloudflare challenge prompt and opens the existing
    /// linux.do challenge page when the user chooses to continue.
    func presentChallengePrompt(
        title: String = String(localized: "challenge.prompt.title"),
        message: String = String(localized: "challenge.prompt.message"),
        actionTitle: String = String(localized: "me.challenge")
    ) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: actionTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            ChallengeViewController.present(from: self)
        })
        present(alert, animated: true)
    }

    /// If `error` indicates the request was intercepted by Cloudflare's
    /// challenge, prompts the user to pass it. Returns true if the prompt was
    /// shown, so callers can suppress generic error alerts on that path.
    ///
    /// The challenge flow targets `linux.do/challenge`, so the prompt is
    /// suppressed for any other forum even if its response trips the CF
    /// detector — sending the user to linux.do wouldn't refresh their cookies
    /// for the forum they were actually browsing.
    @discardableResult
    func presentChallengePromptIfNeeded(error: Error, on api: DiscourseAPI) -> Bool {
        guard api.isLinuxDo else { return false }
        guard (error as? DiscourseAPIError)?.isChallengeRequired == true else {
            return false
        }
        presentChallengePrompt()
        return true
    }
}

/// Presents linux.do's `/challenge` page in a WKWebView seeded with the user's
/// existing web-login cookies. Cookie changes are synced immediately, with a
/// final sync on every dismissal path, so subsequent API requests use the
/// refreshed session even when the challenge completes without a navigation.
final class ChallengeViewController: BaseViewController {
    private let targetURL: URL
    private let userAgent: String?

    /// 用户确认完成、Cookie 与 UA 同步完毕且页面消失后调用一次。
    var onResolved: (() -> Void)?

    private var webView: WKWebView?
    private var proxyLease: AnyObject?
    private var setupTask: Task<Void, Never>?
    private var cookieSyncTask: Task<Void, Never>?
    private var isFinalCookieSyncInProgress = false
    private var isObservingCookieChanges = false
    private var shouldNotifyResolved = false

    private func makeWebViewConfiguration() async throws -> (WKWebViewConfiguration, AnyObject?) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let darkModeCSS = WKUserScript(
            source: "document.documentElement.style.colorScheme = 'light dark';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(darkModeCSS)
        let lease = try await WebViewDoHConfigurator.configure(config)
        return (config, lease)
    }

    private lazy var coordinator = Coordinator(onNavigationFinished: { [weak self] in
        self?.syncCookies()
    })

    private lazy var progressView: UIProgressView = {
        let pv = UIProgressView(progressViewStyle: .bar)
        pv.translatesAutoresizingMaskIntoConstraints = false
        return pv
    }()

    private var progressObservation: NSKeyValueObservation?

    init(targetURL: URL, userAgent: String?) {
        self.targetURL = targetURL
        self.userAgent = userAgent
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "challenge.title")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "challenge.done"), style: .done, target: self, action: #selector(doneTapped)
        )
        navigationItem.rightBarButtonItem?.isEnabled = false

        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        setupTask = Task { [weak self] in
            await self?.setUpWebView()
        }
    }

    private func setUpWebView() async {
        do {
            let (configuration, lease) = try await makeWebViewConfiguration()
            guard !Task.isCancelled else { return }

            proxyLease = lease
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = coordinator
            webView.uiDelegate = coordinator
            webView.isOpaque = false
            webView.backgroundColor = .systemBackground
            if let userAgent {
                webView.customUserAgent = userAgent
            }
            webView.translatesAutoresizingMaskIntoConstraints = false
            self.webView = webView

            view.insertSubview(webView, belowSubview: progressView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

            progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
                self?.progressView.progress = Float(webView.estimatedProgress)
                self?.progressView.isHidden = webView.estimatedProgress >= 1.0
            }
            navigationItem.rightBarButtonItem?.isEnabled = true

            await seedCookies(in: webView)
            guard !Task.isCancelled else { return }
            webView.configuration.websiteDataStore.httpCookieStore.add(coordinator)
            isObservingCookieChanges = true
            webView.load(URLRequest(url: targetURL))
        } catch {
            guard !Task.isCancelled else { return }
            showProxyUnavailableAlert()
        }
    }

    private func showProxyUnavailableAlert() {
        let alert = UIAlertController(
            title: String(localized: "doh.proxy.error.title"),
            message: String(localized: "doh.proxy.error.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    @MainActor
    private func seedCookies(in webView: WKWebView) async {
        // The native MITM proxy keeps the original HTTPS URL, so WebKit still
        // owns the real-origin cookie jar. Seed the existing login and
        // Cloudflare state in both direct and proxied modes.
        let cookies = WebCookieStore.shared.cookies(for: targetURL)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { cont.resume() }
            }
        }
    }

    private func syncCookies() {
        guard !isFinalCookieSyncInProgress else { return }
        let previousTask = cookieSyncTask
        cookieSyncTask = Task { @MainActor [weak self] in
            _ = await previousTask?.value
            await self?.syncWebSession()
        }
    }

    @MainActor
    private func syncWebSession() async {
        guard let webView else { return }
        await WebCookieStore.shared.syncFromWebView(
            webView.configuration.websiteDataStore,
            for: targetURL
        )

        // Cloudflare clearance can be tied to the browser User-Agent. Keep
        // the API request consistent with the WKWebView that passed the
        // challenge, including the first add-forum probe before login state
        // has been persisted.
        if let evaluatedUserAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String,
           !evaluatedUserAgent.isEmpty
        {
            WebCookieStore.shared.userAgent = evaluatedUserAgent
        }
    }

    @objc private func cancelTapped() {
        setupTask?.cancel()
        syncAndDismiss(resolved: false)
    }

    @objc private func doneTapped() {
        syncAndDismiss(resolved: true)
    }

    private func syncAndDismiss(resolved: Bool) {
        guard !isFinalCookieSyncInProgress else { return }
        isFinalCookieSyncInProgress = true
        let pendingSyncTask = cookieSyncTask
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await pendingSyncTask?.value
            await syncWebSession()
            shouldNotifyResolved = resolved
            dismiss(animated: true)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil, isObservingCookieChanges {
            webView?.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
            isObservingCookieChanges = false
        }
        guard view.window == nil else { return }
        let resolved = shouldNotifyResolved ? onResolved : nil
        onResolved = nil
        resolved?()
    }

    /// 展示过盾页；只有用户点击完成并完成最终同步后才调用 `onResolved`。
    static func present(from presenter: UIViewController, onResolved: (() -> Void)? = nil) {
        guard let url = URL(string: "https://linux.do/challenge") else { return }
        let vc = ChallengeViewController(targetURL: url, userAgent: WebCookieStore.shared.userAgent)
        vc.onResolved = onResolved
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        nav.isModalInPresentation = true
        presenter.present(nav, animated: true)
    }

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        private let onNavigationFinished: () -> Void
        private let trustEvaluator: WebViewProxyTrustEvaluator?

        init(onNavigationFinished: @escaping () -> Void) {
            self.onNavigationFinished = onNavigationFinished
            trustEvaluator = WebViewDoHConfigurator.makeTrustEvaluator()
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let credential = trustEvaluator?.credential(for: challenge) {
                #if DEBUG
                print("[WebViewDoHProxy] Challenge accepted proxy CA for \(challenge.protectionSpace.host)")
                #endif
                completionHandler(.useCredential, credential)
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigationFinished()
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            onNavigationFinished()
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
