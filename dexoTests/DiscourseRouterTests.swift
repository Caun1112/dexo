import XCTest
@testable import dexo

final class DiscourseRouterTests: XCTestCase {
    func testLinuxDoFollowRoutesUsePluginEndpointAndMethods() {
        let list = DiscourseRouter.followedUsers(username: "current-user")
        XCTAssertEqual(list.path, "/u/current-user/follow/following.json")
        XCTAssertEqual(list.method, .get)

        let follow = DiscourseRouter.followUser(username: "undefinedmoe")
        XCTAssertEqual(follow.path, "/follow/undefinedmoe.json")
        XCTAssertEqual(follow.method, .put)

        let unfollow = DiscourseRouter.unfollowUser(username: "undefinedmoe")
        XCTAssertEqual(unfollow.path, "/follow/undefinedmoe.json")
        XCTAssertEqual(unfollow.method, .delete)
    }

    func testUserProfileDecodesFollowPluginState() throws {
        let data = Data(
            #"{"user":{"id":42,"username":"undefinedmoe","can_follow":true,"is_followed":false}}"#.utf8
        )
        let response = try JSONDecoder().decode(DiscourseUserProfileResponse.self, from: data)

        XCTAssertEqual(response.user.canFollow, true)
        XCTAssertEqual(response.user.isFollowed, false)
    }

    func testFollowedUsersDecodeBasicUserArray() throws {
        let data = Data(
            #"[{"id":42,"username":"undefinedmoe","name":"Undefined Moe","avatar_template":"/avatar/{size}.png"}]"#.utf8
        )
        let users = try JSONDecoder().decode([DiscourseFollowedUser].self, from: data)

        XCTAssertEqual(users, [
            DiscourseFollowedUser(
                id: 42,
                username: "undefinedmoe",
                name: "Undefined Moe",
                avatarTemplate: "/avatar/{size}.png"
            ),
        ])
    }

    func testTopicFeedRoutesMapAllModesToServerEndpoints() {
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .activity, page: 0).path,
            "/latest.json?page=0"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .created, page: 2).path,
            "/latest.json?page=2&order=created"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .hot, page: 3).path,
            "/hot.json?page=3"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .top, page: 4).path,
            "/top.json?page=4"
        )
    }

    func testCreatedFeedKeepsServerOrderOnEveryPage() {
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .created, page: 0).path,
            "/latest.json?page=0&order=created"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .created, page: 5).path,
            "/latest.json?page=5&order=created"
        )
    }

    func testCategoriesRouteCarriesSubcategoryAndPageParameters() {
        XCTAssertEqual(
            DiscourseRouter.categories(page: 1).path,
            "/categories.json?include_subcategories=true&page=1"
        )
        XCTAssertEqual(
            DiscourseRouter.categories(page: 4).path,
            "/categories.json?include_subcategories=true&page=4"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryChildren(parentCategoryID: 42, page: 2).path,
            "/categories.json?include_subcategories=true&parent_category_id=42&page=2"
        )
    }

    func testCategoryRoutesMapAllFeedModesAndKeepPageParameters() {
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: nil,
                page: 0
            ).path,
            "/c/dev/12.json?page=0"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .activity,
                page: 1
            ).path,
            "/c/dev/12/l/latest.json?page=1"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .created,
                page: 3
            ).path,
            "/c/dev/12/l/latest.json?page=3&order=created"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .hot,
                page: 4
            ).path,
            "/c/dev/12/l/hot.json?page=4"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .top,
                page: 5
            ).path,
            "/c/dev/12/l/top.json?page=5"
        )
    }
}
