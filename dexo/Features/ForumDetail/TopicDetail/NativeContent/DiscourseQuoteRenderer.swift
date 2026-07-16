import CookedHTML
import SDWebImage
import UIKit

enum DiscourseQuoteRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .discourseQuote = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .discourseQuote(let username, let avatarURL, let topicTitle, let topicURL, let categoryName, let categoryURL, let content) = block else {
            return UIView()
        }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = ThemeManager.shared.codeBackgroundColor

        // Header: avatar + (username OR topic title + category badge)
        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerStack)

        let avatarSize = FontManager.shared.scaled(20)
        let avatarImageView = UIImageView()
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = avatarSize / 2
        avatarImageView.backgroundColor = .secondarySystemFill
        headerStack.addArrangedSubview(avatarImageView)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: avatarSize),
            avatarImageView.heightAnchor.constraint(equalToConstant: avatarSize),
        ])

        if let avatarURL, let url = URL(string: avatarURL) {
            avatarImageView.sd_setImage(with: url, context: ImageCacheManager.shared.avatarContext)
        }

        if let topicTitle, !topicTitle.isEmpty {
            // Topic-link variant: title button + optional category badge
            let titleButton = UIButton(type: .system)
            titleButton.setTitle(topicTitle, for: .normal)
            titleButton.titleLabel?.font = FontManager.shared.font(size: 13, weight: .semibold)
            titleButton.titleLabel?.lineBreakMode = .byTruncatingTail
            titleButton.setTitleColor(.link, for: .normal)
            titleButton.contentHorizontalAlignment = .leading
            // Hug tight (high) so a short title doesn't stretch the button and push
            // the category badge to the far right. Low compression resistance still
            // lets long titles shrink + tail-truncate when the stack can't fit them.
            titleButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let topicURL, let url = URL(string: topicURL) {
                titleButton.addAction(UIAction { _ in
                    delegate?.postCell(didTapLinkURL: url)
                }, for: .touchUpInside)
            }
            headerStack.addArrangedSubview(titleButton)

            if let categoryName, !categoryName.isEmpty {
                let badge = CategoryBadgeView(name: categoryName)
                badge.setContentHuggingPriority(.required, for: .horizontal)
                badge.setContentCompressionResistancePriority(.required, for: .horizontal)
                if let categoryURL, let url = URL(string: categoryURL) {
                    let tap = UITapGestureRecognizer()
                    badge.addGestureRecognizer(tap)
                    badge.isUserInteractionEnabled = true
                    tap.addTarget(badge, action: #selector(CategoryBadgeView.handleTap))
                    badge.tapAction = { delegate?.postCell(didTapLinkURL: url) }
                }
                headerStack.addArrangedSubview(badge)
            }
        } else if let username, !username.isEmpty {
            // Username variant (existing behavior)
            let nameLabel = UILabel()
            nameLabel.font = FontManager.shared.font(size: 13, weight: .semibold)
            nameLabel.textColor = .secondaryLabel
            nameLabel.text = username
            headerStack.addArrangedSubview(nameLabel)
        }

        // Vertical bar + content
        let bar = UIView()
        bar.backgroundColor = ThemeManager.shared.quoteBarColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 1.5
        container.addSubview(bar)

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        let quoteConfig = NativeRenderConfig(
            baseFont: config.baseFont.withSize(config.baseFont.pointSize - 1),
            baseColor: .secondaryLabel,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - 36,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )

        let views = NativeContentRenderer.renderBlocks(content, config: quoteConfig, delegate: delegate)
        for view in views {
            contentStack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),

            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            headerStack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            // `lessThanOrEqualTo` so the stack hugs to its natural content width when
            // the title is short — title+badge sit next to each other at the leading
            // side with any extra space left blank, instead of the button stretching
            // and pushing the badge to the trailing edge.
            { let c = headerStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12); c.priority = .init(999); return c }(),

            contentStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            { let c = contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12); c.priority = .init(999); return c }(),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        return container
    }
}

// MARK: - Category Badge

private class CategoryBadgeView: UIView {
    var tapAction: (() -> Void)?

    init(name: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = name
        label.font = FontManager.shared.font(size: 11, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        backgroundColor = .tertiarySystemBackground
        layer.cornerRadius = 3
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func handleTap() {
        tapAction?()
    }
}
