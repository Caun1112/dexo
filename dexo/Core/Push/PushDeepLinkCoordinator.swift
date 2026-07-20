import Foundation
import UIKit

@MainActor
final class PushDeepLinkCoordinator {
    static let shared = PushDeepLinkCoordinator()

    private struct Destination {
        let forumBaseURL: String
        let relativeURL: String
    }

    private weak var window: UIWindow?
    private var pendingDestination: Destination?

    private init() {}

    func activate(window: UIWindow) {
        self.window = window
        openPendingDestinationIfPossible()
    }

    func receive(userInfo: [AnyHashable: Any]) {
        guard let forumBaseURL = userInfo["dexo_forum_base_url"] as? String,
              let relativeURL = userInfo["dexo_relative_url"] as? String else { return }
        pendingDestination = Destination(
            forumBaseURL: forumBaseURL,
            relativeURL: relativeURL
        )
        openPendingDestinationIfPossible()
    }

    private func openPendingDestinationIfPossible() {
        guard let destination = pendingDestination, let window else { return }
        guard let forums = try? DatabaseManager.shared.fetchAllForums(),
              let forum = forums.first(where: {
                normalized($0.baseURL) == normalized(destination.forumBaseURL)
              }) else {
            pendingDestination = nil
            return
        }
        pendingDestination = nil
        ForumOverlayManager.shared.present(forum: forum, in: window)
        DispatchQueue.main.async {
            ForumOverlayManager.shared.currentContainer?.openPushNotification(
                relativeURL: destination.relativeURL
            )
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}
