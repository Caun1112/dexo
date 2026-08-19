import UIKit

final class HomeViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: HomeViewModel
    private weak var authGate: AuthGating?
    private var locallyReadTopicIDs: Set<Int> = []

    private static let linuxDoDefaultCategoryNames = ["前沿快讯", "积分乐园", "跳蚤市场"]

    /// Right bar button items injected by the container (e.g. minimize button), captured before we add our own.
    private var inheritedRightBarItems: [UIBarButtonItem] = []

    private let categoryButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "home.filter.all_categories")
        config.image = UIImage(systemName: "line.3.horizontal.decrease", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = FontManager.shared.font(size: 15, weight: .medium)
            return a
        }
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        tv.delegate = self
        tv.showsVerticalScrollIndicator = false

        return tv
    }()

    private let pinnedBar = PinnedTopicBar()

    private let emptyHeaderPlaceholder = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

    /// Cache hex→UIColor conversions to avoid repeated string parsing.
    private var categoryColorCache: [String: UIColor] = [:]

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = .init(tableView: tableView) { [weak self] tableView, indexPath, topicId in
        guard let self,
              let topic = self.viewModel.topicsById[topicId]
        else {
            return UITableViewCell()
        }
        let category = self.viewModel.category(for: topic)
        let categoryColor: UIColor? = category.flatMap { cat in
            let hex = cat.color
            if let cached = self.categoryColorCache[hex] { return cached }
            let color = Self.color(fromHex: hex)
            if let color { self.categoryColorCache[hex] = color }
            return color
        }

        guard let cell = tableView.dequeueReusableCell(withIdentifier: TopicCell.reuseIdentifier, for: indexPath) as? TopicCell else {
            return UITableViewCell()
        }
        let assetBaseURL = self.api.assetBaseURL
        var avatarURL: URL?
        if let template = self.viewModel.avatarTemplate(for: topic) {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            let urlString = sized.hasPrefix("http") ? sized : assetBaseURL + sized
            avatarURL = URL(string: urlString)
        }
        cell.configure(
            with: topic,
            avatarURL: avatarURL,
            categoryName: category?.name,
            categoryColor: categoryColor,
            timestampKind: self.viewModel.feedMode.timestampKind,
            isLocallyRead: self.locallyReadTopicIDs.contains(topic.id)
        )
        return cell
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private let loginButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "home.login_prompt")
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private let composeButtonSize: CGFloat = 56
    private let composeButtonEdgeMargin: CGFloat = 20
    private var composeDragDistance: CGFloat = 0

    /// Thumb-reachable twin of the nav-bar category filter. The nav bar sits in
    /// the top-left corner, which one-handed right-thumb users can't reach on a
    /// large phone, so the same menu is mirrored just above the compose FAB.
    private let categoryFloatingButtonSize: CGFloat = 46
    /// Gap between the compose FAB and the filter button stacked above it.
    private let categoryFloatingButtonSpacing: CGFloat = 12
    private let sortFloatingBarHeight: CGFloat = 44
    private let sortFloatingBarSpacing: CGFloat = 8
    private let sortFloatingBarWidth: CGFloat = 176

    private lazy var categoryFloatingButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        button.setImage(
            UIImage(systemName: "line.3.horizontal.decrease", withConfiguration: config),
            for: .normal
        )
        button.backgroundColor = ThemeManager.shared.cardBackgroundColor
        button.tintColor = ThemeManager.shared.accentColor
        button.layer.cornerRadius = categoryFloatingButtonSize / 2
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.2
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowRadius = 4
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "home.filter.accessibility.label")
        button.accessibilityHint = String(localized: "home.filter.accessibility.hint")
        return button
    }()

    private lazy var sortFloatingItems: [(mode: TopicFeedMode, button: UIButton)] = [
        (.activity, makeSortFloatingButton(
            mode: .activity,
            title: String(localized: "home.activity"),
            symbol: "clock.arrow.circlepath"
        )),
        (.created, makeSortFloatingButton(
            mode: .created,
            title: String(localized: "home.created"),
            symbol: "calendar"
        )),
        (.hot, makeSortFloatingButton(
            mode: .hot,
            title: String(localized: "home.hot"),
            symbol: "flame"
        )),
        (.top, makeSortFloatingButton(
            mode: .top,
            title: String(localized: "home.top"),
            symbol: "chart.bar"
        )),
    ]

    private lazy var sortFloatingBar: UIView = {
        let bar = UIView()
        bar.layer.cornerRadius = sortFloatingBarHeight / 2
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.2
        bar.layer.shadowOffset = CGSize(width: 0, height: 2)
        bar.layer.shadowRadius = 4
        bar.isAccessibilityElement = false

        let stack = UIStackView(arrangedSubviews: sortFloatingItems.map(\.button))
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }()

    private lazy var composeButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        button.setImage(UIImage(systemName: "plus", withConfiguration: config), for: .normal)
        button.backgroundColor = ThemeManager.shared.accentColor
        button.tintColor = .white
        button.layer.cornerRadius = 28
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.25
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowRadius = 4
        button.addTarget(self, action: #selector(composeButtonTouchDown), for: .touchDown)
        button.addTarget(self, action: #selector(composeTapped), for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleComposePan(_:)))
        button.addGestureRecognizer(pan)

        return button
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = HomeViewModel(api: api)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var hasPlacedComposeButton = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if !hasPlacedComposeButton {
            hasPlacedComposeButton = true
            let safe = view.safeAreaLayoutGuide.layoutFrame
            composeButton.center = CGPoint(
                x: safe.maxX - composeButtonEdgeMargin - composeButtonSize / 2,
                y: safe.maxY - composeButtonEdgeMargin - composeButtonSize / 2
            )
        }
        syncCategoryFloatingButtonPosition()

        if tableView.tableHeaderView === pinnedBar,
           pinnedBar.frame.width != tableView.bounds.width {
            pinnedBar.frame.size.width = tableView.bounds.width
            tableView.tableHeaderView = pinnedBar
        }
    }

    private func installPinnedHeader(items: [PinnedTopicBar.Item]) {
        pinnedBar.setItems(items)
        if items.isEmpty {
            if tableView.tableHeaderView !== emptyHeaderPlaceholder {
                tableView.tableHeaderView = emptyHeaderPlaceholder
            }
        } else {
            pinnedBar.frame = CGRect(
                x: 0,
                y: 0,
                width: tableView.bounds.width,
                height: PinnedTopicBar.height
            )
            if tableView.tableHeaderView !== pinnedBar {
                tableView.tableHeaderView = pinnedBar
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.tableFooterView = footerSpinner
        tableView.refreshControl = refreshControl

        tableView.tableHeaderView = emptyHeaderPlaceholder
        pinnedBar.onSelect = { [weak self] topicId in
            guard let self else { return }
            let detailVC = TopicDetailControllerFactory.make(api: self.api, topicId: topicId)
            self.navigationController?.pushViewController(detailVC, animated: true)
        }
        view.addSubview(tableView)

        view.addSubview(activityIndicator)
        view.addSubview(errorLabel)
        view.addSubview(loginButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            loginButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loginButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 16),
        ])

        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(authDidChange(_:)),
            name: .discourseAuthDidChange,
            object: nil
        )

        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: categoryButton)
        inheritedRightBarItems = navigationItem.rightBarButtonItems ?? []
        navigationItem.rightBarButtonItems = inheritedRightBarItems

        view.addSubview(composeButton)
        composeButton.frame = CGRect(x: 0, y: 0, width: composeButtonSize, height: composeButtonSize)
        view.addSubview(categoryFloatingButton)
        categoryFloatingButton.frame = CGRect(
            x: 0,
            y: 0,
            width: categoryFloatingButtonSize,
            height: categoryFloatingButtonSize
        )
        view.addSubview(sortFloatingBar)
        sortFloatingBar.frame = CGRect(
            x: 0,
            y: 0,
            width: sortFloatingBarWidth,
            height: sortFloatingBarHeight
        )

        Task {
            await viewModel.loadTopics()
        }
        Task {
            await api.loadOrFetchEmojiMap()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadLocalReadState()
    }

    private func reloadLocalReadState() {
        let ids: Set<Int>
        if let scope = ReadHistoryScope.current(api: api) {
            ids = (try? LocalReadHistoryStore.shared.topicIDs(scope: scope)) ?? []
        } else {
            ids = []
        }
        guard ids != locallyReadTopicIDs else { return }
        locallyReadTopicIDs = ids
        updateUI()
    }

    override func updateUI() {
        _ = AppSettings.shared.localBlocklistRevision
        // Login-required state
        if viewModel.requiresLogin {
            errorLabel.text = viewModel.errorMessage
            errorLabel.isHidden = false
            loginButton.isHidden = false
            tableView.isHidden = true
            sortFloatingBar.isHidden = true
            categoryFloatingButton.isHidden = true
            navigationItem.rightBarButtonItems = inheritedRightBarItems
            activityIndicator.stopAnimating()
            return
        }

        loginButton.isHidden = true
        tableView.isHidden = false
        sortFloatingBar.isHidden = false
        categoryFloatingButton.isHidden = false
        navigationItem.rightBarButtonItems = inheritedRightBarItems
        composeButton.backgroundColor = ThemeManager.shared.accentColor
        updateCategoryMenus()
        categoryFloatingButton.backgroundColor = ThemeManager.shared.cardBackgroundColor
        categoryFloatingButton.tintColor = ThemeManager.shared.accentColor
        sortFloatingBar.backgroundColor = ThemeManager.shared.cardBackgroundColor
        updateSortFloatingButtons()
        updateCategoryButton()
        // Show non-login errors (e.g. rate limit) when topic list is empty
        if let error = viewModel.errorMessage, viewModel.topics.isEmpty {
            errorLabel.text = error
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        let topics = viewModel.visibleTopics(
            excluding: AppSettings.shared.localBlockedUsernames(for: api.baseURL)
        )
        var seen = Set<Int>()
        var pinnedItems: [PinnedTopicBar.Item] = []
        var regularIds: [Int] = []
        for topic in topics {
            guard seen.insert(topic.id).inserted else { continue }
            if topic.pinned == true {
                let color = viewModel.category(for: topic).flatMap { Self.color(fromHex: $0.color) }
                pinnedItems.append(PinnedTopicBar.Item(
                    topicId: topic.id,
                    title: topic.fancyTitle,
                    iconColor: color,
                    isLocallyRead: locallyReadTopicIDs.contains(topic.id)
                ))
            } else {
                regularIds.append(topic.id)
            }
        }
        snapshot.appendItems(regularIds, toSection: 0)
        let currentIds = Set(dataSource.snapshot().itemIdentifiers)
        let idsToRefresh = regularIds.filter { currentIds.contains($0) }
        if !idsToRefresh.isEmpty {
            snapshot.reconfigureItems(idsToRefresh)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
        installPinnedHeader(items: pinnedItems)

        if viewModel.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if viewModel.isLoadingMore {
            footerSpinner.startAnimating()
        } else {
            footerSpinner.stopAnimating()
        }
    }

    private func makeSortFloatingButton(
        mode: TopicFeedMode,
        title: String,
        symbol: String
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            ),
            for: .normal
        )
        button.layer.cornerRadius = 10
        button.accessibilityLabel = title
        button.accessibilityIdentifier = "home.sort.\(mode.rawValue)"
        button.addAction(UIAction { [weak self] _ in
            self?.selectFeedMode(mode)
        }, for: .touchUpInside)
        return button
    }

    private func updateSortFloatingButtons() {
        let accentColor = ThemeManager.shared.accentColor
        for item in sortFloatingItems {
            let isSelected = item.mode == viewModel.feedMode
            item.button.isSelected = isSelected
            item.button.tintColor = isSelected ? accentColor : .secondaryLabel
            item.button.backgroundColor = isSelected
                ? accentColor.withAlphaComponent(0.16)
                : .clear
            item.button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    private func selectFeedMode(_ mode: TopicFeedMode) {
        guard viewModel.selectFeedMode(mode) else { return }
        updateSortFloatingButtons()
        Task {
            await viewModel.loadTopics()
        }
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.loadTopics()
            refreshControl.endRefreshing()
        }
    }

    @objc private func handleComposePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            composeDragDistance = 0
        case .changed:
            composeButton.center = CGPoint(
                x: composeButton.center.x + translation.x,
                y: composeButton.center.y + translation.y
            )
            syncCategoryFloatingButtonPosition()
            composeDragDistance += abs(translation.x) + abs(translation.y)
            gesture.setTranslation(.zero, in: view)
        case .ended, .cancelled:
            snapComposeButtonToEdge(velocity: gesture.velocity(in: view))
        default:
            break
        }
    }

    /// 让分类按钮与排序条作为一个整体跟随发帖按钮移动。
    private func syncCategoryFloatingButtonPosition() {
        guard view.bounds.width > 0 else { return }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let categoryHalf = categoryFloatingButtonSize / 2
        let composeHalf = composeButtonSize / 2
        let categoryAboveOffset = composeHalf + categoryFloatingButtonSpacing + categoryHalf
        let categoryUpwardExtent = categoryHalf + sortFloatingBarSpacing + sortFloatingBarHeight

        let minimumCategoryY = safe.minY + categoryUpwardExtent
        let maximumCategoryY = safe.maxY - categoryHalf
        let categoryAboveY = composeButton.center.y - categoryAboveOffset
        let categoryBelowY = composeButton.center.y
            + composeHalf
            + categoryFloatingButtonSpacing
            + sortFloatingBarHeight
            + sortFloatingBarSpacing
            + categoryHalf

        let categoryY: CGFloat
        if categoryAboveY >= minimumCategoryY {
            categoryY = categoryAboveY
        } else if categoryBelowY <= maximumCategoryY {
            categoryY = categoryBelowY
        } else {
            categoryY = min(max(categoryAboveY, minimumCategoryY), maximumCategoryY)
        }
        categoryFloatingButton.center = CGPoint(x: composeButton.center.x, y: categoryY)

        let categoryFrame = categoryFloatingButton.frame
        let prefersRightAlignment = categoryFloatingButton.center.x >= view.bounds.midX
        let preferredBarX = prefersRightAlignment
            ? categoryFrame.maxX - sortFloatingBarWidth
            : categoryFrame.minX
        let maximumBarX = max(safe.minX, safe.maxX - sortFloatingBarWidth)
        let barX = min(max(preferredBarX, safe.minX), maximumBarX)
        sortFloatingBar.frame = CGRect(
            x: barX,
            y: categoryFrame.minY - sortFloatingBarSpacing - sortFloatingBarHeight,
            width: sortFloatingBarWidth,
            height: sortFloatingBarHeight
        )
    }

    private func snapComposeButtonToEdge(velocity: CGPoint) {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let margin = composeButtonEdgeMargin
        let half = composeButtonSize / 2
        let center = composeButton.center

        // Determine left or right based on position + velocity bias
        let goRight: Bool
        if abs(velocity.x) > 200 {
            goRight = velocity.x > 0
        } else {
            goRight = center.x > view.bounds.midX
        }

        let targetX = goRight
            ? safe.maxX - margin - half
            : safe.minX + margin + half

        // Clamp Y within safe area
        let targetY = min(max(center.y, safe.minY + half + margin), safe.maxY - half - margin)

        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0.5,
            options: .curveEaseOut
        ) {
            self.composeButton.center = CGPoint(x: targetX, y: targetY)
            self.syncCategoryFloatingButtonPosition()
        }
    }

    @objc private func composeButtonTouchDown() {
        composeDragDistance = 0
    }

    @objc private func composeTapped() {
        guard composeDragDistance < 10 else { return }
        authGate?.requireAuth { [weak self] in
            self?.presentTopicComposer()
        }
    }

    private func presentTopicComposer() {
        let composer = TopicComposerViewController(api: api)
        composer.onTopicCreated = { [weak self] _ in
            Task {
                await self?.viewModel.loadTopics()
            }
        }
        let nav = UINavigationController(rootViewController: composer)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// Called when the home tab is re-tapped. Scrolls to top if not already there, otherwise refreshes.
    func scrollToTopOrRefresh() {
        let topOffset = -tableView.adjustedContentInset.top
        if tableView.contentOffset.y <= topOffset + 1 {
            // Already at top — trigger refresh
            refreshControl.beginRefreshing()
            tableView.setContentOffset(CGPoint(x: 0, y: topOffset - refreshControl.frame.height), animated: true)
            pullToRefresh()
        } else {
            tableView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: true)
        }
    }

    @objc private func loginTapped() {
        // A successful login posts `discourseAuthDidChange`; the observer below
        // performs one complete categories + topics reload with the new
        // credential.
        authGate?.requireAuth {}
    }

    @objc private func authDidChange(_ notification: Notification) {
        guard let changedBaseURL = notification.userInfo?["baseURL"] as? String,
              changedBaseURL == api.baseURL
        else { return }

        Task {
            await viewModel.reloadAfterAuthChange()
        }
    }

    private func updateCategoryButton() {
        let selected = viewModel.selectedCategory()
        let title = selected?.name ?? String(localized: "home.filter.all_categories")
        var config = categoryButton.configuration ?? UIButton.Configuration.plain()
        config.title = title
        if let selected, let color = Self.color(fromHex: selected.color) {
            config.image = UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
            config.baseForegroundColor = color
        } else {
            config.image = UIImage(systemName: "line.3.horizontal.decrease", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
            config.baseForegroundColor = nil
        }
        categoryButton.configuration = config
        categoryButton.sizeToFit()

        categoryButton.accessibilityLabel = String(localized: "home.filter.accessibility.label")
        categoryButton.accessibilityValue = title
        categoryButton.accessibilityHint = String(localized: "home.filter.accessibility.hint")
        categoryButton.accessibilityTraits = [.button]
        categoryFloatingButton.accessibilityValue = title
    }

    private func buildCategoryMenuElements() -> [UIMenuElement] {
        let allAction = UIAction(
            title: String(localized: "home.filter.all_categories"),
            state: viewModel.selectedCategoryId == nil ? .on : .off
        ) { [weak self] _ in
            self?.selectCategory(nil)
        }

        let availableCategories = flattenedCategories()
        let categoriesByID = Dictionary(
            availableCategories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let preferredIDs = preferredCategoryIDs()
        let preferredIDSet = Set(preferredIDs)
        let preferredCategories = preferredIDs.compactMap { categoriesByID[$0] }

        var elements: [UIMenuElement] = [allAction]
        elements.append(contentsOf: preferredCategories.map(makeCategorySelectionAction))

        let addActions = availableCategories
            .filter { !preferredIDSet.contains($0.id) }
            .map { category in
                UIAction(
                    title: category.name,
                    image: Self.colorDotImage(color: Self.color(fromHex: category.color))
                ) { [weak self] _ in
                    self?.addPreferredCategory(category.id)
                }
            }
        if !addActions.isEmpty {
            elements.append(UIMenu(
                title: String(localized: "home.filter.add_categories"),
                image: UIImage(systemName: "plus.circle"),
                children: addActions
            ))
        }

        let removeActions = preferredCategories.map { category in
            UIAction(
                title: category.name,
                image: Self.colorDotImage(color: Self.color(fromHex: category.color)),
                attributes: .destructive
            ) { [weak self] _ in
                self?.removePreferredCategory(category.id)
            }
        }
        if !removeActions.isEmpty {
            elements.append(UIMenu(
                title: String(localized: "home.filter.remove_categories"),
                image: UIImage(systemName: "minus.circle"),
                children: removeActions
            ))
        }
        return elements
    }

    private func makeCategorySelectionAction(_ category: DiscourseCategory) -> UIAction {
        let state: UIMenuElement.State = viewModel.selectedCategoryId == category.id ? .on : .off
        return UIAction(
            title: category.name,
            image: Self.colorDotImage(color: Self.color(fromHex: category.color)),
            state: state
        ) { [weak self] _ in
            self?.selectCategory(category.id)
        }
    }

    private func flattenedCategories() -> [DiscourseCategory] {
        var result: [DiscourseCategory] = []
        var seen = Set<Int>()

        func append(_ categories: [DiscourseCategory]) {
            for category in categories where seen.insert(category.id).inserted {
                result.append(category)
                if let subcategories = category.subcategoryList {
                    append(subcategories)
                }
            }
        }

        append(viewModel.categories)
        return result
    }

    private func preferredCategoryIDs() -> [Int] {
        let settings = AppSettings.shared
        if let storedIDs = settings.homeCategoryIDs(for: api.baseURL) {
            return storedIDs
        }
        let categories = flattenedCategories()
        guard !categories.isEmpty else { return [] }
        let defaultIDs: [Int]
        if api.isLinuxDo {
            defaultIDs = Self.linuxDoDefaultCategoryNames.compactMap { name in
                categories.first(where: { $0.name == name })?.id
            }
        } else {
            defaultIDs = categories.map(\.id)
        }
        settings.setHomeCategoryIDs(defaultIDs, for: api.baseURL)
        return defaultIDs
    }

    private func addPreferredCategory(_ categoryID: Int) {
        var categoryIDs = preferredCategoryIDs()
        guard !categoryIDs.contains(categoryID) else { return }
        categoryIDs.append(categoryID)
        AppSettings.shared.setHomeCategoryIDs(categoryIDs, for: api.baseURL)
        updateCategoryMenus()
    }

    private func removePreferredCategory(_ categoryID: Int) {
        var categoryIDs = preferredCategoryIDs()
        guard categoryIDs.contains(categoryID) else { return }
        categoryIDs.removeAll { $0 == categoryID }
        AppSettings.shared.setHomeCategoryIDs(categoryIDs, for: api.baseURL)

        if viewModel.selectedCategoryId == categoryID {
            selectCategory(nil)
        } else {
            updateCategoryMenus()
        }
    }

    private func updateCategoryMenus() {
        let categoryMenu = UIMenu(title: "", children: buildCategoryMenuElements())
        categoryButton.menu = categoryMenu
        categoryFloatingButton.menu = categoryMenu
    }

    private func selectCategory(_ categoryId: Int?) {
        guard viewModel.selectCategory(categoryId) else { return }
        updateCategoryButton()
        updateCategoryMenus()
        Task {
            await viewModel.loadTopics()
        }
    }

    private static func color(fromHex hex: String) -> UIColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func colorDotImage(color: UIColor?) -> UIImage? {
        guard let color else { return nil }
        let size = CGSize(width: 12, height: 12)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }
}

extension HomeViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let topicId = dataSource.itemIdentifier(for: indexPath) else { return }
        let detailVC = TopicDetailControllerFactory.make(api: api, topicId: topicId)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let topicId = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: topicId as NSCopying, previewProvider: { [weak self] in
            guard let self else { return nil }
            return TopicDetailControllerFactory.make(api: self.api, topicId: topicId)
        })
    }

    func tableView(_ tableView: UITableView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: any UIContextMenuInteractionCommitAnimating) {
        guard let detailVC = animator.previewViewController else { return }
        animator.addCompletion { [weak self] in
            self?.navigationController?.pushViewController(detailVC, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let totalRows = tableView.numberOfRows(inSection: 0)
        if indexPath.row >= totalRows - 1 {
            Task {
                await viewModel.loadMoreTopics()
            }
        }
    }
}
