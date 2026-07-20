import CryptoKit
import Foundation
import ImageIO
import Intents
import OSLog
import PushCrypto
import UniformTypeIdentifiers
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private static let logger = Logger(
        subsystem: "com.eilgnaw.dexo",
        category: "NotificationService"
    )
    private static let maximumBadgeBytes = 512 * 1024

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = content

        guard let envelope = EncryptedEnvelope(userInfo: content.userInfo),
              let accessGroup = Bundle.main.object(
                forInfoDictionaryKey: "DexoPushKeychainAccessGroup"
              ) as? String,
              let keychain = try? PushKeychainStore(accessGroup: accessGroup),
              let subscription = try? keychain.load(subscriptionID: envelope.subscriptionID),
              let decrypted = try? WebPushDecryptor.decrypt(
                body: envelope.webPushBody,
                keyMaterial: subscription.keyMaterial
              ),
              let payload = try? JSONDecoder().decode(DiscoursePayload.self, from: decrypted),
              payload.isValid(for: subscription.forumBaseURL) else {
            finish(with: content)
            return
        }

        content.title = payload.compactTitle ?? payload.title
        content.subtitle = ""
        content.body = payload.body
        let forumContext = applyForumIdentity(
            for: subscription.forumBaseURL,
            to: content
        )
        if let tag = payload.tag, !tag.isEmpty {
            content.threadIdentifier = tag
        }
        var userInfo = content.userInfo
        userInfo["dexo_forum_base_url"] = subscription.forumBaseURL.absoluteString
        if let relativeURL = payload.url, !relativeURL.isEmpty {
            userInfo["dexo_relative_url"] = relativeURL
        }
        userInfo.removeValue(forKey: "dexo")
        content.userInfo = userInfo

        guard let forumContext else {
            finish(with: content)
            return
        }
        if let forumIdentity = forumContext.cachedIdentity {
            deliverNotification(
                content: content,
                payload: payload,
                subscription: subscription,
                forumIdentity: forumIdentity
            )
            return
        }
        loadBadgeIdentity(
            payload.badge,
            relativeTo: subscription.forumBaseURL,
            forumContext: forumContext
        ) { [weak self] result in
            guard let self, let result else {
                self?.finish(with: content)
                return
            }
            if let attachment = result.attachment {
                content.attachments = [attachment]
            }
            self.deliverNotification(
                content: content,
                payload: payload,
                subscription: subscription,
                forumIdentity: result.identity
            )
        }
    }

    override func serviceExtensionTimeWillExpire() {
        guard let bestAttemptContent else { return }
        finish(with: bestAttemptContent)
    }

    private func finish(with content: UNNotificationContent) {
        let handler = contentHandler
        contentHandler = nil
        bestAttemptContent = nil
        handler?(content)
    }

    private func applyForumIdentity(
        for forumBaseURL: URL,
        to content: UNMutableNotificationContent
    ) -> ForumNotificationContext? {
        guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "DexoPushAppGroup") as? String,
              let store = try? ForumNotificationMetadataStore(
                appGroupIdentifier: appGroup
              ),
              let metadata = try? store.metadata(forBaseURL: forumBaseURL) else { return nil }
        var iconData: Data?
        if let iconURL = try? store.iconURL(for: metadata),
           let data = try? Data(contentsOf: iconURL),
           !data.isEmpty {
            iconData = data
            if let attachment = try? UNNotificationAttachment(
                identifier: "forum-icon",
                url: iconURL,
                options: [
                    UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier,
                    UNNotificationAttachmentOptionsThumbnailHiddenKey: false,
                ]
            ) {
                content.attachments = [attachment]
            }
        }
        return ForumNotificationContext(
            identifier: opaqueForumIdentifier(metadata),
            cachedIconData: iconData
        )
    }

    private func opaqueForumIdentifier(_ metadata: ForumNotificationMetadata) -> String {
        if let iconFileName = metadata.iconFileName {
            return iconFileName
        }
        let digest = SHA256.hash(data: Data(metadata.baseURL.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func loadBadgeIdentity(
        _ badge: String?,
        relativeTo forumBaseURL: URL,
        forumContext: ForumNotificationContext,
        completion: @escaping (DownloadedForumIdentity?) -> Void
    ) {
        guard let badgeURL = secureImageURL(badge, relativeTo: forumBaseURL) else {
            Self.logger.debug("Badge fallback unavailable")
            completion(nil)
            return
        }
        var request = URLRequest(url: badgeURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode),
                  let finalURL = response.url,
                  self.isSecureImageURL(finalURL),
                  let data,
                  let typeIdentifier = self.validatedBadgeTypeIdentifier(data) else {
                Self.logger.debug("Badge fallback download rejected")
                completion(nil)
                return
            }
            completion(DownloadedForumIdentity(
                identity: ForumNotificationIdentity(
                    identifier: forumContext.identifier,
                    iconData: data
                ),
                attachment: self.makeBadgeAttachment(
                    data,
                    typeIdentifier: typeIdentifier
                )
            ))
        }.resume()
    }

    private func secureImageURL(_ value: String?, relativeTo baseURL: URL) -> URL? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 2048,
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              !DiscourseNotificationKind.matchesAsset(url, assetName: "discourse"),
              isSecureImageURL(url) else { return nil }
        return url
    }

    private func isSecureImageURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host != nil
            && components.user == nil
            && components.password == nil
    }

    private func validatedBadgeTypeIdentifier(_ data: Data) -> String? {
        guard !data.isEmpty,
              data.count <= Self.maximumBadgeBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              UTType(typeIdentifier)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        guard width.intValue > 0
            && height.intValue > 0
            && width.intValue <= 2048
            && height.intValue <= 2048 else { return nil }
        return typeIdentifier
    }

    private func makeBadgeAttachment(
        _ data: Data,
        typeIdentifier: String
    ) -> UNNotificationAttachment? {
        let pathExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("forum-badge-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        do {
            try data.write(to: fileURL, options: [.atomic])
            return try UNNotificationAttachment(
                identifier: "forum-badge",
                url: fileURL,
                options: [
                    UNNotificationAttachmentOptionsTypeHintKey: typeIdentifier,
                    UNNotificationAttachmentOptionsThumbnailHiddenKey: false,
                ]
            )
        } catch {
            Self.logger.debug("Badge fallback attachment creation failed")
            return nil
        }
    }

    private func deliverNotification(
        content: UNMutableNotificationContent,
        payload: DiscoursePayload,
        subscription: StoredWebPushSubscription,
        forumIdentity: ForumNotificationIdentity
    ) {
        let senderDisplayName = payload.compactTitle ?? payload.title
        content.title = senderDisplayName
        deliverCommunicationNotification(
            content: content,
            payload: payload,
            subscription: subscription,
            forumIdentity: forumIdentity,
            senderDisplayName: senderDisplayName
        )
    }

    private func deliverCommunicationNotification(
        content: UNMutableNotificationContent,
        payload: DiscoursePayload,
        subscription: StoredWebPushSubscription,
        forumIdentity: ForumNotificationIdentity,
        senderDisplayName: String
    ) {
        let sender = INPerson(
            personHandle: INPersonHandle(value: forumIdentity.identifier, type: .unknown),
            nameComponents: nil,
            displayName: senderDisplayName,
            image: INImage(imageData: forumIdentity.iconData),
            contactIdentifier: nil,
            customIdentifier: forumIdentity.identifier,
            isMe: false,
            suggestionType: .none
        )
        let recipient = INPerson(
            personHandle: INPersonHandle(value: subscription.forumUsername, type: .unknown),
            nameComponents: nil,
            displayName: subscription.forumUsername,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: nil,
            isMe: true,
            suggestionType: .none
        )
        let intent = INSendMessageIntent(
            recipients: [recipient],
            outgoingMessageType: .outgoingMessageText,
            content: payload.body,
            speakableGroupName: nil,
            conversationIdentifier: content.threadIdentifier.isEmpty
                ? forumIdentity.identifier
                : content.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.groupIdentifier = forumIdentity.identifier

        let communicationContent = content.mutableCopy() as? UNMutableNotificationContent
        communicationContent?.attachments = []
        interaction.donate { [weak self] error in
            guard let self else { return }
            if let error {
                Self.logger.error(
                    "Communication intent donation failed: \(error.localizedDescription, privacy: .public)"
                )
                self.finish(with: content)
                return
            }
            guard let communicationContent else {
                Self.logger.error("Communication content copy failed")
                self.finish(with: content)
                return
            }
            do {
                let updatedContent = try communicationContent.updating(from: intent)
                self.finish(with: updatedContent)
            } catch {
                Self.logger.error(
                    "Communication content update failed: \(error.localizedDescription, privacy: .public)"
                )
                self.finish(with: content)
            }
        }
    }
}

