import CookedHTML
import SDWebImage
import UIKit

protocol RenderUnitSizeInvalidating: AnyObject {
    func renderUnitCell(_ cell: VirtualPostBlockCell, didResolveHeight height: CGFloat, for unitId: RenderUnitID)
}

/// Draws the vertical-only portion of a tree connector through virtualized
/// body/footer rows. The header owns the elbow into the avatar; every later
/// item repeats only the columns that must remain continuous.
final class VirtualTreeContinuationView: UIView {
    private var columns: [CGFloat] = []
    var lineColor: UIColor = .separator { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(state: TreeLineState?) {
        columns = Self.columns(for: state)
        isHidden = columns.isEmpty
        setNeedsDisplay()
    }

    static func columns(for state: TreeLineState?) -> [CGFloat] {
        guard let state else { return [] }
        var values: [CGFloat] = []
        for (index, continues) in state.ancestorTrails.enumerated().dropFirst() where continues {
            values.append(TreeLineView.columnX(forDepth: min(index + 1, PostNativeCell.treeMaxIndentLevels)))
        }
        if state.depth >= 2, !state.isLastSibling {
            values.append(TreeLineView.columnX(forDepth: min(state.depth, PostNativeCell.treeMaxIndentLevels)))
        }
        if state.depth >= 1, state.hasChildren, !state.isCollapsed {
            values.append(TreeLineView.columnX(forDepth: min(state.depth + 1, PostNativeCell.treeMaxIndentLevels)))
        }
        return Array(Set(values)).sorted()
    }

    override func draw(_ rect: CGRect) {
        guard !columns.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(1)
        context.setLineCap(.square)
        for x in columns {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: rect.height))
        }
        context.strokePath()
    }
}

/// The expanded-subtree pill that sits on the child connector immediately
/// before the first child row. Virtualized posts span several cells, so the
/// pill is hosted by the post's final visible item rather than its header.
final class VirtualTreeCollapsePill: UIButton {
    static let size: CGFloat = 18
    static let bottomInset: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Self.size / 2
        layer.borderWidth = 1
        let symbol = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        setPreferredSymbolConfiguration(symbol, forImageIn: .normal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func leading(for state: TreeLineState?, isLastVisualItem: Bool) -> CGFloat? {
        guard let state,
              isLastVisualItem,
              state.depth >= 1,
              state.hasChildren,
              !state.isCollapsed
        else { return nil }
        let childDepth = min(state.depth + 1, PostNativeCell.treeMaxIndentLevels)
        return TreeLineView.columnX(forDepth: childDepth) - Self.size / 2
    }

    @discardableResult
    func configure(state: TreeLineState?, isLastVisualItem: Bool) -> CGFloat? {
        let leading = Self.leading(for: state, isLastVisualItem: isLastVisualItem)
        isHidden = leading == nil
        guard leading != nil else { return nil }
        setImage(UIImage(systemName: "minus"), for: .normal)
        backgroundColor = ThemeManager.shared.backgroundColor
        tintColor = .secondaryLabel
        layer.borderColor = UIColor.separator.cgColor
        accessibilityLabel = String(localized: "topic_detail.collapse")
        return leading
    }
}

final class VirtualTopicTitleCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualTopicTitleCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        label.font = FontManager.shared.font(size: 20, weight: .bold)
        label.textColor = .label
        label.text = title
    }
}

