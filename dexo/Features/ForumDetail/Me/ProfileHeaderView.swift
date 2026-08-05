import CookedHTML
import SDWebImage
import UIKit

final class ProfileHeaderView: UIView {
    enum StatType: Int {
        case topics = 0
        case posts = 1
        case likes = 2
        case days = 3
    }

    enum MessageAction {
        case inbox
        case compose
    }

    var onLoginTapped: (() -> Void)?
    var onStatTapped: ((StatType) -> Void)?
    /// Invoked when the message button beside the profile identity is tapped.
    /// Own profile → navigate to the DM inbox; other profile → compose a new DM.
    var onMessageTapped: (() -> Void)?
    /// Invoked when the linux.do follow/unfollow button is tapped.
    var onFollowTapped: (() -> Void)?
    /// Invoked when the local blocklist button is tapped.
    var onLocalBlockTapped: (() -> Void)?

    private static let baseAvatarSize: CGFloat = 68
    private static let messageButtonSize: CGFloat = 44
    private var avatarWidthConstraint: NSLayoutConstraint!
    private var avatarHeightConstraint: NSLayoutConstraint!

    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .secondarySystemFill
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 14)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let displayNameLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 18, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let bioLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let joinDateLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let statsStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.distribution = .fill
        sv.alignment = .center
        sv.spacing = 14
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var messageButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        let symbol = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        config.image = UIImage(systemName: "envelope", withConfiguration: symbol)
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            self?.onMessageTapped?()
        }, for: .touchUpInside)
        return button
    }()

    private lazy var followButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            self?.onFollowTapped?()
        }, for: .touchUpInside)
        return button
    }()

    private lazy var localBlockButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .capsule
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            self?.onLocalBlockTapped?()
        }, for: .touchUpInside)
        return button
    }()

    private let profileActionSpacer = UIView()

    private let profileActionsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()

    // Login prompt state
    private let loginPromptLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "me.login_prompt")
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let loginButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "me.login")
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // Containers for switching between states
    private let loggedInContainer: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .leading
        sv.spacing = 8
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let loggedOutContainer: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .center
        sv.spacing = 16
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        // 头像 + 名字横排
        let nameStack = UIStackView(arrangedSubviews: [displayNameLabel, usernameLabel])
        nameStack.axis = .vertical
        nameStack.alignment = .fill
        nameStack.spacing = 2
        nameStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let avatarNameRow = UIStackView(arrangedSubviews: [avatarImageView, nameStack, messageButton])
        avatarNameRow.axis = .horizontal
        avatarNameRow.alignment = .center
        avatarNameRow.spacing = 12
        avatarNameRow.setCustomSpacing(8, after: nameStack)
        avatarNameRow.translatesAutoresizingMaskIntoConstraints = false

        profileActionsStack.addArrangedSubview(followButton)
        profileActionsStack.addArrangedSubview(profileActionSpacer)
        profileActionsStack.addArrangedSubview(localBlockButton)

        loggedInContainer.addArrangedSubview(avatarNameRow)
        loggedInContainer.addArrangedSubview(titleLabel)
        loggedInContainer.addArrangedSubview(bioLabel)
        loggedInContainer.addArrangedSubview(profileActionsStack)

        loggedInContainer.setCustomSpacing(8, after: avatarNameRow)
        loggedInContainer.setCustomSpacing(4, after: titleLabel)
        loggedInContainer.setCustomSpacing(12, after: bioLabel)
        loggedInContainer.setCustomSpacing(16, after: profileActionsStack)

        loggedInContainer.addArrangedSubview(statsStackView)

        loggedInContainer.addArrangedSubview(joinDateLabel)
        loggedInContainer.setCustomSpacing(12, after: statsStackView)

        loggedOutContainer.addArrangedSubview(loginPromptLabel)
