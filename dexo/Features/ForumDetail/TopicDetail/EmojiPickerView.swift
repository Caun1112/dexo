import SDWebImage
import UIKit

final class EmojiPickerView: UIInputView {
    var onEmojiSelected: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPresentSearch: ((UIViewController) -> Void)?
    var onSearchFinished: (() -> Void)?

    private struct Section {
        let id: String
        let title: String
        let symbolName: String
        let emojis: [DiscourseEmojiEntry]
    }

    private let forumIdentifier: String
    private var catalogGroups: [DiscourseEmojiGroup] = []
    private var sections: [Section] = []
    private var emojiByName: [String: DiscourseEmojiEntry] = [:]
    private var categoryButtons: [String: UIButton] = [:]
    private var selectedCategoryID = EmojiCategory.recent.id

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        layout.headerReferenceSize = CGSize(width: 1, height: 28)
        layout.sectionHeadersPinToVisibleBounds = true

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.register(EmojiGridCell.self, forCellWithReuseIdentifier: EmojiGridCell.reuseIdentifier)
        view.register(
            EmojiCategoryHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: EmojiCategoryHeaderView.reuseIdentifier
        )
        view.dataSource = self
        view.delegate = self
        return view
    }()

    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "emoji.empty")
        label.font = FontManager.shared.font(size: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let categoryBar: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let categoryScrollView: UIScrollView = {
        let view = UIScrollView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        return view
    }()

    private let categoryStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        return stack
    }()

    private lazy var deleteButton: UIButton = {
        let button = makeCategoryButton(
            symbolName: "delete.left",
            accessibilityLabel: String(localized: "emoji.delete")
        )
        button.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        return button
    }()

    init(forumIdentifier: String, frame: CGRect) {
        self.forumIdentifier = forumIdentifier
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        setupViews()
        rebuildSections()
        rebuildCategoryButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 300)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyTheme()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTheme()
    }

    func showLoading() {
        emptyLabel.isHidden = true
        loadingIndicator.startAnimating()
    }

    func setEmojiCatalog(_ groups: [DiscourseEmojiGroup]) {
        catalogGroups = groups.filter { !$0.emojis.isEmpty }
        emojiByName = Dictionary(
            catalogGroups.flatMap(\.emojis).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        loadingIndicator.stopAnimating()
        emptyLabel.isHidden = !catalogGroups.isEmpty
        rebuildSections()
        collectionView.reloadData()
        rebuildCategoryButtons()
        updateSelectedCategory(EmojiCategory.recent.id)
    }

    private func setupViews() {
        addSubview(collectionView)
        addSubview(loadingIndicator)
        addSubview(emptyLabel)
        addSubview(categoryBar)
        categoryBar.addSubview(categoryScrollView)
        categoryBar.addSubview(deleteButton)
        categoryScrollView.addSubview(categoryStackView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: categoryBar.topAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: collectionView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: collectionView.trailingAnchor, constant: -24),

            categoryBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            categoryBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            categoryBar.heightAnchor.constraint(equalToConstant: 48),

            deleteButton.trailingAnchor.constraint(equalTo: categoryBar.trailingAnchor, constant: -6),
            deleteButton.centerYAnchor.constraint(equalTo: categoryBar.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 38),

            categoryScrollView.leadingAnchor.constraint(equalTo: categoryBar.leadingAnchor, constant: 6),
            categoryScrollView.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            categoryScrollView.topAnchor.constraint(equalTo: categoryBar.topAnchor),
            categoryScrollView.bottomAnchor.constraint(equalTo: categoryBar.bottomAnchor),

            categoryStackView.leadingAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.leadingAnchor),
            categoryStackView.trailingAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.trailingAnchor),
            categoryStackView.topAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.topAnchor),
            categoryStackView.bottomAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.bottomAnchor),
            categoryStackView.heightAnchor.constraint(equalTo: categoryScrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    private func rebuildSections() {
        let recent = EmojiRecentStore.names(for: forumIdentifier).compactMap { emojiByName[$0] }
        sections = [
            Section(
                id: EmojiCategory.recent.id,
                title: EmojiCategory.recent.title,
                symbolName: EmojiCategory.recent.symbolName,
                emojis: recent
            ),
        ]
        sections.append(contentsOf: catalogGroups.map { group in
            let category = EmojiCategory(groupID: group.id)
            return Section(
                id: group.id,
                title: category.title,
                symbolName: category.symbolName,
                emojis: group.emojis
            )
        })
    }

    private func rebuildCategoryButtons() {
        categoryStackView.arrangedSubviews.forEach {
            categoryStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        categoryButtons.removeAll()

        let searchButton = makeCategoryButton(
            symbolName: "magnifyingglass",
            accessibilityLabel: String(localized: "emoji.search.title")
        )
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        categoryStackView.addArrangedSubview(searchButton)

        for section in sections {
            let button = makeCategoryButton(
                symbolName: section.symbolName,
                accessibilityLabel: section.title
            )
            button.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
            categoryButtons[section.id] = button
            categoryStackView.addArrangedSubview(button)
        }

        applyTheme()
    }

    private func makeCategoryButton(symbolName: String, accessibilityLabel: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(
            UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            ),
            for: .normal
        )
        button.accessibilityLabel = accessibilityLabel
        button.layer.cornerRadius = 15
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func applyTheme() {
        let theme = ThemeManager.shared
        backgroundColor = theme.cardBackgroundColor
        categoryBar.backgroundColor = theme.cardBackgroundColor
        tintColor = theme.accentColor
        updateCategoryButtonAppearance(theme: theme)
        deleteButton.tintColor = .secondaryLabel
        deleteButton.backgroundColor = .clear
        collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ).compactMap { $0 as? EmojiCategoryHeaderView }.forEach { $0.applyTheme() }
    }

    private func updateCategoryButtonAppearance(theme: ThemeManager = .shared) {
        for (id, button) in categoryButtons {
            let selected = id == selectedCategoryID
            button.tintColor = selected ? theme.accentColor : .secondaryLabel
            button.backgroundColor = selected ? theme.codeBackgroundColor : .clear
        }
    }

    private func updateSelectedCategory(_ id: String) {
        guard selectedCategoryID != id || categoryButtons[id]?.backgroundColor == nil else { return }
        selectedCategoryID = id
        updateCategoryButtonAppearance()
        if let button = categoryButtons[id] {
            categoryScrollView.scrollRectToVisible(button.frame.insetBy(dx: -12, dy: 0), animated: true)
        }
    }

    private func selectEmoji(_ emoji: DiscourseEmojiEntry) {
        EmojiRecentStore.record(emoji.name, for: forumIdentifier)
        rebuildSections()
        if collectionView.numberOfSections > 0 {
            collectionView.reloadSections(IndexSet(integer: 0))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onEmojiSelected?(":\(emoji.name):")
    }

    @objc private func categoryTapped(_ sender: UIButton) {
        guard let id = categoryButtons.first(where: { $0.value === sender })?.key,
              let sectionIndex = sections.firstIndex(where: { $0.id == id })
        else { return }
        updateSelectedCategory(id)
        scrollToSectionHeader(sectionIndex)
    }

    private func scrollToSectionHeader(_ section: Int) {
        collectionView.layoutIfNeeded()
        guard let attributes = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: section)
        ) else { return }

        let minimumOffset = -collectionView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let targetOffset = min(
            max(attributes.frame.minY - collectionView.adjustedContentInset.top, minimumOffset),
            maximumOffset
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: targetOffset),
            animated: true
        )
    }

    @objc private func searchTapped() {
        let emojis = catalogGroups.flatMap(\.emojis)
        guard !emojis.isEmpty else { return }
        let searchController = EmojiSearchViewController(emojis: emojis)
        searchController.onEmojiSelected = { [weak self] emoji in
            self?.selectEmoji(emoji)
        }
        searchController.onFinished = { [weak self] in
            self?.onSearchFinished?()
        }

        let navigationController = UINavigationController(rootViewController: searchController)
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        onPresentSearch?(navigationController)
    }

    @objc private func deleteTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onDeleteBackward?()
    }
}