private struct ForumNotificationContext {
    let identifier: String
    let cachedIconData: Data?

    var cachedIdentity: ForumNotificationIdentity? {
        guard let cachedIconData else { return nil }
        return ForumNotificationIdentity(
            identifier: identifier,
            iconData: cachedIconData
        )
    }
}

private struct ForumNotificationIdentity {
    let identifier: String
    let iconData: Data
}

private struct DownloadedForumIdentity {
    let identity: ForumNotificationIdentity
    let attachment: UNNotificationAttachment?
}

private struct EncryptedEnvelope {
    let subscriptionID: String
    let webPushBody: Data

    init?(userInfo: [AnyHashable: Any]) {
        guard let value = userInfo["dexo"] as? [String: Any],
              value["v"] as? Int == 1,
              let subscriptionID = value["sid"] as? String,
              let encodedBody = value["wp"] as? String,
              let webPushBody = try? Base64URL.decode(encodedBody),
              !subscriptionID.isEmpty,
              !webPushBody.isEmpty,
              webPushBody.count <= 4096 else {
            return nil
        }
        self.subscriptionID = subscriptionID
        self.webPushBody = webPushBody
    }
}

private struct DiscoursePayload: Decodable {
    let title: String
    let body: String
    let tag: String?
    let baseURL: URL?
    let url: String?
    let icon: String?
    let badge: String?

