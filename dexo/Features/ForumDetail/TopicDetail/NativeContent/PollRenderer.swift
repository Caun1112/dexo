import CookedHTML
import UIKit

enum PollRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .poll = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        return UIView()
    }

    static func render(
        poll: DiscourseTopicDetail.Poll,
        votedOptionIds: Set<String>,
        post: DiscourseTopicDetail.Post,
        containerWidth: CGFloat,
        delegate: PostCellDelegate?
    ) -> PollView {
        PollView(poll: poll, votedOptionIds: votedOptionIds, post: post, containerWidth: containerWidth, delegate: delegate)
    }
}

// MARK: - PollView

final class PollView: UIView {
    private let poll: DiscourseTopicDetail.Poll
    private var votedOptionIds: Set<String>
    /// Pending selections for multiple-choice polls (before submitting)
    private var pendingSelections: Set<String>
    private let post: DiscourseTopicDetail.Post
    private let containerWidth: CGFloat
    weak var delegate: PostCellDelegate?
    var onPendingSelectionsChange: ((Set<String>) -> Void)?

    private let mainStack = UIStackView()
    private let optionsStack = UIStackView()
    private var submitButton: UIButton?
    private var removeVoteButton: UIButton?
    private let votersLabel = UILabel()

    private var isOpen: Bool { poll.status == "open" }
    private var isMultiple: Bool { poll.type == "multiple" }
    private var hasVoted: Bool { !votedOptionIds.isEmpty }
    private var showResults: Bool { hasVoted || poll.results == "always" }

    init(poll: DiscourseTopicDetail.Poll, votedOptionIds: Set<String>, post: DiscourseTopicDetail.Post, containerWidth: CGFloat, delegate: PostCellDelegate?) {
        self.poll = poll
        self.votedOptionIds = votedOptionIds
        self.pendingSelections = votedOptionIds
        self.post = post
        self.containerWidth = containerWidth
        self.delegate = delegate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Build UI

    private func buildUI() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        clipsToBounds = true

        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.isLayoutMarginsRelativeArrangement = true
        mainStack.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Title
        if let title = poll.title, !title.isEmpty {
            let titleLabel = UILabel()
            titleLabel.text = title
            titleLabel.font = FontManager.shared.font(size: 15, weight: .semibold)
            titleLabel.numberOfLines = 0
            mainStack.addArrangedSubview(titleLabel)
        }

        // Type hint
        let typeLabel = UILabel()
        if isMultiple {
            let min = poll.min ?? 1
            let max = poll.max ?? poll.options.count
            typeLabel.text = String(localized: "poll.multiple_hint \(min) \(max)")
        } else {
            typeLabel.text = String(localized: "poll.single_hint")
        }
        typeLabel.font = FontManager.shared.font(size: 12)
        typeLabel.textColor = .secondaryLabel
        mainStack.addArrangedSubview(typeLabel)

        // Options
        optionsStack.axis = .vertical
        optionsStack.spacing = 6
        mainStack.addArrangedSubview(optionsStack)

        rebuildOptions()

        // Submit button for multiple-choice (shown when user has pending changes)
        if isMultiple && isOpen {
            let btn = UIButton(type: .system)
            btn.setTitle(String(localized: "poll.submit"), for: .normal)
            btn.titleLabel?.font = FontManager.shared.font(size: 14, weight: .semibold)
            btn.backgroundColor = .systemBlue
            btn.setTitleColor(.white, for: .normal)
            btn.setTitleColor(.white.withAlphaComponent(0.5), for: .disabled)
            btn.layer.cornerRadius = 8
            btn.heightAnchor.constraint(equalToConstant: 36).isActive = true
            btn.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
            btn.isHidden = hasVoted
            mainStack.addArrangedSubview(btn)
            submitButton = btn
        }

        // Footer
        let footerStack = UIStackView()
        footerStack.axis = .horizontal
        footerStack.spacing = 6
        footerStack.alignment = .center

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let voterIcon = UIImageView(image: UIImage(systemName: "person.2", withConfiguration: iconConfig))
        voterIcon.tintColor = .tertiaryLabel
        voterIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            voterIcon.widthAnchor.constraint(equalToConstant: 18),
            voterIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
        footerStack.addArrangedSubview(voterIcon)

        votersLabel.font = FontManager.shared.font(size: 12)
        votersLabel.textColor = .tertiaryLabel
        votersLabel.text = "\(poll.voters)"
        footerStack.addArrangedSubview(votersLabel)

        if !isOpen {
            let closedBadge = UILabel()
            closedBadge.text = String(localized: "poll.closed")
            closedBadge.font = FontManager.shared.font(size: 12, weight: .medium)
            closedBadge.textColor = .secondaryLabel
            footerStack.addArrangedSubview(closedBadge)
        }

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerStack.addArrangedSubview(spacer)

        // Remove vote button
        if hasVoted && isOpen {
            let btn = UIButton(type: .system)
            btn.setTitle(String(localized: "poll.remove_vote"), for: .normal)
            btn.titleLabel?.font = FontManager.shared.font(size: 12)
            btn.tintColor = .secondaryLabel
            btn.addTarget(self, action: #selector(removeVoteTapped), for: .touchUpInside)
            footerStack.addArrangedSubview(btn)
            removeVoteButton = btn
        }

        mainStack.addArrangedSubview(footerStack)
    }

    private func rebuildOptions() {
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let totalVotes = poll.options.reduce(0) { $0 + $1.votes }
        let selections = isMultiple && !hasVoted ? pendingSelections : votedOptionIds

        for option in poll.options {
            let isSelected = selections.contains(option.id)
            let row = makeOptionRow(
                option: option,
                isSelected: isSelected,
                totalVotes: totalVotes,
                showResults: showResults,
                isMultiple: isMultiple
            )
            optionsStack.addArrangedSubview(row)
        }
    }

    // MARK: - Option Row

    private func makeOptionRow(
        option: DiscourseTopicDetail.PollOption,
        isSelected: Bool,
        totalVotes: Int,
        showResults: Bool,
        isMultiple: Bool
    ) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .systemBackground
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1.0 / UIScreen.main.scale
        container.layer.borderColor = UIColor.separator.cgColor
        container.clipsToBounds = true

        // Progress bar
        if showResults {
            let progressBar = UIView()
            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.backgroundColor = isSelected
                ? UIColor.systemBlue.withAlphaComponent(0.2)
                : UIColor.systemGray.withAlphaComponent(0.12)
            container.addSubview(progressBar)

            let fraction: CGFloat = totalVotes > 0
                ? CGFloat(option.votes) / CGFloat(totalVotes)
                : 0

            NSLayoutConstraint.activate([
                progressBar.topAnchor.constraint(equalTo: container.topAnchor),
                progressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                progressBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                progressBar.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: max(fraction, 0.001)),
            ])
        }