final class VirtualPostHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualPostHeaderCell"

    private let avatar = UIImageView()
    private let nameLabel = UILabel()
    private let usernameLabel = UILabel()
    private let timeLabel = UILabel()
    private let floorLabel = UILabel()
    private let treeLineView = TreeLineView()
    private var avatarLeadingConstraint: NSLayoutConstraint!
    private var username: String?
    var onAvatar: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeLineView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeLineView)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))

        for label in [nameLabel, usernameLabel, timeLabel, floorLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }
        contentView.addSubview(avatar)

        avatarLeadingConstraint = avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            avatarLeadingConstraint,
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: avatar.topAnchor),
            usernameLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            usernameLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            timeLabel.topAnchor.constraint(equalTo: floorLabel.bottomAnchor, constant: 2),
            floorLabel.trailingAnchor.constraint(equalTo: timeLabel.trailingAnchor),
            floorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        post: DiscourseTopicDetail.Post,
        floor: Int,
        baseURL: String,
        isOP: Bool,
        treeState: TreeLineState?
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        username = post.username
        nameLabel.font = FontManager.shared.font(size: 14, weight: .semibold)
        usernameLabel.font = FontManager.shared.font(size: 12)
        timeLabel.font = FontManager.shared.font(size: 12)
        floorLabel.font = FontManager.shared.monospacedDigitFont(size: 12)
        nameLabel.text = post.name ?? post.username
        nameLabel.textColor = isOP ? ThemeManager.shared.accentColor : .label
        usernameLabel.text = "@\(post.username)"
        usernameLabel.textColor = .secondaryLabel
        timeLabel.text = Self.displayDate(post.createdAt)
        timeLabel.textColor = .secondaryLabel
        floorLabel.text = treeState == nil ? "#\(floor)" : nil
        floorLabel.isHidden = treeState != nil
        if let treeState {
            avatarLeadingConstraint.constant = 12 + PostNativeCell.treeAvatarIndent(forDepth: treeState.depth)
            treeLineView.state = treeState
            treeLineView.connectorY = 28
            treeLineView.avatarBottomY = 44
            treeLineView.lineColor = .separator
            let drawsIncoming = treeState.depth >= 2
            let drawsOutgoing = treeState.hasChildren && !treeState.isCollapsed && treeState.depth >= 1
            treeLineView.isHidden = !(drawsIncoming || drawsOutgoing)
        } else {
            avatarLeadingConstraint.constant = 12
            treeLineView.state = nil
            treeLineView.isHidden = true
        }
        avatar.layer.cornerRadius = 16
        avatar.backgroundColor = .secondarySystemFill
        if let template = post.avatarTemplate {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            avatar.sd_setImage(with: URL(string: sized.hasPrefix("http") ? sized : baseURL + sized), context: ImageCacheManager.shared.avatarContext)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.sd_cancelCurrentImageLoad()
        avatar.image = nil
        onAvatar = nil
    }

    @objc private func avatarTapped() {
        if let username { onAvatar?(username) }
    }

    private static func displayDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return value }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