extension EmojiPickerView: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].emojis.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EmojiGridCell.reuseIdentifier,
            for: indexPath
        ) as! EmojiGridCell
        cell.configure(emoji: sections[indexPath.section].emojis[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: EmojiCategoryHeaderView.reuseIdentifier,
            for: indexPath
        ) as! EmojiCategoryHeaderView
        header.configure(title: sections[indexPath.section].title)
        return header
    }
}

extension EmojiPickerView: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let availableWidth = max(1, collectionView.bounds.width - 16)
        let columnCount = max(6, Int(availableWidth / 44))
        let spacing = CGFloat(columnCount - 1) * 4
        let side = floor((availableWidth - spacing) / CGFloat(columnCount))
        return CGSize(width: side, height: 42)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectEmoji(sections[indexPath.section].emojis[indexPath.item])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let visibleSection = collectionView.indexPathsForVisibleItems
            .map(\.section)
            .min()
        guard let visibleSection, sections.indices.contains(visibleSection) else { return }
        updateSelectedCategory(sections[visibleSection].id)
    }
}

private struct EmojiCategory {
    static let recent = EmojiCategory(
        id: "recent",
        title: String(localized: "emoji.category.recent"),
        symbolName: "clock"
    )

    let id: String
    let title: String
    let symbolName: String

    init(id: String, title: String, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }

