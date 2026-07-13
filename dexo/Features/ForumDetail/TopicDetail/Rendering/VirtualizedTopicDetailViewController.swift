import CookedHTML
import Lightbox
import SafariServices
import SDWebImage
import UIKit

enum TopicDetailControllerFactory {
    static func make(api: DiscourseAPI, topicId: Int, initialFloor: Int? = nil) -> UIViewController {
        switch AppSettings.shared.topicRenderingMode {
        case .virtualized:
            return VirtualizedTopicDetailViewController(api: api, topicId: topicId, initialFloor: initialFloor)
        case .legacy:
            return LegacyTopicDetailViewController(api: api, topicId: topicId, initialFloor: initialFloor)
        }
    }
}

nonisolated enum VirtualTopicItem: Hashable, Sendable {
    case title(Int)
    case header(Int)
    case unit(RenderUnitID)
    case footer(Int)
    case boosts(Int)
    case collapsed(Int)
    case loadMoreChildren(Int)

    var longPressPostId: Int? {
        switch self {
        case .header(let postId), .footer(let postId), .boosts(let postId), .collapsed(let postId):
            return postId
        case .unit(let id):
            return id.postId
        case .title, .loadMoreChildren:
            return nil
        }
    }
}

/// Default topic renderer. Posts are flattened into independently reusable
/// header/body/footer items, so a very tall post never forces UIKit to create
/// or draw its complete view tree in one frame.
final class VirtualizedTopicDetailViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let topicId: Int
    private let baseURL: String
    private let viewModel: TopicDetailViewModel
    private var initialFloor: Int?
    private var unitsById: [RenderUnitID: RenderUnit] = [:]
    private var postIdByItem: [VirtualTopicItem: Int] = [:]
    private var preparedLayout: PreparedTopicLayout?
    private var heightPolicyCache: [RenderUnitHeightCacheKey: RenderUnitHeightPolicy] = [:]
    private var resolvedHeights: [RenderUnitID: CGFloat] = [:]
    private var resolvedBoostHeights: [Int: CGFloat] = [:]
    private var pendingDynamicHeights = DynamicHeightUpdateBuffer()
    private var dynamicStateRevisions: [RenderUnitID: Int] = [:]
    private var expandedDetailsUnitIds: Set<RenderUnitID> = []
    private var pendingPollSelectionsByUnitId: [RenderUnitID: Set<String>] = [:]
    private var lastEnvironment: RenderEnvironment?
    private var isApplyingSnapshot = false
    private var hasPendingSnapshot = false
    private var pendingSnapshotReloadVisible = false
    private var pendingSnapshotAnchor: (VirtualTopicItem, CGFloat)?
    private var isLoadingPage = false
    private var loadEarlierArmed = true
    private var visibleItemCountsByPost: [Int: Int] = [:]
    private var imagePrefetchTokens: [VirtualTopicItem: SDWebImagePrefetchToken] = [:]
    private var jumpScrubber: JumpScrubberOverlay?
    private var jumpScrubStartLocation: CGPoint = .zero
    private var jumpScrubHasMoved = false
    private var jumpScrubStartFloor = 1
    private var jumpScrubReferenceDistance: CGFloat = 1
    private let jumpScrubMoveThreshold: CGFloat = 8
    private let readTracker = TopicReadTracker()
    private let imageZoomTransition = ImageZoomTransitionDelegate()
    private let floatingReplyButton = FloatingReplyButton()
    private var floatingReplyButtonPositioned = false
    private var treeReloadGeneration: UInt = 0

    private let timelineLayout = TopicTimelineLayout()
    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: timelineLayout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = ThemeManager.shared.cardBackgroundColor
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        view.delegate = self
        view.prefetchDataSource = self
        view.register(VirtualTopicTitleCell.self, forCellWithReuseIdentifier: VirtualTopicTitleCell.reuseIdentifier)
        view.register(VirtualPostHeaderCell.self, forCellWithReuseIdentifier: VirtualPostHeaderCell.reuseIdentifier)
        view.register(VirtualPostBlockCell.self, forCellWithReuseIdentifier: VirtualPostBlockCell.reuseIdentifier)
        view.register(VirtualPostFooterCell.self, forCellWithReuseIdentifier: VirtualPostFooterCell.reuseIdentifier)
        view.register(VirtualTopicMessageCell.self, forCellWithReuseIdentifier: VirtualTopicMessageCell.reuseIdentifier)
        view.register(VirtualPostCollapsedCell.self, forCellWithReuseIdentifier: VirtualPostCollapsedCell.reuseIdentifier)
        view.register(VirtualLoadMoreChildrenCell.self, forCellWithReuseIdentifier: VirtualLoadMoreChildrenCell.reuseIdentifier)
        view.register(VirtualBoostsCell.self, forCellWithReuseIdentifier: VirtualBoostsCell.reuseIdentifier)
        return view
    }()

    private lazy var dataSource = UICollectionViewDiffableDataSource<Int, VirtualTopicItem>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
        guard let self else { return UICollectionViewCell() }
        switch item {
        case .title:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualTopicTitleCell.reuseIdentifier, for: indexPath) as! VirtualTopicTitleCell
            let topic = self.viewModel.topic
            cell.configure(title: topic?.fancyTitle ?? topic?.title ?? "")
            return cell

        case .header(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostHeaderCell.reuseIdentifier, for: indexPath) as! VirtualPostHeaderCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            cell.configure(
                post: post,
                floor: post.postNumber,
                baseURL: self.baseURL,
                isOP: post.username == self.viewModel.opUsername,
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil
            )
            cell.onAvatar = { [weak self] in self?.postCell(didTapAvatarForUsername: $0) }
            return cell

        case .unit(let unitId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostBlockCell.reuseIdentifier, for: indexPath) as! VirtualPostBlockCell
            guard let unit = self.unitsById[unitId], let post = self.viewModel.postsById[unitId.postId] else { return cell }
            let depth = self.viewModel.isTreeMode ? (self.viewModel.postDepths[post.id] ?? 0) : 0
            let indent = PostNativeCell.treeContentIndent(forDepth: depth)
            let config = NativeRenderConfig.default(
                contentWidth: max(1, collectionView.bounds.width - 24 - indent),
                baseURL: self.baseURL
            )
            let heightPolicy = self.preparedLayout?.policy(for: unitId) ?? .fixed(1)
            cell.sizeDelegate = heightPolicy.acceptsDynamicUpdates ? self : nil
            cell.configure(
                unit: unit,
                post: post,
                config: config,
                delegate: self,
                leadingIndent: indent,
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[post.id] : nil,
                detailsExpanded: self.expandedDetailsUnitIds.contains(unitId),
                onDetailsExpansionChange: { [weak self] expanded in
                    if expanded { self?.expandedDetailsUnitIds.insert(unitId) }
                    else { self?.expandedDetailsUnitIds.remove(unitId) }
                },
                pollPendingSelections: self.pendingPollSelectionsByUnitId[unitId],
                onPollPendingSelectionsChange: { [weak self] selections in
                    self?.pendingPollSelectionsByUnitId[unitId] = selections
                },
                heightPolicy: heightPolicy
            )
            return cell

        case .footer(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostFooterCell.reuseIdentifier, for: indexPath) as! VirtualPostFooterCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            cell.configure(
                post: post,
                menu: self.moreMenu(for: post),
                hidesLikeButton: ForumPolicy.hidesLikeButton(baseURL: self.baseURL),
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil,
                isLastVisualItem: !self.viewModel.expandedBoostPostIds.contains(postId)
            )
            cell.onReply = { [weak self] in self?.postCell(didTapReplyToPost: post) }
            cell.onLike = { [weak self] in
                self?.postCell(didToggleLikeForPost: post, liked: post.likeAction?.acted != true)
            }
            cell.onBoost = { [weak self] in
                guard let self else { return }
                if post.boosts.isEmpty {
                    self.postCell(didTapBoostForPost: post)
                } else {
                    self.postCell(didTapToggleBoostsForPost: post, sourceView: cell)
                }
            }
            cell.onCollapse = { [weak self] in
                self?.postCell(didToggleCollapseForPostId: postId)
            }
            return cell

        case .collapsed(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostCollapsedCell.reuseIdentifier, for: indexPath) as! VirtualPostCollapsedCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            cell.configure(
                post: post,
                depth: self.viewModel.postDepths[postId] ?? 0,
                treeState: self.viewModel.postTreeLineStates[postId],
                baseURL: self.baseURL
            )
            cell.onExpand = { [weak self] in self?.postCell(didToggleCollapseForPostId: $0) }
            return cell

        case .loadMoreChildren(let parentId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualLoadMoreChildrenCell.reuseIdentifier, for: indexPath) as! VirtualLoadMoreChildrenCell
            guard let load = self.viewModel.pendingChildLoads[parentId] else { return cell }
            cell.configure(load: load, isLoading: self.viewModel.loadingChildrenParentIds.contains(parentId))
            cell.onLoad = { [weak self] in self?.postCell(didTapLoadMoreChildrenForParentId: $0) }
            return cell

        case .boosts(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualBoostsCell.reuseIdentifier, for: indexPath) as! VirtualBoostsCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            let depth = self.viewModel.isTreeMode ? (self.viewModel.postDepths[postId] ?? 0) : 0
            let indent = PostNativeCell.treeContentIndent(forDepth: depth)
            cell.configure(
                post: post,
                delegate: self,
                assetBaseURL: self.api.assetBaseURL,
                contentWidth: collectionView.bounds.width,
                leadingIndent: indent,
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil
            )
            cell.onCollapse = { [weak self] in
                self?.postCell(didToggleCollapseForPostId: postId)
            }
            return cell
        }
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.hidesWhenStopped = true
        return view
    }()

    private lazy var bottomBar: TopicDetailBottomBar = {
        let bar = TopicDetailBottomBar()
        bar.delegate = self
        return bar
    }()

    init(api: DiscourseAPI, topicId: Int, initialFloor: Int? = nil) {
        self.api = api
        self.topicId = topicId
        baseURL = api.baseURL
        viewModel = TopicDetailViewModel(api: api)
        self.initialFloor = initialFloor
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeManager.shared.cardBackgroundColor
        timelineLayout.delegate = self
        title = String(localized: "topic_detail.default_title")
        viewModel.isTreeMode = AppSettings.shared.topicTreeMode
        viewModel.treeSort = AppSettings.shared.topicTreeSort
        updateTreeModeControls()
        collectionView.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(handlePostLongPress(_:)))
        )

        view.addSubview(collectionView)
        view.addSubview(activityIndicator)
        view.addSubview(bottomBar)
        view.addSubview(floatingReplyButton)
        floatingReplyButton.addTarget(self, action: #selector(floatingReplyTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bottomBar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        collectionView.contentInset.bottom = 68
        updateTreeModeControls()

        NotificationCenter.default.addObserver(self, selector: #selector(renderEnvironmentChanged), name: ThemeManager.themeDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renderEnvironmentChanged), name: FontManager.fontDidChangeNotification, object: nil)
        Task { await initialLoad() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        readTracker.startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        readTracker.pause()
        cancelAllImagePrefetches()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateEnvironmentIfNeeded()
        if !floatingReplyButton.isHidden, view.bounds.width > 0 {
            if floatingReplyButtonPositioned {
                floatingReplyButton.reclampToParent()
            } else {
                floatingReplyButton.placeAtDefaultPosition()
                floatingReplyButtonPositioned = true
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // The active numeric height table is tiny and necessary for scroll
        // stability. Only discard reusable/off-screen measurements.
        heightPolicyCache.removeAll(keepingCapacity: true)
        cancelAllImagePrefetches()
    }

    override func applyThemeBackground() {
        let color = ThemeManager.shared.cardBackgroundColor
        view.backgroundColor = color
        collectionView.backgroundColor = color
    }

    private func initialLoad() async {
        let generation = nextTreeReloadGeneration()
        activityIndicator.startAnimating()
        if let initialFloor, initialFloor > 1, viewModel.isTreeMode {
            // A forced exit for a deep link is session-local. Preserve the
            // user's preferred default tree mode for the next topic.
            viewModel.isTreeMode = false
            updateTreeModeControls()
        }
        if viewModel.isTreeMode {
            await viewModel.loadNestedTopic(id: topicId, containerWidth: view.bounds.width)
        } else {
            await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width, nearPostNumber: initialFloor)
        }
        if let floor = initialFloor, floor > 1,
           !viewModel.posts.contains(where: { $0.postNumber == floor })
        {
            _ = await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
        }
        guard generation == treeReloadGeneration else { return }
        activityIndicator.stopAnimating()
        applySnapshot(reloadVisible: false)
        if let floor = initialFloor { scrollToFloor(floor, position: .top) }
        initialFloor = nil
    }

    override func updateUI() {
        if viewModel.isLoading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        if viewModel.isReady { applySnapshot(reloadVisible: false) }
    }

    /// Builds the complete height table before any matching snapshot is
    /// published. Common blocks use the calculator; rare Auto Layout-backed
    /// blocks are fitted once here, outside cell configuration and scrolling.
    private func prepareCurrentLayout() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let rootEnvironment = RenderEnvironment(
            contentWidth: width,
            displayScale: scale,
            fontRevision: FontManager.shared.revision,
            themeRevision: ThemeManager.shared.revision
        )

        let result = TopicRenderMetrics.measure("PrepareTopicHeights") { () -> ([RenderUnitID: RenderUnitHeightPolicy], [Int: CGFloat]) in
            var policies: [RenderUnitID: RenderUnitHeightPolicy] = [:]
            var boostHeights: [Int: CGFloat] = [:]

            for post in viewModel.visiblePosts {
                guard let document = viewModel.renderDocuments[post.id] else { continue }
                let depth = viewModel.isTreeMode ? (viewModel.postDepths[post.id] ?? 0) : 0
                let indent = PostNativeCell.treeContentIndent(forDepth: depth)
                let contentWidth = max(1, width - 24 - indent)
                let unitEnvironment = RenderEnvironment(
                    contentWidth: contentWidth,
                    displayScale: scale,
                    fontRevision: FontManager.shared.revision,
                    themeRevision: ThemeManager.shared.revision
                )
                let config = NativeRenderConfig.default(contentWidth: contentWidth, baseURL: baseURL)

                for unit in document.units {
                    let expandedRevision = expandedDetailsUnitIds.contains(unit.id) ? 1 : 0
                    let revision = (dynamicStateRevisions[unit.id, default: 0] &* 2) &+ expandedRevision
                    let key = RenderUnitHeightCacheKey(
                        unitId: unit.id,
                        environment: unitEnvironment,
                        dynamicStateRevision: revision
                    )
                    let policy: RenderUnitHeightPolicy
                    if let cached = heightPolicyCache[key] {
                        policy = cached
                    } else {
                        policy = preflightHeightPolicy(for: unit, post: post, config: config)
                        heightPolicyCache[key] = policy
                    }
                    policies[unit.id] = policy
                }

                if viewModel.expandedBoostPostIds.contains(post.id) {
                    boostHeights[post.id] = preflightBoostHeight(
                        post: post,
                        collectionWidth: width,
                        leadingIndent: indent
                    )
                }
            }
            return (policies, boostHeights)
        }

        preparedLayout = PreparedTopicLayout(environment: rootEnvironment, unitPolicies: result.0)
        resolvedBoostHeights = result.1
        if heightPolicyCache.count > 4_000 {
            let active = Set(result.0.keys)
            heightPolicyCache = heightPolicyCache.filter { active.contains($0.key.unitId) }
        }
    }

    private func preflightHeightPolicy(
        for unit: RenderUnit,
        post: DiscourseTopicDetail.Post,
        config: NativeRenderConfig
    ) -> RenderUnitHeightPolicy {
        if let measured = BlockHeightCalculator.height(for: unit.block, config: config) {
            let height = ceil(measured) + 8
            return blockNeedsDeferredHeight(unit.block) ? .deferred(height) : .fixed(height)
        }

        let measured = measureHostedUnit(unit, post: post, config: config)
        let height = max(1, ceil(measured) + 8)
        switch unit.block {
        case .details, .rawHTML:
            return .deferred(height)
        default:
            return .fixed(height)
        }
    }

    private func blockNeedsDeferredHeight(_ block: ContentBlock) -> Bool {
        switch block {
        case .image(_, _, let width, let height, _):
            return width == nil || height == nil || width == 0 || height == 0
        case .details, .rawHTML:
            return true
        default:
            return false
        }
    }

    private func measureHostedUnit(
        _ unit: RenderUnit,
        post: DiscourseTopicDetail.Post,
        config: NativeRenderConfig
    ) -> CGFloat {
        let annotated = AnnotatedBlock(block: unit.block, sourceHTML: unit.sourceHTML)
        let views = NativeContentRenderer.renderBlocks(
            [annotated],
            config: config,
            delegate: nil,
            pollProvider: { name in
                guard let poll = post.polls.first(where: { $0.name == name }) else { return nil }
                return (poll, Set(post.pollsVotes[name] ?? []), post)
            }
        )
        guard let hosted = views.first else { return 1 }
        if let details = findDetailsView(in: hosted) {
            details.setExpanded(expandedDetailsUnitIds.contains(unit.id))
        }
        if let poll = findPollView(in: hosted), let selections = pendingPollSelectionsByUnitId[unit.id] {
            poll.restorePendingSelections(selections)
        }
        return hosted.systemLayoutSizeFitting(
            CGSize(width: config.contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func preflightBoostHeight(
        post: DiscourseTopicDetail.Post,
        collectionWidth: CGFloat,
        leadingIndent: CGFloat
    ) -> CGFloat {
        let sizingCell = BoostCell(style: .default, reuseIdentifier: nil)
        sizingCell.configure(
            post: post,
            delegate: nil,
            assetBaseURL: api.assetBaseURL,
            contentWidth: max(1, collectionWidth - 24 - leadingIndent)
        )
        return max(1, ceil(sizingCell.systemLayoutSizeFitting(
            CGSize(width: max(1, collectionWidth - leadingIndent), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height))
    }

    private func findDetailsView(in view: UIView) -> DetailsCardView? {
        if let details = view as? DetailsCardView { return details }
        for subview in view.subviews {
            if let details = findDetailsView(in: subview) { return details }
        }
        return nil
    }

    private func findPollView(in view: UIView) -> PollView? {
        if let poll = view as? PollView { return poll }
        for subview in view.subviews {
            if let poll = findPollView(in: subview) { return poll }
        }
        return nil
    }

    private func invalidateHeightMeasurements(forPostId postId: Int) {
        heightPolicyCache = heightPolicyCache.filter { $0.key.unitId.postId != postId }
        resolvedHeights = resolvedHeights.filter { $0.key.postId != postId }
        pendingDynamicHeights.removeAll(forPostId: postId)
        if let unitIds = preparedLayout?.unitPolicies.keys {
            for id in unitIds where id.postId == postId {
                dynamicStateRevisions[id, default: 0] &+= 1
            }
        }
        preparedLayout = nil
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Int, VirtualTopicItem> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, VirtualTopicItem>()
        snapshot.appendSections([0])
        var items: [VirtualTopicItem] = []
        unitsById.removeAll(keepingCapacity: true)
        postIdByItem.removeAll(keepingCapacity: true)
        if let topic = viewModel.topic { items.append(.title(topic.id)) }

        let visible = viewModel.visiblePosts
        var loadsByAnchor: [Int: [PendingChildLoad]] = [:]
        for load in viewModel.pendingChildLoads.values {
            loadsByAnchor[load.anchorPostId, default: []].append(load)
        }
        for post in visible where viewModel.renderDocuments[post.id] != nil {
            if viewModel.isTreeMode, viewModel.collapsedPostIds.contains(post.id) {
                let item = VirtualTopicItem.collapsed(post.id)
                items.append(item)
                postIdByItem[item] = post.id
            } else if let document = viewModel.renderDocuments[post.id] {
                let header = VirtualTopicItem.header(post.id)
                items.append(header)
                postIdByItem[header] = post.id
                for unit in document.units {
                    unitsById[unit.id] = unit
                    let item = VirtualTopicItem.unit(unit.id)
                    items.append(item)
                    postIdByItem[item] = post.id
                }
                let footer = VirtualTopicItem.footer(post.id)
                items.append(footer)
                postIdByItem[footer] = post.id
                if viewModel.expandedBoostPostIds.contains(post.id) {
                    let boost = VirtualTopicItem.boosts(post.id)
                    items.append(boost)
                    postIdByItem[boost] = post.id
                }
            }
            for load in loadsByAnchor[post.id] ?? [] {
                let item = VirtualTopicItem.loadMoreChildren(load.parentPostId)
                items.append(item)
            }
        }
        snapshot.appendItems(items)
        return snapshot
    }

    private func applySnapshot(reloadVisible: Bool, preserving anchor: (VirtualTopicItem, CGFloat)? = nil) {
        let isMoving = collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        if isApplyingSnapshot || isMoving {
            hasPendingSnapshot = true
            pendingSnapshotReloadVisible = pendingSnapshotReloadVisible || reloadVisible
            // A caller may have captured its anchor before an async network
            // request. While the user is still moving, use the live anchor at
            // flush time instead of restoring that stale screen position.
            if isMoving { pendingSnapshotAnchor = nil }
            else if pendingSnapshotAnchor == nil { pendingSnapshotAnchor = anchor }
            return
        }
        prepareCurrentLayout()
        let snapshot = makeSnapshot()
        let current = dataSource.snapshot()
        guard snapshot.itemIdentifiers != current.itemIdentifiers || reloadVisible else {
            commitPendingDynamicHeights()
            return
        }
        isApplyingSnapshot = true
        var applied = snapshot
        if reloadVisible {
            let existing = Set(current.itemIdentifiers)
            let reloadable = applied.itemIdentifiers.filter(existing.contains)
            if !reloadable.isEmpty { applied.reloadItems(reloadable) }
        }
        timelineLayout.reloadAllHeights()
        dataSource.apply(applied, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.isApplyingSnapshot = false
            self.collectionView.layoutIfNeeded()
            if let anchor, let indexPath = self.dataSource.indexPath(for: anchor.0),
               let attributes = self.collectionView.layoutAttributesForItem(at: indexPath)
            {
                self.collectionView.contentOffset.y = attributes.frame.minY - anchor.1
            }
            if !self.flushPendingSnapshotIfNeeded() {
                self.commitPendingDynamicHeights()
            }
        }
    }

    @discardableResult
    private func flushPendingSnapshotIfNeeded() -> Bool {
        guard hasPendingSnapshot,
              !isApplyingSnapshot,
              !collectionView.isTracking,
              !collectionView.isDragging,
              !collectionView.isDecelerating
        else { return false }
        let reloadVisible = pendingSnapshotReloadVisible
        let anchor = pendingSnapshotAnchor ?? captureAnchor()
        hasPendingSnapshot = false
        pendingSnapshotReloadVisible = false
        pendingSnapshotAnchor = nil
        applySnapshot(reloadVisible: reloadVisible, preserving: anchor)
        return true
    }

    private func captureAnchor() -> (VirtualTopicItem, CGFloat)? {
        guard let indexPath = collectionView.indexPathsForVisibleItems.sorted().first,
              let item = dataSource.itemIdentifier(for: indexPath),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        else { return nil }
        return (item, attributes.frame.minY - collectionView.contentOffset.y)
    }

    private func scrollToFloor(_ floor: Int, position: UICollectionView.ScrollPosition) {
        guard let post = viewModel.posts.first(where: { $0.postNumber == floor }),
              let indexPath = dataSource.indexPath(for: .header(post.id))
                ?? dataSource.indexPath(for: .collapsed(post.id))
        else { return }
        collectionView.scrollToItem(at: indexPath, at: position, animated: false)
    }

    private func updateEnvironmentIfNeeded() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let backgroundColor = ThemeManager.shared.cardBackgroundColor
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
        let environment = RenderEnvironment(
            contentWidth: width,
            displayScale: view.window?.screen.scale ?? UIScreen.main.scale,
            fontRevision: FontManager.shared.revision,
            themeRevision: ThemeManager.shared.revision
        )
        guard environment != lastEnvironment else { return }
        lastEnvironment = environment
        preparedLayout = nil
        heightPolicyCache.removeAll(keepingCapacity: true)
        resolvedHeights.removeAll(keepingCapacity: true)
        resolvedBoostHeights.removeAll(keepingCapacity: true)
        pendingDynamicHeights.removeAll(keepingCapacity: true)
        timelineLayout.reloadAllHeights()
        applySnapshot(reloadVisible: true, preserving: captureAnchor())
    }

    @objc private func renderEnvironmentChanged() { updateEnvironmentIfNeeded() }

    @objc private func handlePostLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
              let postId = dataSource.itemIdentifier(for: indexPath)?.longPressPostId,
              let post = viewModel.postsById[postId]
        else { return }
        postCell(didLongPressPost: post)
    }

    private func nextTreeReloadGeneration() -> UInt {
        treeReloadGeneration &+= 1
        return treeReloadGeneration
    }

    private func treeModeBarButtonItem() -> UIBarButtonItem {
        let symbol = UIImage(systemName: viewModel.isTreeMode ? "list.bullet.indent" : "list.bullet")
        if viewModel.isTreeMode {
            let button = UIButton(type: .system)
            button.setImage(symbol, for: .normal)
            button.addTarget(self, action: #selector(toggleTreeMode), for: .touchUpInside)
            button.menu = treeSortMenu()
            button.showsMenuAsPrimaryAction = false
            button.accessibilityLabel = String(localized: "topic_detail.tree_mode")
            return UIBarButtonItem(customView: button)
        }
        let item = UIBarButtonItem(image: symbol, style: .plain, target: self, action: #selector(toggleTreeMode))
        item.accessibilityLabel = String(localized: "topic_detail.tree_mode")
        return item
    }

    private func treeSortMenu() -> UIMenu {
        let options: [(String, String, String)] = [
            ("top", String(localized: "topic_detail.tree_sort.top"), "flame"),
            ("new", String(localized: "topic_detail.tree_sort.new"), "clock"),
            ("old", String(localized: "topic_detail.tree_sort.old"), "clock.arrow.circlepath"),
        ]
        let actions = options.map { value, title, symbol in
            UIAction(
                title: title,
                image: UIImage(systemName: symbol),
                state: viewModel.treeSort == value ? .on : .off
            ) { [weak self] _ in
                self?.applyTreeSort(value)
            }
        }
        return UIMenu(title: String(localized: "topic_detail.tree_sort.title"), children: actions)
    }

    private func updateTreeModeControls() {
        navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        let isTreeMode = viewModel.isTreeMode
        bottomBar.hidesFloorControls = isTreeMode
        bottomBar.isHidden = isTreeMode
        floatingReplyButton.isHidden = !isTreeMode
        if isTreeMode, floatingReplyButton.superview != nil {
            view.bringSubviewToFront(floatingReplyButton)
            view.setNeedsLayout()
        }
    }

    private func applyTreeSort(_ sort: String) {
        guard viewModel.isTreeMode, viewModel.treeSort != sort else { return }
        viewModel.treeSort = sort
        AppSettings.shared.topicTreeSort = sort
        navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        let generation = nextTreeReloadGeneration()
        let anchor = captureAnchor()
        Task {
            await viewModel.loadNestedTopic(id: topicId, sort: sort, containerWidth: view.bounds.width)
            guard generation == treeReloadGeneration, viewModel.isTreeMode else { return }
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            applySnapshot(reloadVisible: true, preserving: anchor)
            navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        }
    }

    @objc private func toggleTreeMode() {
        viewModel.isTreeMode.toggle()
        AppSettings.shared.topicTreeMode = viewModel.isTreeMode
        updateTreeModeControls()
        let generation = nextTreeReloadGeneration()
        let anchor = captureAnchor()
        Task {
            if viewModel.isTreeMode {
                await viewModel.loadNestedTopic(id: topicId, containerWidth: view.bounds.width)
            } else {
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
            }
            guard generation == treeReloadGeneration else { return }
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            applySnapshot(reloadVisible: true, preserving: anchor)
        }
    }

    @objc private func floatingReplyTapped() {
        presentReplyComposer(for: nil)
    }

    private func moreMenu(for post: DiscourseTopicDetail.Post) -> UIMenu {
        var actions: [UIAction] = [
            UIAction(title: String(localized: "post.copy_link"), image: UIImage(systemName: "link")) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = "\(self.baseURL)/t/\(self.topicId)/\(post.postNumber)"
            },
            UIAction(
                title: post.bookmarked ? String(localized: "post.remove_bookmark") : String(localized: "post.bookmark"),
                image: UIImage(systemName: post.bookmarked ? "bookmark.fill" : "bookmark")
            ) { [weak self] _ in
                self?.postCell(didToggleBookmarkForPost: post, isBookmarked: !post.bookmarked)
            },
        ]
        if post.canFlag {
            actions.append(UIAction(title: String(localized: "post.flag"), image: UIImage(systemName: "flag"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                self.postCell(didTapFlagPost: post, sourceView: self.view)
            })
        }
        return UIMenu(children: actions)
    }
}

extension VirtualizedTopicDetailViewController: TopicTimelineLayoutDelegate {
    func topicTimelineLayout(_ layout: TopicTimelineLayout, heightForItemAt indexPath: IndexPath, width: CGFloat) -> CGFloat {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return 1 }
        switch item {
        case .title:
            let title = viewModel.topic?.fancyTitle ?? viewModel.topic?.title ?? ""
            let font = FontManager.shared.font(size: 20, weight: .bold)
            let rect = (title as NSString).boundingRect(
                with: CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil
            )
            return ceil(rect.height) + 24
        case .header: return 56
        case .footer: return 50
        case .collapsed: return PostCollapsedCell.cellHeight
        case .loadMoreChildren: return LoadMoreChildrenCell.cellHeight
        case .boosts(let postId): return resolvedBoostHeights[postId] ?? 44
        case .unit(let id):
            if let resolved = resolvedHeights[id] { return resolved }
            return preparedLayout?.policy(for: id)?.height ?? 1
        }
    }
}

extension VirtualizedTopicDetailViewController: RenderUnitSizeInvalidating {
    func renderUnitCell(_ cell: VirtualPostBlockCell, didResolveHeight height: CGFloat, for unitId: RenderUnitID) {
        guard preparedLayout?.policy(for: unitId)?.acceptsDynamicUpdates == true,
              height.isFinite, height > 0,
              abs((resolvedHeights[unitId] ?? preparedLayout?.policy(for: unitId)?.height ?? 0) - height) > 1
        else { return }
        pendingDynamicHeights.enqueue(height: height, for: unitId)
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        commitPendingDynamicHeights()
    }

    private func commitPendingDynamicHeights() {
        guard !pendingDynamicHeights.isEmpty else { return }
        let pending = pendingDynamicHeights.drain()
        let anchor = captureAnchor()
        var updates: [IndexPath: CGFloat] = [:]
        for (unitId, height) in pending {
            guard preparedLayout?.policy(for: unitId)?.acceptsDynamicUpdates == true,
                  let indexPath = dataSource.indexPath(for: .unit(unitId))
            else { continue }
            resolvedHeights[unitId] = height
            updates[indexPath] = height
        }
        guard !updates.isEmpty else { return }

        TopicRenderMetrics.measure("CommitDynamicHeights") {
            timelineLayout.applyHeightUpdates(updates)
            collectionView.layoutIfNeeded()
        }
        if let anchor, let indexPath = dataSource.indexPath(for: anchor.0),
           let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        {
            collectionView.contentOffset.y = attributes.frame.minY - anchor.1
        }
    }
}

extension VirtualizedTopicDetailViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if let postId = postIdByItem[item], let post = viewModel.postsById[postId] {
            let count = visibleItemCountsByPost[postId, default: 0]
            visibleItemCountsByPost[postId] = count + 1
            if count == 0 { readTracker.recordVisible(postNumber: post.postNumber) }
        }
        guard indexPath.item >= collectionView.numberOfItems(inSection: 0) - 3, !isLoadingPage else { return }
        isLoadingPage = true
        Task {
            let anchor = captureAnchor()
            if viewModel.isTreeMode {
                _ = await viewModel.loadMoreNestedRoots()
            } else if viewModel.isReverseOrder {
                _ = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
            } else {
                _ = await viewModel.loadMorePosts(containerWidth: view.bounds.width)
            }
            applySnapshot(reloadVisible: false, preserving: anchor)
            isLoadingPage = false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), let postId = postIdByItem[item] else { return }
        let next = max(0, visibleItemCountsByPost[postId, default: 1] - 1)
        visibleItemCountsByPost[postId] = next
        if next == 0, let post = viewModel.postsById[postId] {
            readTracker.recordHidden(postNumber: post.postNumber)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { loadEarlierArmed = true }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate, !flushPendingSnapshotIfNeeded() { commitPendingDynamicHeights() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if !flushPendingSnapshotIfNeeded() { commitPendingDynamicHeights() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if !flushPendingSnapshotIfNeeded() { commitPendingDynamicHeights() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard loadEarlierArmed, !isLoadingPage, viewModel.canLoadEarlier, !viewModel.isReverseOrder,
              scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 180
        else { return }
        loadEarlierArmed = false
        isLoadingPage = true
        let anchor = captureAnchor()
        Task {
            _ = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
            applySnapshot(reloadVisible: false, preserving: anchor)
            isLoadingPage = false
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  imagePrefetchTokens[item] == nil,
                  case .unit(let id) = item,
                  let unit = unitsById[id]
            else { continue }
            let annotated = AnnotatedBlock(block: unit.block, sourceHTML: unit.sourceHTML)
            let urls = ImageURLCollector.collectImageURLs(from: [annotated]).compactMap(URL.init(string:))
            guard !urls.isEmpty else { continue }
            if let token = SDWebImagePrefetcher.shared.prefetchURLs(urls) {
                imagePrefetchTokens[item] = token
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for item in indexPaths.compactMap({ dataSource.itemIdentifier(for: $0) }) {
            imagePrefetchTokens.removeValue(forKey: item)?.cancel()
        }
    }

    private func cancelAllImagePrefetches() {
        for token in imagePrefetchTokens.values { token.cancel() }
        imagePrefetchTokens.removeAll(keepingCapacity: true)
    }
}

private extension VirtualizedTopicDetailViewController {
    func handleLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        guard let baseHost = URL(string: baseURL)?.host,
              url.host?.caseInsensitiveCompare(baseHost) == .orderedSame
        else {
            present(SFSafariViewController(url: url), animated: true)
            return
        }

        if let linkedTopicId = topicId(from: url) {
            navigationController?.pushViewController(
                TopicDetailControllerFactory.make(api: api, topicId: linkedTopicId),
                animated: true
            )
        } else if let (slug, id) = categoryInfo(from: url) {
            let category = DiscourseCategory(id: id, name: slug, slug: slug)
            navigationController?.pushViewController(
                CategoryTopicsViewController(api: api, category: category),
                animated: true
            )
        } else if let tag = tagInfo(from: url) {
            navigationController?.pushViewController(TagTopicsViewController(api: api, tag: tag), animated: true)
        } else if let username = username(from: url) {
            navigationController?.pushViewController(
                UserProfileViewController(api: api, username: username),
                animated: true
            )
        } else {
            present(SFSafariViewController(url: url), animated: true)
        }
    }

    func topicId(from url: URL) -> Int? {
        guard let index = url.pathComponents.firstIndex(of: "t") else { return nil }
        return url.pathComponents.dropFirst(index + 1).compactMap(Int.init).first
    }

    func categoryInfo(from url: URL) -> (String, Int)? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "c"), index + 2 < components.count else { return nil }
        let remaining = Array(components[(index + 1)...])
        for candidate in remaining.indices.reversed() {
            let cleaned = remaining[candidate].replacingOccurrences(of: ".json", with: "")
            if let id = Int(cleaned), candidate > 0 { return (remaining[candidate - 1], id) }
        }
        return nil
    }

    func tagInfo(from url: URL) -> DiscourseTopicDetail.Tag? {
        let components = url.pathComponents
        guard let index = components.firstIndex(where: { $0 == "tag" || $0 == "tags" }),
              index + 2 < components.count,
              let id = Int(components[index + 2])
        else { return nil }
        let name = components[index + 1]
        return DiscourseTopicDetail.Tag(id: id, name: name, slug: name)
    }

    func username(from url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "u"), index + 1 < components.count else { return nil }
        return components[index + 1]
    }
}

extension VirtualizedTopicDetailViewController: TopicDetailBottomBarDelegate {
    var bottomBarIsReverseOrder: Bool { viewModel.isReverseOrder }
    var bottomBarIsSummaryMode: Bool { viewModel.isSummaryMode }

    func bottomBarDidTapOPOnly() {
        viewModel.isFilteringByOP.toggle()
        applySnapshot(reloadVisible: false)
    }

    func bottomBarDidTapJumpToFloor() {
        let sheet = JumpToFloorSheetViewController(
            totalFloors: viewModel.totalFloors,
            currentFloor: currentVisibleFloor(),
            firstUnreadFloor: viewModel.topic?.lastReadPostNumber.map { $0 + 1 },
            isReverseOrder: viewModel.isReverseOrder,
            isSummaryMode: viewModel.isSummaryMode
        )
        sheet.onJump = { [weak self] in self?.performJump(to: $0) }
        sheet.onToggleReverseOrder = { [weak self] in self?.bottomBarDidToggleReverseOrder() }
        sheet.onToggleSummaryMode = { [weak self] in self?.bottomBarDidToggleSummaryMode() }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    func bottomBarDidToggleReverseOrder() {
        Task {
            if viewModel.isReverseOrder {
                viewModel.disableReverseOrder()
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
            } else {
                await viewModel.enableReverseOrder(containerWidth: view.bounds.width)
            }
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            applySnapshot(reloadVisible: false)
        }
    }

    func bottomBarDidToggleSummaryMode() {
        Task {
            await viewModel.toggleSummaryMode(containerWidth: view.bounds.width)
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            applySnapshot(reloadVisible: false)
        }
    }

    func bottomBarDidTapReply() { presentReplyComposer(for: nil) }
    func bottomBarDidBeginScrubFromJump(at locationInWindow: CGPoint, buttonFrame: CGRect) {
        let total = viewModel.totalFloors
        guard total > 1, jumpScrubber == nil else { return }
        let startingFloor = currentVisibleFloor()
        jumpScrubStartLocation = view.convert(locationInWindow, from: nil)
        jumpScrubHasMoved = false
        jumpScrubStartFloor = startingFloor

        let safeMargin: CGFloat = 60
        let leftSpace = max(jumpScrubStartLocation.x - safeMargin, 1)
        let rightSpace = max(view.bounds.width - jumpScrubStartLocation.x - safeMargin, 1)
        jumpScrubReferenceDistance = min(leftSpace, rightSpace)

        let barTop = bottomBar.convert(bottomBar.bounds, to: view).minY
        let overlay = JumpScrubberOverlay(
            totalFloors: total,
            startingFloor: startingFloor,
            arcCenter: CGPoint(x: view.bounds.midX, y: barTop - 24),
            radius: 130
        )
        overlay.frame = view.bounds
        view.addSubview(overlay)
        overlay.presentTransitionIn()
        jumpScrubber = overlay
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    func bottomBarDidUpdateScrub(at locationInWindow: CGPoint) {
        guard let overlay = jumpScrubber else { return }
        let location = view.convert(locationInWindow, from: nil)
        if !jumpScrubHasMoved {
            let distance = hypot(
                location.x - jumpScrubStartLocation.x,
                location.y - jumpScrubStartLocation.y
            )
            guard distance >= jumpScrubMoveThreshold else { return }
            jumpScrubHasMoved = true
        }
        let dx = location.x - jumpScrubStartLocation.x
        let normalized = min(abs(dx) / jumpScrubReferenceDistance, 1)
        let delta = Int((pow(normalized, 1.8) * CGFloat(viewModel.totalFloors - 1)).rounded())
        let signedDelta = dx >= 0 ? delta : -delta
        overlay.update(floor: max(1, min(viewModel.totalFloors, jumpScrubStartFloor + signedDelta)))
    }

    func bottomBarDidEndScrub(cancelled: Bool) {
        guard let overlay = jumpScrubber else { return }
        jumpScrubber = nil
        overlay.presentTransitionOut()
        guard !cancelled, jumpScrubHasMoved else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        performJump(to: overlay.currentFloor)
    }

    private func currentVisibleFloor() -> Int {
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            if let item = dataSource.itemIdentifier(for: indexPath),
               let id = postIdByItem[item], let post = viewModel.postsById[id]
            { return post.postNumber }
        }
        return 1
    }

    private func performJump(to floor: Int) {
        guard floor >= 1 else { return }
        if viewModel.isTreeMode {
            viewModel.isTreeMode = false
            updateTreeModeControls()
            let generation = nextTreeReloadGeneration()
            Task {
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
                if !viewModel.isFloorLoaded(floor) {
                    _ = await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
                }
                guard generation == treeReloadGeneration, !viewModel.isTreeMode else { return }
                resolvedHeights.removeAll()
                resolvedBoostHeights.removeAll()
                applySnapshot(reloadVisible: false)
                collectionView.layoutIfNeeded()
                scrollToFloor(floor, position: .top)
            }
            return
        }
        if viewModel.posts.contains(where: { $0.postNumber == floor }) {
            scrollToFloor(floor, position: .top)
            return
        }
        Task {
            _ = await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            applySnapshot(reloadVisible: false)
            collectionView.layoutIfNeeded()
            scrollToFloor(floor, position: .top)
        }
    }
}

extension VirtualizedTopicDetailViewController: PostCellDelegate {
    func postCell(didTapImageURL url: URL, inPostId postId: Int) {
        let request = TopicImageBrowserRequest.make(
            annotatedBlocks: viewModel.renderDocuments[postId]?.annotatedBlocks ?? [],
            tappedURL: url
        )
        let images = request.imageURLs.map { LightboxImage(imageURL: $0) }
        guard !images.isEmpty else { return }
        let controller = ImageBrowserController(images: images, startIndex: request.startIndex)
        controller.dynamicBackground = true

        if let source = TappableImageContainer.lastTapped {
            imageZoomTransition.sourceImageView = source.displayedImageView
            imageZoomTransition.sourceContainer = source
            controller.modalPresentationStyle = .custom
            controller.transitioningDelegate = imageZoomTransition
        } else {
            controller.modalPresentationStyle = .fullScreen
        }
        present(controller, animated: true)
    }

    func postCell(didTapLinkURL url: URL) {
        handleLink(url)
    }

    func postCell(didTapShowRepliesForPostId postId: Int) {
        let controller = RepliesViewController(api: api, postId: postId, topicId: topicId, validReactions: viewModel.topic?.validReactions ?? [])
        if let sheet = controller.sheetPresentationController { sheet.detents = [.medium(), .large()] }
        present(controller, animated: true)
    }

    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int) {}
    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) { presentReplyComposer(for: post) }

    func postCell(didTapReplyReferenceForPost post: DiscourseTopicDetail.Post) {
        guard let number = post.replyToPostNumber else { return }
        Task {
            let parent: DiscourseTopicDetail.Post
            if let loaded = viewModel.posts.first(where: { $0.postNumber == number }) {
                parent = loaded
            } else if let fetched = try? await api.fetchPostByNumber(topicId: topicId, postNumber: number) {
                parent = fetched
            } else { return }
            let preview = ReplyPreviewViewController(api: api, post: parent, topicId: topicId, validReactions: viewModel.topic?.validReactions ?? [], floorNumber: parent.postNumber)
            present(UINavigationController(rootViewController: preview), animated: true)
        }
    }

    func postCell(didToggleCollapseForPostId postId: Int) {
        let anchor = captureAnchor()
        viewModel.toggleCollapse(postId: postId)
        applySnapshot(reloadVisible: true, preserving: anchor)
    }

    func postCell(didTapLoadMoreChildrenForParentId parentPostId: Int) {
        Task {
            let anchor = captureAnchor()
            _ = await viewModel.loadMoreChildren(forParentId: parentPostId)
            applySnapshot(reloadVisible: true, preserving: anchor)
        }
    }

    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool) {
        Task {
            if isBookmarked { _ = try? await api.createBookmark(postId: post.id) }
            else if let id = post.bookmarkId { try? await api.deleteBookmark(id: id) }
        }
    }

    func postCell(didTapAvatarForUsername username: String) {
        navigationController?.pushViewController(UserProfileViewController(api: api, username: username), animated: true)
    }

    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post) {
        Task {
            try? await api.toggleReaction(postId: post.id, reactionId: reactionId)
            if let fresh = try? await api.fetchPost(id: post.id) { await viewModel.replacePost(fresh) }
            applySnapshot(reloadVisible: true)
        }
    }

    func postCell(didToggleLikeForPost post: DiscourseTopicDetail.Post, liked: Bool) {
        Task {
            if liked { try? await api.likePost(postId: post.id) } else { try? await api.unlikePost(postId: post.id) }
            if let fresh = try? await api.fetchPost(id: post.id) { await viewModel.replacePost(fresh) }
            applySnapshot(reloadVisible: true)
        }
    }

    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post) {
        let alert = UIAlertController(title: String(localized: "reply.title.to \(post.username)"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = String(localized: "reply.placeholder") }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "reply.send"), style: .default) { [weak self, weak alert] _ in
            guard let self, let raw = alert?.textFields?.first?.text, !raw.isEmpty else { return }
            Task {
                if let boost = try? await self.api.createBoost(postId: post.id, raw: raw) {
                    self.viewModel.appendBoost(boost, toPostId: post.id)
                    self.applySnapshot(reloadVisible: true)
                }
            }
        })
        present(alert, animated: true)
    }

    func postCell(didTapDeleteBoost boost: DiscourseTopicDetail.Boost) {
        Task { try? await api.deleteBoost(id: boost.id); applySnapshot(reloadVisible: true) }
    }

    func postCell(didTapToggleBoostsForPost post: DiscourseTopicDetail.Post, sourceView: UIView) {
        viewModel.toggleBoosts(forPostId: post.id)
        applySnapshot(reloadVisible: false, preserving: captureAnchor())
    }

    func postCell(didVotePoll pollName: String, options: [String], forPost post: DiscourseTopicDetail.Post) {
        Task {
            if let response = try? await api.votePoll(postId: post.id, pollName: pollName, options: options) {
                await viewModel.updatePoll(response.poll, votes: response.vote ?? options, forPostId: post.id, pollName: pollName)
                invalidateHeightMeasurements(forPostId: post.id)
                applySnapshot(reloadVisible: true)
            }
        }
    }

    func postCell(didRemovePollVote pollName: String, forPost post: DiscourseTopicDetail.Post) {
        Task {
            if let response = try? await api.removePollVote(postId: post.id, pollName: pollName) {
                await viewModel.updatePoll(response.poll, votes: response.vote ?? [], forPostId: post.id, pollName: pollName)
                invalidateHeightMeasurements(forPostId: post.id)
                applySnapshot(reloadVisible: true)
            }
        }
    }

    func postCell(didTapFlagPost post: DiscourseTopicDetail.Post, sourceView: UIView) {
        let alert = UIAlertController(title: String(localized: "post.flag"), message: String(localized: "post.flag.message"), preferredStyle: .actionSheet)
        for (title, type) in [(String(localized: "post.flag.off_topic"), 3), (String(localized: "post.flag.inappropriate"), 4), (String(localized: "post.flag.spam"), 8)] {
            alert.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
                guard let self else { return }
                Task { try? await self.api.flagPost(postId: post.id, flagTypeId: type) }
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController { popover.sourceView = sourceView; popover.sourceRect = sourceView.bounds }
        present(alert, animated: true)
    }

    func postCell(didLongPressPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                let detail = try await api.fetchPost(id: post.id)
                guard let raw = detail.raw, !raw.isEmpty else { return }
                let rawController = RawContentViewController(
                    raw: raw,
                    username: post.username,
                    floorNumber: post.postNumber
                )
                let navigationController = UINavigationController(rootViewController: rawController)
                if let sheet = navigationController.sheetPresentationController {
                    sheet.detents = [.medium(), .large()]
                    sheet.prefersGrabberVisible = true
                }
                present(navigationController, animated: true)
            } catch {
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func presentReplyComposer(for post: DiscourseTopicDetail.Post?) {
        let composer = ReplyComposerViewController(api: api, topicId: topicId, replyToPost: post, baseURL: baseURL)
        composer.onPostCreated = { [weak self] _, floor in
            guard let self else { return }
            Task {
                await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width, nearPostNumber: floor)
                self.applySnapshot(reloadVisible: false)
                self.collectionView.layoutIfNeeded()
                self.scrollToFloor(floor, position: .bottom)
            }
        }
        present(UINavigationController(rootViewController: composer), animated: true)
    }
}
