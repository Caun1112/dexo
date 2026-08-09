import CookedHTML
import SDWebImage
import UIKit

/// Background / card colour pairs offered in the share-image preview.
enum ShareImageTheme: Int, CaseIterable {
    case classic
    case light
    case dark
    case black
    case blue
    case green

    var title: String {
        switch self {
        case .classic: return String(localized: "share_image.theme.classic")
        case .light: return String(localized: "share_image.theme.light")
        case .dark: return String(localized: "share_image.theme.dark")
        case .black: return String(localized: "share_image.theme.black")
        case .blue: return String(localized: "share_image.theme.blue")
        case .green: return String(localized: "share_image.theme.green")
        }
    }

    var backgroundColor: UIColor {
        switch self {
        case .classic: return UIColor(red: 0.976, green: 0.945, blue: 0.894, alpha: 1)
        case .light: return .white
        case .dark: return UIColor(white: 0.118, alpha: 1)
        case .black: return .black
        case .blue: return UIColor(red: 0.910, green: 0.957, blue: 0.988, alpha: 1)
        case .green: return UIColor(red: 0.910, green: 0.961, blue: 0.914, alpha: 1)
        }
    }

    var cardColor: UIColor {
        switch self {
        case .classic, .blue, .green: return .white
        case .light: return UIColor(white: 0.961, alpha: 1)
        case .dark: return UIColor(white: 0.176, alpha: 1)
        case .black: return UIColor(white: 0.102, alpha: 1)
        }
    }

    var isDark: Bool {
        self == .dark || self == .black
    }

    var textColor: UIColor { isDark ? .white : .black }

    var secondaryTextColor: UIColor {
        isDark ? UIColor(white: 1, alpha: 0.6) : UIColor(white: 0, alpha: 0.6)
    }

    var borderColor: UIColor {
        isDark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0, alpha: 0.1)
    }
}

/// Which parts of the card are drawn.
struct ShareImageOptions: Equatable {
    var showsSite = true
    var showsTitle = true
    var showsAuthor = true
    var showsContent = true
    var showsLink = true
}

/// Offscreen-renderable card for one post. Laid out with autolayout at a fixed
/// width so `snapshot()` can rasterize the whole thing, however tall it gets.
final class ShareImageCardView: UIView {
    /// Card width in points. Matches the userscript-era 375pt canvas, which
    /// keeps the exported image a sensible size for chat apps.
    static let cardWidth: CGFloat = 375
    private static let outerPadding: CGFloat = 20
    private static let contentPadding: CGFloat = 12

