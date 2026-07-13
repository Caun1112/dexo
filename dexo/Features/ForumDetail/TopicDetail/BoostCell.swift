import CookedHTML
import SDWebImage
import UIKit

final class BoostCell: UITableViewCell {
    static let reuseIdentifier = "BoostCell"

    private let rowsStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let separatorLine: UIView = {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearRows()
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .systemBackground
        contentView.addSubview(rowsStackView)
        contentView.addSubview(separatorLine)

        NSLayoutConstraint.activate([
            rowsStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            rowsStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            rowsStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rowsStackView.bottomAnchor.constraint(equalTo: separatorLine.topAnchor, constant: -8),

            separatorLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
    }

    func configure(
        post: DiscourseTopicDetail.Post,
        delegate: PostCellDelegate?,
        assetBaseURL: String,
        contentWidth: CGFloat,
        showsSeparator: Bool = true
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        separatorLine.backgroundColor = .separator
        separatorLine.isHidden = !showsSeparator
        let boosts = post.boosts
        clearRows()

        let maxRowWidth = max(contentWidth, 0)
        let chipSpacing: CGFloat = 4
        var currentRow: [(view: UIView, size: CGSize)] = []
        var currentRowWidth: CGFloat = 0

        func appendRow() {
            guard !currentRow.isEmpty else { return }
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = chipSpacing
            rowStack.alignment = .fill
            rowStack.distribution = .fill
            rowStack.translatesAutoresizingMaskIntoConstraints = false

            for (view, size) in currentRow {
                view.translatesAutoresizingMaskIntoConstraints = false
                rowStack.addArrangedSubview(view)
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalToConstant: size.width),
                    view.heightAnchor.constraint(equalToConstant: size.height),
                ])
            }

            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rowStack.addArrangedSubview(spacer)

            rowsStackView.addArrangedSubview(rowStack)
            currentRow.removeAll(keepingCapacity: true)
            currentRowWidth = 0
        }

        func appendItem(_ view: UIView, size: CGSize) {
            let projectedWidth = currentRow.isEmpty ? size.width : currentRowWidth + chipSpacing + size.width
            if !currentRow.isEmpty, projectedWidth > maxRowWidth {
                appendRow()
            }
            currentRow.append((view, size))
            currentRowWidth = currentRow.count == 1 ? size.width : currentRowWidth + chipSpacing + size.width
        }

        for boost in boosts {
            let chipView = BoostChipView()
            chipView.configure(with: boost, delegate: delegate, assetBaseURL: assetBaseURL)
            let size = chipView.sizeThatFits(CGSize(width: maxRowWidth, height: .greatestFiniteMagnitude))
            appendItem(chipView, size: size)
        }

        // Hide the "publish a boost" chip when the user can't boost (e.g. they've
        // already boosted this post — one per user). The expanded list still shows
        // so they can view or delete existing boosts.
        if post.canBoost {
            let actionChipView = BoostActionChipView()
            actionChipView.configure(post: post, delegate: delegate)
            let size = actionChipView.sizeThatFits(CGSize(width: maxRowWidth, height: .greatestFiniteMagnitude))
            appendItem(actionChipView, size: size)
        }

        appendRow()
    }

    private func clearRows() {
        for row in rowsStackView.arrangedSubviews {
            rowsStackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }
}

private final class BoostActionChipView: UIControl {
    private enum Layout {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 2
        static let iconSize: CGFloat = 16
        static let textSpacing: CGFloat = 5
        static let minimumChipHeight: CGFloat = 26
    }

    private weak var delegate: PostCellDelegate?
    private var post: DiscourseTopicDetail.Post?
    private let textFont = FontManager.shared.font(size: 13, weight: .medium)

