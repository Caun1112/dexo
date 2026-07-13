import CookedHTML
import SDWebImage
import UIKit

enum OneboxRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .onebox = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .onebox(let sourceURL, let title, let description, let imageURL, let imageWidth, let imageHeight, let faviconURL) = block else {
            return UIView()
        }

        let container = OneboxCardView(
            sourceURL: sourceURL,
            title: title,
            description: description,
            imageURL: imageURL,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            faviconURL: faviconURL,
            containerWidth: config.contentWidth
        )
        container.delegate = delegate
        return container
    }
}

// MARK: - OneboxCardView

final class OneboxCardView: UIView {
    weak var delegate: PostCellDelegate?
    private let sourceURL: String?
    private let imageView = UIImageView()
    private let faviconView = UIImageView()
    private let contentImageURL: URL?
    private let faviconImageURL: URL?

    init(sourceURL: String?, title: String?, description: String?, imageURL: String?, imageWidth: Int?, imageHeight: Int?, faviconURL: String?, containerWidth: CGFloat) {
        self.sourceURL = sourceURL
        contentImageURL = imageURL.flatMap(URL.init(string:))
        faviconImageURL = faviconURL.flatMap(URL.init(string:))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 4
        clipsToBounds = true
        layer.borderWidth = 1.0 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor

        // MARK: Header — favicon + domain

        let headerView = UIView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerStack)

        // Favicon
        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.contentMode = .scaleAspectFit
        faviconView.clipsToBounds = true
        faviconView.layer.cornerRadius = 2
        let faviconSize: CGFloat = 16

        if faviconImageURL != nil {
            headerStack.addArrangedSubview(faviconView)
            NSLayoutConstraint.activate([
                faviconView.widthAnchor.constraint(equalToConstant: faviconSize),
                faviconView.heightAnchor.constraint(equalToConstant: faviconSize),
            ])
        }

        // Domain label
        let domainLabel = UILabel()
        domainLabel.translatesAutoresizingMaskIntoConstraints = false
        domainLabel.font = FontManager.shared.font(size: 12)
        domainLabel.textColor = .secondaryLabel
        if let sourceURL, let url = URL(string: sourceURL), let host = url.host {
            domainLabel.text = host
        }
        headerStack.addArrangedSubview(domainLabel)

        let headerSeparator = UIView()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.backgroundColor = .separator
        headerView.addSubview(headerSeparator)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -12),
            headerStack.bottomAnchor.constraint(equalTo: headerSeparator.topAnchor, constant: -8),

            headerSeparator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerSeparator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        // MARK: Body

        let bodyStack = UIStackView()
        bodyStack.axis = .vertical
        bodyStack.spacing = 0
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyStack)

        NSLayoutConstraint.activate([
            bodyStack.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Text area
        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isLayoutMarginsRelativeArrangement = true
        textStack.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bodyStack.addArrangedSubview(textStack)

        if let title, !title.isEmpty {
            let titleLabel = UILabel()
            titleLabel.font = FontManager.shared.font(size: 14, weight: .medium)
            titleLabel.textColor = .link
            titleLabel.numberOfLines = 2
            titleLabel.text = title
            textStack.addArrangedSubview(titleLabel)
        }

        if let description, !description.isEmpty {
            let descLabel = UILabel()
            descLabel.font = FontManager.shared.font(size: 13)
            descLabel.textColor = .secondaryLabel
            descLabel.numberOfLines = 3
            descLabel.text = description
            textStack.addArrangedSubview(descLabel)
        }

        // Thumbnail image (only for actual content images, not favicons)
        if contentImageURL != nil {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .tertiarySystemFill
            imageView.layer.cornerRadius = 6

            let imageWrapper = UIView()
            imageWrapper.translatesAutoresizingMaskIntoConstraints = false
            imageWrapper.addSubview(imageView)

            let displayWidth = containerWidth - 24
            let imageH: CGFloat
            if let w = imageWidth, let h = imageHeight, w > 0 {
                imageH = displayWidth * CGFloat(h) / CGFloat(w)
            } else {
                imageH = displayWidth * 9.0 / 16.0
            }

            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: imageWrapper.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: imageWrapper.leadingAnchor, constant: 12),
                imageView.trailingAnchor.constraint(equalTo: imageWrapper.trailingAnchor, constant: -12),
                imageView.bottomAnchor.constraint(equalTo: imageWrapper.bottomAnchor, constant: -12),
                imageView.heightAnchor.constraint(equalToConstant: imageH),
            ])

            bodyStack.addArrangedSubview(imageWrapper)
        }

        startImageLoads()

        // Tap gesture
        let tap = UITapGestureRecognizer(target: self, action: #selector(cardTapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func cardTapped() {
        guard let sourceURL, let url = URL(string: sourceURL) else { return }
        delegate?.postCell(didTapLinkURL: url)
    }

    func cancelImageLoad() {
        imageView.sd_cancelCurrentImageLoad()
        faviconView.sd_cancelCurrentImageLoad()
    }

    private func startImageLoads() {
        if let faviconImageURL, faviconView.image == nil {
            faviconView.sd_setImage(with: faviconImageURL, context: ImageCacheManager.shared.contentContext)
        }
        if let contentImageURL, imageView.image == nil {
            imageView.sd_setImage(with: contentImageURL, placeholderImage: nil, options: [], context: ImageCacheManager.shared.contentContext, progress: nil) { [weak self] _, _, _, _ in
                self?.imageView.backgroundColor = .clear
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startImageLoads() }
    }
}
