import Foundation
import XCTest
@testable import dexo

final class PushSubscriptionDatabaseTests: XCTestCase {
    func testRetiringSubscriptionKeepsEndpointsForRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dexo-push-subscription-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DatabaseManager(
            testingPath: directory.appendingPathComponent("test.sqlite").path
        )
        var forum = ForumInstance.new(
            title: "Forum",
            baseURL: "https://forum.example.com"
        )
        try database.saveForum(&forum)
        let forumID = try XCTUnwrap(forum.id)

        var subscription = PushSubscriptionRecord(
            subscriptionID: "subscription-id",
            forumId: forumID,
            accountName: "alice",
            endpoint: "https://relay.example.com/current",
            previousEndpoint: "https://relay.example.com/previous",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            apnsTokenFingerprint: "fingerprint",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1_900_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_900_000_100)
        )
        subscription.supersededEndpoints = [
            "https://relay.example.com/previous",
            "https://relay.example.com/oldest",
        ]
        try database.savePushSubscription(subscription)

        subscription.state = .retiring
        subscription.endpoint = "https://relay.example.com/remaining"
        subscription.supersededEndpoints = [
            "https://relay.example.com/oldest",
        ]
        try database.savePushSubscription(subscription)

        let stored = try XCTUnwrap(
            database.fetchPushSubscription(
                forumId: forumID,
                accountName: "alice"
            )
        )
        XCTAssertEqual(stored.state, .retiring)
        XCTAssertEqual(
            stored.endpoint,
            "https://relay.example.com/remaining"
        )
        XCTAssertEqual(
            stored.supersededEndpoints,
            ["https://relay.example.com/oldest"]
        )
    }
}