    private let iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .systemYellow
        imageView.image = UIImage(systemName: "bolt.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 13, weight: .medium)
        label.textColor = .label
        label.text = String(localized: "reply.send")
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ThemeManager.shared.codeBackgroundColor
        addSubview(iconView)
        addSubview(titleLabel)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(post: DiscourseTopicDetail.Post, delegate: PostCellDelegate?) {
        self.post = post
        self.delegate = delegate
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconY = (bounds.height - Layout.iconSize) / 2
        iconView.frame = CGRect(x: Layout.horizontalPadding, y: iconY, width: Layout.iconSize, height: Layout.iconSize)
        let textX = iconView.frame.maxX + Layout.textSpacing
        let textWidth = max(0, bounds.width - textX - Layout.horizontalPadding)
        titleLabel.frame = CGRect(x: textX, y: 0, width: textWidth, height: bounds.height)
        layer.cornerRadius = bounds.height / 2
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelSize = titleLabel.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude))
        let width = Layout.horizontalPadding + Layout.iconSize + Layout.textSpacing + ceil(labelSize.width) + Layout.horizontalPadding
        let height = max(Layout.minimumChipHeight, max(Layout.iconSize, ceil(labelSize.height)) + Layout.verticalPadding * 2)
        return CGSize(width: ceil(width), height: ceil(height))
    }

    @objc private func handleTap() {
        guard let post else { return }
        delegate?.postCell(didTapBoostForPost: post)
    }
}

