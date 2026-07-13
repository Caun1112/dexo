import CookedHTML
import UIKit
import XCTest
@testable import dexo

final class TopicRenderPipelineTests: XCTestCase {
    func testLongParagraphIsSplitWithoutLosingText() {
        let text = String(repeating: "Swift 渲染性能测试。", count: 120)
        let annotated = [AnnotatedBlock(block: .paragraph([.text(text)]), sourceHTML: "<p>…</p>")]

        let units = RenderUnitBuilder.build(postId: 42, contentVersion: 7, annotatedBlocks: annotated)

        XCTAssertGreaterThan(units.count, 1)
        let rebuilt = units.compactMap { unit -> String? in
            guard case .paragraph(let nodes) = unit.block else { return nil }
            return nodes.compactMap {
                if case .text(let value) = $0 { return value }
                return nil
            }.joined()
        }.joined()
        XCTAssertEqual(rebuilt, text)
        for unit in units {
            guard case .paragraph(let nodes) = unit.block else { continue }
            XCTAssertLessThanOrEqual(nodes.reduce(0) { $0 + InlineNodeChunker.utf16Length(of: $1) }, RenderUnitBuilder.maxParagraphUTF16)
        }
    }

    func testChunkingPreservesLinkAndSpoilerWrappers() {
        let linked = String(repeating: "linked ", count: 100)
        let hidden = String(repeating: "hidden ", count: 100)
        let chunks = InlineNodeChunker.chunk([
            .link(href: "https://example.com", children: [.text(linked)]),
            .spoiler(children: [.styledText(hidden, [.bold])]),
        ], maximumUTF16Length: 80)

        XCTAssertGreaterThan(chunks.count, 2)
        for node in chunks.flatMap({ $0 }) {
            switch node {
            case .link(let href, _): XCTAssertEqual(href, "https://example.com")
            case .spoiler: break
            default: XCTFail("Wrapper was lost while chunking: \(node)")
            }
        }
    }

    func testRenderUnitIDsAreStableAndVersioned() {
        let blocks = [AnnotatedBlock(block: .paragraph([.text("hello")]), sourceHTML: "<p>hello</p>")]
        let first = RenderUnitBuilder.build(postId: 1, contentVersion: 10, annotatedBlocks: blocks)
        let again = RenderUnitBuilder.build(postId: 1, contentVersion: 10, annotatedBlocks: blocks)
        let changed = RenderUnitBuilder.build(postId: 1, contentVersion: 11, annotatedBlocks: blocks)

        XCTAssertEqual(first.map(\.id), again.map(\.id))
        XCTAssertNotEqual(first.map(\.id), changed.map(\.id))
    }

