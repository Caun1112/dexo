import UIKit

final class UserProfileViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: UserProfileViewModel

    private let profileHeader = ProfileHeaderView()

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.dataSource = self
        return tv
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    /// Prefill context for the "send message" composer, set when this profile
    /// is opened from a topic so the PM carries that topic's title + link.
    private let messagePrefillTitle: String?
    private let messagePrefillBody: String?

    init(api: DiscourseAPI, username: String, messagePrefillTitle: String? = nil, messagePrefillBody: String? = nil) {
        self.api = api
        self.viewModel = UserProfileViewModel(api: api, username: username)
        self.messagePrefillTitle = messagePrefillTitle
        self.messagePrefillBody = messagePrefillBody
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = viewModel.username
        view.addSubview(tableView)
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        profileHeader.onStatTapped = { [weak self] statType in
            self?.handleStatTapped(statType)
        }
        profileHeader.onMessageTapped = { [weak self] in
            self?.handleMessageTapped()
        }

        Task {
            await viewModel.load()
        }
    }

    private func handleMessageTapped() {
        if viewModel.isOwnProfile {
            guard let authGate = findAuthGating() else { return }
            authGate.requireAuth { [weak self] in
                guard let self else { return }
                let vc = MessagesViewController(api: self.api, authGate: authGate)
                self.navigationController?.pushViewController(vc, animated: true)
            }
        } else {
            presentMessageComposer()
        }
    }

    private func findAuthGating() -> AuthGating? {
        var vc: UIViewController? = self
        while let parent = vc?.parent {
            if let gate = parent as? AuthGating { return gate }
            for child in parent.children {
                if let gate = child as? AuthGating { return gate }
                for grandchild in child.children {
                    if let gate = grandchild as? AuthGating { return gate }
                }
            }
            vc = parent
        }
        return nil
    }

    override func updateUI() {
        if viewModel.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if let profile = viewModel.userProfile {
            let user = DiscourseCurrentUser(
                id: profile.id,
                username: profile.username,
                name: profile.name,
                avatarTemplate: profile.avatarTemplate,
                unreadNotifications: nil,
                unreadPrivateMessages: nil,
                unreadHighPriorityNotifications: nil
            )
            profileHeader.configure(
                user: user,
                userProfile: profile,
                summary: viewModel.summary,
                messageAction: viewModel.isOwnProfile ? .inbox : .compose,
                assetBaseURL: api.assetBaseURL
            )
        }

        layoutHeaderView()
        tableView.reloadData()
    }

    private func layoutHeaderView() {
        tableView.tableHeaderView = profileHeader
        profileHeader.translatesAutoresizingMaskIntoConstraints = true
        let targetSize = CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let fittingSize = profileHeader.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        profileHeader.frame = CGRect(origin: .zero, size: fittingSize)
        tableView.tableHeaderView = profileHeader
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeaderView()
    }

    // MARK: - Actions

    private func presentMessageComposer() {
        let composer = MessageComposerViewController(
            api: api,
            recipients: viewModel.username,
            prefillTitle: messagePrefillTitle,
            prefillBody: messagePrefillBody
        )
        composer.onSent = { [weak self] in
            self?.presentMessageSentConfirmation()
        }
        let nav = UINavigationController(rootViewController: composer)
        present(nav, animated: true)
    }

    private func presentMessageSentConfirmation() {
        let done = UIAlertController(title: nil, message: String(localized: "user.message_sent"), preferredStyle: .alert)
        done.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(done, animated: true)
    }

    // MARK: - Stat Taps

    private func handleStatTapped(_ statType: ProfileHeaderView.StatType) {
        switch statType {
        case .topics:
            let vc = UserPostsViewController(api: api, username: viewModel.username, filter: .topics)
            navigationController?.pushViewController(vc, animated: true)
        case .posts:
            let vc = UserPostsViewController(api: api, username: viewModel.username, filter: .posts)
            navigationController?.pushViewController(vc, animated: true)
        case .likes, .days:
            break
        }
    }
}

// MARK: - UITableViewDataSource

extension UserProfileViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        guard viewModel.userProfile != nil else { return 0 }
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard viewModel.userProfile != nil else { return 0 }
        return 2
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        var content = cell.defaultContentConfiguration()
        switch indexPath.row {
        case 0:
            content.image = UIImage(systemName: "text.bubble")
            content.text = String(localized: "user.topics_title")
        case 1:
            content.image = UIImage(systemName: "text.quote")
            content.text = String(localized: "user.posts_title")
        default:
            break
        }
        content.imageProperties.tintColor = .tintColor
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }
}

// MARK: - UITableViewDelegate

extension UserProfileViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch indexPath.row {
        case 0:
            let vc = UserPostsViewController(api: api, username: viewModel.username, filter: .topics)
            navigationController?.pushViewController(vc, animated: true)
        case 1:
            let vc = UserPostsViewController(api: api, username: viewModel.username, filter: .posts)
            navigationController?.pushViewController(vc, animated: true)
        default:
            break
        }
    }
}
