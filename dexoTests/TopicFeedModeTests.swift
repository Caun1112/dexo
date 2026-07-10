import XCTest
@testable import dexo

final class TopicFeedModeTests: XCTestCase {
    func testAllProductModesHaveStableRawValues() {
        XCTAssertEqual(
            TopicFeedMode.allCases.map(\.rawValue),
            ["activity", "created", "hot", "top"]
        )
    }

    func testActivityAndCreatedModesShareLatestEndpoint() {
        XCTAssertEqual(TopicFeedMode.activity.listPathComponent, "latest")
        XCTAssertEqual(TopicFeedMode.created.listPathComponent, "latest")
        XCTAssertEqual(TopicFeedMode.hot.listPathComponent, "hot")
        XCTAssertEqual(TopicFeedMode.top.listPathComponent, "top")
    }

    func testOnlyCreatedModeRequestsServerCreationOrder() {
        XCTAssertNil(TopicFeedMode.activity.orderQueryValue)
        XCTAssertEqual(TopicFeedMode.created.orderQueryValue, "created")
        XCTAssertNil(TopicFeedMode.hot.orderQueryValue)
        XCTAssertNil(TopicFeedMode.top.orderQueryValue)
    }

    func testTimestampKindFollowsFeedSemantics() {
        XCTAssertEqual(TopicFeedMode.activity.timestampKind, .activity)
        XCTAssertEqual(TopicFeedMode.created.timestampKind, .created)
        XCTAssertEqual(TopicFeedMode.hot.timestampKind, .activity)
        XCTAssertEqual(TopicFeedMode.top.timestampKind, .activity)
    }
}
