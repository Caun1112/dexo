import UIKit

final class BookmarksViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: BookmarksViewModel

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(BookmarkCell.self, forCellReuseIdentifier: BookmarkCell.reuseIdentifier)
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
        label.text = String(localized: "me.bookmarks.empty")
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

    init(api: DiscourseAPI, username: String) {
        self.api = api
        self.viewModel = BookmarksViewModel(api: api, username: username)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "me.bookmarks")
        tableView.refreshControl = refreshControl
        // Hide the plain-style table's top hairline (same trick used by HomeViewController).
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

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
            await viewModel.loadBookmarks()
        }
    }

    override func updateUI() {
        if viewModel.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if !viewModel.isLoading, viewModel.bookmarks.isEmpty {
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }

        tableView.reloadData()
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.reload()
            refreshControl.endRefreshing()
        }
    }
}

// MARK: - UITableViewDataSource

extension BookmarksViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.bookmarks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: BookmarkCell.reuseIdentifier, for: indexPath) as? BookmarkCell else {
            return UITableViewCell()
        }
        let bookmark = viewModel.bookmarks[indexPath.row]
        cell.configure(with: bookmark, assetBaseURL: api.assetBaseURL)
        cell.accessoryType = .disclosureIndicator
        return cell
    }
}

// MARK: - UITableViewDelegate

extension BookmarksViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let bookmark = viewModel.bookmarks[indexPath.row]
        if let topicId = bookmark.topicId {
            let detailVC = TopicDetailControllerFactory.make(api: api, topicId: topicId, initialFloor: bookmark.linkedPostNumber)
            navigationController?.pushViewController(detailVC, animated: true)
        }
    }
}
