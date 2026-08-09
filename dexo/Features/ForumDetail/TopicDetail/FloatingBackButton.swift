import UIKit

/// Circular back affordance pinned to the right edge of the topic detail
/// screen at 55% of the screen height — within thumb reach for one-handed
/// use, unlike the nav-bar back button. Phone-only; on iPad the nav bar is
/// already reachable and the button would just cover content.
final class FloatingBackButton: UIButton {
    private static let buttonSize: CGFloat = 44
    private static let edgeInset: CGFloat = 16
    /// Fraction of the screen height the button's center sits at.
    private static let verticalAnchorRatio: CGFloat = 0.55

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize))
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let size = Self.buttonSize
        layer.cornerRadius = size / 2
        clipsToBounds = false

        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .plain()
        }
        config.image = UIImage(systemName: "chevron.backward")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        config.baseForegroundColor = .label
        config.background.backgroundColor = .clear
        configuration = config
        accessibilityLabel = String(localized: "action.back")

        if #unavailable(iOS 26.0) {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.16
            layer.shadowOffset = CGSize(width: 0, height: 3)
            layer.shadowRadius = 6
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            blur.layer.cornerRadius = size / 2
            blur.clipsToBounds = true
            blur.isUserInteractionEnabled = false
            blur.frame = bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            insertSubview(blur, at: 0)
        }
    }

    /// Re-anchor to the right edge at 55% of the *screen* height. Called on
    /// layout so rotation and split-view resizes keep the button in place.
    func updatePosition() {
        guard let parent = superview else { return }
        let screenHeight = parent.window?.bounds.height ?? UIScreen.main.bounds.height
        let anchorInWindow = screenHeight * Self.verticalAnchorRatio
        let anchorInParent = parent.window.map { window in
            parent.convert(CGPoint(x: 0, y: anchorInWindow), from: window).y
        } ?? anchorInWindow

        let half = Self.buttonSize / 2
        let insets = parent.safeAreaInsets
        let minY = insets.top + Self.edgeInset + half
        let maxY = parent.bounds.height - insets.bottom - Self.edgeInset - half
        center = CGPoint(
            x: parent.bounds.width - insets.right - Self.edgeInset - half,
            y: min(max(anchorInParent, minY), max(minY, maxY))
        )
    }
}
