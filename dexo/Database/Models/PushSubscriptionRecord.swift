import Foundation
import GRDB

struct PushSubscriptionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    nonisolated static let databaseTableName = "pushSubscription"

    enum State: String, Codable, Sendable {
        case pending
        case active
    }

    let subscriptionID: String
    let forumId: Int64
    let accountName: String
    let endpoint: String
    var previousEndpoint: String?
    let expiresAt: Date
    let apnsTokenFingerprint: String
    var state: State
    let createdAt: Date
    var updatedAt: Date
}