    init(groupID: String) {
        id = groupID
        switch groupID {
        case "smileys_&_emotion":
            title = String(localized: "emoji.category.smileys")
            symbolName = "face.smiling"
        case "people_&_body":
            title = String(localized: "emoji.category.people")
            symbolName = "person.2"
        case "animals_&_nature":
            title = String(localized: "emoji.category.nature")
            symbolName = "leaf"
        case "food_&_drink":
            title = String(localized: "emoji.category.food")
            symbolName = "fork.knife"
        case "activities":
            title = String(localized: "emoji.category.activities")
            symbolName = "sportscourt"
        case "travel_&_places":
            title = String(localized: "emoji.category.travel")
            symbolName = "car"
        case "objects":
            title = String(localized: "emoji.category.objects")
            symbolName = "lightbulb"
        case "symbols":
            title = String(localized: "emoji.category.symbols")
            symbolName = "number"
        case "flags":
            title = String(localized: "emoji.category.flags")
            symbolName = "flag"
        case "default":
            title = String(localized: "emoji.community")
            symbolName = "star"
        default:
            title = String(localized: "emoji.category.other")
            symbolName = "square.grid.2x2"
        }
    }
}

private enum EmojiRecentStore {
    private static let limit = 30

    static func names(for forumIdentifier: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(for: forumIdentifier)) ?? []
    }

    static func record(_ name: String, for forumIdentifier: String) {
        var recent = names(for: forumIdentifier)
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
        if recent.count > limit {
            recent.removeLast(recent.count - limit)
        }
        UserDefaults.standard.set(recent, forKey: key(for: forumIdentifier))
    }

    private static func key(for forumIdentifier: String) -> String {
        "emoji.recent.\(forumIdentifier)"
    }
}

final class EmojiGridCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiGridCell"
    private static let placeholderImage = UIImage(
        systemName: "face.dashed",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .light)
    )?.withRenderingMode(.alwaysTemplate)

    private let imageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.tintColor = .tertiaryLabel
        return view
    }()

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.contentView.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.82, y: 0.82)
                    : .identity
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 30),
            imageView.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(emoji: DiscourseEmojiEntry) {
        let readableName = emoji.name.replacingOccurrences(of: "_", with: " ")
        accessibilityLabel = String(localized: "emoji.accessibility.name \(readableName)")
        imageView.sd_setImage(
            with: URL(string: emoji.url),
            placeholderImage: Self.placeholderImage,
            options: [.retryFailed],
            context: ImageCacheManager.shared.emojiContext
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.sd_cancelCurrentImageLoad()
        imageView.image = Self.placeholderImage
        accessibilityLabel = nil
        contentView.transform = .identity
    }
}

private final class EmojiCategoryHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "EmojiCategoryHeaderView"

    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FontManager.shared.font(size: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.text = title
        applyTheme()
    }

    func applyTheme() {
        backgroundColor = ThemeManager.shared.cardBackgroundColor.withAlphaComponent(0.96)
    }
}

final class EmojiSearchViewController: BaseViewController {
    var onEmojiSelected: ((DiscourseEmojiEntry) -> Void)?
    var onFinished: (() -> Void)?

    private let emojis: [DiscourseEmojiEntry]
    private var filteredEmojis: [DiscourseEmojiEntry]
    private var hasFinished = false

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchResultsUpdater = self
        controller.searchBar.placeholder = String(localized: "emoji.search.placeholder")
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        return controller
    }()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.keyboardDismissMode = .interactive
        view.register(EmojiGridCell.self, forCellWithReuseIdentifier: EmojiGridCell.reuseIdentifier)
        view.dataSource = self
        view.delegate = self
        return view
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "emoji.search.no_results")
        label.font = FontManager.shared.font(size: 15)
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()

    init(emojis: [DiscourseEmojiEntry]) {
        self.emojis = emojis
        filteredEmojis = emojis
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "emoji.search.title")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "action.cancel"),
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )

        view.addSubview(collectionView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
        searchController.isActive = true
        searchController.searchBar.becomeFirstResponder()
    }

    private func finishOnce() {
        guard !hasFinished else { return }
        hasFinished = true
        onFinished?()
    }

    private func close() {
        searchController.isActive = false
        navigationController?.dismiss(animated: true) { [weak self] in
            self?.finishOnce()
        }
    }

    @objc private func cancelTapped() {
        close()
    }
}

extension EmojiSearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let rawQuery = searchController.searchBar.text ?? ""
        let query = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "_")

        if query.isEmpty {
            filteredEmojis = emojis
        } else {
            filteredEmojis = emojis.filter { emoji in
                if emoji.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).contains(query) {
                    return true
                }
                return emoji.searchAliases?.contains {
                    $0.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    ).contains(query)
                } == true
            }
        }

        emptyLabel.isHidden = !filteredEmojis.isEmpty
        collectionView.reloadData()
    }
}

extension EmojiSearchViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredEmojis.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EmojiGridCell.reuseIdentifier,
            for: indexPath
        ) as! EmojiGridCell
        cell.configure(emoji: filteredEmojis[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let availableWidth = max(1, collectionView.bounds.width - 24)
        let columnCount = max(6, Int(availableWidth / 48))
        let spacing = CGFloat(columnCount - 1) * 4
        let side = floor((availableWidth - spacing) / CGFloat(columnCount))
        return CGSize(width: side, height: 44)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onEmojiSelected?(filteredEmojis[indexPath.item])
        close()
    }
}

extension EmojiSearchViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishOnce()
    }
}
