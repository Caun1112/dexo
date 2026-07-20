import Foundation
import GRDB

struct ReadHistoryScope: Equatable, Sendable {
    static let anonymousAccountKey = "anonymous"

    let forumId: Int64
    let accountKey: String
    let accountName: String?

    static func current(api: DiscourseAPI) -> ReadHistoryScope? {
        guard let forumId = api.forumID else { return nil }
        let auth = AuthManager.shared
        if auth.isAuthenticated(for: api.baseURL) {
            guard let username = auth.username(for: api.baseURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !username.isEmpty
            else {
                // Never mix an authenticated-but-unresolved account into the
                // anonymous history bucket.
                return nil
            }
            return ReadHistoryScope(
                forumId: forumId,
                accountKey: "user:\(username.lowercased())",
                accountName: username
            )
        }
        return ReadHistoryScope(
            forumId: forumId,
            accountKey: anonymousAccountKey,
            accountName: nil
        )
    }
}

struct StoredReadTopicTag: Codable, Equatable, Sendable {
    let id: Int?
    let name: String
    let slug: String

    init(_ tag: DiscourseTopicDetail.Tag) {
        id = tag.id
        name = tag.name
        slug = tag.slug
    }

    var topicListTag: TopicListTag {
        TopicListTag(id: id, name: name, slug: slug)
    }
}

struct LocalReadTopic: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "localReadTopic"

    var forumId: Int64
    var accountKey: String
    var topicId: Int
    var title: String
    var fancyTitle: String?
    var postsCount: Int
    var replyCount: Int
    var categoryId: Int?
    var createdAt: String
    var avatarTemplate: String?
    var tagsJSON: String
    var lastViewedAt: Date

    var tags: [TopicListTag] {
        guard let data = tagsJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode([StoredReadTopicTag].self, from: data)
        else { return [] }
        return stored.map(\.topicListTag)
    }

    init(topic: DiscourseTopicDetail, scope: ReadHistoryScope, viewedAt: Date = Date()) {
        let tags = topic.tags.map { StoredReadTopicTag($0) }
        forumId = scope.forumId
        accountKey = scope.accountKey
        topicId = topic.id
        title = topic.title
        fancyTitle = topic.fancyTitle
        postsCount = topic.postsCount
        replyCount = topic.replyCount
        categoryId = topic.categoryId
        createdAt = topic.createdAt
        avatarTemplate = topic.postStream.posts.first(where: { $0.postNumber == 1 })?.avatarTemplate
        tagsJSON = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
        lastViewedAt = viewedAt
    }
}

struct LocalReadHistoryStore: Sendable {
    static let shared = LocalReadHistoryStore()

    func record(topic: DiscourseTopicDetail, scope: ReadHistoryScope, viewedAt: Date = Date()) throws {
        try DatabaseManager.shared.recordLocalRead(topic: topic, scope: scope, viewedAt: viewedAt)
    }

    func fetch(scope: ReadHistoryScope) throws -> [LocalReadTopic] {
        try DatabaseManager.shared.fetchLocalReads(scope: scope)
    }

    func topicIDs(scope: ReadHistoryScope) throws -> Set<Int> {
        try DatabaseManager.shared.fetchLocalReadTopicIDs(scope: scope)
    }
}
