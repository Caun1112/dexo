import Foundation
import XCTest
@testable import dexo

final class ReadBoostConfigTests: XCTestCase {
    func testNormalizedOrdersMinMaxPairs() {
        let config = ReadBoostConfig(
            minReqSize: 30,
            maxReqSize: 5,
            minReadTime: 4000,
            maxReadTime: 1000
        ).normalized()

        XCTAssertEqual(config.minReqSize, 30)
        XCTAssertEqual(config.maxReqSize, 30, "max must not fall below min")
        XCTAssertEqual(config.minReadTime, 4000)
        XCTAssertEqual(config.maxReadTime, 4000)
    }

    func testNormalizedClampsOutOfRangeValues() {
        let config = ReadBoostConfig(
            baseDelay: -1,
            randomDelayRange: 10_000_000,
            minReqSize: 0,
            maxReqSize: 5000,
            minReadTime: 1,
            maxReadTime: 999_999
        ).normalized()

        XCTAssertEqual(config.baseDelay, 0)
        XCTAssertEqual(config.randomDelayRange, 600_000)
        XCTAssertEqual(config.minReqSize, 1)
        XCTAssertEqual(config.maxReqSize, 300)
        XCTAssertEqual(config.minReadTime, 100)
        XCTAssertEqual(config.maxReadTime, 120_000)
    }

    func testNormalizedKeepsDefaultsUntouched() {
        XCTAssertEqual(ReadBoostConfig.defaults.normalized(), ReadBoostConfig.defaults)
    }

    func testSaveRoundTripsThroughDefaults() {
        let suiteName = "ReadBoostConfigTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ReadBoostManager(testingDefaults: defaults)
        var config = ReadBoostConfig.defaults
        config.baseDelay = 4200
        config.startFromCurrent = true
        config.hasAgreed = true
        manager.save(config: config)

        let reloaded = ReadBoostManager(testingDefaults: defaults)
        XCTAssertEqual(reloaded.config.baseDelay, 4200)
        XCTAssertTrue(reloaded.config.startFromCurrent)
        XCTAssertTrue(reloaded.config.hasAgreed)
        XCTAssertFalse(reloaded.config.autoStart)
    }
}
