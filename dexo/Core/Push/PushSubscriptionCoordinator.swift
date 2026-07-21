import CryptoKit
import Foundation
import PushCrypto
import Security

enum PushSubscriptionError: LocalizedError {
    case notConfigured
    case permissionDenied
    case apnsRegistrationTimedOut
    case forumUnsupported
    case invalidForumKey
    case missingForumIdentity
    case relayRejected
    case localRecordUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "push.error.not_configured")
        case .permissionDenied:
            String(localized: "push.error.permission_denied")
        case .apnsRegistrationTimedOut:
            String(localized: "push.error.apns_timeout")
        case .forumUnsupported:
            String(localized: "push.error.forum_unsupported")
        case .invalidForumKey:
            String(localized: "push.error.invalid_forum_key")
        case .missingForumIdentity:
            String(localized: "push.error.missing_identity")
        case .relayRejected:
            String(localized: "push.error.relay_rejected")
        case .localRecordUnavailable:
            String(localized: "push.error.local_record")
        }
    }
}

@MainActor
final class PushSubscriptionCoordinator {
    private let api: DiscourseAPI
    private let database: DatabaseManager
    private let tokenProvider: APNSTokenProvider

    init(
        api: DiscourseAPI,
        database: DatabaseManager? = nil,
        tokenProvider: APNSTokenProvider? = nil
    ) {
        self.api = api
        self.database = database ?? .shared
        self.tokenProvider = tokenProvider ?? .shared
    }

    func isEnabled(username: String) -> Bool {
        guard let forumID = api.forumID else { return false }
        return (try? database.fetchPushSubscription(
            forumId: forumID,
            accountName: username
        )?.state) == .active
    }

    func hasSubscription(username: String) -> Bool {
        guard let forumID = api.forumID else { return false }
        return (try? database.fetchPushSubscription(
            forumId: forumID,
            accountName: username
        )) != nil
    }

