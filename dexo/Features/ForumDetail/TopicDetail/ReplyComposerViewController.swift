import PhotosUI
import UIKit

final class ReplyComposerViewController: BaseViewController {
    private let api: DiscourseAPI
    private let topicId: Int
    private let replyToPost: DiscourseTopicDetail.Post?
    private let baseURL: String
    var onPostCreated: ((_ postId: Int, _ postNumber: Int) -> Void)?

    private var isEmojiPickerVisible = false
    private var hasLoadedEmojiCatalog = false

    private let textView: UITextView = {
        let tv = UITextView()
        tv.font = FontManager.shared.font(size: 16)
        tv.backgroundColor = .clear
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        return tv
    }()

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "reply.placeholder")
        label.font = FontManager.shared.font(size: 16)
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let charCountLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.monospacedDigitFont(size: 12)
        label.textColor = .tertiaryLabel
        label.text = "0"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var markdownToolbar: MarkdownToolbarView = {
        let toolbar = MarkdownToolbarView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        toolbar.onAction = { [weak self] action in
            self?.handleToolbarAction(action)
        }
        return toolbar
    }()

    private lazy var emojiPickerInputView: EmojiPickerView = {
        let picker = EmojiPickerView(
            forumIdentifier: api.baseURL,
            frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 300)
        )
        picker.autoresizingMask = .flexibleWidth
        picker.onEmojiSelected = { [weak self] emoji in
            self?.insertText(emoji)
        }
        picker.onDeleteBackward = { [weak self] in
            self?.textView.deleteBackward()
        }
        picker.onPresentSearch = { [weak self] controller in
            self?.present(controller, animated: true)
        }
        picker.onSearchFinished = { [weak self] in
            guard let self, self.isEmojiPickerVisible else { return }
            self.textView.inputView = self.emojiPickerInputView
            self.textView.reloadInputViews()
            self.textView.becomeFirstResponder()
        }
        return picker
    }()

    private lazy var sendButton: UIBarButtonItem = {
        let item = UIBarButtonItem(title: String(localized: "reply.send"), style: .done, target: self, action: #selector(sendTapped))
        item.accessibilityLabel = String(localized: "reply.send")
        return item
    }()

    private lazy var sendSpinner: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    init(api: DiscourseAPI, topicId: Int, replyToPost: DiscourseTopicDetail.Post?, baseURL: String) {
        self.api = api
        self.topicId = topicId
        self.replyToPost = replyToPost
        self.baseURL = baseURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        if let username = replyToPost?.username {
            title = String(localized: "reply.title.to \(username)")
        } else {
            title = String(localized: "reply.title")
        }

        let cancelItem = UIBarButtonItem(title: String(localized: "action.cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        cancelItem.accessibilityLabel = String(localized: "action.cancel")
        navigationItem.leftBarButtonItem = cancelItem
        navigationItem.rightBarButtonItem = sendButton
        updateSendButton()

        view.addSubview(textView)
        view.addSubview(placeholderLabel)
        view.addSubview(charCountLabel)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),

            charCountLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            charCountLabel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])

        textView.inputAccessoryView = markdownToolbar
        textView.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    // MARK: - Toolbar Actions

    private func handleToolbarAction(_ action: MarkdownAction) {
        switch action {
        case .bold:
            wrapSelection(prefix: "**", suffix: "**")
        case .italic:
            wrapSelection(prefix: "_", suffix: "_")
        case .heading:
            prependToCurrentLine("## ")
        case .link:
            insertLinkTemplate()
        case .bulletList:
            prependToCurrentLine("- ")
        case .quote:
            prependToCurrentLine("> ")
        case .code:
            insertCode()
        case .pickImage:
            presentImagePicker()
        case .toggleEmoji:
            toggleEmojiPicker()
        }
    }

    // MARK: - Markdown Helpers

    private func wrapSelection(prefix: String, suffix: String) {
        guard let range = textView.selectedTextRange else { return }
        let selected = textView.text(in: range) ?? ""
        let replacement = prefix + selected + suffix
        textView.replace(range, withText: replacement)
        if selected.isEmpty {
            if let newPos = textView.position(from: range.start, offset: prefix.count) {
                textView.selectedTextRange = textView.textRange(from: newPos, to: newPos)
            }
        }
        textViewDidChange(textView)
    }

    private func prependToCurrentLine(_ prefix: String) {
        let text = textView.text ?? ""
        let nsRange = textView.selectedRange
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: nsRange.location, length: 0))
        let mutable = NSMutableString(string: text)
        mutable.insert(prefix, at: lineRange.location)
        textView.text = mutable as String
        textView.selectedRange = NSRange(location: nsRange.location + prefix.count, length: 0)
        textViewDidChange(textView)
    }

    private func insertLinkTemplate() {
        guard let range = textView.selectedTextRange else { return }
        let selected = textView.text(in: range) ?? ""
        if selected.isEmpty {
            textView.replace(range, withText: "[](url)")
            if let newPos = textView.position(from: range.start, offset: 1) {
                textView.selectedTextRange = textView.textRange(from: newPos, to: newPos)
            }
        } else {
            let replacement = "[\(selected)](url)"
            textView.replace(range, withText: replacement)
            if let urlStart = textView.position(from: range.start, offset: selected.count + 3),
               let urlEnd = textView.position(from: urlStart, offset: 3) {
                textView.selectedTextRange = textView.textRange(from: urlStart, to: urlEnd)
            }
        }
        textViewDidChange(textView)
    }

    private func insertCode() {
        guard let range = textView.selectedTextRange else { return }
        let selected = textView.text(in: range) ?? ""
        if selected.contains("\n") {
            textView.replace(range, withText: "```\n\(selected)\n```")
        } else {
            wrapSelection(prefix: "`", suffix: "`")
        }
    }

    private func insertText(_ text: String) {
        guard let range = textView.selectedTextRange else {
            textView.text.append(text)
            textViewDidChange(textView)
            return
        }
        var padded = text
        // Add space before if previous character is not whitespace/newline
        if let before = textView.position(from: range.start, offset: -1),
           let beforeRange = textView.textRange(from: before, to: range.start),
           let prev = textView.text(in: beforeRange),
           let ch = prev.last, !ch.isWhitespace && !ch.isNewline {
            padded = " " + padded
        }
        // Add space after if next character is not whitespace/newline
        if let after = textView.position(from: range.end, offset: 1),
           let afterRange = textView.textRange(from: range.end, to: after),
           let next = textView.text(in: afterRange),
           let ch = next.first, !ch.isWhitespace && !ch.isNewline {
            padded = padded + " "
        }
        textView.replace(range, withText: padded)
        textViewDidChange(textView)
    }

    // MARK: - Emoji Picker

    private func toggleEmojiPicker() {
        isEmojiPickerVisible.toggle()
        if isEmojiPickerVisible {
            textView.inputView = emojiPickerInputView
            loadEmojiCatalog()
        } else {
            textView.inputView = nil
        }
        markdownToolbar.updateEmojiButtonIcon(isEmojiVisible: isEmojiPickerVisible)
        textView.reloadInputViews()
        if !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
    }

    private func loadEmojiCatalog() {
        guard !hasLoadedEmojiCatalog else { return }
        hasLoadedEmojiCatalog = true
        emojiPickerInputView.showLoading()
        Task {
            let groups = await api.fetchEmojiCatalog()
            emojiPickerInputView.setEmojiCatalog(groups)
        }
    }

    // MARK: - Image Upload

    private func presentImagePicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func uploadImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let filename = "image_\(Int(Date().timeIntervalSince1970)).jpg"

        let placeholder = "[" + String(localized: "compose.uploading") + "]"
        let insertRange = textView.selectedTextRange ?? textView.textRange(
            from: textView.endOfDocument, to: textView.endOfDocument
        )!
        textView.replace(insertRange, withText: placeholder)
        textViewDidChange(textView)

        textView.isEditable = false
        textView.textColor = .placeholderText

        Task {
            do {
                let response = try await api.uploadImage(data: data, filename: filename)
                let markdown = "![\(response.originalFilename)](\(response.shortUrl))"
                if let range = (textView.text as NSString?)?.range(of: placeholder),
                   range.location != NSNotFound {
                    let mutable = NSMutableString(string: textView.text)
                    mutable.replaceCharacters(in: range, with: markdown)
                    textView.text = mutable as String
                }
                textViewDidChange(textView)
            } catch {
                if let range = (textView.text as NSString?)?.range(of: placeholder),
                   range.location != NSNotFound {
                    let mutable = NSMutableString(string: textView.text)
                    mutable.deleteCharacters(in: range)
                    textView.text = mutable as String
                }
                textViewDidChange(textView)
                let alert = UIAlertController(
                    title: String(localized: "compose.upload.failed"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
            textView.isEditable = true
            textView.textColor = .label
        }
    }

    // MARK: - UI State

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private func updateSendButton() {
        sendButton.isEnabled = !(textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func updateCharCount() {
        charCountLabel.text = "\(textView.text.count)"
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        let raw = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        navigationItem.rightBarButtonItem = sendSpinner
        textView.isEditable = false

        Task {
            do {
                let response = try await api.createReply(
                    topicId: topicId,
                    replyToPostNumber: replyToPost?.postNumber,
                    raw: raw
                )
                if response.enqueued {
                    // Post is in the moderation queue — there's no floor to
                    // scroll to yet, so skip the refresh callback and inform
                    // the user before dismissing.
                    let alert = UIAlertController(
                        title: String(localized: "reply.send.enqueued.title"),
                        message: String(localized: "reply.send.enqueued.message"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default) { [weak self] _ in
                        self?.dismiss(animated: true)
                    })
                    present(alert, animated: true)
                    return
                }
                let newPostId = response.id
                let newPostNumber = response.postNumber ?? 0
                dismiss(animated: true) { [weak self] in
                    self?.onPostCreated?(newPostId, newPostNumber)
                }
            } catch {
                navigationItem.rightBarButtonItem = sendButton
                sendButton.isEnabled = true
                textView.isEditable = true
                if presentChallengePromptIfNeeded(error: error, on: api) {
                    return
                }
                let alert = UIAlertController(
                    title: String(localized: "reply.send.failed"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

// MARK: - UITextViewDelegate

extension ReplyComposerViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
        updateSendButton()
        updateCharCount()
    }
}

// MARK: - PHPickerViewControllerDelegate

extension ReplyComposerViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage else { return }
            Task { @MainActor in
                self.uploadImage(image)
            }
        }
    }
}
