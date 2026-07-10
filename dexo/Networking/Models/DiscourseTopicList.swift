import Foundation

struct TopicListTag: Decodable, Equatable {
    let id: Int?
    let name: String
    let slug: String

    private enum CodingKeys: String, CodingKey {
        case id, name, slug
    }

    init(id: Int? = nil, name: String, slug: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug ?? name
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let name = try? container.decode(String.self)
        {
            id = nil
            self.name = name
            slug = name
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? name
    }
}

struct DiscourseTopicList: Decodable {
    let users: [User]?
    let topicList: TopicList

    enum CodingKeys: String, CodingKey {
        case users
        case topicList = "topic_list"
    }

    struct User: Decodable {
        let id: Int
        let username: String
        let avatarTemplate: String?

        enum CodingKeys: String, CodingKey {
            case id, username
            case avatarTemplate = "avatar_template"
        }
    }

    struct Poster: Decodable {
        let userId: Int
        let extras: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case extras
        }
    }

    struct TopicList: Decodable {
        let topics: [Topic]
        let moreTopicsUrl: String?

        enum CodingKeys: String, CodingKey {
            case topics
            case moreTopicsUrl = "more_topics_url"
        }
    }

    struct Topic: Decodable, Identifiable {
        let id: Int
        let fancyTitle: String
        let title: String
        let postsCount: Int
        let replyCount: Int
        let views: Int
        let categoryId: Int?
        let createdAt: String
        let lastPostedAt: String?
        let bumpedAt: String?
        let pinned: Bool?
        let unseen: Bool?
        let excerpt: String?
        let posters: [Poster]?
        let tags: [TopicListTag]

        enum CodingKeys: String, CodingKey {
            case id, title, views, pinned, unseen, excerpt, posters
            case fancyTitle = "fancy_title"
            case postsCount = "posts_count"
            case replyCount = "reply_count"
            case categoryId = "category_id"
            case createdAt = "created_at"
            case lastPostedAt = "last_posted_at"
            case bumpedAt = "bumped_at"
            case tags
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            fancyTitle = try container.decode(String.self, forKey: .fancyTitle).decodingHTMLEntities()
            title = try container.decode(String.self, forKey: .title)
            postsCount = try container.decode(Int.self, forKey: .postsCount)
            replyCount = try container.decode(Int.self, forKey: .replyCount)
            views = try container.decode(Int.self, forKey: .views)
            categoryId = try container.decodeIfPresent(Int.self, forKey: .categoryId)
            createdAt = try container.decode(String.self, forKey: .createdAt)
            lastPostedAt = try container.decodeIfPresent(String.self, forKey: .lastPostedAt)
            bumpedAt = try container.decodeIfPresent(String.self, forKey: .bumpedAt)
            pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
            unseen = try container.decodeIfPresent(Bool.self, forKey: .unseen)
            excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
            posters = try container.decodeIfPresent([Poster].self, forKey: .posters)
            // Older Discourse versions serialized tags as strings while current
            // versions return { id, name, slug } objects. A malformed optional
            // tag list must not make the entire topic page fail to decode.
            tags = (try? container.decodeIfPresent([TopicListTag].self, forKey: .tags)) ?? []
        }
    }
}

enum TopicTimestampKind: Equatable {
    case activity
    case created

    func dateString(for topic: DiscourseTopicList.Topic) -> String {
        switch self {
        case .activity:
            return topic.bumpedAt ?? topic.lastPostedAt ?? topic.createdAt
        case .created:
            return topic.createdAt
        }
    }
}
