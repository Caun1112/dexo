import UIKit

protocol TopicTimelineLayoutDelegate: AnyObject {
    func topicTimelineLayout(_ layout: TopicTimelineLayout, heightForItemAt indexPath: IndexPath, width: CGFloat) -> CGFloat
}

/// Value-only frame table shared by the collection layout and unit tests.
/// Keeping UIKit attribute objects out of the cache avoids ownership crashes
/// across layout invalidations and makes suffix updates deterministic.
nonisolated struct TopicTimelineGeometry {
    private(set) var frames: [CGRect] = []
    private(set) var heights: [CGFloat] = []
    private(set) var contentHeight: CGFloat = 0
    private(set) var width: CGFloat = 0

    mutating func rebuild(heights: [CGFloat], width: CGFloat) {
        self.width = width
        self.heights = heights.map { max(1, $0) }
        frames.removeAll(keepingCapacity: true)
        var y: CGFloat = 0
        for height in self.heights {
            let frame = CGRect(x: 0, y: y, width: width, height: height).integral
            frames.append(frame)
            y = frame.maxY
        }
        contentHeight = y
    }

    mutating func applyHeightUpdates(_ updates: [Int: CGFloat]) {
        let valid = updates.compactMap { index, height -> (Int, CGFloat)? in
            guard heights.indices.contains(index), height.isFinite, height > 0 else { return nil }
            return (index, max(1, height))
        }
        guard let earliest = valid.map(\.0).min() else { return }
        for (index, height) in valid { heights[index] = height }

        var y = earliest == 0 ? 0 : frames[earliest - 1].maxY
        for index in earliest..<frames.count {
            frames[index] = CGRect(x: 0, y: y, width: width, height: heights[index]).integral
            y = frames[index].maxY
        }
        contentHeight = frames.last?.maxY ?? 0
    }
}

/// A deliberately small vertical layout whose item frames come from the
/// render pipeline rather than UICollectionView's self-sizing pass. Dynamic
/// blocks update one cached height and invalidate the suffix only.
final class TopicTimelineLayout: UICollectionViewLayout {
    weak var delegate: TopicTimelineLayoutDelegate?

    private var geometry = TopicTimelineGeometry()
    private var preparedWidth: CGFloat = 0
    private var needsFullRebuild = true

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: geometry.contentHeight)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }

        let itemCount = (0..<collectionView.numberOfSections).reduce(0) {
            $0 + collectionView.numberOfItems(inSection: $1)
        }
        if abs(width - preparedWidth) > 0.5 || itemCount != geometry.frames.count {
            needsFullRebuild = true
        }
        guard needsFullRebuild else { return }

        var measured: [CGFloat] = []
        measured.reserveCapacity(itemCount)
        for section in 0..<collectionView.numberOfSections {
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: item, section: section)
                measured.append(max(1, delegate?.topicTimelineLayout(self, heightForItemAt: indexPath, width: width) ?? 200))
            }
        }
        geometry.rebuild(heights: measured, width: width)
        preparedWidth = width
        needsFullRebuild = false
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let frames = geometry.frames
        guard !frames.isEmpty else { return [] }
        var lower = 0
        var upper = frames.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if frames[mid].maxY < rect.minY { lower = mid + 1 }
            else { upper = mid }
        }
        let start = lower
        lower = start
        upper = frames.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if frames[mid].minY <= rect.maxY { lower = mid + 1 }
            else { upper = mid }
        }
        guard start < lower else { return [] }
        return (start..<lower).map { makeAttributes(item: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, geometry.frames.indices.contains(indexPath.item) else { return nil }
        return makeAttributes(item: indexPath.item)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    func reloadAllHeights() {
        needsFullRebuild = true
        invalidateLayout()
    }

    func applyHeightUpdates(_ updates: [IndexPath: CGFloat]) {
        let indexed = Dictionary(uniqueKeysWithValues: updates.compactMap { indexPath, height in
            indexPath.section == 0 ? (indexPath.item, height) : nil
        })
        geometry.applyHeightUpdates(indexed)
        invalidateLayout()
    }

    private func makeAttributes(item: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0))
        attributes.frame = geometry.frames[item]
        return attributes
    }
}
