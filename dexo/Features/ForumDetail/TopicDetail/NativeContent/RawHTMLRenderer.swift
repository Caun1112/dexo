import CookedHTML
import UIKit

/// Last-resort rendering for a SwiftSoup parse failure. It deliberately stays
/// isolated from the normal native path and, unlike the old empty UIView
/// placeholder, never makes an entire post silently disappear.
enum RawHTMLRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .rawHTML = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .rawHTML(let html) = block else { return UIView() }
        let attributed: NSAttributedString
        if let data = html.data(using: .utf8),
           let rendered = try? NSMutableAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           )
        {
            let full = NSRange(location: 0, length: rendered.length)
            rendered.addAttributes([
                .font: config.baseFont,
                .foregroundColor: config.baseColor,
            ], range: full)
            attributed = rendered
        } else {
            attributed = NSAttributedString(string: html, attributes: [
                .font: config.baseFont,
                .foregroundColor: config.baseColor,
            ])
        }
        return ParagraphRenderer.makeTextView(attributedText: attributed, config: config)
    }
}
