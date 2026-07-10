import XCTest
@testable import dexo

@MainActor
final class CategoryPageAccumulatorTests: XCTestCase {
    func testCategoryDecodesSubcategoryIDsAndNestedList() throws {
        let category = try JSONDecoder().decode(
            DiscourseCategory.self,
            from: Data(
                #"{"id":10,"name":"Root","color":"0088CC","slug":"root","topic_count":1,"subcategory_ids":[11,12],"subcategory_list":[{"id":11,"name":"Child","color":"0088CC","slug":"child","topic_count":0,"parent_category_id":10}]}"#.utf8
            )
        )

        XCTAssertEqual(category.subcategoryIds, [11, 12])
        XCTAssertEqual(category.subcategoryList?.map(\.id), [11])
        XCTAssertEqual(category.subcategoryList?.first?.parentCategoryId, 10)
    }

    func testAccumulatorDeduplicatesAcrossPagesAndPreservesServerOrder() {
        var accumulator = CategoryPageAccumulator()

        XCTAssertTrue(accumulator.append([
            category(id: 10, name: "First"),
            category(id: 20, name: "Second"),
        ]))
        XCTAssertTrue(accumulator.append([
            category(id: 20, name: "Duplicate should not replace"),
            category(id: 30, name: "Third"),
        ]))

        XCTAssertEqual(accumulator.categories.map(\.id), [10, 20, 30])
        XCTAssertEqual(accumulator.categories.map(\.name), ["First", "Second", "Third"])
    }

    func testAccumulatorStopsOnEmptyPage() {
        var accumulator = CategoryPageAccumulator()

        XCTAssertFalse(accumulator.append([]))
        XCTAssertTrue(accumulator.categories.isEmpty)
    }

    func testAccumulatorStopsWhenPageContainsOnlyKnownIDs() {
        var accumulator = CategoryPageAccumulator()
        XCTAssertTrue(accumulator.append([
            category(id: 1, name: "One"),
            category(id: 2, name: "Two"),
        ]))

        XCTAssertFalse(accumulator.append([
            category(id: 2, name: "Two again"),
            category(id: 1, name: "One again"),
        ]))
        XCTAssertEqual(accumulator.categories.map(\.id), [1, 2])
    }

    func testAccumulatorContinuesWhenPageAddsOnlyALazyChildID() {
        var accumulator = CategoryPageAccumulator()
        XCTAssertTrue(accumulator.append([
            category(id: 10, name: "Root", subcategoryIDs: [11]),
        ]))

        XCTAssertTrue(accumulator.append([
            category(id: 11, name: "Lazy child", parentID: 10),
        ]))
        XCTAssertEqual(accumulator.categories[0].subcategoryList?.map(\.id), [11])
    }

    func testLazyLoadFlatChildrenAreNestedInsteadOfBecomingRoots() {
        var accumulator = CategoryPageAccumulator()

        XCTAssertTrue(accumulator.append([
            category(id: 10, name: "First", subcategoryIDs: [11, 12]),
            category(id: 20, name: "Second", subcategoryIDs: []),
            category(id: 11, name: "Preview child", parentID: 10),
        ]))

        XCTAssertEqual(accumulator.categories.map(\.id), [10, 20])
        XCTAssertEqual(accumulator.categories[0].subcategoryList?.map(\.id), [11])
        XCTAssertEqual(accumulator.nextParentCategoryIDNeedingFetch, 10)

        XCTAssertTrue(accumulator.appendChildren([
            category(id: 11, name: "Duplicate preview", parentID: 10),
            category(id: 12, name: "Remaining child", parentID: 10),
        ], parentCategoryID: 10))
        XCTAssertTrue(accumulator.hasAllExpectedChildren(for: 10))
        XCTAssertEqual(accumulator.categories[0].subcategoryList?.map(\.id), [11, 12])
    }

    func testNestedSubcategoryListIsPreserved() {
        var accumulator = CategoryPageAccumulator()
        let grandchild = category(id: 12, name: "Grandchild", parentID: 11)
        let child = category(
            id: 11,
            name: "Child",
            parentID: 10,
            subcategoryIDs: [12],
            subcategoryList: [grandchild]
        )

        XCTAssertTrue(accumulator.append([
            category(
                id: 10,
                name: "Root",
                subcategoryIDs: [11],
                subcategoryList: [child]
            ),
        ]))

        XCTAssertNil(accumulator.nextParentCategoryIDNeedingFetch)
        XCTAssertEqual(
            accumulator.categories[0].subcategoryList?[0].subcategoryList?.map(\.id),
            [12]
        )
    }

    func testChildPaginationReplacesPreviewOrderThenStopsOnDuplicatePage() {
        var accumulator = CategoryPageAccumulator()
        _ = accumulator.append([
            category(id: 10, name: "Root", subcategoryIDs: [11, 12]),
            category(id: 11, name: "Preview", parentID: 10),
        ])

        XCTAssertTrue(accumulator.appendChildren([
            category(id: 11, name: "Preview again", parentID: 10),
        ], parentCategoryID: 10))
        XCTAssertFalse(accumulator.appendChildren([
            category(id: 11, name: "Duplicate page", parentID: 10),
        ], parentCategoryID: 10))

        accumulator.markChildFetchCompleted(for: 10)
        XCTAssertNil(accumulator.nextParentCategoryIDNeedingFetch)
    }

    private func category(
        id: Int,
        name: String,
        parentID: Int? = nil,
        subcategoryIDs: [Int]? = nil,
        subcategoryList: [DiscourseCategory]? = nil
    ) -> DiscourseCategory {
        DiscourseCategory(
            id: id,
            name: name,
            slug: "category-\(id)",
            parentCategoryId: parentID,
            subcategoryIds: subcategoryIDs,
            subcategoryList: subcategoryList
        )
    }
}