    enum CodingKeys: String, CodingKey {
        case title, body, tag, url, icon, badge
        case baseURL = "base_url"
    }

    var notificationKind: DiscourseNotificationKind {
        DiscourseNotificationKind(icon: icon)
    }

    var compactSenderName: String? {
        guard notificationKind.usesCompactSenderTitle,
              let candidate = title.split(whereSeparator: \Character.isWhitespace).first,
              !candidate.isEmpty,
              candidate.count <= 64,
              candidate.unicodeScalars.allSatisfy(Self.isUsernameScalar) else {
            return nil
        }
        return String(candidate)
    }

    var compactTitle: String? {
        guard let senderName = compactSenderName else { return nil }
        return notificationKind.compactTitle(senderName: senderName)
    }

    private static func isUsernameScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
            || scalar == "_"
            || scalar == "-"
            || scalar == "."
    }

    func isValid(for expectedBaseURL: URL) -> Bool {
        guard !title.isEmpty, !body.isEmpty, let baseURL else { return false }
        return normalizedOriginAndPath(baseURL) == normalizedOriginAndPath(expectedBaseURL)
    }

    private func normalizedOriginAndPath(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }
}

private enum DiscourseNotificationKind {
    case privateMessage
    case chatMessage
    case chatMention
    case mentioned
    case groupMentioned
    case replied
    case quoted
    case linked
    case posted
    case watchingFirstPost
    case inlineReply
    case liked
    case other

    init(icon: String?) {
        if Self.matchesAsset(icon, assetName: "private_message") {
            self = .privateMessage
        } else if Self.matchesAsset(icon, assetName: "chat_message") {
            self = .chatMessage
        } else if Self.matchesAsset(icon, assetName: "chat_mention") {
            self = .chatMention
        } else if Self.matchesAsset(icon, assetName: "mentioned") {
            self = .mentioned
        } else if Self.matchesAsset(icon, assetName: "group_mentioned") {
            self = .groupMentioned
        } else if Self.matchesAsset(icon, assetName: "replied") {
            self = .replied
        } else if Self.matchesAsset(icon, assetName: "quoted") {
            self = .quoted
        } else if Self.matchesAsset(icon, assetName: "linked") {
            self = .linked
        } else if Self.matchesAsset(icon, assetName: "posted") {
            self = .posted
        } else if Self.matchesAsset(icon, assetName: "watching_first_post") {
            self = .watchingFirstPost
        } else if Self.matchesAsset(icon, assetName: "inline_reply") {
            self = .inlineReply
        } else if Self.matchesAsset(icon, assetName: "liked") {
            self = .liked
        } else {
            self = .other
        }
    }

    var usesCompactSenderTitle: Bool {
        switch self {
        case .privateMessage, .chatMessage, .chatMention, .mentioned, .groupMentioned,
             .replied, .quoted, .linked, .posted, .watchingFirstPost, .inlineReply, .liked:
            true
        case .other:
            false
        }
    }

    func compactTitle(senderName: String) -> String? {
        let format: String
        switch self {
        case .privateMessage:
            format = String(localized: "push.compact.private_message.format")
        case .chatMessage:
            format = String(localized: "push.compact.message.format")
        case .chatMention, .mentioned, .groupMentioned:
            format = String(localized: "push.compact.mention.format")
        case .replied, .inlineReply:
            format = String(localized: "push.compact.reply.format")
        case .quoted:
            format = String(localized: "push.compact.quote.format")
        case .linked:
            format = String(localized: "push.compact.link.format")
        case .posted:
            format = String(localized: "push.compact.post.format")
        case .watchingFirstPost:
            format = String(localized: "push.compact.new_topic.format")
        case .liked:
            format = String(localized: "push.compact.like.format")
        case .other:
            return nil
        }
        return String(format: format, locale: .current, senderName)
    }

    static func matchesAsset(_ value: String?, assetName: String) -> Bool {
        guard let value, let url = URL(string: value) else { return false }
        return matchesAsset(url, assetName: assetName)
    }

    static func matchesAsset(_ url: URL, assetName: String) -> Bool {
        let fileName = url.lastPathComponent.lowercased()
        return fileName == "\(assetName).png"
            || (fileName.hasPrefix("\(assetName)-") && fileName.hasSuffix(".png"))
    }
}
