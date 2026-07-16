import UIKit
import CookedHTML

enum CodeBlockRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .codeBlock = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .codeBlock(let language, let code) = block else { return UIView() }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = config.codeBackgroundColor
        container.layer.cornerRadius = 8

        // Header row: language badge (left) + copy button (right)
        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerStack)

        let badge = UILabel()
        badge.font = FontManager.shared.font(size: 11, weight: .medium)
        badge.textColor = .tertiaryLabel
        if let language, !language.isEmpty {
            badge.text = language.uppercased()
        }
        headerStack.addArrangedSubview(badge)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(spacer)

        let copyButton = CopyCodeButton(code: code)
        headerStack.addArrangedSubview(copyButton)

        NSLayoutConstraint.activate([
            copyButton.widthAnchor.constraint(equalToConstant: 30),
            copyButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        // Code view — a single UITextView that wraps and scrolls vertically.
        //
        // Why not UILabel-in-UIScrollView? `UILabel.numberOfLines = 0` computes its
        // intrinsicContentSize by running a full TextKit layout over the whole
        // string. For a ~350-line code block this pushed `sizeFitting` to 2.6s and
        // the resulting cell height to 11000+pt — catastrophic. UITextView's layout
        // manager is incremental: it only lays out glyphs in (and slightly around)
        // the visible bounds, so initial-render cost is bounded by the visible
        // window, independent of the code length.
        //
        // Sizing strategy:
        // - Long logical lines wrap at the available code width, which keeps
        //   natural-language snippets (especially Chinese) readable.
        // - The view height is capped at `Self.maxVisibleLines` visual lines.
        //   Longer blocks scroll vertically inside the box.
        let codeView = UITextView()
        codeView.isEditable = false
        codeView.isSelectable = true          // allow select/copy
        codeView.isScrollEnabled = true
        codeView.backgroundColor = .clear
        codeView.textContainerInset = .zero
        codeView.textContainer.lineFragmentPadding = 0
        codeView.textContainer.widthTracksTextView = true
        codeView.textContainer.lineBreakMode = .byWordWrapping
        codeView.showsHorizontalScrollIndicator = false
        codeView.showsVerticalScrollIndicator = true
        codeView.alwaysBounceHorizontal = false
        codeView.alwaysBounceVertical = false
        codeView.dataDetectorTypes = []
        codeView.translatesAutoresizingMaskIntoConstraints = false
        codeView.attributedText = NSAttributedString(string: code, attributes: [
            .font: config.codeFont,
            .foregroundColor: config.baseColor,
        ])
        container.addSubview(codeView)

        let codeHeight = Self.measureCodeHeight(
            code: code,
            font: config.codeFont,
            contentWidth: config.contentWidth
        )

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            codeView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 2),
            codeView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            codeView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            codeView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            codeView.heightAnchor.constraint(equalToConstant: codeHeight),
        ])

        return container
    }

    /// Upper bound on the visible code rows — anything longer scrolls inside the box.
    static let maxVisibleLines = 20

    /// Measured height of the code view (inner scroll area, no header chrome).
    /// Measures visual lines at the same width used by the rendered text view.
    /// `maximumNumberOfLines` stops TextKit after the visible cap, avoiding a
    /// full layout pass for very large pasted code blocks.
    static func measureCodeHeight(code: String, font: UIFont, contentWidth: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: code, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(
            width: max(1, contentWidth - Self.horizontalPadding),
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        container.maximumNumberOfLines = maxVisibleLines
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + 2
    }

    /// 12pt leading + 12pt trailing inset around the text view.
    private static let horizontalPadding: CGFloat = 24
}

// MARK: - Copy Button

private final class CopyCodeButton: UIButton {
    private let code: String
    private static let copyImage = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
    private static let checkImage = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))

    init(code: String) {
        self.code = code
        super.init(frame: .zero)
        setImage(Self.copyImage, for: .normal)
        tintColor = .tertiaryLabel
        addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyTapped() {
        UIPasteboard.general.string = code
        setImage(Self.checkImage, for: .normal)
        tintColor = ThemeManager.shared.accentColor
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.25, delay: 1.5) {
            self.alpha = 0.5
        } completion: { _ in
            self.setImage(Self.copyImage, for: .normal)
            self.tintColor = .tertiaryLabel
            self.alpha = 1.0
            self.isUserInteractionEnabled = true
        }
    }
}
