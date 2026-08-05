import Perception
import SDWebImage
import UIKit

@Perceptible
final class FollowedUsersViewModel {
    private(set) var users: [DiscourseFollowedUser] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var updatingUsernames: Set<String> = []

    private let api: DiscourseAPI
    private let currentUsername: String

    init(api: DiscourseAPI, currentUsername: String) {
        self.api = api
        self.currentUsername = currentUsername
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            users = try await api.fetchFollowedUsers(username: currentUsername)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func isUpdating(_ user: DiscourseFollowedUser) -> Bool {
        updatingUsernames.contains(user.username.lowercased())
    }

    func unfollow(_ user: DiscourseFollowedUser) async throws {
        let key = user.username.lowercased()
        guard updatingUsernames.insert(key).inserted else { return }
        defer { updatingUsernames.remove(key) }
        errorMessage = nil

        do {
            try await api.unfollowUser(username: user.username)
            users.removeAll { $0.id == user.id }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}

final class FollowedUsersViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: FollowedUsersViewModel

    private lazy var tableView: UITableView = {
        let tableView = ThemedTableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 64
        tableView.register(FollowedUserCell.self, forCellReuseIdentifier: FollowedUserCell.reuseIdentifier)
        tableView.refreshControl = refreshControl
        return tableView
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        return refreshControl
    }()

    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private let stateLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(api: DiscourseAPI, currentUsername: String) {
        self.api = api
        self.viewModel = FollowedUsersViewModel(api: api, currentUsername: currentUsername)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.following")

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        view.addSubview(stateLabel)
        view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stateLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { [weak self] in
            await self?.viewModel.load()
        }
    }

    override func updateUI() {
        let users = viewModel.users
        let isLoading = viewModel.isLoading
        let errorMessage = viewModel.errorMessage
        _ = viewModel.updatingUsernames

        if isLoading, users.isEmpty {
            stateLabel.isHidden = true
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
            stateLabel.text = errorMessage ?? String(localized: "settings.following.empty")
            stateLabel.isHidden = !users.isEmpty
        }
        if !isLoading {
            refreshControl.endRefreshing()
        }
        tableView.reloadData()
    }

    @objc private func refresh() {
        Task { [weak self] in
            await self?.viewModel.load()
        }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }
}

extension FollowedUsersViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.users.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FollowedUserCell.reuseIdentifier,
            for: indexPath
        ) as! FollowedUserCell
        let user = viewModel.users[indexPath.row]
        cell.configure(
            user: user,
            assetBaseURL: api.assetBaseURL,
            isUpdating: viewModel.isUpdating(user)
        )
        return cell
    }
}

extension FollowedUsersViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard viewModel.users.indices.contains(indexPath.row) else { return }
        let user = viewModel.users[indexPath.row]
        navigationController?.pushViewController(
            UserProfileViewController(api: api, username: user.username),
            animated: true
        )
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard viewModel.users.indices.contains(indexPath.row) else { return nil }
        let user = viewModel.users[indexPath.row]
        let action = UIContextualAction(
            style: .destructive,
            title: String(localized: "user.unfollow")
        ) { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            Task {
                do {
                    try await self.viewModel.unfollow(user)
                    completion(true)
                } catch {
                    completion(false)
                    self.showError(error)
                }
            }
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

private final class FollowedUserCell: UITableViewCell {
    static let reuseIdentifier = "FollowedUserCell"

    private let avatarView = UIImageView()
    private let displayNameLabel = UILabel()
    private let usernameLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 20

        displayNameLabel.font = FontManager.shared.font(size: 16, weight: .semibold)
        usernameLabel.font = FontManager.shared.font(size: 13)
        usernameLabel.textColor = .secondaryLabel

        let labels = UIStackView(arrangedSubviews: [displayNameLabel, usernameLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarView)
        contentView.addSubview(labels)
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 40),
            avatarView.heightAnchor.constraint(equalToConstant: 40),
            labels.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -32),
            labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(user: DiscourseFollowedUser, assetBaseURL: String, isUpdating: Bool) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        avatarView.backgroundColor = ThemeManager.shared.backgroundColor
        avatarView.tintColor = ThemeManager.shared.accentColor
        displayNameLabel.text = user.name?.isEmpty == false ? user.name : user.username
        usernameLabel.text = "@\(user.username)"
        accessibilityLabel = [displayNameLabel.text, usernameLabel.text].compactMap { $0 }.joined(separator: ", ")

        if let template = user.avatarTemplate {
            let path = template.replacingOccurrences(of: "{size}", with: "96")
            let urlString = path.hasPrefix("http") ? path : assetBaseURL + path
            avatarView.sd_setImage(
                with: URL(string: urlString),
                context: ImageCacheManager.shared.avatarContext
            )
        } else {
            avatarView.image = UIImage(systemName: "person.crop.circle")
        }

        if isUpdating {
            loadingIndicator.startAnimating()
            accessoryView = loadingIndicator
            accessoryType = .none
            selectionStyle = .none
        } else {
            loadingIndicator.stopAnimating()
            accessoryView = nil
            accessoryType = .disclosureIndicator
            selectionStyle = .default
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.sd_cancelCurrentImageLoad()
        avatarView.image = nil
        displayNameLabel.text = nil
        usernameLabel.text = nil
        accessoryView = nil
        accessoryType = .none
    }
}
