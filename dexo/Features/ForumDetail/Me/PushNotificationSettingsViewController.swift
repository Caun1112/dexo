import UIKit

final class PushNotificationSettingsViewController: BaseViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private let coordinator: PushSubscriptionCoordinator
    private let username: String
    private var enabled = false
    private var isBusy = false

    private lazy var tableView: ThemedTableView = {
        let tableView = ThemedTableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        return tableView
    }()

    init(api: DiscourseAPI, username: String) {
        coordinator = PushSubscriptionCoordinator(api: api)
        self.username = username
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "push.settings.title")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadState()
    }

    private func reloadState() {
        enabled = coordinator.isEnabled(username: username)
        tableView.reloadData()
    }

    @objc private func switchChanged(_ sender: UISwitch) {
        guard !isBusy else { return }
        let targetEnabled = sender.isOn
        isBusy = true
        tableView.reloadData()
        Task { [weak self] in
            guard let self else { return }
            do {
                if targetEnabled {
                    try await coordinator.enable(username: username)
                } else {
                    try await coordinator.disable(username: username)
                }
                enabled = targetEnabled
            } catch {
                enabled = coordinator.isEnabled(username: username)
                showError(error)
            }
            isBusy = false
            tableView.reloadData()
        }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "push.error.title"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }
}

extension PushNotificationSettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        var content = cell.defaultContentConfiguration()
        content.text = String(localized: "push.settings.enable")
        content.image = UIImage(systemName: "bell.badge")
        content.imageProperties.tintColor = ThemeManager.shared.accentColor
        cell.contentConfiguration = content
        if isBusy {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            indicator.color = ThemeManager.shared.accentColor
            indicator.startAnimating()
            cell.accessoryView = indicator
        } else {
            let toggle = UISwitch()
            toggle.isOn = enabled
            toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        }
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "push.settings.footer")
    }
}

extension PushNotificationSettingsViewController: UITableViewDelegate {}
