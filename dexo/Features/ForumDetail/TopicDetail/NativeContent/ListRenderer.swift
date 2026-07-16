import CookedHTML
import UIKit

enum ListRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .list = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .list(let ordered, let items) = block else { return UIView() }

        let indent: CGFloat = ordered ? 20 : 12

        // Fast path: if ALL items are flat (paragraph-only), combine into a single UITextView.
        // This avoids creating N separate UITextViews for long lists (e.g. 29-item link lists).
        if items.allSatisfy({ canRenderFlat($0) }) {
            return renderCombinedFlatList(items, ordered: ordered, indent: indent, config: config)
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, item) in items.enumerated() {
            let itemView = renderItem(
                item,
                ordered: ordered,
                index: index,
                indent: indent,
                config: config,
                delegate: delegate
            )
            stack.addArrangedSubview(itemView)
        }

        return stack
    }

    /// Renders all flat items as a single view — O(1) views instead of O(n).
    private static func renderCombinedFlatList(
        _ items: [ListItem],
        ordered: Bool,
        indent: CGFloat,
        config: NativeRenderConfig
    ) -> UIView {
        let combined = NSMutableAttributedString()
        var interactive = false
        for (index, item) in items.enumerated() {
            if index > 0 { combined.append(NSAttributedString(string: "\n")) }

            var allInlines: [InlineNode] = []
            for (i, block) in item.blocks.enumerated() {
                if case .paragraph(let inlines) = block {
                    if i > 0 { allInlines.append(.lineBreak) }
                    allInlines.append(contentsOf: inlines)
                }
            }
            if !interactive, NativeContentRenderer.inlinesNeedTextView(allInlines) {
                interactive = true
            }
            combined.append(makeBulletedAttributedString(
                inlines: allInlines,
                ordered: ordered,
                index: index,
                indent: indent,
                config: config
            ))
        }
        return makeLineView(attributedText: combined, interactive: interactive, config: config)
    }

    private static func renderItem(
        _ item: ListItem,
        ordered: Bool,
        index: Int,
        indent: CGFloat,
        config: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> UIView {
        // Simple case: item has only inline paragraphs (no nested blocks).
        // Render as a single attributed string for compact layout.
        if canRenderFlat(item) {
            return renderFlatItem(item, ordered: ordered, index: index, indent: indent, config: config)
        }

        // Complex case: item has nested blocks. Use a vertical stack.
        let itemStack = UIStackView()
        itemStack.axis = .vertical
        itemStack.spacing = 4

        var isFirstBlock = true

        for block in item.blocks {
            if isFirstBlock, case .paragraph(let inlines) = block {
                // First paragraph: prepend bullet
                isFirstBlock = false
                let result = makeBulletedAttributedString(
                    inlines: inlines,
                    ordered: ordered,
                    index: index,
                    indent: indent,
                    config: config
                )
                let interactive = NativeContentRenderer.inlinesNeedTextView(inlines)
                itemStack.addArrangedSubview(makeLineView(attributedText: result, interactive: interactive, config: config))
            } else {
                if isFirstBlock {
                    // First block is not a paragraph — show standalone bullet
                    isFirstBlock = false
                    let bulletOnly = makeBulletedAttributedString(
                        inlines: [],
                        ordered: ordered,
                        index: index,
                        indent: indent,
                        config: config
                    )
                    itemStack.addArrangedSubview(makeLineView(attributedText: bulletOnly, interactive: false, config: config))
                }

                // Render child block with indentation
                let childConfig = NativeRenderConfig(
                    baseFont: config.baseFont,
                    baseColor: config.baseColor,
                    linkColor: config.linkColor,
                    codeFont: config.codeFont,
                    codeBackgroundColor: config.codeBackgroundColor,
                    contentWidth: config.contentWidth - indent,
                    baseURL: config.baseURL,
                    imageSizingMode: config.imageSizingMode
                )
                let childViews = NativeContentRenderer.renderBlocks([block], config: childConfig, delegate: delegate)
                for childView in childViews {
                    let wrapper = UIView()
                    wrapper.translatesAutoresizingMaskIntoConstraints = false
                    childView.translatesAutoresizingMaskIntoConstraints = false
                    wrapper.addSubview(childView)
                    NSLayoutConstraint.activate([
                        childView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: indent),
                        childView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                        childView.topAnchor.constraint(equalTo: wrapper.topAnchor),
                        childView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                    ])
                    itemStack.addArrangedSubview(wrapper)
                }
            }
        }

        // Edge case: empty item
        if isFirstBlock {
            let bulletOnly = makeBulletedAttributedString(
                inlines: [],
                ordered: ordered,
                index: index,
                indent: indent,
                config: config
            )
            itemStack.addArrangedSubview(makeLineView(attributedText: bulletOnly, interactive: false, config: config))
        }

        return itemStack
    }

    /// Returns true if the item contains only paragraphs (no nested lists, images, code blocks, etc.)
    private static func canRenderFlat(_ item: ListItem) -> Bool {
        item.blocks.allSatisfy { block in
            if case .paragraph = block { return true }
            return false
        }
    }

    /// Renders a simple item (all-paragraph) as a single text view with bullet prefix.
    private static func renderFlatItem(
        _ item: ListItem,
        ordered: Bool,
        index: Int,
        indent: CGFloat,
        config: NativeRenderConfig
    ) -> UIView {
        var allInlines: [InlineNode] = []
        for (i, block) in item.blocks.enumerated() {
            if case .paragraph(let inlines) = block {
                if i > 0 { allInlines.append(.lineBreak) }
                allInlines.append(contentsOf: inlines)
            }
        }
        let result = makeBulletedAttributedString(
            inlines: allInlines,
            ordered: ordered,
            index: index,
            indent: indent,
            config: config
        )
        let interactive = NativeContentRenderer.inlinesNeedTextView(allInlines)
        return makeLineView(attributedText: result, interactive: interactive, config: config)
    }

    // MARK: - Helpers

    private static func makeBulletedAttributedString(
        inlines: [InlineNode],
        ordered: Bool,
        index: Int,
        indent: CGFloat,
        config: NativeRenderConfig
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 4
        paragraphStyle.lineSpacing = config.baseFont.pointSize * 0.2
        paragraphStyle.headIndent = indent
        paragraphStyle.firstLineHeadIndent = 0
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent, options: [:])]
        paragraphStyle.defaultTabInterval = indent

        let result = NSMutableAttributedString()
        let bullet = ordered ? "\(index + 1).\t" : "\u{2022}\t"
        result.append(NSAttributedString(string: bullet, attributes: [
            .font: config.baseFont,
            .foregroundColor: config.baseColor,
            .paragraphStyle: paragraphStyle,
        ]))

        if !inlines.isEmpty {
            result.append(inlines.attributedString(config: config.attributedStringConfig))
        }

        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )

        return result
    }

    private static func makeTextView(attributedText: NSAttributedString, config: NativeRenderConfig) -> LinkTextView {
        let textView = LinkTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        textView.attributedText = attributedText
        textView.linkTextAttributes = [
            .foregroundColor: config.linkColor,
        ]
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }

    /// Cheap UILabel when the line is non-interactive; LinkTextView otherwise.
    /// A flat list of N pure-text items collapses to N UILabels (or 1 UILabel via
    /// renderCombinedFlatList), avoiding N expensive UITextView instantiations.
    private static func makeLineView(
        attributedText: NSAttributedString,
        interactive: Bool,
        config: NativeRenderConfig
    ) -> UIView {
        if interactive {
            return makeTextView(attributedText: attributedText, config: config)
        }
        return NativeContentRenderer.makeContentLabel(attributedText: attributedText)
    }
}
