import UIKit

protocol TopicDetailBottomBarDelegate: AnyObject {
    func bottomBarDidTapOPOnly()
    func bottomBarDidTapJumpToFloor()
    func bottomBarDidToggleReverseOrder()
    func bottomBarDidToggleSummaryMode()
    func bottomBarDidTapReply()
    /// Tap the ReadBoost pill — opens the settings / start-stop sheet.
    func bottomBarDidTapReadBoost()
    /// Whether the reverse / summary modes are currently active.
    var bottomBarIsReverseOrder: Bool { get }
    var bottomBarIsSummaryMode: Bool { get }

    /// Long-press on the jump-to-floor button begins a continuous scrub gesture.
    /// The bar forwards every state change (begin/change/end) so the VC can
    /// drive the overlay floor in real time without the user ever having to
    /// lift their finger. Locations are in the window's coordinate space.
    func bottomBarDidBeginScrubFromJump(at locationInWindow: CGPoint, buttonFrame: CGRect)
    func bottomBarDidUpdateScrub(at locationInWindow: CGPoint)
    func bottomBarDidEndScrub(cancelled: Bool)
}

extension TopicDetailBottomBarDelegate {
    /// Screens that don't surface the ReadBoost pill don't have to implement it.
    func bottomBarDidTapReadBoost() {}
}

final class TopicDetailBottomBar: UIView {
    weak var delegate: TopicDetailBottomBarDelegate?

    private static let buttonSize: CGFloat = 44

    /// `rocket` only exists from iOS 16.1, and the deployment target is 16.0.
    private static var readBoostSymbolName: String {
        UIImage(systemName: "rocket") != nil ? "rocket" : "bolt.fill"
    }

    private static let readBoostRingWidth: CGFloat = 3