    func enable(username: String) async throws {
        guard let forumID = api.forumID,
              let forumURL = URL(string: api.baseURL),
              !username.isEmpty else {
            throw PushSubscriptionError.missingForumIdentity
        }
        await ForumNotificationMetadataSynchronizer.sync(forumID: forumID)
        let configuration = try PushConfiguration.load()
        let settings = try await api.fetchPushSiteSettings()
        let vapidKey = try settings.validatedVAPIDPublicKey()
        guard (try? P256.KeyAgreement.PublicKey(x963Representation: vapidKey)) != nil else {
            throw PushSubscriptionError.invalidForumKey
        }

        let deviceToken = try await tokenProvider.requestToken()
        let tokenFingerprint = Base64URL.encode(Data(SHA256.hash(data: deviceToken)))
        let keychain = try PushKeychainStore(accessGroup: configuration.keychainAccessGroup)
        var existing = try database.fetchPushSubscription(
            forumId: forumID,
            accountName: username
        )

        if var active = existing,
           active.state == .active,
           let previousEndpoint = active.previousEndpoint {
            let secret = try loadSecret(
                active.subscriptionID,
                username: username,
                from: keychain
            )
            try await api.unsubscribePush(
                endpoint: previousEndpoint,
                p256dh: secret.keyMaterial.p256dh,
                auth: secret.keyMaterial.auth
            )
            active.previousEndpoint = nil
            active.updatedAt = Date()
            try database.savePushSubscription(active)
            existing = active
        }

        if let existing,
           existing.apnsTokenFingerprint == tokenFingerprint,
           existing.expiresAt > Date() {
            if existing.state == .active,
               existing.expiresAt > Date().addingTimeInterval(30 * 24 * 60 * 60) {
                return
            }
            if existing.state == .pending {
                let secret = try loadSecret(
                    existing.subscriptionID,
                    username: username,
                    from: keychain
                )
                try await api.subscribePush(
                    endpoint: existing.endpoint,
                    p256dh: secret.keyMaterial.p256dh,
                    auth: secret.keyMaterial.auth
                )
                var active = existing
                active.state = .active
                active.updatedAt = Date()
                if let previousEndpoint = active.previousEndpoint {
                    do {
                        try await api.unsubscribePush(
                            endpoint: previousEndpoint,
                            p256dh: secret.keyMaterial.p256dh,
                            auth: secret.keyMaterial.auth
                        )
                        active.previousEndpoint = nil
                    } catch {
                        // Preserve it for a future cleanup attempt.
                    }
                }
                try database.savePushSubscription(active)
                return
            }
        }

        let isNew = existing == nil
        let secret: StoredWebPushSubscription
        if let existing {
            secret = try loadSecret(
                existing.subscriptionID,
                username: username,
                from: keychain
            )
        } else {
            let subscriptionID = try makeSubscriptionID()
            secret = StoredWebPushSubscription(
                subscriptionID: subscriptionID,
                forumBaseURL: forumURL,
                forumUsername: username,
                keyMaterial: try WebPushKeyMaterial.generate()
            )
            try keychain.save(secret)
        }

        var didPersistRecord = false
        do {
            let relay = PushRelayAPI(baseURL: configuration.relayBaseURL)
            let endpoint = try await relay.createEndpoint(PushRelayEndpointRequest(
                version: 1,
                apnsToken: Base64URL.encode(deviceToken),
                apnsEnvironment: configuration.apnsEnvironment,
                subscriptionID: secret.subscriptionID,
                forumBaseURL: forumURL.absoluteString,
                forumVAPIDPublicKey: Base64URL.encode(vapidKey)
            ))
            let now = Date()
            var record = PushSubscriptionRecord(
                subscriptionID: secret.subscriptionID,
                forumId: forumID,
                accountName: username,
                endpoint: endpoint.endpoint,
                previousEndpoint: existing?.endpoint,
                expiresAt: endpoint.expiresAt,
                apnsTokenFingerprint: tokenFingerprint,
                state: .pending,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try database.savePushSubscription(record)
            didPersistRecord = true
            try await api.subscribePush(
                endpoint: record.endpoint,
                p256dh: secret.keyMaterial.p256dh,
                auth: secret.keyMaterial.auth
            )
            record.state = .active
            record.updatedAt = Date()

            if let previousEndpoint = record.previousEndpoint {
                do {
                    try await api.unsubscribePush(
                        endpoint: previousEndpoint,
                        p256dh: secret.keyMaterial.p256dh,
                        auth: secret.keyMaterial.auth
                    )
                    record.previousEndpoint = nil
                } catch {
                    // Keep the exact old endpoint locally so a later disable can remove it.
                }
            }
            try database.savePushSubscription(record)
        } catch {
            if isNew, !didPersistRecord {
                try? keychain.delete(subscriptionID: secret.subscriptionID)
            }
            throw error
        }
    }

    func disable(username: String) async throws {
        guard let forumID = api.forumID,
              let record = try database.fetchPushSubscription(
                forumId: forumID,
                accountName: username
              ) else { return }
        let keychain = try PushKeychainStore(
            accessGroup: PushConfiguration.loadKeychainAccessGroup()
        )
        let secret = try loadSecret(
            record.subscriptionID,
            username: username,
            from: keychain
        )
        try await api.unsubscribePush(
            endpoint: record.endpoint,
            p256dh: secret.keyMaterial.p256dh,
            auth: secret.keyMaterial.auth
        )
        if let previousEndpoint = record.previousEndpoint {
            try await api.unsubscribePush(
                endpoint: previousEndpoint,
                p256dh: secret.keyMaterial.p256dh,
                auth: secret.keyMaterial.auth
            )
        }
        try database.deletePushSubscription(subscriptionID: record.subscriptionID)
        try keychain.delete(subscriptionID: record.subscriptionID)
    }

    /// Logout must not be blocked by an unreachable forum or an expired
    /// credential. Try to unregister every known endpoint, then always remove
    /// the local decryption material and database record.
    func disableForLogout(username: String) async {
        guard let forumID = api.forumID else { return }
        guard let record = try? database.fetchPushSubscription(
                forumId: forumID,
                accountName: username
              ) else {
            discardLocalSubscriptions()
            return
        }

        let keychain = try? PushKeychainStore(
            accessGroup: PushConfiguration.loadKeychainAccessGroup()
        )
        let secret = keychain.flatMap {
            try? loadSecret(record.subscriptionID, username: username, from: $0)
        }

        if let secret {
            var endpoints = [record.endpoint]
            if let previousEndpoint = record.previousEndpoint {
                endpoints.append(previousEndpoint)
            }
            for endpoint in endpoints {
                do {
                    try await api.unsubscribePush(
                        endpoint: endpoint,
                        p256dh: secret.keyMaterial.p256dh,
                        auth: secret.keyMaterial.auth
                    )
                } catch {
                    debugLog("[PushSubscriptionCoordinator] best-effort logout unsubscribe failed: \(error.localizedDescription)")
                }
            }
        }

        discardLocalSubscriptions()
    }

    /// Drops every local subscription for this forum without contacting it.
    /// Used after the forum has already rejected the current authentication.
    func discardLocalSubscriptions() {
        guard let forumID = api.forumID,
              let records = try? database.fetchAllPushSubscriptions()
        else { return }
        let keychain = try? PushKeychainStore(
            accessGroup: PushConfiguration.loadKeychainAccessGroup()
        )

        for record in records where record.forumId == forumID {
            try? database.deletePushSubscription(subscriptionID: record.subscriptionID)
            try? keychain?.delete(subscriptionID: record.subscriptionID)
        }
    }

    private func loadSecret(
        _ subscriptionID: String,
        username: String,
        from keychain: PushKeychainStore
    ) throws -> StoredWebPushSubscription {
        do {
            let secret = try keychain.load(subscriptionID: subscriptionID)
            let storedBaseURL = secret.forumBaseURL.absoluteString.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            let currentBaseURL = api.baseURL.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            guard secret.forumUsername == username,
                  storedBaseURL == currentBaseURL else {
                throw PushSubscriptionError.localRecordUnavailable
            }
            return secret
        } catch {
            throw PushSubscriptionError.localRecordUnavailable
        }
    }

    private func makeSubscriptionID() throws -> String {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PushSubscriptionError.localRecordUnavailable
        }
        return Base64URL.encode(bytes)
    }
}
