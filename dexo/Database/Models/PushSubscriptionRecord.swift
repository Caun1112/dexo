import Foundation
import GRDB

struct PushSubscriptionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    nonisolated static let databaseTableName = "pushSubscription"

    enum State: String, Codable, Sendable {
        case pending
        case active
        /// Delivery is disabled locally, but the forum may still hold one or
        /// more endpoints that must be unregistered before key material can
        /// be destroyed.
        case retiring
        /// The same account logged in again. The old generation is muted and
        /// must be revoked before a fresh subscription ID can be created.
        case rotating
    }

    let subscriptionID: String
    let forumId: Int64
    let accountName: String
    var endpoint: String
    var previousEndpoint: String?
    var staleEndpointsJSON: String = "[]"
    let expiresAt: Date
    let apnsTokenFingerprint: String
    var state: State
    let createdAt: Date
    var updatedAt: Date

    var supersededEndpoints: [String] {
        get {
            var endpoints = previousEndpoint.map { [$0] } ?? []
            if let data = staleEndpointsJSON.data(using: .utf8),
               let stale = try? JSONDecoder().decode([String].self, from: data) {
                endpoints.append(contentsOf: stale)
            }
            var seen = Set<String>()
            return endpoints.filter {
                !$0.isEmpty && $0 != endpoint && seen.insert($0).inserted
            }
        }
        set {
            var seen = Set<String>()
            let endpoints = newValue.filter {
                !$0.isEmpty && $0 != endpoint && seen.insert($0).inserted
            }
            previousEndpoint = endpoints.first
            let stale = Array(endpoints.dropFirst())
            staleEndpointsJSON = (try? String(
                data: JSONEncoder().encode(stale),
                encoding: .utf8
            )) ?? "[]"
        }
    }
}
