import CookedHTML
import Photos
import UIKit

/// Preview + export screen for "share as image". Shows the live card so what
/// the user sees — including images that finished loading — is exactly what
/// gets rasterized.
final class ShareImagePreviewViewController: ObservableViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private let post: DiscourseTopicDetail.Post
    private let topicTitle: String
    private let topicId: Int
    private let baseURL: String
    private let annotatedBlocks: [AnnotatedBlock]

    private var theme: ShareImageTheme
    private var options: ShareImageOptions

    private let scrollView = UIScrollView()
    private let cardView = ShareImageCardView()
    private lazy var themeControl = UISegmentedControl(
        items: ShareImageTheme.allCases.map(\.title)
    )
    private let optionsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        return stack
    }()

    init(
        post: DiscourseTopicDetail.Post,
        topicTitle: String,
        topicId: Int,
        baseURL: String,
        annotatedBlocks: [AnnotatedBlock]
    ) {
        self.post = post
        self.topicTitle = topicTitle
        self.topicId = topicId
        self.baseURL = baseURL
        self.annotatedBlocks = annotatedBlocks
        theme = ShareImageTheme(rawValue: AppSettings.shared.shareImageThemeIndex) ?? .classic
        options = AppSettings.shared.shareImageOptions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "share_image.title")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "action.cancel"),
            style: .plain,
            target: self,
            action: #selector(dismissSelf)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: self,
            action: #selector(shareTapped)
        )

        setupViews()
        rebuildCard()
    }

    private func setupViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        cardView.translatesAutoresizingMaskIntoConstraints = false

        themeControl.translatesAutoresizingMaskIntoConstraints = false
        themeControl.selectedSegmentIndex = theme.rawValue
        themeControl.apportionsSegmentWidthsByContent = true
        themeControl.addTarget(self, action: #selector(themeChanged), for: .valueChanged)
        let themeScroll = UIScrollView()
        themeScroll.translatesAutoresizingMaskIntoConstraints = false
        themeScroll.showsHorizontalScrollIndicator = false
        themeScroll.addSubview(themeControl)

        optionsStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildOptionButtons()

        let toolbar = UIStackView(arrangedSubviews: [themeScroll, optionsStack])
        toolbar.axis = .vertical
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        toolbar.backgroundColor = ThemeManager.shared.cardBackgroundColor

        let copyButton = makeActionButton(
            title: String(localized: "share_image.action.copy"),
            symbol: "doc.on.doc",
            action: #selector(copyTapped)
        )
        let saveButton = makeActionButton(
            title: String(localized: "share_image.action.save"),
            symbol: "square.and.arrow.down",
            action: #selector(saveTapped)
        )
        let actions = UIStackView(arrangedSubviews: [copyButton, saveButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 12
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.isLayoutMarginsRelativeArrangement = true
        actions.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        view.addSubview(scrollView)
        scrollView.addSubview(cardView)
        view.addSubview(toolbar)
        view.addSubview(actions)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            cardView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            cardView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            cardView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            // The card has a fixed 375pt width, so pin the scroll content to
            // the viewport width — only vertical scrolling is wanted.
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            themeControl.topAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.topAnchor),
            themeControl.bottomAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.bottomAnchor),
            themeControl.leadingAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.leadingAnchor),
            themeControl.trailingAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.trailingAnchor),
            themeControl.heightAnchor.constraint(equalTo: themeScroll.frameLayoutGuide.heightAnchor),
            themeScroll.heightAnchor.constraint(equalToConstant: 32),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: actions.topAnchor),

            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func makeActionButton(title: String, symbol: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 6
        config.baseForegroundColor = ThemeManager.shared.accentColor
        let button = UIButton(configuration: config)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Display options

    private enum OptionKind: CaseIterable {
        case site, title, author, content, link

        var label: String {
            switch self {
            case .site: return String(localized: "share_image.option.site")
            case .title: return String(localized: "share_image.option.title")
            case .author: return String(localized: "share_image.option.author")
            case .content: return String(localized: "share_image.option.content")
            case .link: return String(localized: "share_image.option.link")
            }
        }

        func isOn(_ options: ShareImageOptions) -> Bool {
            switch self {
            case .site: return options.showsSite
            case .title: return options.showsTitle
            case .author: return options.showsAuthor
            case .content: return options.showsContent
            case .link: return options.showsLink
            }
        }

        func toggle(_ options: inout ShareImageOptions) {
            switch self {
            case .site: options.showsSite.toggle()
            case .title: options.showsTitle.toggle()
            case .author: options.showsAuthor.toggle()
            case .content: options.showsContent.toggle()
            case .link: options.showsLink.toggle()
            }
        }
    }

    private func rebuildOptionButtons() {
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, kind) in OptionKind.allCases.enumerated() {
            var config = UIButton.Configuration.plain()
            config.title = kind.label
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
            let button = UIButton(configuration: config)
            button.tag = index
            let on = kind.isOn(options)
            button.configuration?.baseForegroundColor = on
                ? ThemeManager.shared.accentColor
                : .secondaryLabel
            button.configuration?.background.backgroundColor = on
                ? ThemeManager.shared.accentColor.withAlphaComponent(0.12)
                : .clear
            button.configuration?.background.cornerRadius = 8
            button.titleLabel?.font = FontManager.shared.font(size: 13)
            button.addTarget(self, action: #selector(optionTapped(_:)), for: .touchUpInside)
            optionsStack.addArrangedSubview(button)
        }
    }

    @objc private func optionTapped(_ sender: UIButton) {
        guard let kind = OptionKind.allCases[safe: sender.tag] else { return }
        kind.toggle(&options)
        AppSettings.shared.shareImageOptions = options
        rebuildOptionButtons()
        rebuildCard()
    }

    @objc private func themeChanged() {
        guard let selected = ShareImageTheme(rawValue: themeControl.selectedSegmentIndex) else { return }
        theme = selected
        AppSettings.shared.shareImageThemeIndex = selected.rawValue
        rebuildCard()
    }

    private func rebuildCard() {
        cardView.configure(
            post: post,
            topicTitle: topicTitle,
            topicId: topicId,
            baseURL: baseURL,
            annotatedBlocks: annotatedBlocks,
            theme: theme,
            options: options
        )
        view.setNeedsLayout()
    }

    // MARK: - Export

    private func renderImage() -> UIImage {
        cardView.layoutIfNeeded()
        return cardView.snapshot()
    }

    @objc private func shareTapped() {
        let image = renderImage()
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

    @objc private func copyTapped() {
        UIPasteboard.general.image = renderImage()
        presentToast(String(localized: "share_image.copied"))
    }

    @objc private func saveTapped() {
        let image = renderImage()
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.presentToast(String(localized: "share_image.save_denied"))
                    return
                }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                    self.presentToast(String(localized: "share_image.saved"))
                } catch {
                    self.presentToast(String(localized: "share_image.save_failed"))
                }
            }
        }
    }

    private func presentToast(_ message: String) {
        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        container.layer.cornerRadius = 10
        container.layer.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.alpha = 0

        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.font = FontManager.shared.font(size: 14, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        UIView.animate(withDuration: 0.2) {
            container.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 1.2) {
                container.alpha = 0
            } completion: { _ in
                container.removeFromSuperview()
            }
        }
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
