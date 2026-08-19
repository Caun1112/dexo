import XCTest
@testable import dexo

final class HomeCategoryPreferencesTests: XCTestCase {
    func testCategoryIDsAreOrderedDeduplicatedAndScopedByNormalizedForumURL() throws {
        let suiteName = "dexo-home-category-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(testingDefaults: defaults)

        settings.setHomeCategoryIDs(
            [7, 3, 7, 1, 3],
            for: "https://LINUX.DO/t/123"
        )
        settings.setHomeCategoryIDs(
            [9, 9, 8],
            for: "https://example.com/latest"
        )

        XCTAssertEqual(settings.homeCategoryIDs(for: "https://linux.do/"), [7, 3, 1])
        XCTAssertEqual(settings.homeCategoryIDs(for: "https://LINUX.DO/top"), [7, 3, 1])
        XCTAssertEqual(settings.homeCategoryIDs(for: "https://example.com"), [9, 8])
        XCTAssertNil(settings.homeCategoryIDs(for: "https://another.example.com"))

        let reloadedSettings = AppSettings(testingDefaults: defaults)
        XCTAssertEqual(reloadedSettings.homeCategoryIDs(for: "https://linux.do"), [7, 3, 1])
        XCTAssertEqual(reloadedSettings.homeCategoryIDs(for: "https://EXAMPLE.COM/"), [9, 8])
    }

    func testExplicitEmptyCategoryListSurvivesReload() throws {
        let suiteName = "dexo-home-category-empty-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(testingDefaults: defaults)

        XCTAssertNil(settings.homeCategoryIDs(for: "https://linux.do"))
        settings.setHomeCategoryIDs([], for: "https://linux.do")
        XCTAssertEqual(try XCTUnwrap(settings.homeCategoryIDs(for: "https://linux.do")), [])

        let reloadedSettings = AppSettings(testingDefaults: defaults)
        XCTAssertEqual(try XCTUnwrap(reloadedSettings.homeCategoryIDs(for: "https://LINUX.DO/")), [])
    }
}