final class VirtualPostBlockCell: UICollectionViewCell, UITextViewDelegate, TopicPostIDProviding {
    static let reuseIdentifier = "VirtualPostBlockCell"
    weak var sizeDelegate: RenderUnitSizeInvalidating?
    private weak var postDelegate: PostCellDelegate?
    private var postId = 0
    var renderedPostId: Int { postId }
    private var hostedView: UIView?
    private var unitId: RenderUnitID?
    private var leadingConstraint: NSLayoutConstraint?
    private var hostedHeightConstraint: NSLayoutConstraint?
    private var acceptsDynamicHeightUpdates = false
    private var observationTokens: [NSObjectProtocol] = []
    private let treeContinuationView = VirtualTreeContinuationView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Deferred renderers may discover a larger intrinsic size while the
        // user is scrolling. Keep that content inside the stable placeholder
        // until the controller commits the queued height batch.
        contentView.clipsToBounds = true
        treeContinuationView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeContinuationView)
        NSLayoutConstraint.activate([
            treeContinuationView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeContinuationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeContinuationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeContinuationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        let center = NotificationCenter.default
        for name in [
            TappableImageContainer.intrinsicHeightDidChangeNotification,
            Notification.Name("TopicDetailsHeightDidChange"),
        ] {
            observationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let sender = note.object as? UIView,
                      self.acceptsDynamicHeightUpdates,
                      sender === self.hostedView || sender.isDescendant(of: self.hostedView ?? UIView())
                else { return }
                self.measureHostedView()
            })
        }
    }

    deinit {
        for token in observationTokens { NotificationCenter.default.removeObserver(token) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        unit: RenderUnit,
        post: DiscourseTopicDetail.Post,
        config: NativeRenderConfig,
        delegate: PostCellDelegate?,
        leadingIndent: CGFloat,
        treeState: TreeLineState?,
        detailsExpanded: Bool,
        onDetailsExpansionChange: ((Bool) -> Void)?,
        pollPendingSelections: Set<String>?,
        onPollPendingSelectionsChange: ((Set<String>) -> Void)?,
        heightPolicy: RenderUnitHeightPolicy
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        tearDownHostedView()
        postId = post.id
        unitId = unit.id
        postDelegate = delegate
        acceptsDynamicHeightUpdates = heightPolicy.acceptsDynamicUpdates
        if !acceptsDynamicHeightUpdates { sizeDelegate = nil }
        treeContinuationView.configure(state: treeState)

        let annotated = AnnotatedBlock(block: unit.block, sourceHTML: unit.sourceHTML)
        let views = TopicRenderMetrics.measure("ConfigureRenderUnitCell") {
            NativeContentRenderer.renderBlocks(
                [annotated],
                config: config,
                delegate: delegate,
                pollProvider: { name in
                    guard let poll = post.polls.first(where: { $0.name == name }) else { return nil }
                    return (poll, Set(post.pollsVotes[name] ?? []), post)
                }
            )
        }
        let view = views.first ?? UIView()
        hostedView = view
        if let detailsView = findDetailsView(in: view) {
            detailsView.setExpanded(detailsExpanded)
            detailsView.onExpansionChange = onDetailsExpansionChange
        }
        if let pollView = findPollView(in: view) {
            if let pollPendingSelections { pollView.restorePendingSelections(pollPendingSelections) }
            pollView.onPendingSelectionsChange = onPollPendingSelectionsChange
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        let leading = view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12 + leadingIndent)
        leadingConstraint = leading
        var constraints = [
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            leading,
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ]
        if !heightPolicy.acceptsDynamicUpdates {
            let height = view.heightAnchor.constraint(equalToConstant: max(0, heightPolicy.height - 8))
            hostedHeightConstraint = height
            constraints.append(height)
        }
        NSLayoutConstraint.activate(constraints)
        configureTextViews(in: view)
        setNeedsLayout()
        if acceptsDynamicHeightUpdates {
            let configuredUnitId = unit.id
            DispatchQueue.main.async { [weak self] in
                guard let self, self.unitId == configuredUnitId else { return }
                self.measureHostedView()
            }
        }
    }

    private func measureHostedView() {
        guard acceptsDynamicHeightUpdates, let hostedView, let unitId,
              hostedView.bounds.width > 0 || contentView.bounds.width > 24
        else { return }
        let width = max(1, contentView.bounds.width - 24 - (leadingConstraint?.constant ?? 12) + 12)
        let size = hostedView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if size.height > 0 { sizeDelegate?.renderUnitCell(self, didResolveHeight: ceil(size.height) + 8, for: unitId) }
    }

    private func configureTextViews(in view: UIView) {
        if let textView = view as? UITextView {
            textView.delegate = self
            loadInlineImages(in: textView)
        }
        for subview in view.subviews { configureTextViews(in: subview) }
    }

    private func findDetailsView(in view: UIView) -> DetailsCardView? {
        if let details = view as? DetailsCardView { return details }
        for subview in view.subviews {
            if let details = findDetailsView(in: subview) { return details }
        }
        return nil
    }

    private func findPollView(in view: UIView) -> PollView? {
        if let poll = view as? PollView { return poll }
        for subview in view.subviews {
            if let poll = findPollView(in: subview) { return poll }
        }
        return nil
    }

    private func loadInlineImages(in textView: UITextView) {
        guard let text = textView.attributedText, text.length > 0 else { return }
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.cookedHTMLImageURL, in: full) { value, range, _ in
            guard let raw = value as? String, let url = URL(string: raw) else { return }
            SDWebImageManager.shared.loadImage(with: url, context: ImageCacheManager.shared.emojiContext, progress: nil) { image, _, _, _, _, _ in
                guard let image else { return }
                for location in range.location..<(range.location + range.length) {
                    guard let attachment = text.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment else { continue }
                    attachment.image = image
                    textView.textStorage.edited(.editedAttributes, range: NSRange(location: location, length: 1), changeInLength: 0)
                }
            }
        }
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        postDelegate?.postCell(didTapLinkURL: URL)
        return false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tearDownHostedView()
        unitId = nil
        postId = 0
        postDelegate = nil
        sizeDelegate = nil
        acceptsDynamicHeightUpdates = false
    }

    private func tearDownHostedView() {
        findDetailsView(in: hostedView ?? UIView())?.onExpansionChange = nil
        findPollView(in: hostedView ?? UIView())?.onPendingSelectionsChange = nil
        if let image = hostedView as? TappableImageContainer { image.cancelImageLoad() }
        if let onebox = hostedView as? OneboxCardView { onebox.cancelImageLoad() }
        if let video = hostedView as? VideoCardView { video.cancelImageLoad() }
        hostedView?.removeFromSuperview()
        hostedView = nil
        hostedHeightConstraint = nil
    }
}

