import UIKit
import XCTest
@testable import dexo

@MainActor
final class TopicCellTests: XCTestCase {
    func testPureTagsHaveNoEmptyCategoryOrLeadingSeparatorAndAreTruncated() {
        let metadata = TopicCellMetadata(
            categoryName: "   ",
            tags: [
                TopicListTag(name: "swift"),
                TopicListTag(name: "ios"),
                TopicListTag(name: "uikit"),
            ]
        )

        XCTAssertNil(metadata.categoryName)
        XCTAssertEqual(metadata.displayText, "swift · ios +1")
        XCTAssertEqual(metadata.allTagNames, ["swift", "ios", "uikit"])
    }

    func testCellVoiceOverReadsEveryTagWhileVisualMetadataStaysTruncated() throws {
        let topic = try decodeTopic(tags: ["one", "two", "three"])
        let cell = TopicCell(style: .default, reuseIdentifier: nil)

        cell.configure(
            with: topic,
            avatarURL: nil,
            categoryName: nil,
            categoryColor: nil
        )

        let visibleTexts = labels(in: cell).compactMap(\.text)
        XCTAssertTrue(visibleTexts.contains("one"))
        XCTAssertTrue(visibleTexts.contains("two"))
        XCTAssertTrue(visibleTexts.contains("+1"))
        XCTAssertFalse(visibleTexts.contains("three"))
        XCTAssertTrue(cell.accessibilityLabel?.contains("one, two, three") == true)
    }

    func testTagBadgesUseTightCenteredIntrinsicWidth() throws {
        let topic = try decodeTopic(tags: ["ai", "ios", "swift"])
        let cell = TopicCell(style: .default, reuseIdentifier: nil)
        cell.bounds = CGRect(x: 0, y: 0, width: 390, height: 1)
        cell.contentView.bounds = cell.bounds

        cell.configure(
            with: topic,
            avatarURL: nil,
            categoryName: nil,
            categoryColor: nil
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let aiBadge = try XCTUnwrap(labels(in: cell).first { $0.text == "ai" })
        let countBadge = try XCTUnwrap(labels(in: cell).first { $0.text == "+1" })

        XCTAssertEqual(aiBadge.textAlignment, .center)
        XCTAssertEqual(countBadge.textAlignment, .center)

        let aiTextWidth = ("ai" as NSString).size(withAttributes: [.font: aiBadge.font as Any]).width
        XCTAssertEqual(aiBadge.intrinsicContentSize.width, aiTextWidth + 10, accuracy: 1)
        XCTAssertLessThan(aiBadge.intrinsicContentSize.width - aiTextWidth, 12)
    }

    func testCellFontsAndSelfSizingGrowAtLargeAppFontSetting() throws {
        let settings = AppSettings.shared
        let originalLevel = settings.fontSizeLevel
        let originalFollowSystem = settings.followSystemFontSize
        defer {
            settings.fontSizeLevel = originalLevel
            settings.followSystemFontSize = originalFollowSystem
            FontManager.shared.notifyChange()
        }

        settings.followSystemFontSize = false
        settings.fontSizeLevel = 0
        FontManager.shared.notifyChange()

        let topic = try decodeTopic(tags: ["swift", "ios"])
        let cell = TopicCell(style: .default, reuseIdentifier: nil)
        cell.configure(
            with: topic,
            avatarURL: nil,
            categoryName: "Development",
            categoryColor: nil
        )
        let normalTitleSize = labels(in: cell).first { $0.text == "A topic" }?.font.pointSize
        let normalHeight = fittedHeight(of: cell)

        settings.fontSizeLevel = 4
        FontManager.shared.notifyChange()
        cell.configure(
            with: topic,
            avatarURL: nil,
            categoryName: "Development",
            categoryColor: nil
        )
        let largeTitleSize = labels(in: cell).first { $0.text == "A topic" }?.font.pointSize
        let largeHeight = fittedHeight(of: cell)

        XCTAssertNotNil(normalTitleSize)
        XCTAssertNotNil(largeTitleSize)
        XCTAssertGreaterThan(largeTitleSize ?? 0, normalTitleSize ?? 0)
        XCTAssertGreaterThan(largeHeight, normalHeight)
    }

    private func fittedHeight(of cell: TopicCell) -> CGFloat {
        cell.bounds = CGRect(x: 0, y: 0, width: 390, height: 1)
        cell.contentView.bounds = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { subview -> [UILabel] in
            let current = (subview as? UILabel).map { [$0] } ?? []
            return current + labels(in: subview)
        }
    }

    private func decodeTopic(tags: [String]) throws -> DiscourseTopicList.Topic {
        let tagsJSON = try JSONSerialization.data(withJSONObject: tags)
        let tagsString = String(decoding: tagsJSON, as: UTF8.self)
        let json = """
        {
          "id": 1,
          "fancy_title": "A topic",
          "title": "A topic",
          "posts_count": 3,
          "reply_count": 2,
          "views": 10,
          "created_at": "2026-07-08T01:00:00.000Z",
          "tags": \(tagsString)
        }
        """
        return try JSONDecoder().decode(
            DiscourseTopicList.Topic.self,
            from: Data(json.utf8)
        )
    }
}
