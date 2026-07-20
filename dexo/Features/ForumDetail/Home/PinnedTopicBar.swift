import UIKit

/// Slim 40pt header that compresses every pinned topic into a single bar.
/// Tap the bar to open the current pinned topic, tap the segmented indicator
/// (or swipe) to cycle through the pinned set.
final class PinnedTopicBar: UIView {
    struct Item {
        let topicId: Int
        let title: String
        let iconColor: UIColor?
        let isLocallyRead: Bool
    }

    static let height: CGFloat = 50

    var onSelect: ((Int) -> Void)?

    private(set) var items: [Item] = []
    private var currentIndex: Int = 0

    private let pinIcon: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .center
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 14, weight: .medium)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let indicator = PinnedIndicator()

    private let separator: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .fill
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height))
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeDidChange),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    private func setupUI() {
        addSubview(pinIcon)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(indicator)
        addSubview(contentStack)
        addSubview(separator)

        isAccessibilityElement = true
        accessibilityTraits = .button

        let indicatorTap = UITapGestureRecognizer(target: self, action: #selector(advance))
        indicator.addGestureRecognizer(indicatorTap)

        let barTap = UITapGestureRecognizer(target: self, action: #selector(handleBarTap))
        addGestureRecognizer(barTap)

        let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(advance))
        leftSwipe.direction = .left
        addGestureRecognizer(leftSwipe)

        let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(retreat))
        rightSwipe.direction = .right
        addGestureRecognizer(rightSwipe)

        NSLayoutConstraint.activate([
            pinIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pinIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIcon.widthAnchor.constraint(equalToConstant: 16),
            pinIcon.heightAnchor.constraint(equalToConstant: 16),

            contentStack.leadingAnchor.constraint(equalTo: pinIcon.trailingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        applyTheme()
    }

    private func applyTheme() {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        separator.backgroundColor = .separator
        titleLabel.textColor = .label
        indicator.activeColor = ThemeManager.shared.accentColor
        indicator.inactiveColor = .quaternaryLabel
    }

    func setItems(_ newItems: [Item]) {
        let preservedId = currentItem?.topicId
        items = newItems
        if let preservedId, let idx = newItems.firstIndex(where: { $0.topicId == preservedId }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        update(animated: false)
    }

    private var currentItem: Item? {
        guard !items.isEmpty, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    @objc private func handleBarTap() {
        guard let item = currentItem else { return }
        onSelect?(item.topicId)
    }

    @objc private func advance() {
        guard items.count > 1 else { return }
        currentIndex = (currentIndex + 1) % items.count
        update(animated: true)
    }

    @objc private func retreat() {
        guard items.count > 1 else { return }
        currentIndex = (currentIndex - 1 + items.count) % items.count
        update(animated: true)
    }

    @objc private func handleThemeDidChange() {
        applyTheme()
        if let item = currentItem {
            titleLabel.textColor = item.isLocallyRead ? .secondaryLabel : .label
            pinIcon.alpha = item.isLocallyRead ? 0.7 : 1
            applyIcon(for: item)
        }
        indicator.configure(totalCount: items.count, currentIndex: currentIndex, animated: false)
    }

    private func applyIcon(for item: Item) {
        let tint = item.iconColor ?? ThemeManager.shared.accentColor
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        pinIcon.image = UIImage(systemName: "pin.fill", withConfiguration: config)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    private func update(animated: Bool) {
        let multi = items.count > 1
        indicator.isHidden = !multi
        guard let item = currentItem else {
            titleLabel.text = nil
            pinIcon.image = nil
            pinIcon.alpha = 1
            return
        }
        let body: () -> Void = { [self] in
            TopicCell.applyEmojiTitle(item.title, to: titleLabel)
            titleLabel.textColor = item.isLocallyRead ? .secondaryLabel : .label
            pinIcon.alpha = item.isLocallyRead ? 0.7 : 1
            applyIcon(for: item)
            indicator.configure(totalCount: items.count, currentIndex: currentIndex, animated: false)
            accessibilityLabel = String(localized: "topic.cell.a11y.pinned \(item.title)")
        }
        if animated {
            UIView.transition(
                with: self,
                duration: 0.22,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: body
            )
        } else {
            body()
        }
    }
}

// MARK: - PinnedIndicator

/// Telegram-style segmented progress bar — vertical, max 3 segments.
/// When the pinned set has more items than segments, the highlighted segment
/// is mapped proportionally so it slides through them as the user advances.
private final class PinnedIndicator: UIView {
    static let visibleHeight: CGFloat = 22
    static let visibleWidth: CGFloat = 2
    static let segmentSpacing: CGFloat = 2
    static let containerWidth: CGFloat = 48
    static let maxSegments = 3

    var activeColor: UIColor = .label {
        didSet { applyColors() }
    }
    var inactiveColor: UIColor = .quaternaryLabel {
        didSet { applyColors() }
    }

    private(set) var totalCount: Int = 0
    private(set) var currentIndex: Int = 0

    private let stack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.distribution = .fillEqually
        s.spacing = PinnedIndicator.segmentSpacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    init() {
        super.init(frame: .zero)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.visibleWidth),
            stack.heightAnchor.constraint(equalToConstant: Self.visibleHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.containerWidth, height: Self.visibleHeight)
    }

    func configure(totalCount: Int, currentIndex: Int, animated: Bool) {
        let segments = max(0, min(Self.maxSegments, totalCount))
        if stack.arrangedSubviews.count != segments {
            stack.arrangedSubviews.forEach {
                stack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for _ in 0..<segments {
                let v = UIView()
                v.layer.cornerRadius = 1
                v.layer.cornerCurve = .continuous
                v.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(v)
            }
        }
        self.totalCount = totalCount
        self.currentIndex = currentIndex
        if animated {
            UIView.animate(withDuration: 0.18) { [weak self] in self?.applyColors() }
        } else {
            applyColors()
        }
    }

    private func applyColors() {
        let segments = stack.arrangedSubviews.count
        guard segments > 0 else { return }
        let active: Int
        if totalCount <= segments {
            active = currentIndex
        } else {
            active = min(segments - 1, currentIndex * segments / max(totalCount, 1))
        }
        for (i, v) in stack.arrangedSubviews.enumerated() {
            v.backgroundColor = (i == active) ? activeColor : inactiveColor
        }
    }
}
