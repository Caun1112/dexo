import CookedHTML
import UIKit

enum DetailsRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .details = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .details(let summary, let content) = block else { return UIView() }
        return DetailsCardView(summary: summary, content: content, config: config, delegate: delegate)
    }
}

// MARK: - DetailsCardView

final class DetailsCardView: UIView {
    static let intrinsicHeightDidChangeNotification = Notification.Name("TopicDetailsHeightDidChange")
    private let chevron = UIImageView()
    private let headerView = UIView()
    private var contentStack: UIStackView?
    private var isExpanded = false
    var onExpansionChange: ((Bool) -> Void)?
    private var headerBottomConstraint: NSLayoutConstraint!
    private var contentBottomConstraint: NSLayoutConstraint?

    private var contentBlocks: [ContentBlock] = []
    private var innerConfig: NativeRenderConfig!
    private weak var delegate: PostCellDelegate?

    init(summary: [InlineNode], content: [ContentBlock], config: NativeRenderConfig, delegate: PostCellDelegate?) {
        self.contentBlocks = content
        self.delegate = delegate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        clipsToBounds = true

        innerConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - 24,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )

        // MARK: Header

        chevron.image = UIImage(systemName: "chevron.right")
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let summaryLabel = UILabel()
        summaryLabel.numberOfLines = 0
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        let summaryConfig = AttributedStringConfig(
            baseFont: config.baseFont.bold(),
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor
        )
        summaryLabel.attributedText = summary.attributedString(config: summaryConfig)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(chevron)
        headerView.addSubview(summaryLabel)
        addSubview(headerView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleExpanded))
        headerView.addGestureRecognizer(tap)

        headerBottomConstraint = headerView.bottomAnchor.constraint(equalTo: bottomAnchor)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBottomConstraint,

            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            chevron.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            chevron.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            summaryLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 10),
            summaryLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            summaryLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleExpanded() {
        setExpanded(!isExpanded, notify: true)
    }

    func setExpanded(_ expanded: Bool, notify: Bool = false) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded

        if isExpanded {
            // Lazily create and add the content stack
            if contentStack == nil {
                let stack = UIStackView()
                stack.axis = .vertical
                stack.spacing = 8
                stack.translatesAutoresizingMaskIntoConstraints = false
                addSubview(stack)

                let views = NativeContentRenderer.renderBlocks(contentBlocks, config: innerConfig, delegate: delegate)
                for view in views {
                    stack.addArrangedSubview(view)
                }

                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 4),
                    stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                    stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                ])

                contentBottomConstraint = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
                contentStack = stack
            }

            contentStack?.isHidden = false
            headerBottomConstraint.isActive = false
            contentBottomConstraint?.isActive = true
        } else {
            contentBottomConstraint?.isActive = false
            headerBottomConstraint.isActive = true
            contentStack?.isHidden = true
        }

        chevron.transform = isExpanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        invalidateIntrinsicContentSize()
        guard notify else { return }
        onExpansionChange?(isExpanded)
        NotificationCenter.default.post(name: Self.intrinsicHeightDidChangeNotification, object: self)
        if let tableView = findTableView() {
            let offset = tableView.contentOffset
            tableView.beginUpdates()
            tableView.endUpdates()
            if abs(tableView.contentOffset.y - offset.y) > 1 {
                tableView.contentOffset = offset
            }
        }
    }

    private func findTableView() -> UITableView? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let tv = next as? UITableView { return tv }
            responder = next
        }
        return nil
    }
}

// MARK: - UIFont + Bold Helper

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
