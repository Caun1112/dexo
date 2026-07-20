import Foundation

struct ReadTopicOrigin: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let local = ReadTopicOrigin(rawValue: 1 << 0)
    static let cloud = ReadTopicOrigin(rawValue: 1 << 1)
}

struct ReadTopicRow: Identifiable {
    let id: Int
    let local: LocalReadTopic?
    let cloud: DiscourseTopicList.Topic?
    let cloudOrder: Int?

    var origins: ReadTopicOrigin {
        var value: ReadTopicOrigin = []
        if local != nil { value.insert(.local) }
        if cloud != nil { value.insert(.cloud) }
        return value
    }

    var topic: DiscourseTopicList.Topic {
        cloud ?? local!.asTopicListTopic
    }

    var displayDate: Date? {
        if let local { return local.lastViewedAt }
        return cloud.flatMap(Self.cloudSortDate)
    }

    var mergedSortDate: Date {
        let localDate = local?.lastViewedAt
        let cloudReadDate = cloud?.lastVisitedAt.flatMap(Self.parseISODate)
        if let localDate, let cloudReadDate { return max(localDate, cloudReadDate) }
        if let localDate { return localDate }
        if let cloudReadDate { return cloudReadDate }
        return cloud.flatMap(Self.cloudActivityDate) ?? .distantPast
    }

    static func cloudSortDate(_ topic: DiscourseTopicList.Topic) -> Date? {
        topic.lastVisitedAt.flatMap(parseISODate) ?? cloudActivityDate(topic)
    }

    private static func cloudActivityDate(_ topic: DiscourseTopicList.Topic) -> Date? {
        [topic.bumpedAt, topic.lastPostedAt, Optional(topic.createdAt)]
            .compactMap { $0 }
            .lazy
            .compactMap(parseISODate)
            .first
    }

    static func parseISODate(_ value: String) -> Date? {
        ISO8601DateFormatter.readHistoryWithFraction.date(from: value)
            ?? ISO8601DateFormatter.readHistoryWithoutFraction.date(from: value)
    }
}

enum ReadTopicMerger {
    static func merge(
        localTopics: [LocalReadTopic],
        cloudTopics: [DiscourseTopicList.Topic]
    ) -> [ReadTopicRow] {
        var merged = Dictionary(uniqueKeysWithValues: localTopics.map {
            ($0.topicId, ReadTopicRow(id: $0.topicId, local: $0, cloud: nil, cloudOrder: nil))
        })
        for (index, topic) in cloudTopics.enumerated() {
            merged[topic.id] = ReadTopicRow(
                id: topic.id,
                local: merged[topic.id]?.local,
                cloud: topic,
                cloudOrder: index
            )
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.mergedSortDate != rhs.mergedSortDate {
                return lhs.mergedSortDate > rhs.mergedSortDate
            }
            return (lhs.cloudOrder ?? .max) < (rhs.cloudOrder ?? .max)
        }
    }
}

private extension ISO8601DateFormatter {
    static let readHistoryWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let readHistoryWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension LocalReadTopic {
    var asTopicListTopic: DiscourseTopicList.Topic {
        DiscourseTopicList.Topic(
            id: topicId,
            fancyTitle: fancyTitle ?? title,
            title: title,
            postsCount: postsCount,
            replyCount: replyCount,
            views: 0,
            categoryId: categoryId,
            createdAt: createdAt,
            lastPostedAt: nil,
            bumpedAt: nil,
            lastVisitedAt: nil,
            pinned: nil,
            unseen: false,
            excerpt: nil,
            posters: nil,
            tags: tags
        )
    }
}
