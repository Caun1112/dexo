import UIKit

@MainActor
enum ReactionFeedback {
    struct CapturedSource {
        fileprivate let snapshot: UIView
        fileprivate let frame: CGRect
        fileprivate weak var window: UIWindow?
    }

    static func capture(_ view: UIView) -> CapturedSource? {
        guard let window = view.window,
              let snapshot = view.snapshotView(afterScreenUpdates: false)
        else { return nil }
        return CapturedSource(
            snapshot: snapshot,
            frame: view.convert(view.bounds, to: window),
            window: window
        )
    }

    static func play(from sourceView: UIView?, to destinationView: UIView? = nil) {
        playHaptic()

        guard let sourceView,
              let capturedSource = capture(sourceView)
        else { return }
        animate(capturedSource, to: destinationView)
    }

    static func play(captured source: CapturedSource, to destinationView: UIView?) {
        playHaptic()
        animate(source, to: destinationView)
    }

    static func confirm(on destinationView: UIView, countView: UIView? = nil) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        destinationView.layer.removeAllAnimations()
        destinationView.transform = CGAffineTransform(scaleX: 0.76, y: 0.76)
        countView?.alpha = 0

        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            destinationView.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            countView?.alpha = 1
        } completion: { _ in
            UIView.animate(
                withDuration: 0.1,
                delay: 0,
                options: [.allowUserInteraction, .curveEaseInOut]
            ) {
                destinationView.transform = .identity
            }
        }
    }

    private static func playHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.8)
    }

    private static func animate(_ source: CapturedSource, to destinationView: UIView?) {
        guard !UIAccessibility.isReduceMotionEnabled,
              let window = source.window
        else { return }

        let snapshot = source.snapshot
        snapshot.frame = source.frame
        snapshot.isUserInteractionEnabled = false
        window.addSubview(snapshot)

        let destinationCenter: CGPoint
        if let destinationView {
            destinationCenter = destinationView.convert(
                CGPoint(x: destinationView.bounds.midX, y: destinationView.bounds.midY),
                to: window
            )
        } else {
            destinationCenter = CGPoint(x: snapshot.center.x - 72, y: snapshot.center.y)
        }
        let translationX = destinationCenter.x - snapshot.center.x
        let translationY = destinationCenter.y - snapshot.center.y

        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseIn]
        ) {
            snapshot.transform = CGAffineTransform(translationX: translationX, y: translationY)
                .scaledBy(x: 0.58, y: 0.58)
            snapshot.alpha = 0.12
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }
}