    func testRenderEnvironmentInvalidatesEveryLayoutDimension() {
        let base = RenderEnvironment(contentWidth: 350, displayScale: 3, fontRevision: 1, themeRevision: 1)
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 351, displayScale: 3, fontRevision: 1, themeRevision: 1))
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 350, displayScale: 2, fontRevision: 1, themeRevision: 1))
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 350, displayScale: 3, fontRevision: 2, themeRevision: 1))
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 350, displayScale: 3, fontRevision: 1, themeRevision: 2))
    }

    func testHeightPoliciesSeparateFixedAndDeferredUnits() {
        let fixed = RenderUnitHeightPolicy.fixed(120)
        let deferred = RenderUnitHeightPolicy.deferred(180)

        XCTAssertEqual(fixed.height, 120)
        XCTAssertFalse(fixed.acceptsDynamicUpdates)
        XCTAssertEqual(deferred.height, 180)
        XCTAssertTrue(deferred.acceptsDynamicUpdates)
    }

    func testDynamicHeightBufferCoalescesLatestValueAndDrainsOnce() {
        let first = RenderUnitID(postId: 1, contentVersion: 1, ordinal: 0)
        let second = RenderUnitID(postId: 1, contentVersion: 1, ordinal: 1)
        var buffer = DynamicHeightUpdateBuffer()

        buffer.enqueue(height: 100, for: first)
        buffer.enqueue(height: 140, for: first)
        buffer.enqueue(height: 80, for: second)

        XCTAssertEqual(buffer.count, 2)
        let batch = buffer.drain()
        XCTAssertEqual(batch[first], 140)
        XCTAssertEqual(batch[second], 80)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func testHeightCacheKeyIncludesEffectiveEnvironmentAndStateRevision() {
        let id = RenderUnitID(postId: 1, contentVersion: 1, ordinal: 0)
        let compact = RenderEnvironment(contentWidth: 300, displayScale: 3, fontRevision: 1, themeRevision: 1)
        let wide = RenderEnvironment(contentWidth: 320, displayScale: 3, fontRevision: 1, themeRevision: 1)
        let base = RenderUnitHeightCacheKey(unitId: id, environment: compact, dynamicStateRevision: 0)

        XCTAssertNotEqual(base, RenderUnitHeightCacheKey(unitId: id, environment: wide, dynamicStateRevision: 0))
        XCTAssertNotEqual(base, RenderUnitHeightCacheKey(unitId: id, environment: compact, dynamicStateRevision: 1))
    }

    func testPipelineParsesBatchAndUsesStableDocuments() async {
        let input = PostRenderInput(postId: 9, cookedHTML: "<p>Hello <strong>world</strong></p>")
        let first = await TopicRenderPipeline.shared.renderDocuments(inputs: [input], baseURL: "https://example.com")
        let second = await TopicRenderPipeline.shared.renderDocuments(inputs: [input], baseURL: "https://example.com")

        XCTAssertEqual(first[9]?.contentVersion, input.contentVersion)
        XCTAssertEqual(first[9]?.units.map(\.id), second[9]?.units.map(\.id))
        XCTAssertEqual(first[9]?.units.count, 1)
    }

    func testImageBrowserRequestUsesAllUniqueImagesAndTappedIndex() {
        let blocks = [
            AnnotatedBlock(
                block: .image(src: "https://example.com/thumb-a.jpg", alt: nil, width: 10, height: 10, href: "https://example.com/a.jpg"),
                sourceHTML: ""
            ),
            AnnotatedBlock(
                block: .image(src: "https://example.com/b.jpg", alt: nil, width: nil, height: nil),
                sourceHTML: ""
            ),
            AnnotatedBlock(
                block: .image(src: "https://example.com/thumb-a.jpg", alt: nil, width: 10, height: 10, href: "https://example.com/a.jpg"),
                sourceHTML: ""
            ),
        ]

        let request = TopicImageBrowserRequest.make(
            annotatedBlocks: blocks,
            tappedURL: URL(string: "https://example.com/b.jpg")!
        )

        XCTAssertEqual(request.imageURLs.map(\.absoluteString), [
            "https://example.com/a.jpg",
            "https://example.com/b.jpg",
        ])
        XCTAssertEqual(request.startIndex, 1)
    }

    func testImageBrowserRequestFallsBackToTappedImage() {
        let tapped = URL(string: "https://example.com/only.jpg")!
        let request = TopicImageBrowserRequest.make(annotatedBlocks: [], tappedURL: tapped)

        XCTAssertEqual(request.imageURLs, [tapped])
        XCTAssertEqual(request.startIndex, 0)
    }

    func testVirtualItemsExposeOnlyPostLongPressTargets() {
        let unitId = RenderUnitID(postId: 42, contentVersion: 1, ordinal: 0)
        XCTAssertEqual(VirtualTopicItem.header(42).longPressPostId, 42)
        XCTAssertEqual(VirtualTopicItem.unit(unitId).longPressPostId, 42)
        XCTAssertEqual(VirtualTopicItem.footer(42).longPressPostId, 42)
        XCTAssertEqual(VirtualTopicItem.boosts(42).longPressPostId, 42)
        XCTAssertEqual(VirtualTopicItem.collapsed(42).longPressPostId, 42)
        XCTAssertNil(VirtualTopicItem.title(1).longPressPostId)
        XCTAssertNil(VirtualTopicItem.loadMoreChildren(42).longPressPostId)
    }
}

@MainActor
final class TopicRenderCacheTests: XCTestCase {
    func testLRUEvictsLeastRecentlyUsedEntry() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache[1] = "one"
        cache[2] = "two"
        _ = cache[1]
        cache[3] = "three"

