import CookedHTML
import SDWebImage
import UIKit

protocol TopicPostIDProviding: AnyObject {
    var renderedPostId: Int { get }
}

enum TopicPostIDResolver {
    static func postId(startingAt view: UIView?) -> Int {
        var current = view
        while let candidate = current {
            if let provider = candidate as? TopicPostIDProviding {
                return provider.renderedPostId
            }
            current = candidate.superview
        }
        return 0
    }
}

// MARK: - TappableImageContainer

final class TappableImageContainer: UIView {
    static let intrinsicHeightDidChangeNotification = Notification.Name("TopicContentImageHeightDidChange")
    /// URL used when tapped — prefers the full-size href over the img src.
    var imageURL: URL?
    weak var delegate: PostCellDelegate?

    /// The actual image view. `SDAnimatedImageView` only for formats that can animate
    /// (GIF); for static JPEG/PNG/WebP we use plain `UIImageView`, which is several
    /// times cheaper to instantiate (no animation state, no frame timer, no
    /// `SDAnimatedImageProvider` plumbing).
    /// Exposed for zoom transition animations.
    var displayedImageView: UIImageView { imageView }
    private let imageView: UIImageView
    private let sourceURL: URL
    private let containerWidth: CGFloat
    private let hasOriginalSize: Bool

    private var imageHeightConstraint: NSLayoutConstraint!
    private var imageWidthConstraint: NSLayoutConstraint!

    /// Discourse renders images at a reference width of 690px.
    /// Images narrower than this are displayed proportionally smaller on screen.
    private static let referenceWidth: CGFloat = 690

    private static func isLikelyAnimated(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif"
    }

    init(url: URL, width: Int?, height: Int?, containerWidth: CGFloat, href: URL? = nil) {
        sourceURL = url
        self.containerWidth = containerWidth
        hasOriginalSize = width != nil && height != nil
        imageURL = href ?? url
        let iv: UIImageView = Self.isLikelyAnimated(url) ? SDAnimatedImageView() : UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        imageView = iv
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)

        let displayWidth: CGFloat
        let displayHeight: CGFloat
        if let w = width, let h = height, w > 0, h > 0 {
            let fraction = min(CGFloat(w) / Self.referenceWidth, 1)
            displayWidth = containerWidth * fraction
            displayHeight = CGFloat(h) * (displayWidth / CGFloat(w))
        } else {
            displayWidth = containerWidth
            displayHeight = containerWidth * 9.0 / 16.0
        }

        let isFullWidth = displayWidth >= containerWidth

        if isFullWidth {
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: displayWidth)
        imageWidthConstraint.isActive = !isFullWidth
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: displayHeight)
        imageHeightConstraint.isActive = true

        backgroundColor = .clear
        imageView.backgroundColor = .clear
        imageView.layer.cornerRadius = 4
        imageView.clipsToBounds = true

        // Pause GIF animation by default; resumed when visible on screen
        (imageView as? SDAnimatedImageView)?.autoPlayAnimatedImage = false

        startImageLoad()

        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    private func startImageLoad() {
        imageView.sd_setImage(with: sourceURL, placeholderImage: nil, options: [], context: ImageCacheManager.shared.contentContext, progress: nil) { [weak self] image, _, _, _ in
            guard let self, let image else { return }
            if !self.hasOriginalSize, image.size.width > 0 {
                let ratio = self.containerWidth / image.size.width
                self.imageHeightConstraint.constant = image.size.height * ratio
                self.scheduleCoalescedHeightUpdate()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Last tapped container, used by the zoom transition to find the source frame.
    static weak var lastTapped: TappableImageContainer?

    @objc private func imageTapped() {
        guard let imageURL else { return }
        Self.lastTapped = self
        let postId = findPostId()
        delegate?.postCell(didTapImageURL: imageURL, inPostId: postId)
    }

    private func findPostId() -> Int {
        TopicPostIDResolver.postId(startingAt: superview)
    }

    func cancelImageLoad() {
        imageView.sd_cancelCurrentImageLoad()
    }

    // MARK: - Coalesced Height Updates

    /// Table views that already have a pending height update scheduled.
    /// Multiple image loads resolving in the same run-loop pass are coalesced
    /// into a single beginUpdates/endUpdates call.
    private static var pendingUpdateTableViews = Set<ObjectIdentifier>()

    private func scheduleCoalescedHeightUpdate() {
        let postId = findPostId()
        NotificationCenter.default.post(
            name: Self.intrinsicHeightDidChangeNotification,
            object: self,
            userInfo: postId == 0 ? nil : ["postId": postId]
        )
        guard let tableView = findTableView() else { return }
        let id = ObjectIdentifier(tableView)
        guard !Self.pendingUpdateTableViews.contains(id) else { return }
        Self.pendingUpdateTableViews.insert(id)
        DispatchQueue.main.async { [weak tableView] in
            Self.pendingUpdateTableViews.remove(id)
            guard let tableView else { return }
            let t0 = CACurrentMediaTime()
            let offset = tableView.contentOffset
            tableView.beginUpdates()
            tableView.endUpdates()
            if abs(tableView.contentOffset.y - offset.y) > 1 {
                tableView.contentOffset = offset
            }
            let ms = (CACurrentMediaTime() - t0) * 1000
            if ms > 3 { FrameDropDetector.shared.log("imageHeightUpdate \(String(format: "%.1f", ms))ms") }
        }
    }

    private func findTableView() -> UITableView? {
        var view: UIView? = superview
        while let v = view {
            if let tv = v as? UITableView { return tv }
            view = v.superview
        }
        return nil
    }

    // MARK: - GIF Animation Control

    func startAnimating() {
        imageView.startAnimating()
    }

    func stopAnimating() {
        imageView.stopAnimating()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if imageView.image == nil { startImageLoad() }
            imageView.startAnimating()
        } else {
            imageView.stopAnimating()
        }
    }
}

// MARK: - ImageRenderer

enum ImageRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .image = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .image(let src, _, let width, let height, let href) = block,
              let url = URL(string: src)
        else {
            return UIView()
        }

        let hrefURL: URL? = {
            guard let href, !href.isEmpty else { return nil }
            return URL(string: href)
        }()

        let container = TappableImageContainer(
            url: url,
            width: width,
            height: height,
            containerWidth: config.contentWidth,
            href: hrefURL
        )
        container.delegate = delegate
        return container
    }
}
