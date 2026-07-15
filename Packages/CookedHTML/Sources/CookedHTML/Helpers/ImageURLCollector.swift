import Foundation

/// Recursively collects all non-emoji image URLs from content blocks.
public enum ImageURLCollector {
    /// Collects image URLs from annotated blocks, preferring `href` (full-size) over `src`.
    public static func collectImageURLs(from annotatedBlocks: [AnnotatedBlock]) -> [String] {
        collectImageURLs(from: annotatedBlocks.map(\.block))
    }

    /// Collects image URLs from content blocks, preferring `href` (full-size) over `src`.
    public static func collectImageURLs(from blocks: [ContentBlock]) -> [String] {
        var urls: [String] = []
        for block in blocks {
            collectFromBlock(block, into: &urls)
        }
        return urls
    }

    private static func collectFromBlock(_ block: ContentBlock, into urls: inout [String]) {
        switch block {
        case .image(let src, _, _, _, let href):
            urls.append(href ?? src)

        case .paragraph(let inlines), .heading(_, let inlines):
            collectFromInlines(inlines, into: &urls)

        case .blockquote(let blocks), .spoiler(let blocks):
            for b in blocks { collectFromBlock(b, into: &urls) }

        case .discourseQuote(_, _, _, _, _, _, let content):
            for b in content { collectFromBlock(b, into: &urls) }

        case .list(_, let items):
            for item in items {
                for b in item.blocks { collectFromBlock(b, into: &urls) }
            }

        case .details(_, let content):
            for b in content { collectFromBlock(b, into: &urls) }

        case .table(let headers, let rows):
            for cell in headers { for b in cell { collectFromBlock(b, into: &urls) } }
            for row in rows { for cell in row { for b in cell { collectFromBlock(b, into: &urls) } } }

        case .codeBlock, .video, .onebox, .poll, .divider, .rawHTML:
            break
        }
    }

    private static func collectFromInlines(_ inlines: [InlineNode], into urls: inout [String]) {
        for node in inlines {
            switch node {
            case .image(let src, _, _, _, let isEmoji):
                if !isEmoji { urls.append(src) }
            case .link(let href, let children):
                if containsNonEmojiImage(children), isLikelyImageURL(href) {
                    urls.append(href)
                } else {
                    collectFromInlines(children, into: &urls)
                }
            case .spoiler(let children):
                collectFromInlines(children, into: &urls)
            default:
                break
            }
        }
    }

    private static func containsNonEmojiImage(_ inlines: [InlineNode]) -> Bool {
        inlines.contains { node in
            switch node {
            case .image(_, _, _, _, let isEmoji):
                return !isEmoji
            case .link(_, let children), .spoiler(let children):
                return containsNonEmojiImage(children)
            default:
                return false
            }
        }
    }

    private static func isLikelyImageURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        let extensions = Set(["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "svg"])
        return extensions.contains(url.pathExtension.lowercased())
    }
}
