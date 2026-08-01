import Foundation

public struct StoredWebPushSubscription: Codable, Equatable, Sendable {
    public let version: Int
    public let subscriptionID: String
    public let forumBaseURL: URL
    public let forumUsername: String
    public let keyMaterial: WebPushKeyMaterial
    public let deliveryEnabled: Bool

    public init(
        version: Int = 1,
        subscriptionID: String,
        forumBaseURL: URL,
        forumUsername: String,
        keyMaterial: WebPushKeyMaterial,
        deliveryEnabled: Bool = true
    ) {
        self.version = version
        self.subscriptionID = subscriptionID
        self.forumBaseURL = forumBaseURL
        self.forumUsername = forumUsername
        self.keyMaterial = keyMaterial
        self.deliveryEnabled = deliveryEnabled
    }

    public func settingDeliveryEnabled(_ enabled: Bool) -> Self {
        Self(
            version: version,
            subscriptionID: subscriptionID,
            forumBaseURL: forumBaseURL,
            forumUsername: forumUsername,
            keyMaterial: keyMaterial,
            deliveryEnabled: enabled
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case subscriptionID
        case forumBaseURL
        case forumUsername
        case keyMaterial
        case deliveryEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        subscriptionID = try container.decode(String.self, forKey: .subscriptionID)
        forumBaseURL = try container.decode(URL.self, forKey: .forumBaseURL)
        forumUsername = try container.decode(String.self, forKey: .forumUsername)
        keyMaterial = try container.decode(WebPushKeyMaterial.self, forKey: .keyMaterial)
        // Subscriptions created by older app versions did not persist a
        // delivery policy. They were active, so preserve that behavior.
        deliveryEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .deliveryEnabled
        ) ?? true
    }
}
