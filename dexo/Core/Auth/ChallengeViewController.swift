import UIKit
import WebKit

extension UIViewController {
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
/// existing web-login cookies. On dismiss (or each navigation completion), the
/// updated cookies are synced back into `WebCookieStore` so subsequent API
/// requests use the refreshed session.
final class ChallengeViewController: BaseViewController {
    private let targetURL: URL
    private let userAgent: String?

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

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
        if let ua = userAgent {
            wv.customUserAgent = ua
        }
        wv.translatesAutoresizingMaskIntoConstraints = false
        return wv
    }()

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

        Task { @MainActor in
            await seedCookies()
            webView.load(URLRequest(url: targetURL))
        }
    }

    @MainActor
    private func seedCookies() async {
        let cookies = WebCookieStore.shared.cookies(for: targetURL)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { cont.resume() }
            }
        }
    }

    private func syncCookies() {
        Task { @MainActor in
            await WebCookieStore.shared.syncFromWebView(webView.configuration.websiteDataStore)
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        Task { @MainActor in
            await WebCookieStore.shared.syncFromWebView(webView.configuration.websiteDataStore)
            dismiss(animated: true)
        }
    }

    /// Convenience for presenting the challenge flow from any view controller.
    static func present(from presenter: UIViewController) {
        guard let url = URL(string: "https://linux.do/challenge") else { return }
        let vc = ChallengeViewController(targetURL: url, userAgent: WebCookieStore.shared.userAgent)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        presenter.present(nav, animated: true)
    }

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onNavigationFinished: () -> Void

        init(onNavigationFinished: @escaping () -> Void) {
            self.onNavigationFinished = onNavigationFinished
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigationFinished()
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        {
            completionHandler(.performDefaultHandling, nil)
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
