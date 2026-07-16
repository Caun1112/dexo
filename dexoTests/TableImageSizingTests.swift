import XCTest
@testable import dexo

final class TableImageSizingTests: XCTestCase {
    func testFitWithoutUpscalingPreservesThumbnailDimensions() {
        let size = TappableImageContainer.displaySize(
            width: 64,
            height: 40,
            containerWidth: 320,
            sizingMode: .fitWithoutUpscaling
        )

        XCTAssertEqual(size.width, 64, accuracy: 0.001)
        XCTAssertEqual(size.height, 40, accuracy: 0.001)
    }

    func testFitWithoutUpscalingShrinksImageWiderThanCell() {
        let size = TappableImageContainer.displaySize(
            width: 640,
            height: 360,
            containerWidth: 320,
            sizingMode: .fitWithoutUpscaling
        )

        XCTAssertEqual(size.width, 320, accuracy: 0.001)
        XCTAssertEqual(size.height, 180, accuracy: 0.001)
    }

    func testResponsivePostImageSizingRemainsUnchanged() {
        let size = TappableImageContainer.displaySize(
            width: 345,
            height: 200,
            containerWidth: 320,
            sizingMode: .discourseResponsive
        )

        XCTAssertEqual(size.width, 160, accuracy: 0.001)
        XCTAssertEqual(size.height, 160 * 200 / 345, accuracy: 0.001)
    }
}