private final class BoostChipView: UIView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 2
        static let trailingPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 2
        static let avatarSize: CGFloat = 20
        static let textSpacing: CGFloat = 5
        static let minimumTextWidth: CGFloat = 10
        static let minimumChipHeight: CGFloat = 26
        static let maxChipWidthFraction: CGFloat = 0.82
    }

    private weak var delegate: PostCellDelegate?
    private var username: String?
    private var currentBoost: DiscourseTopicDetail.Boost?
    private let textFont = FontManager.shared.font(size: 13)

    private lazy var deleteInteraction = UIContextMenuInteraction(delegate: self)
    private var hasDeleteInteraction = false

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = Layout.avatarSize / 2
        imageView.layer.borderWidth = 1.5
        imageView.layer.borderColor = UIColor.systemBackground.cgColor
        imageView.backgroundColor = .secondarySystemBackground
        return imageView
    }()

    private let textView: LinkTextView = {
        let textView = LinkTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 1
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [.foregroundColor: UIColor.link]
        return textView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ThemeManager.shared.codeBackgroundColor
        addSubview(avatarImageView)
        addSubview(textView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(avatarTapped))
        avatarImageView.addGestureRecognizer(tapGesture)
        avatarImageView.isUserInteractionEnabled = true
        textView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with boost: DiscourseTopicDetail.Boost, delegate: PostCellDelegate?, assetBaseURL: String) {
        self.delegate = delegate
        currentBoost = boost
        username = boost.user.username

        if boost.canDelete == true {
            if !hasDeleteInteraction {
                addInteraction(deleteInteraction)
                hasDeleteInteraction = true
            }
        } else if hasDeleteInteraction {
            removeInteraction(deleteInteraction)
            hasDeleteInteraction = false
        }

        let sizedAvatar = boost.user.avatarTemplate?.replacingOccurrences(of: "{size}", with: "48")
        if let sizedAvatar {
            let urlString = sizedAvatar.hasPrefix("http") ? sizedAvatar : assetBaseURL + sizedAvatar
            if let url = URL(string: urlString) {
                avatarImageView.sd_setImage(with: url, context: ImageCacheManager.shared.avatarContext)
            }
        }

        let inlineNodes = Self.inlineNodes(from: boost.cooked, baseURL: assetBaseURL)
        let attributedText = inlineNodes.attributedString(
            config: AttributedStringConfig(
                baseFont: textFont,
                baseColor: .label,
                linkColor: .link,
                codeFont: FontManager.shared.monospacedFont(size: textFont.pointSize),
                codeBackgroundColor: .secondarySystemBackground
            )
        )
        textView.attributedText = attributedText
        loadInlineImages(in: textView)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let contentX = Layout.horizontalPadding
        let contentY = Layout.verticalPadding
        let avatarY = (bounds.height - Layout.avatarSize) / 2
        avatarImageView.frame = CGRect(
            x: contentX,
            y: avatarY,
            width: Layout.avatarSize,
            height: Layout.avatarSize
        )

        let textX = avatarImageView.frame.maxX + Layout.textSpacing
        let textWidth = max(
            Layout.minimumTextWidth,
            bounds.width - textX - Layout.trailingPadding
        )
        let textHeight = max(ceil(textFont.lineHeight), ceil(textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height))
        textView.frame = CGRect(
            x: textX,
            y: max(contentY, (bounds.height - textHeight) / 2),
            width: textWidth,
            height: textHeight
        )

        layer.cornerRadius = bounds.height / 2
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let maxWidth = max(120, size.width * Layout.maxChipWidthFraction)
        let maxTextWidth = max(
            Layout.minimumTextWidth,
            maxWidth - Layout.horizontalPadding - Layout.avatarSize - Layout.textSpacing - Layout.trailingPadding
        )
        let textSize = measuredTextSize(maxWidth: maxTextWidth)
        let width = min(
            maxWidth,
            Layout.horizontalPadding + Layout.avatarSize + Layout.textSpacing + textSize.width + Layout.trailingPadding
        )
        let height = max(
            Layout.minimumChipHeight,
            max(Layout.avatarSize, textSize.height) + Layout.verticalPadding * 2
        )
        return CGSize(width: ceil(width), height: ceil(height))
    }

    @objc private func avatarTapped() {
        guard let username else { return }
        delegate?.postCell(didTapAvatarForUsername: username)
    }

    private func measuredTextSize(maxWidth: CGFloat) -> CGSize {
        guard let attributedText = textView.attributedText, attributedText.length > 0 else {
            let lineHeight = ceil(textFont.lineHeight)
            return CGSize(width: Layout.minimumTextWidth, height: lineHeight)
        }

        let size = textView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(
            width: max(Layout.minimumTextWidth, ceil(size.width)),
            height: max(ceil(textFont.lineHeight), ceil(size.height))
        )
    }

    private static func inlineNodes(from cooked: String, baseURL: String) -> [InlineNode] {
        let blocks = CookedHTMLParser.parse(html: cooked, baseURL: baseURL)
        guard let first = blocks.first else { return [.text("")] }
        switch first {
        case .paragraph(let inlines) where !inlines.isEmpty:
            return inlines.flatMap { node -> [InlineNode] in
                node == .lineBreak ? [.text(" ")] : [node]
            }.trimmedWhitespace()
        case .image(let src, let alt, let width, let height, _):
            return [.image(src: src, alt: alt, width: width, height: height, isEmoji: true)]
        default:
            return [.text("")]
        }
    }

    private func loadInlineImages(in textView: UITextView) {
        guard let attributedText = textView.attributedText else { return }
        let fullRange = NSRange(location: 0, length: attributedText.length)

        var entries: [(attachment: NSTextAttachment, location: Int, url: URL)] = []
        attributedText.enumerateAttribute(.cookedHTMLImageURL, in: fullRange) { value, range, _ in
            guard let urlString = value as? String,
                  let url = URL(string: urlString) else { return }
            for index in 0 ..< range.length {
                let location = range.location + index
                if let attachment = attributedText.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment {
                    entries.append((attachment, location, url))
                }
            }
        }

        for entry in entries {
            SDWebImageManager.shared.loadImage(with: entry.url, options: [], context: ImageCacheManager.shared.emojiContext, progress: nil) { [weak textView] image, _, _, _, _, _ in
                guard let textView, let image else { return }
                entry.attachment.image = image
                textView.textStorage.edited(
                    .editedAttributes,
                    range: NSRange(location: entry.location, length: 1),
                    changeInLength: 0
                )
                textView.setNeedsLayout()
                textView.superview?.setNeedsLayout()
            }
        }
    }
}

extension BoostChipView: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        delegate?.postCell(didTapLinkURL: URL)
        return false
    }
}

extension BoostChipView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let boost = currentBoost, boost.canDelete == true else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return UIMenu() }
            return UIMenu(children: [
                UIAction(title: String(localized: "action.delete"), attributes: .destructive) { _ in
                    self.delegate?.postCell(didTapDeleteBoost: boost)
                },
            ])
        })
    }
}
