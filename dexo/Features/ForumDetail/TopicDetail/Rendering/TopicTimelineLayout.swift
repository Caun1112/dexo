import UIKit

protocol TopicTimelineLayoutDelegate: AnyObject {
    func topicTimelineLayout(_ layout: TopicTimelineLayout, heightForItemAt indexPath: IndexPath, width: CGFloat) -> CGFloat
}

/// A deliberately small vertical layout whose item frames come from the
/// render pipeline rather than UICollectionView's self-sizing pass. Dynamic
/// blocks update one cached height and invalidate the suffix only.
final class TopicTimelineLayout: UICollectionViewLayout {
    weak var delegate: TopicTimelineLayoutDelegate?

    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var heights: [CGFloat] = []
    private var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat = 0
    private var needsFullRebuild = true

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }

        let itemCount = (0..<collectionView.numberOfSections).reduce(0) {
            $0 + collectionView.numberOfItems(inSection: $1)
        }
        if abs(width - preparedWidth) > 0.5 || itemCount != attributes.count {
            needsFullRebuild = true
        }
        guard needsFullRebuild else { return }

        attributes.removeAll(keepingCapacity: true)
        heights.removeAll(keepingCapacity: true)
        var y: CGFloat = 0
        for section in 0..<collectionView.numberOfSections {
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: item, section: section)
                let height = max(1, delegate?.topicTimelineLayout(self, heightForItemAt: indexPath, width: width) ?? 200)
                let attr = UICollectionViewLayoutAttributes(forCellWith: indexPath)
                attr.frame = CGRect(x: 0, y: y, width: width, height: height).integral
                attributes.append(attr)
                heights.append(height)
                y = attr.frame.maxY
            }
        }
        preparedWidth = width
        contentHeight = y
        needsFullRebuild = false
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !attributes.isEmpty else { return [] }
        var lower = 0
        var upper = attributes.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if attributes[mid].frame.maxY < rect.minY { lower = mid + 1 }
            else { upper = mid }
        }
        let start = lower
        lower = start
        upper = attributes.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if attributes[mid].frame.minY <= rect.maxY { lower = mid + 1 }
            else { upper = mid }
        }
        guard start < lower else { return [] }
        return Array(attributes[start..<lower])
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    /// Marks snapshot/environment changes for one full height-table rebuild.
    func reloadAllHeights() {
        needsFullRebuild = true
        invalidateLayout()
    }

    /// Applies a dynamic-height batch without asking the delegate to remeasure
    /// every item. Only the changed item and the suffix receive new frames.
    func applyHeightUpdates(_ updates: [IndexPath: CGFloat]) {
        let valid = updates.compactMap { indexPath, height -> (Int, CGFloat)? in
            guard indexPath.section == 0, heights.indices.contains(indexPath.item),
                  height.isFinite, height > 0
            else { return nil }
            return (indexPath.item, height)
        }
        guard let earliest = valid.map(\.0).min() else { return }
        for (index, height) in valid { heights[index] = max(1, height) }

        var y = earliest == 0 ? 0 : attributes[earliest - 1].frame.maxY
        for index in earliest..<attributes.count {
            attributes[index].frame = CGRect(
                x: 0,
                y: y,
                width: preparedWidth,
                height: heights[index]
            ).integral
            y = attributes[index].frame.maxY
        }
        contentHeight = attributes.last?.frame.maxY ?? 0
        invalidateLayout()
    }

}
