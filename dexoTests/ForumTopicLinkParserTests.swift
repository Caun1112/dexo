import XCTest
@testable import dexo

final class ForumTopicLinkParserTests: XCTestCase {
    func testParsesTopicLinkWithSlugAndFloor() throws {
        let url = try XCTUnwrap(URL(string: "https://forum.example.com/t/a-topic/123/45"))

        XCTAssertEqual(
            ForumTopicLinkParser.parse(url, baseURL: "https://forum.example.com"),
            ForumTopicLinkRoute(topicId: 123, floor: 45)
        )
    }

    func testParsesTopicLinkWithoutSlug() throws {
        let url = try XCTUnwrap(URL(string: "https://forum.example.com/t/123"))

        XCTAssertEqual(
            ForumTopicLinkParser.parse(url, baseURL: "https://forum.example.com"),
            ForumTopicLinkRoute(topicId: 123, floor: nil)
        )
    }

    func testHostComparisonIsCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "https://FORUM.EXAMPLE.COM/t/topic/123/2"))

        XCTAssertEqual(
            ForumTopicLinkParser.parse(url, baseURL: "https://forum.example.com"),
            ForumTopicLinkRoute(topicId: 123, floor: 2)
        )
    }

    func testRejectsAnotherForumHost() throws {
        let url = try XCTUnwrap(URL(string: "https://other.example.com/t/topic/123/2"))

        XCTAssertNil(ForumTopicLinkParser.parse(url, baseURL: "https://forum.example.com"))
    }
}
