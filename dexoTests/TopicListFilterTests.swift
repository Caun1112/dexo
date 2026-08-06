import XCTest
@testable import dexo

final class TopicListFilterTests: XCTestCase {
    func testExcludesTopicWhoseAuthorIsBlockedCaseInsensitively() {
        let topic = makeTopic(posters: [.init(userId: 1, extras: "latest single")])
        let users = [1: DiscourseTopicList.User(id: 1, username: "Alice", avatarTemplate: nil)]

        let visible = TopicListFilter.excludingBlockedAuthors(
            from: [topic],
            usersById: users,
            blockedUsernames: ["ALICE"]
        )

        XCTAssertTrue(visible.isEmpty)
    }

    func testUsesOriginalPosterInsteadOfLatestPoster() {
        let topic = makeTopic(posters: [
            .init(userId: 2, extras: "latest"),
            .init(userId: 1, extras: "original"),
        ])
        let users = [
            1: DiscourseTopicList.User(id: 1, username: "alice", avatarTemplate: nil),
            2: DiscourseTopicList.User(id: 2, username: "bob", avatarTemplate: nil),
        ]

        let visible = TopicListFilter.excludingBlockedAuthors(
            from: [topic],
            usersById: users,
            blockedUsernames: ["alice"]
        )

        XCTAssertTrue(visible.isEmpty)
    }

    func testKeepsTopicWhenAuthorCannotBeResolved() {
        let topic = makeTopic(posters: [.init(userId: 99, extras: "original")])

        let visible = TopicListFilter.excludingBlockedAuthors(
            from: [topic],
            usersById: [:],
            blockedUsernames: ["alice"]
        )

        XCTAssertEqual(visible.map(\.id), [topic.id])
    }

    func testKeepsTopicWhoseAuthorIsNotBlocked() {
        let topic = makeTopic(posters: [.init(userId: 2, extras: "original")])
        let users = [2: DiscourseTopicList.User(id: 2, username: "bob", avatarTemplate: nil)]

        let visible = TopicListFilter.excludingBlockedAuthors(
            from: [topic],
            usersById: users,
            blockedUsernames: ["alice"]
        )

        XCTAssertEqual(visible.map(\.id), [topic.id])
    }

    private func makeTopic(posters: [DiscourseTopicList.Poster]) -> DiscourseTopicList.Topic {
        DiscourseTopicList.Topic(
            id: 1,
            fancyTitle: "Topic",
            title: "Topic",
            postsCount: 1,
            replyCount: 0,
            views: 1,
            categoryId: nil,
            createdAt: "2026-08-06T00:00:00.000Z",
            lastPostedAt: nil,
            bumpedAt: nil,
            lastVisitedAt: nil,
            pinned: false,
            unseen: false,
            excerpt: nil,
            posters: posters,
            tags: []
        )
    }
}
