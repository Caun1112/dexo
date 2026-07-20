import Foundation
import PushCrypto
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
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

        content.title = payload.title
        content.body = payload.body
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
        finish(with: content)
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

    enum CodingKeys: String, CodingKey {
        case title, body, tag, url
        case baseURL = "base_url"
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
