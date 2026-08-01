import Foundation

@MainActor
enum PushSubscriptionReconciler {
    static func reconcileAll(database providedDatabase: DatabaseManager? = nil) async {
        let database = providedDatabase ?? .shared
        guard let subscriptions = try? database.fetchAllPushSubscriptions(),
              let forums = try? database.fetchAllForums() else { return }
        let forumsByID = Dictionary(uniqueKeysWithValues: forums.compactMap { forum in
            forum.id.map { ($0, forum) }
        })
        for subscription in subscriptions {
            guard !Task.isCancelled,
                  let forum = forumsByID[subscription.forumId],
                  AuthManager.shared.isAuthenticated(for: forum.baseURL)
            else { continue }

            guard let currentUsername = AuthManager.shared.username(
                for: forum.baseURL
            ) else { continue }
            let api = DiscourseAPI(forum: forum)
            let coordinator = PushSubscriptionCoordinator(
                api: api,
                database: database
            )
            guard currentUsername == subscription.accountName else {
                // A different account must never mutate the old account's
                // Discourse subscriptions. Mute it locally and use only the
                // relay endpoint capability; a failed relay call keeps the
                // tombstone for the next reconciliation.
                await coordinator.revokeSubscriptionForDifferentAccount(
                    username: subscription.accountName
                )
                continue
            }

            switch subscription.state {
            case .retiring:
                await coordinator.retryRetirement(username: subscription.accountName)
            case .rotating:
                await coordinator.retryRotation(username: subscription.accountName)
            case .pending, .active:
                try? await coordinator.enable(username: subscription.accountName)
            }
        }
    }
}
