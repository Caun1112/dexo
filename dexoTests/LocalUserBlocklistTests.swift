import XCTest
@testable import dexo

final class LocalUserBlocklistTests: XCTestCase {
    func testEntriesArePersistedAndScopedToTheirForum() throws {
        let suiteName = "dexo-local-blocklist-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(testingDefaults: defaults)

        XCTAssertEqual(
            settings.blockUserLocally(username: "Alice", baseURL: "https://LINUX.DO/t/123"),
            .added
        )
        XCTAssertEqual(
            settings.blockUserLocally(username: "alice", baseURL: "https://linux.do/"),
            .alreadyBlocked
        )
        XCTAssertTrue(settings.isUserLocallyBlocked(username: "ALICE", baseURL: "https://linux.do"))
        XCTAssertFalse(settings.isUserLocallyBlocked(username: "Alice", baseURL: "https://example.com"))

        let reloadedSettings = AppSettings(testingDefaults: defaults)
        XCTAssertTrue(reloadedSettings.isUserLocallyBlocked(username: "alice", baseURL: "https://linux.do/latest"))
        XCTAssertTrue(reloadedSettings.unblockUserLocally(username: "alice", baseURL: "https://LINUX.DO"))
        XCTAssertTrue(reloadedSettings.localBlockedUsers.isEmpty)
    }

    func testGlobalLimitIsFiftyUsers() throws {
        let suiteName = "dexo-local-blocklist-limit-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(testingDefaults: defaults)

        for index in 0..<AppSettings.maximumLocalBlockedUsers {
            XCTAssertEqual(
                settings.blockUserLocally(username: "user\(index)", baseURL: "https://linux.do"),
                .added
            )
        }

        XCTAssertEqual(settings.localBlockedUsers.count, 50)
        XCTAssertEqual(
            settings.blockUserLocally(username: "user0", baseURL: "https://linux.do"),
            .alreadyBlocked
        )
        XCTAssertEqual(
            settings.blockUserLocally(username: "one-too-many", baseURL: "https://example.com"),
            .limitReached
        )
        XCTAssertEqual(settings.localBlockedUsers.count, 50)
    }
}
