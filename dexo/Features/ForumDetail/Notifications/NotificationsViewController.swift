import UIKit

final class NotificationsViewController: ObservableViewController {
    private let viewModel: NotificationsViewModel
    private let api: DiscourseAPI
    private weak var authGate: AuthGating?

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(NotificationCell.self, forCellReuseIdentifier: NotificationCell.reuseIdentifier)
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

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "notifications.empty")
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = NotificationsViewModel(api: api)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "notifications.title")
        tableView.refreshControl = refreshControl
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "notifications.mark_all_read"),
            style: .plain,
            target: self,
            action: #selector(markAllReadTapped)
        )

        view.addSubview(tableView)
        view.addSubview(activityIndicator)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        Task {
            await viewModel.loadNotifications()
        }
    }

    override func updateUI() {
        if viewModel.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        let hasUnread = viewModel.notifications.contains { !$0.read }
        navigationItem.rightBarButtonItem?.isEnabled = hasUnread

        if !viewModel.isLoading, viewModel.notifications.isEmpty {
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }

        tableView.reloadData()
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.loadNotifications()
            refreshControl.endRefreshing()
        }
    }

    @objc private func markAllReadTapped() {
        Task {
            await viewModel.markAllRead()
        }
    }
}

// MARK: - UITableViewDataSource

extension NotificationsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.notifications.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: NotificationCell.reuseIdentifier, for: indexPath) as? NotificationCell else {
            return UITableViewCell()
        }
        let notification = viewModel.notifications[indexPath.row]
        cell.configure(with: notification)
        return cell
    }
}

// MARK: - UITableViewDelegate

extension NotificationsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let notification = viewModel.notifications[indexPath.row]

        if !notification.read {
            Task {
                await viewModel.markRead(id: notification.id)
            }
        }

        if let topicId = notification.topicId {
            let detailVC = TopicDetailControllerFactory.make(api: api, topicId: topicId, initialFloor: notification.postNumber)
            navigationController?.pushViewController(detailVC, animated: true)
        }
    }
}
