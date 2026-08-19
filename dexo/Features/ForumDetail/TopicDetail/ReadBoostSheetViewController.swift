import UIKit

/// Settings + start/stop panel for ReadBoost, presented as a sheet from the
/// topic detail bottom bar.
final class ReadBoostSheetViewController: ObservableViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private enum Section {
        case status
        case risk
        case options
        case advanced
        case actions
    }

    private let manager = ReadBoostManager.shared
    private let themeManager = ThemeManager.shared

    private let api: DiscourseAPI
    private let topicId: Int
    private let currentPosition: Int
    private let totalReplies: Int

    /// Advanced numeric tuning stays locked behind an explicit opt-in — the
    /// defaults are the pacing least likely to trip site-side rate limits.
    private var advancedUnlocked = false
    private var sections: [Section] = []

    init(api: DiscourseAPI, topicId: Int, currentPosition: Int, totalReplies: Int) {
        self.api = api
        self.topicId = topicId
        self.currentPosition = currentPosition
        self.totalReplies = totalReplies
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private lazy var tableView: UITableView = {
        let tableView = ThemedTableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.keyboardDismissMode = .interactive
        tableView.register(ReadBoostNumberCell.self, forCellReuseIdentifier: ReadBoostNumberCell.reuseIdentifier)
        return tableView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "readboost.title")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "action.done"),
            style: .done,
            target: self,
            action: #selector(dismissSheet)
        )

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rebuildSections()
    }

    override func updateUI() {
        _ = FontManager.shared.scale
        _ = themeManager.revision
        _ = manager.message
        _ = manager.status
        _ = manager.processedEnd
        _ = manager.failedStatusCode
        _ = manager.config
        _ = AppSettings.shared.linuxDoReadTimingsEnabled
        rebuildSections()
    }

    override func applyThemeBackground() {
        super.applyThemeBackground()
        guard isViewLoaded else { return }
        tableView.tintColor = themeManager.accentColor
        tableView.reloadData()
    }

    private func rebuildSections() {
        var next: [Section] = [.status]
        if !manager.config.hasAgreed {
            next.append(.risk)
        } else {
            next.append(.options)
            if advancedUnlocked { next.append(.advanced) }
            next.append(.actions)
        }
        sections = next
        tableView.reloadData()
    }

    @objc private func dismissSheet() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    // MARK: - Rows

    private enum OptionRow: Int, CaseIterable {
        case autoStart
        case startFromCurrent
        case advancedMode
    }

    private enum AdvancedRow: Int, CaseIterable {
        case baseDelay
        case randomDelayRange
        case minReqSize
        case maxReqSize
        case minReadTime
        case maxReadTime

        var title: String {
            switch self {
            case .baseDelay: return String(localized: "readboost.field.base_delay")
            case .randomDelayRange: return String(localized: "readboost.field.random_delay_range")
            case .minReqSize: return String(localized: "readboost.field.min_req_size")
            case .maxReqSize: return String(localized: "readboost.field.max_req_size")
            case .minReadTime: return String(localized: "readboost.field.min_read_time")
            case .maxReadTime: return String(localized: "readboost.field.max_read_time")
            }
        }

        func value(in config: ReadBoostConfig) -> Int {
            switch self {
            case .baseDelay: return config.baseDelay
            case .randomDelayRange: return config.randomDelayRange
            case .minReqSize: return config.minReqSize
            case .maxReqSize: return config.maxReqSize
            case .minReadTime: return config.minReadTime
            case .maxReadTime: return config.maxReadTime
            }
        }

        func apply(_ value: Int, to config: inout ReadBoostConfig) {
            switch self {
            case .baseDelay: config.baseDelay = value
            case .randomDelayRange: config.randomDelayRange = value
            case .minReqSize: config.minReqSize = value
            case .maxReqSize: config.maxReqSize = value
            case .minReadTime: config.minReadTime = value
            case .maxReadTime: config.maxReadTime = value
            }
        }
    }

    private enum ActionRow {
        case runToggle
        case challengeRetry
        case reset
    }

    private var actionRows: [ActionRow] {
        var rows: [ActionRow] = [.runToggle]
        if showsChallengeRetry { rows.append(.challengeRetry) }
        rows.append(.reset)
        return rows
    }

    private var showsChallengeRetry: Bool {
        guard api.isLinuxDo, !manager.isRunning else { return false }
        if !AppSettings.shared.linuxDoReadTimingsEnabled { return true }
        return manager.status == .failed
            && manager.failedStatusCode == 403
            && manager.topicId == topicId
    }

    // MARK: - Actions

    private func toggleRun() {
        view.endEditing(true)
        if manager.isRunning {
            manager.stop()
        } else {
            manager.start(
                api: api,
                topicId: topicId,
                currentPosition: currentPosition,
                totalReplies: totalReplies
            )
        }
    }

    private func challengeAndRetry() {
        view.endEditing(true)
        ChallengeViewController.present(from: self) { [weak self] in
            guard let self else { return }
            self.api.resumeTopicTimingsAfterChallenge()
            self.manager.retryAfterChallenge(
                api: self.api,
                topicId: self.topicId,
                currentPosition: self.currentPosition,
                totalReplies: self.totalReplies
            )
        }
    }

    private func confirmAdvancedMode(_ enabled: Bool, switchControl: UISwitch) {
        guard enabled else {
            advancedUnlocked = false
            rebuildSections()
            return
        }
        let alert = UIAlertController(
            title: String(localized: "readboost.advanced.confirm_title"),
            message: String(localized: "readboost.advanced.confirm_message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel) { [weak self] _ in
            switchControl.setOn(false, animated: true)
            self?.advancedUnlocked = false
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default) { [weak self] _ in
            self?.advancedUnlocked = true
            self?.rebuildSections()
        })
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension ReadBoostSheetViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status: return 1
        case .risk: return 2
        case .options: return OptionRow.allCases.count
        case .advanced: return AdvancedRow.allCases.count
        case .actions: return actionRows.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status: return String(localized: "readboost.section.status")
        case .risk: return String(localized: "readboost.section.risk")
        case .options: return String(localized: "readboost.section.options")
        case .advanced: return String(localized: "readboost.section.advanced")
        case .actions: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .options:
            return String(localized: "readboost.footer.current_position \(currentPosition) \(totalReplies)")
        case .advanced:
            return String(localized: "readboost.footer.advanced")
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .status:
            return statusCell()
        case .risk:
            return riskCell(at: indexPath.row)
        case .options:
            return optionCell(for: OptionRow(rawValue: indexPath.row) ?? .autoStart)
        case .advanced:
            return advancedCell(tableView, for: AdvancedRow(rawValue: indexPath.row) ?? .baseDelay)
        case .actions:
            return actionCell(for: actionRows[indexPath.row])
        }
    }

    private func statusCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = themeManager.cardBackgroundColor
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = FontManager.shared.font(size: 15)
        cell.textLabel?.text = manager.message
        cell.detailTextLabel?.font = FontManager.shared.font(size: 13)
        cell.detailTextLabel?.textColor = .secondaryLabel
        if let percent = manager.progressPercent {
            cell.detailTextLabel?.text = String(
                localized: "readboost.status.progress \(percent) \(manager.processedEnd) \(manager.totalReplies)"
            )
        } else {
            cell.detailTextLabel?.text = nil
        }
        if manager.status == .failed, let error = manager.errorDescription {
            cell.detailTextLabel?.text = error
            cell.detailTextLabel?.textColor = .systemRed
        }
        return cell
    }

    private func riskCell(at row: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = themeManager.cardBackgroundColor
        cell.textLabel?.numberOfLines = 0
        if row == 0 {
            cell.selectionStyle = .none
            cell.textLabel?.font = FontManager.shared.font(size: 14)
            cell.textLabel?.textColor = .secondaryLabel
            cell.textLabel?.text = String(localized: "readboost.risk.body")
        } else {
            cell.textLabel?.font = FontManager.shared.font(size: 16, weight: .medium)
            cell.textLabel?.textColor = themeManager.accentColor
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.text = String(localized: "readboost.risk.accept")
        }
        return cell
    }

    private func optionCell(for row: OptionRow) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = themeManager.cardBackgroundColor
        cell.textLabel?.font = FontManager.shared.font(size: 16)
        let toggle = UISwitch()
        toggle.onTintColor = themeManager.accentColor
        switch row {
        case .autoStart:
            cell.textLabel?.text = String(localized: "readboost.option.auto_start")
            toggle.isOn = manager.config.autoStart
            toggle.addTarget(self, action: #selector(autoStartChanged(_:)), for: .valueChanged)
        case .startFromCurrent:
            cell.textLabel?.text = String(localized: "readboost.option.start_from_current")
            toggle.isOn = manager.config.startFromCurrent
            toggle.addTarget(self, action: #selector(startFromCurrentChanged(_:)), for: .valueChanged)
        case .advancedMode:
            cell.textLabel?.text = String(localized: "readboost.option.advanced_mode")
            toggle.isOn = advancedUnlocked
            toggle.addTarget(self, action: #selector(advancedModeChanged(_:)), for: .valueChanged)
        }
        cell.accessoryView = toggle
        return cell
    }

    private func advancedCell(_ tableView: UITableView, for row: AdvancedRow) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ReadBoostNumberCell.reuseIdentifier
        ) as? ReadBoostNumberCell ?? ReadBoostNumberCell(style: .default, reuseIdentifier: ReadBoostNumberCell.reuseIdentifier)
        cell.backgroundColor = themeManager.cardBackgroundColor
        cell.configure(title: row.title, value: row.value(in: manager.config), enabled: !manager.isRunning)
        cell.onValueCommitted = { [weak self] value in
            guard let self else { return }
            var config = self.manager.config
            row.apply(value, to: &config)
            self.manager.save(config: config)
        }
        return cell
    }

    private func actionCell(for row: ActionRow) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = themeManager.cardBackgroundColor
        cell.textLabel?.textAlignment = .center
        cell.textLabel?.font = FontManager.shared.font(size: 16, weight: .medium)
        switch row {
        case .runToggle:
            cell.textLabel?.text = manager.isRunning
                ? String(localized: "readboost.action.stop")
                : String(localized: "readboost.action.start")
            cell.textLabel?.textColor = manager.isRunning ? .systemRed : themeManager.accentColor
        case .challengeRetry:
            cell.textLabel?.text = String(localized: "readboost.action.challenge_retry")
            cell.textLabel?.textColor = themeManager.accentColor
        case .reset:
            cell.textLabel?.text = String(localized: "readboost.action.reset")
            cell.textLabel?.textColor = manager.isRunning ? .tertiaryLabel : .label
            cell.isUserInteractionEnabled = !manager.isRunning
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .risk where indexPath.row == 1:
            manager.acceptRisk()
        case .actions:
            switch actionRows[indexPath.row] {
            case .runToggle: toggleRun()
            case .challengeRetry: challengeAndRetry()
            case .reset: manager.resetConfig()
            }
        default:
            break
        }
    }

    @objc private func autoStartChanged(_ sender: UISwitch) {
        var config = manager.config
        config.autoStart = sender.isOn
        manager.save(config: config)
    }

    @objc private func startFromCurrentChanged(_ sender: UISwitch) {
        var config = manager.config
        config.startFromCurrent = sender.isOn
        manager.save(config: config)
    }

    @objc private func advancedModeChanged(_ sender: UISwitch) {
        confirmAdvancedMode(sender.isOn, switchControl: sender)
    }
}

// MARK: - Number cell

/// Label + right-aligned numeric field for one ReadBoost tunable.
final class ReadBoostNumberCell: UITableViewCell, UITextFieldDelegate {
    static let reuseIdentifier = "ReadBoostNumberCell"

    var onValueCommitted: ((Int) -> Void)?

    private let titleLabel = UILabel()
    private let field = UITextField()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        field.keyboardType = .numberPad
        field.textAlignment = .right
        field.delegate = self
        field.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)

        contentView.addSubview(titleLabel)
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 96),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, value: Int, enabled: Bool) {
        titleLabel.text = title
        titleLabel.font = FontManager.shared.font(size: 16)
        field.font = FontManager.shared.font(size: 16)
        field.textColor = enabled ? .label : .tertiaryLabel
        field.isEnabled = enabled
        // Don't stomp what the user is mid-way through typing.
        if !field.isFirstResponder { field.text = String(value) }
    }

    @objc private func editingEnded() {
        guard let value = Int(field.text?.trimmingCharacters(in: .whitespaces) ?? "") else { return }
        onValueCommitted?(value)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
