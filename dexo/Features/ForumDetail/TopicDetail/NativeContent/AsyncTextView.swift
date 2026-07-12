import UIKit

/// Renders a long pure-text attributed string off the main thread.
///
/// Background: long paragraph chunks rendered via `UILabel` (Core Text) or
/// `UITextView` (TextKit 2) both pay their typesetting + glyph rasterization
/// cost during `CALayer` commit on the main thread. For posts with multiple
/// 1000-char chunks coming on screen at once, this routinely costs 100ms+ —
/// directly visible as a frame hitch.
///
/// `AsyncTextView` rasterizes the attributed string to a `UIImage` on a
/// concurrent background queue (using `UIGraphicsImageRenderer` +
/// `NSAttributedString.draw(in:)` — both documented thread-safe), then
/// assigns the resulting `cgImage` to `layer.contents` on the main thread.
/// The main-thread cost reduces to view instantiation + a layer assignment,
/// roughly an order of magnitude smaller.
///
/// **Visual contract**: the view is briefly blank (~30–50ms typical) while
/// the background render completes. The fade is usually masked by scroll
/// momentum on first appearance; on slow scrolls a noticeable pop-in is
/// possible. Trade-off accepted in exchange for 60fps scroll on long posts.
///
/// **Resolution**: rendered at the host window's `screen.scale`, with
/// `layer.contentsScale` matched. Visually identical to `UILabel`'s output —
/// not a bitmap-scale "screenshot".
///
/// **Memory**: holds one `UIImage` of `width × height × scale² × 4 bytes`.
/// At 350pt × 800pt @3x ~10MB. Discarded when the view is deallocated; the
/// VC-level `contentViewCache` keeps the view (and image) alive across cell
/// reuse for visited posts.
final class AsyncTextView: UIView {
    private static let renderQueue = DispatchQueue(
        label: "AsyncTextView.render",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let attributedText: NSAttributedString
    private var lastRenderedSize: CGSize = .zero
    private var lastRenderedScale: CGFloat = 0
    private var renderToken: UUID?

    init(attributedString: NSAttributedString) {
        self.attributedText = attributedString
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Rendered image origin is top-left; without this UIKit centres it.
        layer.contentsGravity = .topLeft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        renderIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else {
            return
        }
        invalidateRendering()
    }

    /// Forces the cached bitmap to be regenerated for the current appearance.
    /// This is also used by the topic detail controller when its custom theme
    /// changes without a UIKit trait transition.
    func invalidateRendering() {
        lastRenderedSize = .zero
        lastRenderedScale = 0
        renderToken = nil
        layer.contents = nil
        setNeedsLayout()
    }

    private func renderIfNeeded() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        if size == lastRenderedSize, scale == lastRenderedScale { return }
        lastRenderedSize = size
        lastRenderedScale = scale
        scheduleRender(size: size, scale: scale)
    }

    private func scheduleRender(size: CGSize, scale: CGFloat) {
        let token = UUID()
        renderToken = token
        // UIColor's dynamic colors are resolved on the background queue using
        // that queue's trait environment, which can otherwise default to light
        // mode. Resolve them while the view still has the correct traits.
        let attr = resolvedAttributedString(attributedText, for: traitCollection)
        Self.renderQueue.async { [weak self] in
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { _ in
                attr.draw(
                    with: CGRect(origin: .zero, size: size),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            }
            DispatchQueue.main.async {
                guard let self, self.renderToken == token else { return }
                self.layer.contents = image.cgImage
                self.layer.contentsScale = scale
            }
        }
    }

    private func resolvedAttributedString(_ source: NSAttributedString, for traits: UITraitCollection) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let colorKeys: [NSAttributedString.Key] = [
            .foregroundColor,
            .backgroundColor,
            .strokeColor,
            .underlineColor,
            .strikethroughColor,
        ]
        let fullRange = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: fullRange) { attributes, range, _ in
            for key in colorKeys {
                guard let color = attributes[key] as? UIColor else { continue }
                result.addAttribute(key, value: color.resolvedColor(with: traits), range: range)
            }
        }
        return result
    }
}
