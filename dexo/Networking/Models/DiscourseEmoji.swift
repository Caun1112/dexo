import Foundation

struct DiscourseCustomEmoji: Decodable {
    let name: String
    let url: String
}

struct DiscourseEmojiGroup: Hashable {
    let id: String
    let emojis: [DiscourseEmojiEntry]
}

struct DiscourseEmojiEntry: Codable, Hashable {
    let name: String
    let url: String
    let searchAliases: [String]?
    let group: String?
    let tonable: Bool

    enum CodingKeys: String, CodingKey {
        case name, url, group, tonable
        case searchAliases = "search_aliases"
    }

    init(
        name: String,
        url: String,
        searchAliases: [String]? = nil,
        group: String? = nil,
        tonable: Bool = false
    ) {
        self.name = name
        self.url = url
        self.searchAliases = searchAliases
        self.group = group
        self.tonable = tonable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        searchAliases = try container.decodeIfPresent([String].self, forKey: .searchAliases)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        tonable = try container.decodeIfPresent(Bool.self, forKey: .tonable) ?? false
    }
}

struct DiscourseCreatePostResponse: Decodable {
    /// True when Discourse queued the post for moderation review (the
    /// "needs approval" flow), in which case the post isn't published in
    /// the stream yet and `postNumber` is unavailable. The response then
    /// looks like `{"action":"enqueued","success":true,"pending_post":{"id":N,…}}`.
    let enqueued: Bool
    /// Post ID. For the normal path this is the published post's id; for
    /// `enqueued` it falls back to `pending_post.id` so callers that index
    /// by id still have *something* to key on.
    let id: Int
    /// Position of the new post in the topic. Nil when the post is queued
    /// for review — the floor only gets assigned after a moderator approves.
    let postNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id, action
        case postNumber = "post_number"
        case pendingPost = "pending_post"
    }

    private enum PendingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let action = (try? c.decodeIfPresent(String.self, forKey: .action)) ?? nil
        if action == "enqueued" {
            enqueued = true
            let pending = try c.nestedContainer(keyedBy: PendingKeys.self, forKey: .pendingPost)
            id = try pending.decode(Int.self, forKey: .id)
            postNumber = nil
        } else {
            enqueued = false
            id = try c.decode(Int.self, forKey: .id)
            postNumber = try? c.decodeIfPresent(Int.self, forKey: .postNumber)
        }
    }
}