    /// Faint full circle the progress arc runs on top of.
    private lazy var readBoostTrackRing: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = Self.readBoostRingWidth
        layer.isHidden = true
        return layer
    }()

    /// Accent-coloured arc whose `strokeEnd` tracks the sweep's progress.
    private lazy var readBoostProgressRing: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = Self.readBoostRingWidth
        layer.lineCap = .round
        layer.strokeStart = 0
        layer.strokeEnd = 0
        layer.isHidden = true
        return layer
    }()

    private(set) lazy var opOnlyButton = makeCircularButton(icon: "person", a11yLabel: String(localized: "topic.bottombar.op_only"))
    private(set) lazy var jumpToFloorButton = makeCircularButton(icon: "number", a11yLabel: String(localized: "topic.bottombar.jump_to_floor"))
    private(set) lazy var readBoostButton = makeCircularButton(icon: Self.readBoostSymbolName, a11yLabel: String(localized: "readboost.title"))
    private lazy var replyButton = makeCircularButton(icon: "arrowshape.turn.up.left", a11yLabel: String(localized: "reply.title"))

    /// Show the ReadBoost pill. Off by default so screens that never wired the
    /// delegate method don't grow a dead button.
    var showsReadBoost: Bool = false {
        didSet {
            guard oldValue != showsReadBoost else { return }
            readBoostButton.isHidden = !showsReadBoost
        }
    }

    /// Hide the OP-filter and jump-to-floor pills when the topic is being
    /// shown as a reply tree — neither floor numbers nor the OP filter make
    /// sense once posts are reordered into a DFS view.
    var hidesFloorControls: Bool = false {
        didSet {
            guard oldValue != hidesFloorControls else { return }
            opOnlyButton.isHidden = hidesFloorControls
            jumpToFloorButton.isHidden = hidesFloorControls
        }
    }

    private lazy var stackView: UIStackView = {
        let sv = UIStackView(arrangedSubviews: [opOnlyButton, jumpToFloorButton, readBoostButton, replyButton])
        sv.axis = .horizontal
        sv.spacing = 12
        sv.alignment = .center
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        addSubview(stackView)

        opOnlyButton.addTarget(self, action: #selector(opOnlyTapped), for: .touchUpInside)
        jumpToFloorButton.addTarget(self, action: #selector(jumpToFloorTapped), for: .touchUpInside)
        readBoostButton.addTarget(self, action: #selector(readBoostTapped), for: .touchUpInside)
        readBoostButton.isHidden = !showsReadBoost
        readBoostButton.layer.addSublayer(readBoostTrackRing)
        readBoostButton.layer.addSublayer(readBoostProgressRing)
        replyButton.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)

        // Long-press + drag the jump button to scrub through floors. We don't
        // require an initial movement, so the gesture begins after a short
        // hold; subsequent movement is reported via the same recognizer.
        let scrubGesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleScrubGesture(_:))
        )
        scrubGesture.minimumPressDuration = 0.22
        // The default `allowableMovement` (10pt) cancels the gesture if the
        // user moves before recognition — but they may rest a finger then
        // immediately drag, which is exactly the scrub flow we want.
        scrubGesture.allowableMovement = .greatestFiniteMagnitude
        jumpToFloorButton.addGestureRecognizer(scrubGesture)

        let size = Self.buttonSize
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            opOnlyButton.widthAnchor.constraint(equalToConstant: size),
            opOnlyButton.heightAnchor.constraint(equalToConstant: size),
            jumpToFloorButton.widthAnchor.constraint(equalToConstant: size),
            jumpToFloorButton.heightAnchor.constraint(equalToConstant: size),
            readBoostButton.widthAnchor.constraint(equalToConstant: size),
            readBoostButton.heightAnchor.constraint(equalToConstant: size),
            replyButton.widthAnchor.constraint(equalToConstant: size),
            replyButton.heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - State

    func setOPOnlySelected(_ selected: Bool) {
        updateButtonAppearance(opOnlyButton, selected: selected)
    }

    /// Reflect the current ReadBoost run: a stop glyph inside a ring that fills
    /// clockwise with progress. The button keeps its glass background — a solid
    /// fill would hide the ring.
    func setReadBoostRunning(_ running: Bool, progress: Double?) {
        readBoostButton.configuration?.image = UIImage(
            systemName: running ? "stop.fill" : Self.readBoostSymbolName
        )
        let accent = ThemeManager.shared.accentColor
        readBoostButton.configuration?.baseForegroundColor = running ? accent : .label
        readBoostProgressRing.isHidden = !running
        readBoostTrackRing.isHidden = !running
        guard running else { return }
        // Theme-dependent colors belong in display-time code, not init.
        readBoostProgressRing.strokeColor = accent.cgColor
        readBoostTrackRing.strokeColor = UIColor.tertiaryLabel.withAlphaComponent(0.35).cgColor
        layoutReadBoostRing()
        // No ring for an indeterminate start: show a thin arc so the button
        // still reads as active before the first batch lands.
        // The implicit CALayer animation is what makes it creep around.
        readBoostProgressRing.strokeEnd = CGFloat(progress ?? 0.02)
    }

    private func layoutReadBoostRing() {
        let size = Self.buttonSize
        let inset = Self.readBoostRingWidth / 2 + 1
        let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
        readBoostProgressRing.frame = CGRect(x: 0, y: 0, width: size, height: size)
        readBoostTrackRing.frame = readBoostProgressRing.frame
        // Start at 12 o'clock and sweep clockwise.
        let path = UIBezierPath(
            arcCenter: CGPoint(x: size / 2, y: size / 2),
            radius: rect.width / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        ).cgPath
        readBoostProgressRing.path = path
        readBoostTrackRing.path = path
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !readBoostProgressRing.isHidden { layoutReadBoostRing() }
    }

    private func updateButtonAppearance(_ button: UIButton, selected: Bool) {
        if selected {
            button.configuration?.baseForegroundColor = .white
            button.backgroundColor = .tintColor
            button.layer.sublayers?
                .filter { $0 is CAShapeLayer || ($0.name == "glassLayer") }
                .forEach { $0.isHidden = true }
            // Hide the effect view when selected
            button.subviews.compactMap { $0 as? UIVisualEffectView }.forEach { $0.isHidden = true }
        } else {
            button.configuration?.baseForegroundColor = .label
            button.backgroundColor = .clear
            button.subviews.compactMap { $0 as? UIVisualEffectView }.forEach { $0.isHidden = false }
        }
    }

    // MARK: - Factory

    private func makeCircularButton(icon: String, a11yLabel: String) -> UIButton {
        let size = Self.buttonSize
        var config = UIButton.Configuration.plain()
        if #available(iOS 26.0, *) {
            config = UIButton.Configuration.glass()
        }
        config.image = UIImage(systemName: icon)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        config.baseForegroundColor = .label
        config.background.backgroundColor = .clear

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = size / 2
        button.clipsToBounds = false
        button.accessibilityLabel = a11yLabel

        if #unavailable(iOS 26.0) {
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.12
            button.layer.shadowOffset = CGSize(width: 0, height: 2)
            button.layer.shadowRadius = 4
            addGlassBackground(to: button, size: size)
        }

        return button
    }

    private func addGlassBackground(to button: UIButton, size: CGFloat) {
        if #available(iOS 26, *) {
            let glassView = UIVisualEffectView(effect: UIGlassEffect())
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassView.layer.cornerRadius = size / 2
            glassView.clipsToBounds = true
            glassView.isUserInteractionEnabled = false
            button.insertSubview(glassView, at: 0)

            NSLayoutConstraint.activate([
                glassView.topAnchor.constraint(equalTo: button.topAnchor),
                glassView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                glassView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                glassView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        } else {
            let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.layer.cornerRadius = size / 2
            effectView.clipsToBounds = true
            effectView.isUserInteractionEnabled = false
            button.insertSubview(effectView, at: 0)
            NSLayoutConstraint.activate([
                effectView.topAnchor.constraint(equalTo: button.topAnchor),
                effectView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                effectView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
    }

    // MARK: - Actions

    @objc private func opOnlyTapped() {
        delegate?.bottomBarDidTapOPOnly()
    }

    @objc private func jumpToFloorTapped() {
        delegate?.bottomBarDidTapJumpToFloor()
    }

    @objc private func readBoostTapped() {
        delegate?.bottomBarDidTapReadBoost()
    }

    /// No-op since the long-press menu was replaced by the scrubber gesture;
    /// retained as a hook for callers that still ping it after mode toggles.
    func refreshJumpMenu() {}

    @objc private func replyTapped() {
        delegate?.bottomBarDidTapReply()
    }

    @objc private func handleScrubGesture(_ gesture: UILongPressGestureRecognizer) {
        let locationInWindow = gesture.location(in: nil)
        switch gesture.state {
        case .began:
            delegate?.bottomBarDidBeginScrubFromJump(
                at: locationInWindow,
                buttonFrame: jumpToFloorButton.convert(jumpToFloorButton.bounds, to: self)
            )
        case .changed:
            delegate?.bottomBarDidUpdateScrub(at: locationInWindow)
        case .ended:
            delegate?.bottomBarDidEndScrub(cancelled: false)
        case .cancelled, .failed:
            delegate?.bottomBarDidEndScrub(cancelled: true)
        default:
            break
        }
    }
}
