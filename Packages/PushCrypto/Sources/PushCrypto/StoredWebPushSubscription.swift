import Foundation

public struct StoredWebPushSubscription: Codable, Equatable, Sendable {
    public let version: Int
    public let subscriptionID: String
    public let forumBaseURL: URL
    public let forumUsername: String
    public let keyMaterial: WebPushKeyMaterial

    public init(
        version: Int = 1,
        subscriptionID: String,
        forumBaseURL: URL,
        forumUsername: String,
        keyMaterial: WebPushKeyMaterial
    ) {
        self.version = version
        self.subscriptionID = subscriptionID
        self.forumBaseURL = forumBaseURL
        self.forumUsername = forumUsername
        self.keyMaterial = keyMaterial
    }
}