//        loggedOutContainer.addArrangedSubview(loginButton)

        addSubview(loggedInContainer)
        addSubview(loggedOutContainer)

        avatarWidthConstraint = avatarImageView.widthAnchor.constraint(equalToConstant: Self.baseAvatarSize)
        avatarHeightConstraint = avatarImageView.heightAnchor.constraint(equalToConstant: Self.baseAvatarSize)

        NSLayoutConstraint.activate([
            avatarWidthConstraint,
            avatarHeightConstraint,
            messageButton.widthAnchor.constraint(equalToConstant: Self.messageButtonSize),
            messageButton.heightAnchor.constraint(equalToConstant: Self.messageButtonSize),
            followButton.heightAnchor.constraint(equalToConstant: 38),
            localBlockButton.heightAnchor.constraint(equalToConstant: 38),

            // Horizontal insets align with the `.insetGrouped` cell content start
            // (section inset 20pt + cell layout margin ~12pt), using
            // `safeAreaLayoutGuide` for iPad split-view / landscape safety.
            loggedInContainer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            loggedInContainer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            loggedInContainer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            loggedInContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            loggedOutContainer.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            loggedOutContainer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 32),
            loggedOutContainer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -32),
            loggedOutContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),

            avatarNameRow.leadingAnchor.constraint(equalTo: loggedInContainer.layoutMarginsGuide.leadingAnchor),
            avatarNameRow.trailingAnchor.constraint(equalTo: loggedInContainer.layoutMarginsGuide.trailingAnchor),
            profileActionsStack.leadingAnchor.constraint(equalTo: loggedInContainer.layoutMarginsGuide.leadingAnchor),
            profileActionsStack.trailingAnchor.constraint(equalTo: loggedInContainer.layoutMarginsGuide.trailingAnchor),
            profileActionsStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            statsStackView.leadingAnchor.constraint(equalTo: loggedInContainer.layoutMarginsGuide.leadingAnchor),
            statsStackView.trailingAnchor.constraint(equalTo: loggedInContainer.layoutMarginsGuide.trailingAnchor),
        ])

        loggedInContainer.isLayoutMarginsRelativeArrangement = true
        loggedInContainer.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        loggedInContainer.backgroundColor = ThemeManager.shared.cardBackgroundColor
        loggedInContainer.layer.cornerRadius = 18
        loggedInContainer.clipsToBounds = true

