import Foundation

enum TopicListFilter {
    static func excludingBlockedAuthors(
        from topics: [DiscourseTopicList.Topic],
        usersById: [Int: DiscourseTopicList.User],
        blockedUsernames: Set<String>
    ) -> [DiscourseTopicList.Topic] {
        guard !blockedUsernames.isEmpty else { return topics }
        let normalizedBlockedUsernames = Set(blockedUsernames.map { $0.lowercased() })

        return topics.filter { topic in
            guard let username = authorUsername(for: topic, usersById: usersById) else {
                return true
            }
            return !normalizedBlockedUsernames.contains(username.lowercased())
        }
    }

    private static func authorUsername(
        for topic: DiscourseTopicList.Topic,
        usersById: [Int: DiscourseTopicList.User]
    ) -> String? {
        guard let posters = topic.posters, !posters.isEmpty else { return nil }
        let author = posters.first { poster in
            poster.extras?.split(separator: " ").contains("original") == true
        } ?? posters[0]
        return usersById[author.userId]?.username
    }
}
