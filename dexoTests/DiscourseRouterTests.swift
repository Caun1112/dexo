import XCTest
@testable import dexo

final class DiscourseRouterTests: XCTestCase {
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
