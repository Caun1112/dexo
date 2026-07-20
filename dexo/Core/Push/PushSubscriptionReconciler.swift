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
                  let forum = forumsByID[subscription.forumId] else { continue }
            let api = DiscourseAPI(forum: forum)
            try? await PushSubscriptionCoordinator(
                api: api,
                database: database
            ).enable(username: subscription.accountName)
        }
    }
}