        // Content
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 8
        rowStack.alignment = .center
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            rowStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            rowStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        // Check indicator
        let checkIcon = UIImageView()
        checkIcon.translatesAutoresizingMaskIntoConstraints = false
        let symbolName: String
        if isSelected {
            symbolName = isMultiple ? "checkmark.square.fill" : "largecircle.fill.circle"
        } else {
            symbolName = isMultiple ? "square" : "circle"
        }
        let checkConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        checkIcon.image = UIImage(systemName: symbolName, withConfiguration: checkConfig)
        checkIcon.tintColor = isSelected ? .systemBlue : .tertiaryLabel
        NSLayoutConstraint.activate([
            checkIcon.widthAnchor.constraint(equalToConstant: 20),
            checkIcon.heightAnchor.constraint(equalToConstant: 20),
        ])
        rowStack.addArrangedSubview(checkIcon)

        // Text
        let textLabel = UILabel()
        textLabel.text = option.html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        textLabel.font = isSelected ? FontManager.shared.font(size: 15, weight: .medium) : FontManager.shared.font(size: 15)
        textLabel.numberOfLines = 0
        textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(textLabel)

        // Percentage
        if showResults {
            let pct = totalVotes > 0 ? Int(round(Double(option.votes) / Double(totalVotes) * 100)) : 0
            let statsLabel = UILabel()
            statsLabel.text = "\(pct)%"
            statsLabel.font = FontManager.shared.monospacedDigitFont(size: 13, weight: .medium)
            statsLabel.textColor = isSelected ? .systemBlue : .secondaryLabel
            statsLabel.setContentHuggingPriority(.required, for: .horizontal)
            statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            rowStack.addArrangedSubview(statsLabel)
        }

        // Tap gesture
        if isOpen {
            let tap = UITapGestureRecognizer(target: self, action: #selector(optionTapped(_:)))
            container.addGestureRecognizer(tap)
            container.isUserInteractionEnabled = true
            container.accessibilityIdentifier = option.id
        }

        return container
    }

    // MARK: - Actions

    @objc private func optionTapped(_ gesture: UITapGestureRecognizer) {
        guard let optionId = gesture.view?.accessibilityIdentifier else { return }

        if isMultiple {
            // Toggle pending selection
            if pendingSelections.contains(optionId) {
                pendingSelections.remove(optionId)
            } else {
                // Enforce max
                let max = poll.max ?? poll.options.count
                if pendingSelections.count >= max {
                    return
                }
                pendingSelections.insert(optionId)
            }
            rebuildOptions()
            // Show/hide submit button
            let changed = pendingSelections != votedOptionIds
            submitButton?.isHidden = !changed || pendingSelections.isEmpty
            updateSubmitEnabled()
            onPendingSelectionsChange?(pendingSelections)
        } else {
            // Single choice — vote immediately
            delegate?.postCell(didVotePoll: poll.name, options: [optionId], forPost: post)
        }
    }

    @objc private func submitTapped() {
        guard !pendingSelections.isEmpty else { return }
        delegate?.postCell(didVotePoll: poll.name, options: Array(pendingSelections), forPost: post)
    }

    @objc private func removeVoteTapped() {
        delegate?.postCell(didRemovePollVote: poll.name, forPost: post)
    }

    private func updateSubmitEnabled() {
        let min = poll.min ?? 1
        submitButton?.isEnabled = pendingSelections.count >= min
        submitButton?.backgroundColor = pendingSelections.count >= min ? .systemBlue : .systemGray3
    }

    func restorePendingSelections(_ selections: Set<String>) {
        guard isMultiple, !hasVoted else { return }
        let validIds = Set(poll.options.map(\.id))
        pendingSelections = selections.intersection(validIds)
        rebuildOptions()
        let changed = pendingSelections != votedOptionIds
        submitButton?.isHidden = !changed || pendingSelections.isEmpty
        updateSubmitEnabled()
    }
}