    private let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.outerPadding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.outerPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.outerPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.outerPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        post: DiscourseTopicDetail.Post,
        topicTitle: String,
        topicId: Int,
        baseURL: String,
        annotatedBlocks: [AnnotatedBlock],
        theme: ShareImageTheme,
        options: ShareImageOptions
    ) {
        backgroundColor = theme.backgroundColor
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var isFirst = true
        func append(_ view: UIView, spacing: CGFloat) {
            if !isFirst, let previous = stack.arrangedSubviews.last {
                stack.setCustomSpacing(spacing, after: previous)
            }
            stack.addArrangedSubview(view)
            isFirst = false
        }

        if options.showsSite {
            append(makeSiteHeader(baseURL: baseURL, theme: theme), spacing: 16)
        }
        if options.showsTitle {
            append(makeTitleLabel(topicTitle, theme: theme), spacing: 16)
        }
        if options.showsAuthor {
            append(makeAuthorView(post: post, baseURL: baseURL, theme: theme), spacing: 12)
        }
        if options.showsContent {
            if !isFirst { append(makeSeparator(theme: theme), spacing: 12) }
            append(
                makeContentCard(annotatedBlocks: annotatedBlocks, baseURL: baseURL, theme: theme),
                spacing: 12
            )
        }
        if options.showsLink {
            if !isFirst { append(makeSeparator(theme: theme), spacing: 16) }
            append(
                makeLinkView(
                    url: "\(baseURL)/t/\(topicId)/\(post.postNumber)",
                    theme: theme
                ),
                spacing: 12
            )
        }
        if stack.arrangedSubviews.isEmpty {
            let empty = UILabel()
            empty.text = String(localized: "share_image.empty")
            empty.textColor = theme.secondaryTextColor
            empty.textAlignment = .center
            stack.addArrangedSubview(empty)
        }
    }

    /// Rasterize the laid-out card. Call after `layoutIfNeeded()` so the height
    /// reflects the final content.
    func snapshot(scale: CGFloat = 3) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        return renderer.image { context in
            // `layer.render` captures the full height even for the parts that
            // were never on screen — the card holds no visual-effect views,
            // which are the one thing that path can't reproduce.
            layer.render(in: context.cgContext)
        }
    }

    // MARK: - Sections

    private func makeSiteHeader(baseURL: String, theme: ShareImageTheme) -> UIView {
        let container = UIStackView()
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 8

        let icon = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right.fill"))
        icon.tintColor = theme.textColor.withAlphaComponent(0.8)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])

        let label = UILabel()
        label.text = URL(string: baseURL)?.host?.uppercased() ?? baseURL
        label.font = FontManager.shared.font(size: 16, weight: .semibold)
        label.textColor = theme.textColor.withAlphaComponent(0.8)

        container.addArrangedSubview(icon)
        container.addArrangedSubview(label)
        container.addArrangedSubview(UIView())
        return container
    }

    private func makeTitleLabel(_ title: String, theme: ShareImageTheme) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = FontManager.shared.font(size: 17, weight: .semibold)
        label.textColor = theme.textColor.withAlphaComponent(0.9)
        TopicCell.applyEmojiTitle(title, to: label)
        return label
    }

    private func makeAuthorView(
        post: DiscourseTopicDetail.Post,
        baseURL: String,
        theme: ShareImageTheme
    ) -> UIView {
        let container = UIStackView()
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 10

        let avatar = UIImageView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 18
        avatar.clipsToBounds = true
        avatar.backgroundColor = theme.borderColor
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
        ])
        if let template = post.avatarTemplate {
            let sized = template.replacingOccurrences(of: "{size}", with: "120")
            avatar.sd_setImage(
                with: URL(string: sized.hasPrefix("http") ? sized : baseURL + sized),
                context: ImageCacheManager.shared.avatarContext
            )
        }

        let nameLabel = UILabel()
        nameLabel.font = FontManager.shared.font(size: 14, weight: .medium)
        nameLabel.textColor = theme.textColor.withAlphaComponent(0.85)
        let displayName = post.name?.isEmpty == false ? post.name! : post.username
        nameLabel.text = displayName

        let metaLabel = UILabel()
        metaLabel.font = FontManager.shared.font(size: 12)
        metaLabel.textColor = theme.secondaryTextColor
        metaLabel.text = "@\(post.username) · \(Self.relativeDate(post.createdAt))"

        let textStack = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        container.addArrangedSubview(avatar)
        container.addArrangedSubview(textStack)
        container.addArrangedSubview(UIView())
        return container
    }

    private func makeContentCard(
        annotatedBlocks: [AnnotatedBlock],
        baseURL: String,
        theme: ShareImageTheme
    ) -> UIView {
        let card = UIView()
        card.backgroundColor = theme.cardColor
        card.layer.cornerRadius = 8
        card.clipsToBounds = true

        let contentWidth = Self.cardWidth
            - Self.outerPadding * 2
            - Self.contentPadding * 2
        let config = NativeRenderConfig(
            baseFont: FontManager.shared.font(size: 15),
            baseColor: theme.textColor.withAlphaComponent(0.9),
            linkColor: ThemeManager.shared.accentColor,
            codeFont: FontManager.shared.monospacedFont(size: 14),
            codeBackgroundColor: theme.isDark
                ? UIColor(white: 1, alpha: 0.08)
                : UIColor(white: 0, alpha: 0.05),
            contentWidth: contentWidth,
            baseURL: baseURL
        )
        // No delegate: taps are meaningless in a still image, and passing one
        // would retain the topic screen from an offscreen view.
        let views = NativeContentRenderer.renderBlocks(
            annotatedBlocks,
            config: config,
            delegate: nil
        )
        let contentStack = UIStackView(arrangedSubviews: views)
        contentStack.axis = .vertical
        contentStack.spacing = NativeContentRenderer.contentStackSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.contentPadding),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.contentPadding),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.contentPadding),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.contentPadding),
        ])
        return card
    }

    private func makeSeparator(theme: ShareImageTheme) -> UIView {
        let line = UIView()
        line.backgroundColor = theme.borderColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func makeLinkView(url: String, theme: ShareImageTheme) -> UIView {
        let container = UIStackView()
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 6

        let icon = UIImageView(image: UIImage(systemName: "link"))
        icon.tintColor = theme.secondaryTextColor
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
        ])

        let label = UILabel()
        label.text = url
        label.font = FontManager.shared.font(size: 11)
        label.textColor = theme.secondaryTextColor
        label.lineBreakMode = .byTruncatingMiddle

        container.addArrangedSubview(icon)
        container.addArrangedSubview(label)
        return container
    }

    private static func relativeDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return value }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