        XCTAssertEqual(cache[1], "one")
        XCTAssertNil(cache[2])
        XCTAssertEqual(cache[3], "three")
    }

    func testParagraphPrecomputedHeightMatchesRenderedView() {
        let config = NativeRenderConfig.default(contentWidth: 320, baseURL: nil)
        let block = ContentBlock.paragraph([.text(String(repeating: "height parity ", count: 30))])
        let expected = try! XCTUnwrap(BlockHeightCalculator.height(for: block, config: config))
        let view = ParagraphRenderer.render(block, config: config, delegate: nil)
        let actual = view.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        XCTAssertEqual(expected, actual, accuracy: 1)
    }

    func testPostIDResolverFindsVirtualizedContainer() {
        let provider = TestPostIDProviderView(postId: 77)
        let nested = UIView()
        provider.addSubview(nested)

        XCTAssertEqual(TopicPostIDResolver.postId(startingAt: nested), 77)
        XCTAssertEqual(TopicPostIDResolver.postId(startingAt: UIView()), 0)
    }

    func testTreeContinuationIncludesAncestorOwnAndChildColumns() {
        let state = TreeLineState(
            depth: 3,
            isLastSibling: false,
            ancestorTrails: [false, true],
            hasChildren: true,
            isCollapsed: false
        )

        XCTAssertEqual(VirtualTreeContinuationView.columns(for: state), [
            TreeLineView.columnX(forDepth: 2),
            TreeLineView.columnX(forDepth: 3),
            TreeLineView.columnX(forDepth: 4),
        ])
    }

    func testTreeContinuationHandlesEmptyAncestorTrail() {
        let opState = TreeLineState(
            depth: 0,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )
        let directReplyState = TreeLineState(
            depth: 1,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )

        XCTAssertEqual(VirtualTreeContinuationView.columns(for: opState), [])
        XCTAssertEqual(VirtualTreeContinuationView.columns(for: directReplyState), [
            TreeLineView.columnX(forDepth: 2),
        ])
    }

    func testTreeContinuationStopsOwnAndChildColumnsWhenRequired() {
        let state = TreeLineState(
            depth: 3,
            isLastSibling: true,
            ancestorTrails: [false, true],
            hasChildren: true,
            isCollapsed: true
        )

        XCTAssertEqual(VirtualTreeContinuationView.columns(for: state), [
            TreeLineView.columnX(forDepth: 2),
        ])
    }

    func testTreeContinuationClampsDeepColumnsToMaximumIndent() {
        let state = TreeLineState(
            depth: 9,
            isLastSibling: false,
            ancestorTrails: [false, true, true, true, true, true, true, true],
            hasChildren: true,
            isCollapsed: false
        )
        let columns = VirtualTreeContinuationView.columns(for: state)
        let maximumColumn = TreeLineView.columnX(forDepth: PostNativeCell.treeMaxIndentLevels)

        XCTAssertEqual(columns.last, maximumColumn)
        XCTAssertTrue(columns.allSatisfy { $0 <= maximumColumn })
        XCTAssertEqual(columns, Array(Set(columns)).sorted())
    }

    func testTreeCollapsePillOnlyAppearsOnEligibleLastVisualItem() {
        let parent = TreeLineState(
            depth: 2,
            isLastSibling: false,
            ancestorTrails: [false],
            hasChildren: true,
            isCollapsed: false
        )
        let leaf = TreeLineState(
            depth: 2,
            isLastSibling: false,
            ancestorTrails: [false],
            hasChildren: false,
            isCollapsed: false
        )

        XCTAssertNil(VirtualTreeCollapsePill.leading(for: nil, isLastVisualItem: true))
        XCTAssertNil(VirtualTreeCollapsePill.leading(for: leaf, isLastVisualItem: true))
        XCTAssertNil(VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: false))
        XCTAssertNotNil(VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: true))
    }

    func testTreeCollapsePillMovesFromFooterToExpandedBoost() {
        let parent = TreeLineState(
            depth: 1,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )

        let footerWithoutBoost = VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: true)
        let footerWithBoost = VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: false)
        let expandedBoost = VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: true)

        XCTAssertNotNil(footerWithoutBoost)
        XCTAssertNil(footerWithBoost)
        XCTAssertEqual(expandedBoost, footerWithoutBoost)
    }

    func testTreeCollapsePillUsesLegacyGeometryAndClampsDeepIndent() {
        let deepParent = TreeLineState(
            depth: 9,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )
        let expectedLeading = TreeLineView.columnX(forDepth: PostNativeCell.treeMaxIndentLevels)
            - VirtualTreeCollapsePill.size / 2

        XCTAssertEqual(VirtualTreeCollapsePill.size, 18)
        XCTAssertEqual(VirtualTreeCollapsePill.bottomInset, 4)
        XCTAssertEqual(
            VirtualTreeCollapsePill.leading(for: deepParent, isLastVisualItem: true),
            expectedLeading
        )
    }

    func testTreeCollapsePillClearsVisibilityWhenReused() {
        let parent = TreeLineState(
            depth: 1,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )
        let pill = VirtualTreeCollapsePill(frame: .zero)

        pill.configure(state: parent, isLastVisualItem: true)
        XCTAssertFalse(pill.isHidden)
        pill.configure(state: nil, isLastVisualItem: false)
        XCTAssertTrue(pill.isHidden)
    }

    func testVirtualCellBackgroundMatchesLegacyCardBackground() {
        let cell = VirtualTopicTitleCell(frame: .zero)
        cell.configure(title: "Topic")

        XCTAssertEqual(cell.backgroundColor, ThemeManager.shared.cardBackgroundColor)
        XCTAssertEqual(cell.contentView.backgroundColor, ThemeManager.shared.cardBackgroundColor)
    }

    func testVirtualFooterButtonTintsMatchLegacyStates() {
        let normal = VirtualPostFooterButtonTints.resolve(isLiked: false, hasCurrentUserBoost: false)
        XCTAssertEqual(normal.reply, .tertiaryLabel)
        XCTAssertEqual(normal.like, .tertiaryLabel)
        XCTAssertEqual(normal.boost, .tertiaryLabel)
        XCTAssertEqual(normal.more, .tertiaryLabel)

        let liked = VirtualPostFooterButtonTints.resolve(isLiked: true, hasCurrentUserBoost: false)
        XCTAssertEqual(liked.like, .systemRed)
        XCTAssertEqual(liked.boost, .tertiaryLabel)

        let ordinaryBoost = VirtualPostFooterButtonTints.resolve(isLiked: false, hasCurrentUserBoost: false)
        XCTAssertEqual(ordinaryBoost.boost, .tertiaryLabel)

        let currentUserBoost = VirtualPostFooterButtonTints.resolve(isLiked: false, hasCurrentUserBoost: true)
        XCTAssertEqual(currentUserBoost.like, .tertiaryLabel)
        XCTAssertEqual(currentUserBoost.boost, .systemYellow)
    }

    func testVirtualFooterButtonTintsResetAfterReuseStateChange() {
        let cell = VirtualPostFooterCell(frame: .zero)
        cell.applyButtonTints(.resolve(isLiked: true, hasCurrentUserBoost: true))
        XCTAssertEqual(cell.appliedButtonTints.like, .systemRed)
        XCTAssertEqual(cell.appliedButtonTints.boost, .systemYellow)

        cell.applyButtonTints(.resolve(isLiked: false, hasCurrentUserBoost: false))
        XCTAssertEqual(cell.appliedButtonTints.reply, .tertiaryLabel)
        XCTAssertEqual(cell.appliedButtonTints.like, .tertiaryLabel)
        XCTAssertEqual(cell.appliedButtonTints.boost, .tertiaryLabel)
        XCTAssertEqual(cell.appliedButtonTints.more, .tertiaryLabel)
    }

    func testTimelineDynamicUpdateMovesOnlySuffixWithoutRemeasuring() {
        let layout = TopicTimelineLayout()
        let delegate = TestTimelineLayoutDelegate(heights: [40, 50, 60])
        layout.delegate = delegate
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), collectionViewLayout: layout)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "Cell")
        let source = TestTimelineDataSource(itemCount: 3)
        collection.dataSource = source
        collection.reloadData()
        collection.layoutIfNeeded()

        XCTAssertEqual(delegate.measurementCount, 3)
        XCTAssertEqual(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame.minY, 90)

        layout.applyHeightUpdates([IndexPath(item: 1, section: 0): 80])
        collection.layoutIfNeeded()

        XCTAssertEqual(delegate.measurementCount, 3)
        XCTAssertEqual(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame.height, 80)
        XCTAssertEqual(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame.minY, 120)
    }
}

private final class TestPostIDProviderView: UIView, TopicPostIDProviding {
    let renderedPostId: Int

    init(postId: Int) {
        renderedPostId = postId
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class TestTimelineLayoutDelegate: TopicTimelineLayoutDelegate {
    let heights: [CGFloat]
    private(set) var measurementCount = 0

    init(heights: [CGFloat]) { self.heights = heights }

    func topicTimelineLayout(_ layout: TopicTimelineLayout, heightForItemAt indexPath: IndexPath, width: CGFloat) -> CGFloat {
        measurementCount += 1
        return heights[indexPath.item]
    }
}

@MainActor
private final class TestTimelineDataSource: NSObject, UICollectionViewDataSource {
    private let itemCount: Int

    init(itemCount: Int) { self.itemCount = itemCount }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        itemCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "Cell", for: indexPath)
    }
}
