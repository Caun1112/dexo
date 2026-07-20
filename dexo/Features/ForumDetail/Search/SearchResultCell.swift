import SDWebImage
import UIKit

final class SearchResultCell: UITableViewCell {
    static let reuseIdentifier = "SearchResultCell"

    private static let baseAvatarSize: CGFloat = 36
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

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 16, weight: .medium)
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let blurbLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var bottomToBlurb: NSLayoutConstraint!
    private var bottomToUsername: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        contentView.addSubview(avatarImageView)
        contentView.addSubview(usernameLabel)
        contentView.addSubview(titleLabel)
        contentView.addSubview(blurbLabel)

        bottomToBlurb = blurbLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        bottomToUsername = titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)

        avatarWidthConstraint = avatarImageView.widthAnchor.constraint(equalToConstant: Self.baseAvatarSize)
        avatarHeightConstraint = avatarImageView.heightAnchor.constraint(equalToConstant: Self.baseAvatarSize)

        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatarWidthConstraint,
            avatarHeightConstraint,

            usernameLabel.topAnchor.constraint(equalTo: avatarImageView.topAnchor),
            usernameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),

            titleLabel.topAnchor.constraint(equalTo: usernameLabel.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: usernameLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            blurbLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            blurbLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            blurbLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    func configure(
        with post: DiscourseSearchResult.SearchPost,
        topicTitle: String?,
        assetBaseURL: String,
        isLocallyRead: Bool = false
    ) {
        let avatarSize = FontManager.shared.scaled(Self.baseAvatarSize)
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        avatarImageView.layer.cornerRadius = avatarSize / 2

        // Use topic title when available, fall back to headline
        if let topicTitle, !topicTitle.isEmpty {
            titleLabel.attributedText = nil
            titleLabel.text = topicTitle
            titleLabel.textColor = isLocallyRead ? .secondaryLabel : .label
        } else if let headline = post.topicTitleHeadline {
            titleLabel.attributedText = Self.highlightedString(
                html: headline,
                baseFont: FontManager.shared.font(size: 16, weight: .medium),
                highlightFont: FontManager.shared.font(size: 16, weight: .bold),
                baseColor: isLocallyRead ? .secondaryLabel : .label
            )
        } else {
            titleLabel.attributedText = nil
            titleLabel.text = nil
        }

        usernameLabel.text = post.username

        // Show blurb for replies
        let hasBlurb = post.blurb != nil && !post.blurb!.isEmpty
        if hasBlurb {
            blurbLabel.attributedText = Self.highlightedString(
                html: post.blurb!,
                baseFont: FontManager.shared.font(size: 14),
                highlightFont: FontManager.shared.font(size: 14, weight: .semibold),
                baseColor: isLocallyRead ? .tertiaryLabel : .secondaryLabel
            )
            blurbLabel.isHidden = false
            bottomToUsername.isActive = false
            bottomToBlurb.isActive = true
        } else {
            blurbLabel.isHidden = true
            bottomToBlurb.isActive = false
            bottomToUsername.isActive = true
        }

        if let template = post.avatarTemplate {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            let urlString = sized.hasPrefix("http") ? sized : assetBaseURL + sized
            avatarImageView.sd_setImage(with: URL(string: urlString), context: ImageCacheManager.shared.avatarContext)
        } else {
            avatarImageView.image = nil
        }
        avatarImageView.alpha = isLocallyRead ? 0.7 : 1
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        titleLabel.attributedText = nil
        blurbLabel.attributedText = nil
        usernameLabel.text = nil
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        avatarImageView.alpha = 1
        titleLabel.textColor = .label
    }

    // MARK: - Search Highlight Parsing

    /// Parses simple HTML with `<span class="search-highlight">` tags into an attributed string
    /// where highlighted terms use `highlightFont` and the rest uses `baseFont`.
    private static func highlightedString(
        html: String,
        baseFont: UIFont,
        highlightFont: UIFont,
        baseColor: UIColor
    ) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: baseColor]
        let highlightAttrs: [NSAttributedString.Key: Any] = [.font: highlightFont, .foregroundColor: baseColor]

        let result = NSMutableAttributedString()
        let scanner = Scanner(string: html)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            // Scan text before the next tag
            if let text = scanner.scanUpToString("<") {
                result.append(NSAttributedString(string: text, attributes: baseAttrs))
            }

            guard !scanner.isAtEnd else { break }

            // Check if this is a search-highlight span
            if scanner.scanString("<span class=\"search-highlight\">") != nil {
                if let highlighted = scanner.scanUpToString("</span>") {
                    result.append(NSAttributedString(string: highlighted, attributes: highlightAttrs))
                }
                _ = scanner.scanString("</span>")
            } else if scanner.scanString("<") != nil {
                // Skip other HTML tags
                if let tagContent = scanner.scanUpToString(">") {
                    _ = tagContent // discard
                }
                _ = scanner.scanString(">")
            }
        }

        return result
    }
}
