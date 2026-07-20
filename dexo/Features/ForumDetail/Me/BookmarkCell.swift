import SDWebImage
import UIKit

final class BookmarkCell: UITableViewCell {
    static let reuseIdentifier = "BookmarkCell"

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 16, weight: .medium)
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let excerptLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 14)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

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
        contentView.addSubview(titleLabel)
        contentView.addSubview(excerptLabel)
        contentView.addSubview(timeLabel)

        avatarWidthConstraint = avatarImageView.widthAnchor.constraint(equalToConstant: Self.baseAvatarSize)
        avatarHeightConstraint = avatarImageView.heightAnchor.constraint(equalToConstant: Self.baseAvatarSize)

        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatarWidthConstraint,
            avatarHeightConstraint,

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            excerptLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            excerptLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            excerptLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            timeLabel.topAnchor.constraint(equalTo: excerptLabel.bottomAnchor, constant: 4),
            timeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    func configure(with bookmark: DiscourseBookmark, assetBaseURL: String, isLocallyRead: Bool = false) {
        let avatarSize = FontManager.shared.scaled(Self.baseAvatarSize)
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        avatarImageView.layer.cornerRadius = avatarSize / 2

        titleLabel.text = bookmark.title ?? bookmark.name
        titleLabel.textColor = isLocallyRead ? .secondaryLabel : .label
        excerptLabel.text = bookmark.excerpt?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        if let createdAt = bookmark.createdAt {
            timeLabel.text = Self.formatDate(createdAt)
        } else {
            timeLabel.text = nil
        }

        if let template = bookmark.avatarTemplate {
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
        excerptLabel.text = nil
        timeLabel.text = nil
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        avatarImageView.alpha = 1
        titleLabel.textColor = .label
    }

    private static func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else { return isoString }
        let now = Date()
        if abs(date.timeIntervalSince(now)) < 5 {
            return String(localized: "time.just_now")
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: now)
    }
}
