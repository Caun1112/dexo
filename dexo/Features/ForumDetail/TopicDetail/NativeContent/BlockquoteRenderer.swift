import UIKit
import CookedHTML

enum BlockquoteRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .blockquote = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .blockquote(let inner) = block else { return UIView() }

        if let callout = parseCallout(inner) {
            return renderCallout(callout, config: config, delegate: delegate)
        }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let bar = UIView()
        bar.backgroundColor = ThemeManager.shared.quoteBarColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 1.5
        container.addSubview(bar)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let quoteConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: .secondaryLabel,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - 15,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )

        let views = NativeContentRenderer.renderBlocks(inner, config: quoteConfig, delegate: delegate)
        for view in views {
            stack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),

            stack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        return container
    }

    // MARK: - Callout

    /// Markdown-style callouts inside a blockquote:
    /// `> [!warning]` followed by a line-break and content. Maps to a tinted,
    /// rounded panel with an icon + title instead of the standard quote bar.
    enum CalloutKind: String {
        case note, abstract, info, todo, tip, success, question, warning
        case failure, danger, bug, example, quote

        /// Accepts the canonical name and the aliases from the Obsidian /
        /// Discourse spec (summary/tldr, hint/important, check/done, help/faq,
        /// caution/attention, fail/missing, error, cite).
        init?(rawType: String) {
            switch rawType.lowercased() {
            case "note": self = .note
            case "abstract", "summary", "tldr": self = .abstract
            case "info": self = .info
            case "todo": self = .todo
            case "tip", "hint", "important": self = .tip
            case "success", "check", "done": self = .success
            case "question", "help", "faq": self = .question
            case "warning", "caution", "attention": self = .warning
            case "failure", "fail", "missing": self = .failure
            case "danger", "error": self = .danger
            case "bug": self = .bug
            case "example": self = .example
            case "quote", "cite": self = .quote
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .note: return String(localized: "callout.note")
            case .abstract: return String(localized: "callout.abstract")
            case .info: return String(localized: "callout.info")
            case .todo: return String(localized: "callout.todo")
            case .tip: return String(localized: "callout.tip")
            case .success: return String(localized: "callout.success")
            case .question: return String(localized: "callout.question")
            case .warning: return String(localized: "callout.warning")
            case .failure: return String(localized: "callout.failure")
            case .danger: return String(localized: "callout.danger")
            case .bug: return String(localized: "callout.bug")
            case .example: return String(localized: "callout.example")
            case .quote: return String(localized: "callout.quote")
            }
        }

        var iconName: String {
            switch self {
            case .note: return "note.text"
            case .abstract: return "doc.text.fill"
            case .info: return "info.circle.fill"
            case .todo: return "checklist"
            case .tip: return "lightbulb.fill"
            case .success: return "checkmark.circle.fill"
            case .question: return "questionmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.circle.fill"
            case .danger: return "bolt.fill"
            case .bug: return "ant.fill"
            case .example: return "book.closed.fill"
            case .quote: return "text.quote"
            }
        }

        var tint: UIColor {
            switch self {
            case .note: return .systemBlue
            case .abstract: return .systemCyan
            case .info: return .systemTeal
            case .todo: return .systemBlue
            case .tip: return .systemGreen
            case .success: return .systemGreen
            case .question: return .systemYellow
            case .warning: return .systemOrange
            case .failure: return .systemRed
            case .danger: return .systemRed
            case .bug: return .systemRed
            case .example: return .systemPurple
            case .quote: return .systemGray
            }
        }
    }

    struct ParsedCallout {
        let kind: CalloutKind
        /// Custom title inlines from the same line as the `[!kind]` marker
        /// (e.g. `[!success]视频端上来咯` → "视频端上来咯"). Empty falls back
        /// to the localized default (`kind.title`).
        let titleInlines: [InlineNode]
        let blocks: [ContentBlock]
    }

    /// Horizontal padding inside the callout panel (per side).
    static let calloutHorizontalPadding: CGFloat = 12
    /// Vertical padding inside the callout panel (top + bottom, combined).
    static let calloutVerticalPadding: CGFloat = 20
    /// Gap between title row and content stack.
    static let calloutTitleContentGap: CGFloat = 8
    /// Approximate title-row height (icon+label baseline).
    static let calloutTitleHeight: CGFloat = 22
    /// Vertical spacing between content blocks inside the callout.
    static let calloutContentSpacing: CGFloat = 6

    /// Detects `[!kind]` at the start of the first paragraph inside a blockquote.
    /// Returns the matched kind plus `blocks` with the marker (and the
    /// immediately-following line break, if any) stripped.
    static func parseCallout(_ inner: [ContentBlock]) -> ParsedCallout? {
        guard let firstBlock = inner.first,
              case .paragraph(let inlines) = firstBlock,
              let firstInline = inlines.first(where: { !$0.isPurelyWhitespace }),
              case .text(let text) = firstInline
        else { return nil }

        let pattern = #"^\s*\[!([a-zA-Z]+)\]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }

        let typeRange = match.range(at: 1)
        let rawType = ns.substring(with: typeRange)
        guard let kind = CalloutKind(rawType: rawType) else { return nil }

        let remainderText = ns.substring(from: match.range.upperBound)

        // Rebuild the first paragraph without the marker.
        var firstIsConsumed = false
        var rebuilt: [InlineNode] = []
        for inline in inlines {
            if !firstIsConsumed {
                if case .text(let t) = inline, t == text {
                    firstIsConsumed = true
                    if !remainderText.isEmpty {
                        rebuilt.append(.text(remainderText))
                    }
                    continue
                }
                if case .text(let t) = inline, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // leading whitespace text node — skip
                    continue
                }
            }
            rebuilt.append(inline)
        }

        // Obsidian-style callout title: content up to the first line break on
        // the marker's line becomes the title; anything after the break is body.
        // If nothing precedes the break, the default `kind.title` is used.
        let splitIndex = rebuilt.firstIndex(where: {
            if case .lineBreak = $0 { return true }
            return false
        })
        let titleInlines: [InlineNode]
        let bodyInlines: [InlineNode]
        if let idx = splitIndex {
            titleInlines = Array(rebuilt[..<idx]).trimmedWhitespace()
            bodyInlines = Array(rebuilt[(idx + 1)...]).trimmedWhitespace()
        } else {
            titleInlines = rebuilt.trimmedWhitespace()
            bodyInlines = []
        }

        var resultBlocks = Array(inner)
        if bodyInlines.isEmpty {
            resultBlocks.removeFirst()
        } else {
            resultBlocks[0] = .paragraph(bodyInlines)
        }
        return ParsedCallout(kind: kind, titleInlines: titleInlines, blocks: resultBlocks)
    }

    private static func renderCallout(
        _ parsed: ParsedCallout,
        config: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = parsed.kind.tint.withAlphaComponent(0.12)
        container.layer.cornerRadius = 6

        let iconView = UIImageView(image: UIImage(systemName: parsed.kind.iconName))
        iconView.tintColor = parsed.kind.tint
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        let customTitle = plainText(from: parsed.titleInlines)
        titleLabel.text = customTitle.isEmpty ? parsed.kind.title : customTitle
        titleLabel.font = FontManager.shared.font(size: config.baseFont.pointSize, weight: .semibold)
        titleLabel.textColor = parsed.kind.tint
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        let titleRow = UIStackView(arrangedSubviews: [iconView, titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .center

        let contentConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - calloutHorizontalPadding * 2,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )
        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = calloutContentSpacing
        let innerViews = NativeContentRenderer.renderBlocks(parsed.blocks, config: contentConfig, delegate: delegate)
        for view in innerViews {
            contentStack.addArrangedSubview(view)
        }

        let mainStack = UIStackView(arrangedSubviews: [titleRow, contentStack])
        mainStack.axis = .vertical
        mainStack.spacing = calloutTitleContentGap
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: calloutHorizontalPadding),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -calloutHorizontalPadding),
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: calloutVerticalPadding / 2),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -calloutVerticalPadding / 2),
        ])

        return container
    }
}

private extension BlockquoteRenderer {
    /// Flatten callout-title inlines to a single-line plain string. Formatting,
    /// links, and inline emoji images are dropped — the title label is a simple
    /// single-line caption next to the icon.
    static func plainText(from inlines: [InlineNode]) -> String {
        var out = ""
        for node in inlines {
            appendPlainText(node, into: &out)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendPlainText(_ node: InlineNode, into out: inout String) {
        switch node {
        case .text(let t), .styledText(let t, _), .code(let t):
            out.append(t)
        case .link(_, let children), .spoiler(let children):
            for child in children { appendPlainText(child, into: &out) }
        case .mention(let username, _):
            out.append("@")
            out.append(username)
        case .mentionGroup(let name, _):
            out.append("@")
            out.append(name)
        case .hashtag(let text, _, _):
            out.append("#")
            out.append(text)
        case .image(_, let alt, _, _, _):
            if let alt, !alt.isEmpty { out.append(alt) }
        case .lineBreak:
            out.append(" ")
        }
    }
}

private extension InlineNode {
    var isPurelyWhitespace: Bool {
        if case .text(let t) = self, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if case .lineBreak = self { return true }
        return false
    }
}
