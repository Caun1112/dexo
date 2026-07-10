import SDWebImage
import UIKit

struct TopicCellMetadata: Equatable {
    let categoryName: String?
    let visibleTagNames: [String]
    let hiddenTagCount: Int
    let allTagNames: [String]

    init(categoryName: String?, tags: [TopicListTag], maximumVisibleTags: Int = 2) {
        let normalizedCategory = categoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.categoryName = normalizedCategory?.isEmpty == false ? normalizedCategory : nil

        allTagNames = tags.map(\.name)
        let visibleCount = min(max(maximumVisibleTags, 0), tags.count)
        visibleTagNames = Array(allTagNames.prefix(visibleCount))
        hiddenTagCount = tags.count - visibleCount
    }

    var displayText: String {
        var components = categoryName.map { [$0] } ?? []
        components.append(contentsOf: visibleTagNames)
        var text = components.joined(separator: " · ")
        if hiddenTagCount > 0 {
            text += text.isEmpty ? "+\(hiddenTagCount)" : " +\(hiddenTagCount)"
        }
        return text
    }
}

final class TopicCell: UITableViewCell {
    static let reuseIdentifier = "TopicCell"

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

    private let replyCountLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 16, weight: .bold)
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let categoryLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let tagStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return stack
    }()

    private let metadataStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
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
        contentView.addSubview(replyCountLabel)
        contentView.addSubview(metadataStack)
        contentView.addSubview(timeLabel)
        metadataStack.addArrangedSubview(categoryLabel)
        metadataStack.addArrangedSubview(tagStack)

        isAccessibilityElement = true
        accessibilityTraits = .button

        avatarWidthConstraint = avatarImageView.widthAnchor.constraint(equalToConstant: Self.baseAvatarSize)
        avatarHeightConstraint = avatarImageView.heightAnchor.constraint(equalToConstant: Self.baseAvatarSize)

        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatarWidthConstraint,
            avatarHeightConstraint,

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: replyCountLabel.leadingAnchor, constant: -10),

            replyCountLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            replyCountLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            replyCountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),

            metadataStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            metadataStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            metadataStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            timeLabel.centerYAnchor.constraint(equalTo: metadataStack.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: metadataStack.trailingAnchor, constant: 8),
        ])
    }

    func configure(
        with topic: DiscourseTopicList.Topic,
        avatarURL: URL?,
        categoryName: String?,
        categoryColor: UIColor?,
        timestampKind: TopicTimestampKind = .activity,
    ) {
        let titleFont = FontManager.shared.font(size: 16, weight: .medium)
        let replyFont = FontManager.shared.font(size: 16, weight: .bold)
        let metadataFont = FontManager.shared.font(size: 12)
        titleLabel.font = titleFont
        replyCountLabel.font = replyFont
        categoryLabel.font = metadataFont
        timeLabel.font = metadataFont
        tagStack.arrangedSubviews.forEach { view in
            tagStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let avatarSize = FontManager.shared.scaled(Self.baseAvatarSize)
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        avatarImageView.layer.cornerRadius = avatarSize / 2

        Self.applyEmojiTitle(topic.fancyTitle, to: titleLabel)

        // Reply count with gray→orange color
        let replies = max(topic.postsCount - 1, 0)
        replyCountLabel.text = "\(replies)"
        replyCountLabel.textColor = Self.replyCountColor(replies)

        // Category and topic tags share a compact metadata line. Tags are
        // visual badges only; the cell remains the single tap target.
        let metadataModel = TopicCellMetadata(categoryName: categoryName, tags: topic.tags)
        let metadata = NSMutableAttributedString()
        if let name = metadataModel.categoryName {
            if let color = categoryColor {
                let dot = NSTextAttachment()
                let dotConfig = UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                dot.image = UIImage(systemName: "circle.fill", withConfiguration: dotConfig)?.withTintColor(color, renderingMode: .alwaysOriginal)
                metadata.append(NSAttributedString(attachment: dot))
                metadata.append(NSAttributedString(string: " "))
            }
            metadata.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: UIColor.secondaryLabel,
                .font: metadataFont,
            ]))
        }
        categoryLabel.attributedText = metadataModel.categoryName == nil ? nil : metadata
        categoryLabel.isHidden = metadataModel.categoryName == nil

        for tagName in metadataModel.visibleTagNames {
            tagStack.addArrangedSubview(Self.makeTagBadge(text: tagName, font: metadataFont, preservesText: false))
        }
        if metadataModel.hiddenTagCount > 0 {
            tagStack.addArrangedSubview(Self.makeTagBadge(text: "+\(metadataModel.hiddenTagCount)", font: metadataFont, preservesText: true))
        }
        tagStack.isHidden = tagStack.arrangedSubviews.isEmpty

        // Time
        timeLabel.text = Self.formatDate(timestampKind.dateString(for: topic))

        // Avatar
        if let url = avatarURL {
            avatarImageView.sd_setImage(with: url, context: ImageCacheManager.shared.avatarContext)
        } else {
            avatarImageView.image = nil
        }

        let repliesText = String(localized: "topic.cell.a11y.replies \(replies)")
        let tagsText: String? = metadataModel.allTagNames.isEmpty
            ? nil
            : String(localized: "topic.cell.a11y.tags \(metadataModel.allTagNames.joined(separator: ", "))")
        let timeText = timeLabel.text.map { time in
            switch timestampKind {
            case .activity:
                return String(localized: "topic.cell.a11y.activity \(time)")
            case .created:
                return String(localized: "topic.cell.a11y.created \(time)")
            }
        }
        let parts = [topic.title, metadataModel.categoryName, tagsText, repliesText, timeText]
            .compactMap { (s: String?) -> String? in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        titleLabel.attributedText = nil
        replyCountLabel.text = nil
        categoryLabel.attributedText = nil
        categoryLabel.isHidden = false
        tagStack.arrangedSubviews.forEach { view in
            tagStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tagStack.isHidden = false
        timeLabel.text = nil
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
    }

    // MARK: - Emoji title

    private static let emojiPattern = try! NSRegularExpression(pattern: ":([\\w\\-+]+):")

    static func applyEmojiTitle(_ title: String, to label: UILabel) {
        guard !EmojiStore.lookupMap.isEmpty else {
            label.attributedText = nil
            label.text = title
            return
        }
        let matches = emojiPattern.matches(in: title, range: NSRange(title.startIndex..., in: title))
        guard !matches.isEmpty else {
            label.attributedText = nil
            label.text = title
            return
        }

        let result = NSMutableAttributedString()
        let titleFont = label.font ?? FontManager.shared.font(size: 16, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: titleFont]
        var lastEnd = title.startIndex
        var hasEmoji = false

        for match in matches {
            guard let fullRange = Range(match.range, in: title),
                  let codeRange = Range(match.range(at: 1), in: title)
            else { continue }

            let code = String(title[codeRange])

            if lastEnd < fullRange.lowerBound {
                result.append(NSAttributedString(string: String(title[lastEnd..<fullRange.lowerBound]), attributes: attrs))
            }

            if let urlString = EmojiStore.url(for: code), let url = URL(string: urlString) {
                let attachment = EmojiTextAttachment()
                attachment.emojiURL = url
                attachment.bounds = CGRect(x: 0, y: titleFont.descender, width: titleFont.lineHeight, height: titleFont.lineHeight)
                result.append(NSAttributedString(attachment: attachment))
                hasEmoji = true
            } else {
                result.append(NSAttributedString(string: String(title[fullRange]), attributes: attrs))
            }

            lastEnd = fullRange.upperBound
        }

        guard hasEmoji else {
            label.attributedText = nil
            label.text = title
            return
        }

        if lastEnd < title.endIndex {
            result.append(NSAttributedString(string: String(title[lastEnd...]), attributes: attrs))
        }

        label.attributedText = result
        loadEmojiImages(in: result, into: label)
    }

    private static func loadEmojiImages(in attributedString: NSMutableAttributedString, into label: UILabel) {
        attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedString.length)) { value, _, _ in
            guard let attachment = value as? EmojiTextAttachment, let url = attachment.emojiURL else { return }
            SDWebImageManager.shared.loadImage(with: url, options: [], context: ImageCacheManager.shared.emojiContext, progress: nil) { [weak label] image, _, _, _, _, _ in
                guard let image, let label else { return }
                attachment.image = image
                label.setNeedsDisplay()
            }
        }
    }

    // MARK: - Helpers

    private static func replyCountColor(_ count: Int) -> UIColor {
        // 0 → gray, 50+ → orange, linear in between
        let t = min(CGFloat(count) / 50.0, 1.0)
        return UIColor(
            red: 0.55 + t * 0.45, // 0.55 → 1.0
            green: 0.55 - t * 0.05, // 0.55 → 0.50
            blue: 0.58 - t * 0.58, // 0.58 → 0.0
            alpha: 1.0
        )
    }

    private static func makeTagBadge(text: String, font: UIFont, preservesText: Bool) -> UILabel {
        let label = TopicTagBadgeLabel()
        label.text = text
        label.font = font
        label.textColor = ThemeManager.shared.accentColor.withAlphaComponent(0.82)
        label.backgroundColor = ThemeManager.shared.codeBackgroundColor
        label.lineBreakMode = .byTruncatingTail
        label.layer.cornerRadius = 7
        label.layer.masksToBounds = true
        label.isAccessibilityElement = false
        label.setContentHuggingPriority(preservesText ? .required : .defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(preservesText ? .required : .defaultLow, for: .horizontal)
        return label
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func formatDate(_ isoString: String) -> String {
        guard let date = isoFormatter.date(from: isoString)
            ?? isoFormatterWithoutFractionalSeconds.date(from: isoString)
        else { return isoString }
        let now = Date()
        if abs(date.timeIntervalSince(now)) < 5 {
            return String(localized: "time.just_now")
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}

private final class TopicTagBadgeLabel: UILabel {
    private let contentInsets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetBounds = bounds.inset(by: contentInsets)
        let rect = super.textRect(forBounds: insetBounds, limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(
            top: -contentInsets.top,
            left: -contentInsets.left,
            bottom: -contentInsets.bottom,
            right: -contentInsets.right
        ))
    }
}