//        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
    }

    func configure(
        user: DiscourseCurrentUser?,
        userProfile: DiscourseUserProfile?,
        summary: DiscourseUserSummary?,
        messageAction: MessageAction,
        assetBaseURL: String,
        showsFollowButton: Bool = false,
        isFollowing: Bool = false,
        isFollowLoading: Bool = false,
        showsLocalBlockButton: Bool = false,
        isLocallyBlocked: Bool = false
    ) {
        let avatarSize = FontManager.shared.scaled(Self.baseAvatarSize)
        let theme = ThemeManager.shared
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        avatarImageView.layer.cornerRadius = avatarSize / 2
        avatarImageView.backgroundColor = theme.backgroundColor
        loggedInContainer.backgroundColor = theme.cardBackgroundColor
        configureMessageButton(action: messageAction, theme: theme)
        configureFollowButton(
            isVisible: showsFollowButton,
            isFollowing: isFollowing,
            isLoading: isFollowLoading,
            theme: theme
        )
        configureLocalBlockButton(
            isVisible: showsLocalBlockButton,
            isBlocked: isLocallyBlocked,
            theme: theme
        )
        profileActionsStack.isHidden = !showsFollowButton && !showsLocalBlockButton

        if let user {
            loggedInContainer.isHidden = false
            loggedOutContainer.isHidden = true

            displayNameLabel.text = userProfile?.name ?? user.name ?? user.username
            usernameLabel.text = "@\(user.username)"

            let avatarTemplate = userProfile?.avatarTemplate ?? user.avatarTemplate
            if let template = avatarTemplate {
                let sized = template.replacingOccurrences(of: "{size}", with: "240")
                let urlString = sized.hasPrefix("http") ? sized : assetBaseURL + sized
                avatarImageView.sd_setImage(with: URL(string: urlString), context: ImageCacheManager.shared.avatarContext)
            }

            if let title = userProfile?.title, !title.isEmpty {
                titleLabel.text = title
                titleLabel.isHidden = false
            } else {
                titleLabel.isHidden = true
            }

            if let cooked = userProfile?.bioCooked, !cooked.isEmpty,
               let attr = Self.renderBio(cooked: cooked), attr.length > 0
            {
                bioLabel.attributedText = attr
                bioLabel.isHidden = false
            } else {
                bioLabel.isHidden = true
            }

            if let createdAt = userProfile?.createdAt {
                joinDateLabel.text = formatJoinDate(createdAt)
                joinDateLabel.isHidden = false
            } else {
                joinDateLabel.isHidden = true
            }

            configureStats(summary: summary)
        } else {
            loggedInContainer.isHidden = true
            loggedOutContainer.isHidden = false
        }
    }

    private func configureMessageButton(action: MessageAction, theme: ThemeManager) {
        var config = messageButton.configuration ?? UIButton.Configuration.tinted()
        let symbol = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        config.image = UIImage(systemName: "envelope", withConfiguration: symbol)
        config.title = nil
        config.baseForegroundColor = theme.accentColor
        config.baseBackgroundColor = theme.accentColor
        messageButton.configuration = config

        switch action {
        case .inbox:
            messageButton.accessibilityLabel = String(localized: "me.messages")
        case .compose:
            messageButton.accessibilityLabel = String(localized: "user.send_message")
        }
    }

    private func configureFollowButton(
        isVisible: Bool,
        isFollowing: Bool,
        isLoading: Bool,
        theme: ThemeManager
    ) {
        followButton.isHidden = !isVisible
        followButton.isEnabled = !isLoading

        var config = isFollowing ? UIButton.Configuration.tinted() : UIButton.Configuration.filled()
        let visibleTitle = isFollowing
            ? String(localized: "user.following")
            : String(localized: "user.follow")
        let actionTitle = isFollowing
            ? String(localized: "user.unfollow")
            : String(localized: "user.follow")
        config.title = visibleTitle
        config.image = UIImage(systemName: isFollowing ? "checkmark" : "person.badge.plus")
        config.imagePadding = 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        config.cornerStyle = .capsule
        config.showsActivityIndicator = isLoading
        config.baseForegroundColor = isFollowing ? theme.accentColor : nil
        config.baseBackgroundColor = theme.accentColor
        followButton.configuration = config
        followButton.accessibilityLabel = actionTitle
        followButton.accessibilityTraits = isFollowing ? [.button, .selected] : .button
    }

    private func configureLocalBlockButton(
        isVisible: Bool,
        isBlocked: Bool,
        theme: ThemeManager
    ) {
        localBlockButton.isHidden = !isVisible

        var config = UIButton.Configuration.tinted()
        let actionTitle = isBlocked
            ? String(localized: "user.local_unblock")
            : String(localized: "user.local_block")
        config.title = isBlocked
            ? String(localized: "user.local_blocked")
            : String(localized: "user.local_block.compact")
        config.image = UIImage(systemName: isBlocked ? "checkmark" : "person.crop.circle.badge.xmark")
        config.imagePadding = 5
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.cornerStyle = .capsule
        config.baseForegroundColor = isBlocked ? .systemRed : .secondaryLabel
        config.baseBackgroundColor = isBlocked ? .systemRed : theme.backgroundColor
        localBlockButton.configuration = config
        localBlockButton.accessibilityLabel = actionTitle
        localBlockButton.accessibilityTraits = isBlocked ? [.button, .selected] : .button
    }

    private func formatJoinDate(_ dateString: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFormatter.date(from: dateString)
            ?? ISO8601DateFormatter().date(from: dateString)
        guard let date else { return "" }
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .none
        return String(localized: "me.joined_date \(displayFormatter.string(from: date))")
    }

    private func configureStats(summary: DiscourseUserSummary?) {
        statsStackView.arrangedSubviews.forEach {
            statsStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if let summary {
            let items: [(String, Int, StatType)] = [
                (String(localized: "me.stats.topics"), summary.topicCount, .topics),
                (String(localized: "me.stats.posts"), summary.postCount, .posts),
                (String(localized: "me.stats.likes"), summary.likesReceived, .likes),
                (String(localized: "me.stats.days"), summary.daysVisited, .days),
            ]

            for (label, value, statType) in items {
                let statView = createStatView(title: label, value: value, statType: statType)
                statsStackView.addArrangedSubview(statView)
            }
        }

        statsStackView.distribution = .fillEqually
        statsStackView.spacing = 8
    }

    private func createStatView(title: String, value: Int, statType: StatType) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 1
        container.isUserInteractionEnabled = true
        container.tag = statType.rawValue
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.backgroundColor = ThemeManager.shared.accentColor.withAlphaComponent(0.10)
        container.layer.cornerRadius = 12
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)

        let tap = UITapGestureRecognizer(target: self, action: #selector(statTapped(_:)))
        container.addGestureRecognizer(tap)

        let valueLabel = UILabel()
        valueLabel.font = FontManager.shared.font(size: 15, weight: .bold)
        valueLabel.text = "\(value)"
        valueLabel.textAlignment = .center

        let titleLabel = UILabel()
        titleLabel.font = FontManager.shared.font(size: 10)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = title
        titleLabel.textAlignment = .center

        container.addArrangedSubview(valueLabel)
        container.addArrangedSubview(titleLabel)
        return container
    }

    @objc private func statTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view,
              let statType = StatType(rawValue: view.tag) else { return }
        onStatTapped?(statType)
    }

    @objc private func loginTapped() {
        onLoginTapped?()
    }

    private static func renderBio(cooked: String) -> NSAttributedString? {
        let blocks = CookedHTMLParser.parse(html: cooked)
        let config = AttributedStringConfig(
            baseFont: FontManager.shared.font(size: 14),
            baseColor: .secondaryLabel,
            codeFont: FontManager.shared.monospacedFont(size: 13),
            codeBackgroundColor: ThemeManager.shared.codeBackgroundColor
        )
        let result = NSMutableAttributedString()
        for block in blocks {
            guard case .paragraph(let inlines) = block else { continue }
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(inlines.attributedString(config: config))
        }
        return result.length > 0 ? result : nil
    }
}