struct VirtualPostFooterButtonTints {
    let reply: UIColor
    let like: UIColor
    let boost: UIColor
    let more: UIColor

    static func resolve(isLiked: Bool, hasCurrentUserBoost: Bool) -> Self {
        Self(
            reply: .tertiaryLabel,
            like: isLiked ? .systemRed : .tertiaryLabel,
            boost: hasCurrentUserBoost ? .systemYellow : .tertiaryLabel,
            more: .tertiaryLabel
        )
    }
}

final class VirtualPostFooterCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualPostFooterCell"
    private let reply = UIButton(type: .system)
    private let like = UIButton(type: .system)
    private let boost = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private let treeContinuationView = VirtualTreeContinuationView()
    private let collapsePill = VirtualTreeCollapsePill()
    private let separatorLine = UIView()
    private var collapseLeadingConstraint: NSLayoutConstraint!
    var onReply: (() -> Void)?
    var onLike: (() -> Void)?
    var onBoost: (() -> Void)?
    var onCollapse: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeContinuationView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeContinuationView)
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.backgroundColor = .separator
        contentView.addSubview(separatorLine)
        reply.setImage(UIImage(systemName: "arrowshape.turn.up.left"), for: .normal)
        like.setImage(UIImage(systemName: "heart"), for: .normal)
        boost.setImage(UIImage(named: "roket.symbols"), for: .normal)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        reply.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
        like.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        boost.addTarget(self, action: #selector(boostTapped), for: .touchUpInside)
        more.showsMenuAsPrimaryAction = true
        let stack = UIStackView(arrangedSubviews: [boost, like, reply, more])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        collapsePill.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        contentView.addSubview(collapsePill)
        collapseLeadingConstraint = collapsePill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        NSLayoutConstraint.activate([
            treeContinuationView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeContinuationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeContinuationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeContinuationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            separatorLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            collapseLeadingConstraint,
            collapsePill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -VirtualTreeCollapsePill.bottomInset),
            collapsePill.widthAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
            collapsePill.heightAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        post: DiscourseTopicDetail.Post,
        menu: UIMenu,
        hidesLikeButton: Bool,
        treeState: TreeLineState?,
        isLastVisualItem: Bool
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        let liked = post.likeAction?.acted == true
        let buttonTints = VirtualPostFooterButtonTints.resolve(
            isLiked: liked,
            hasCurrentUserBoost: post.boosts.contains { $0.canDelete == true }
        )
        like.setImage(UIImage(systemName: liked ? "heart.fill" : "heart"), for: .normal)
        applyButtonTints(buttonTints)
        like.isHidden = hidesLikeButton
        boost.isHidden = !post.canBoost && post.boosts.isEmpty
        more.menu = menu
        treeContinuationView.configure(state: treeState)
        collapseLeadingConstraint.constant = collapsePill.configure(
            state: treeState,
            isLastVisualItem: isLastVisualItem
        ) ?? 0
        separatorLine.isHidden = treeState != nil
    }

    var appliedButtonTints: VirtualPostFooterButtonTints {
        VirtualPostFooterButtonTints(
            reply: reply.tintColor,
            like: like.tintColor,
            boost: boost.tintColor,
            more: more.tintColor
        )
    }

    func applyButtonTints(_ tints: VirtualPostFooterButtonTints) {
        reply.tintColor = tints.reply
        like.tintColor = tints.like
        boost.tintColor = tints.boost
        more.tintColor = tints.more
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onReply = nil
        onLike = nil
        onBoost = nil
        onCollapse = nil
        more.menu = nil
        collapsePill.configure(state: nil, isLastVisualItem: false)
    }

    @objc private func replyTapped() { onReply?() }
    @objc private func likeTapped() { onLike?() }
    @objc private func boostTapped() { onBoost?() }
    @objc private func collapseTapped() { onCollapse?() }
}

