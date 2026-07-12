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

    var onLoginTapped: (() -> Void)?
    var onStatTapped: ((StatType) -> Void)?
    /// Invoked when the message button on the stats row is tapped.
    /// Own profile → navigate to the DM inbox; other profile → compose a new DM.
    var onMessageTapped: (() -> Void)?

    private static let baseAvatarSize: CGFloat = 68
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
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let displayNameLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 18, weight: .bold)
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
        let symbol = UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        config.image = UIImage(systemName: "envelope", withConfiguration: symbol)
        config.imagePadding = 5
        config.title = String(localized: "me.messages")
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 11, bottom: 5, trailing: 13)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = FontManager.shared.font(size: 12, weight: .semibold)
            return out
        }
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            self?.onMessageTapped?()
        }, for: .touchUpInside)
        return button
    }()

    private lazy var messageButtonRow: UIStackView = {
        let row = UIStackView(arrangedSubviews: [messageButton])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
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
        nameStack.alignment = .leading
        nameStack.spacing = 2

        let avatarNameRow = UIStackView(arrangedSubviews: [avatarImageView, nameStack])
        avatarNameRow.axis = .horizontal
        avatarNameRow.alignment = .center
        avatarNameRow.spacing = 12

        loggedInContainer.addArrangedSubview(avatarNameRow)
        loggedInContainer.addArrangedSubview(titleLabel)
        loggedInContainer.addArrangedSubview(bioLabel)

        loggedInContainer.setCustomSpacing(8, after: avatarNameRow)
        loggedInContainer.setCustomSpacing(4, after: titleLabel)
        loggedInContainer.setCustomSpacing(8, after: bioLabel)

        loggedInContainer.addArrangedSubview(statsStackView)
        loggedInContainer.setCustomSpacing(16, after: bioLabel)

        loggedInContainer.addArrangedSubview(joinDateLabel)
        loggedInContainer.setCustomSpacing(12, after: statsStackView)
        loggedInContainer.addArrangedSubview(messageButtonRow)
        loggedInContainer.setCustomSpacing(12, after: joinDateLabel)

        loggedOutContainer.addArrangedSubview(loginPromptLabel)
//        loggedOutContainer.addArrangedSubview(loginButton)

        addSubview(loggedInContainer)
        addSubview(loggedOutContainer)

        avatarWidthConstraint = avatarImageView.widthAnchor.constraint(equalToConstant: Self.baseAvatarSize)
        avatarHeightConstraint = avatarImageView.heightAnchor.constraint(equalToConstant: Self.baseAvatarSize)

        NSLayoutConstraint.activate([
            avatarWidthConstraint,
            avatarHeightConstraint,

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

    func configure(user: DiscourseCurrentUser?, userProfile: DiscourseUserProfile?, summary: DiscourseUserSummary?, assetBaseURL: String) {
        let avatarSize = FontManager.shared.scaled(Self.baseAvatarSize)
        let theme = ThemeManager.shared
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        avatarImageView.layer.cornerRadius = avatarSize / 2
        avatarImageView.backgroundColor = theme.backgroundColor
        loggedInContainer.backgroundColor = theme.cardBackgroundColor

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