final class VirtualTopicMessageCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualTopicMessageCell"
    private let label = UILabel()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FontManager.shared.font(size: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        contentView.addSubview(label)
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(text: String) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        label.text = text
    }
    override func prepareForReuse() { super.prepareForReuse(); onTap = nil }
    @objc private func tapped() { onTap?() }
}

final class VirtualPostCollapsedCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualPostCollapsedCell"

    private let treeLineView = TreeLineView()
    private let avatar = UIImageView()
    private let expandButton = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private var avatarLeadingConstraint: NSLayoutConstraint!
    private var postId = 0
    var onExpand: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeLineView.translatesAutoresizingMaskIntoConstraints = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.backgroundColor = .secondarySystemFill
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(expandTapped)))

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.backgroundColor = .clear
        expandButton.layer.cornerRadius = 9
        expandButton.layer.borderWidth = 1
        expandButton.tintColor = .secondaryLabel
        expandButton.setImage(UIImage(systemName: "plus"), for: .normal)
        expandButton.setPreferredSymbolConfiguration(.init(pointSize: 9, weight: .bold), forImageIn: .normal)
        expandButton.accessibilityLabel = String(localized: "topic_detail.expand")
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = FontManager.shared.font(size: 13, weight: .medium)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.lineBreakMode = .byTruncatingTail

        contentView.addSubview(treeLineView)
        contentView.addSubview(avatar)
        contentView.addSubview(expandButton)
        contentView.addSubview(summaryLabel)
        avatarLeadingConstraint = avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            avatarLeadingConstraint,
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            expandButton.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            expandButton.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 18),
            expandButton.heightAnchor.constraint(equalToConstant: 18),
            summaryLabel.leadingAnchor.constraint(equalTo: expandButton.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            summaryLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(post: DiscourseTopicDetail.Post, depth: Int, treeState: TreeLineState?, baseURL: String) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        postId = post.id
        avatarLeadingConstraint.constant = 12 + PostNativeCell.treeAvatarIndent(forDepth: depth)
        let format = String(localized: "topic_detail.collapsed_summary %@ %lld")
        summaryLabel.text = String.localizedStringWithFormat(format, post.name ?? post.username, post.replyCount)
        expandButton.layer.borderColor = UIColor.separator.cgColor

        if let treeState, treeState.depth >= 2 {
            treeLineView.isHidden = false
            treeLineView.state = treeState
            treeLineView.connectorY = PostCollapsedCell.cellHeight / 2
            treeLineView.avatarBottomY = (PostCollapsedCell.cellHeight + 32) / 2
            treeLineView.lineColor = .separator
        } else {
            treeLineView.isHidden = true
            treeLineView.state = nil
        }
        if let template = post.avatarTemplate {
            let path = template.replacingOccurrences(of: "{size}", with: "96")
            avatar.sd_setImage(with: URL(string: path.hasPrefix("http") ? path : baseURL + path), context: ImageCacheManager.shared.avatarContext)
        } else {
            avatar.image = nil
        }
        avatar.layer.cornerRadius = 16
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.sd_cancelCurrentImageLoad()
        avatar.image = nil
        postId = 0
        onExpand = nil
    }

    @objc private func expandTapped() { onExpand?(postId) }
}

final class VirtualLoadMoreChildrenCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualLoadMoreChildrenCell"

    private let treeLineView = TreeLineView()
    private let glyph = UIImageView(image: UIImage(systemName: "arrow.turn.down.right"))
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var glyphLeadingConstraint: NSLayoutConstraint!
    private var parentPostId = 0
    var onLoad: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeLineView.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = .init(pointSize: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FontManager.shared.font(size: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        contentView.addSubview(treeLineView)
        contentView.addSubview(glyph)
        contentView.addSubview(titleLabel)
        contentView.addSubview(spinner)
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(loadTapped)))
        glyphLeadingConstraint = glyph.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            glyphLeadingConstraint,
            glyph.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(load: PendingChildLoad, isLoading: Bool) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        parentPostId = load.parentPostId
        glyphLeadingConstraint.constant = 12 + PostNativeCell.treeAvatarIndent(forDepth: load.depth)
        let format = String(localized: "topic_detail.view_more_replies %lld")
        titleLabel.text = String.localizedStringWithFormat(format, load.remaining)
        titleLabel.textColor = ThemeManager.shared.accentColor
        glyph.tintColor = ThemeManager.shared.accentColor
        treeLineView.state = load.treeLineState
        treeLineView.connectorY = LoadMoreChildrenCell.cellHeight / 2
        treeLineView.avatarBottomY = LoadMoreChildrenCell.cellHeight
        treeLineView.lineColor = .separator
        treeLineView.isHidden = load.treeLineState.depth < 2
        setLoading(isLoading)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        parentPostId = 0
        onLoad = nil
        setLoading(false)
    }

    private func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        glyph.isHidden = loading
        titleLabel.alpha = loading ? 0.5 : 1
    }

    @objc private func loadTapped() {
        guard !spinner.isAnimating else { return }
        setLoading(true)
        onLoad?(parentPostId)
    }
}

final class VirtualBoostsCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualBoostsCell"

    private let hostedCell = BoostCell(style: .default, reuseIdentifier: nil)
    private let treeContinuationView = VirtualTreeContinuationView()
    private let collapsePill = VirtualTreeCollapsePill()
    private var hostedLeadingConstraint: NSLayoutConstraint!
    private var collapseLeadingConstraint: NSLayoutConstraint!
    var onCollapse: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeContinuationView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeContinuationView)
        hostedCell.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostedCell)
        collapsePill.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        contentView.addSubview(collapsePill)
        hostedLeadingConstraint = hostedCell.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        collapseLeadingConstraint = collapsePill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        NSLayoutConstraint.activate([
            treeContinuationView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeContinuationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeContinuationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeContinuationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hostedCell.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostedLeadingConstraint,
            hostedCell.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostedCell.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            collapseLeadingConstraint,
            collapsePill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -VirtualTreeCollapsePill.bottomInset),
            collapsePill.widthAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
            collapsePill.heightAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        post: DiscourseTopicDetail.Post,
        delegate: PostCellDelegate?,
        assetBaseURL: String,
        contentWidth: CGFloat,
        leadingIndent: CGFloat,
        treeState: TreeLineState?
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        hostedLeadingConstraint.constant = leadingIndent
        treeContinuationView.configure(state: treeState)
        collapseLeadingConstraint.constant = collapsePill.configure(
            state: treeState,
            isLastVisualItem: true
        ) ?? 0
        hostedCell.configure(
            post: post,
            delegate: delegate,
            assetBaseURL: assetBaseURL,
            contentWidth: max(1, contentWidth - 24 - leadingIndent)
        )
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCollapse = nil
        collapsePill.configure(state: nil, isLastVisualItem: false)
    }

    @objc private func collapseTapped() { onCollapse?() }
}
