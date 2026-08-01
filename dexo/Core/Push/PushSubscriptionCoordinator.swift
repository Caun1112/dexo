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
        var replacement: PushSubscriptionRecord?

        if let retiring = existing,
           retiring.state == .retiring || retiring.state == .rotating {
            let secret = try? loadSecret(
                retiring.subscriptionID,
                username: username,
                from: keychain
            )
            let retirementCompleted = await finishRetirement(
                record: retiring,
                secret: secret?.settingDeliveryEnabled(false),
                keychain: keychain
            )
            guard retirementCompleted else {
                throw PushSubscriptionError.localRecordUnavailable
            }
            if retiring.state == .rotating {
                replacement = retiring
                existing = nil
            } else {
                guard try database.fetchPushSubscription(
                    forumId: forumID,
                    accountName: username
                ) == nil else {
                    throw PushSubscriptionError.localRecordUnavailable
                }
                existing = nil
            }
        }

        if var active = existing,
           active.state == .active,
           !active.supersededEndpoints.isEmpty {
            let secret = try loadSecret(
                active.subscriptionID,
                username: username,
                from: keychain
            )
            active.supersededEndpoints = await failedUnsubscriptions(
                active.supersededEndpoints,
                secret: secret
            )
            active.updatedAt = Date()
            try database.savePushSubscription(active)
            existing = active
        }

        if let existing,
           existing.apnsTokenFingerprint == tokenFingerprint,
           existing.expiresAt > Date() {
            if existing.state == .active,
               existing.expiresAt > Date().addingTimeInterval(30 * 24 * 60 * 60) {
                let secret = try loadSecret(
                    existing.subscriptionID,
                    username: username,
                    from: keychain
                )
                if !secret.deliveryEnabled {
                    try keychain.save(secret.settingDeliveryEnabled(true))
                }
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
                active.supersededEndpoints = await failedUnsubscriptions(
                    active.supersededEndpoints,
                    secret: secret
                )
                try database.savePushSubscription(active)
                if !secret.deliveryEnabled {
                    try keychain.save(secret.settingDeliveryEnabled(true))
                }
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
                previousEndpoint: nil,
                expiresAt: endpoint.expiresAt,
                apnsTokenFingerprint: tokenFingerprint,
                state: .pending,
                createdAt: replacement?.createdAt ?? existing?.createdAt ?? now,
                updatedAt: now
            )
            if let existing {
                record.supersededEndpoints = [
                    existing.endpoint,
                ] + existing.supersededEndpoints
            }
            if let replacement {
                try database.replacePushSubscription(
                    subscriptionID: replacement.subscriptionID,
                    with: record
                )
                try? keychain.delete(subscriptionID: replacement.subscriptionID)
            } else {
                try database.savePushSubscription(record)
            }
            didPersistRecord = true
            try await api.subscribePush(
                endpoint: record.endpoint,
                p256dh: secret.keyMaterial.p256dh,
                auth: secret.keyMaterial.auth
            )
            record.state = .active
            record.updatedAt = Date()
            record.supersededEndpoints = await failedUnsubscriptions(
                record.supersededEndpoints,
                secret: secret
            )
            try database.savePushSubscription(record)
            if !secret.deliveryEnabled {
                try keychain.save(secret.settingDeliveryEnabled(true))
            }
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
        let retirement = try markRetiring(record, username: username)
        await finishRetirement(
            record: retirement.record,
            secret: retirement.secret,
            keychain: retirement.keychain
        )
    }

    /// Stop delivery locally before contacting the forum. If the forum is
    /// unreachable or the credential has expired, retain the exact endpoints
    /// and key material so a later login can finish the unsubscription.
    func disableForLogout(username: String) async {
        guard let forumID = api.forumID else { return }
        guard let record = try? database.fetchPushSubscription(
                forumId: forumID,
                accountName: username
              ) else {
            retireLocalSubscriptions()
            return
        }

        do {
            let retirement = try markRetiring(record, username: username)
            await finishRetirement(
                record: retirement.record,
                secret: retirement.secret,
                keychain: retirement.keychain
            )
        } catch {
            debugLog(
                "[PushSubscriptionCoordinator] failed to persist logout retirement: " +
                    error.localizedDescription
            )
        }
    }

    func retryRetirement(username: String) async {
        guard let forumID = api.forumID,
              let record = try? database.fetchPushSubscription(
                forumId: forumID,
                accountName: username
              ),
              record.state == .retiring else { return }
        let retirement = try? markRetiring(record, username: username)
        await finishRetirement(
            record: retirement?.record ?? record,
            secret: retirement?.secret,
            keychain: retirement?.keychain
        )
    }

    func retryRotation(username: String) async {
        guard let forumID = api.forumID,
              let record = try? database.fetchPushSubscription(
                forumId: forumID,
                accountName: username
              ),
              record.state == .rotating else { return }
        do {
            try await enable(username: username)
        } catch {
            debugLog(
                "[PushSubscriptionCoordinator] rotation retry unavailable: " +
                    error.localizedDescription
            )
        }
    }

    /// A successful login is a generation boundary. Revoke every older
    /// subscription for this forum at the relay, including subscriptions that
    /// belong to another account and therefore cannot be removed with the new
    /// account's Discourse credential.
    func rotateSubscriptionsAfterLogin(username: String) async {
        guard let forumID = api.forumID,
              let records = try? database.fetchAllPushSubscriptions()
        else { return }

        var shouldEnableFreshGeneration = false
        for record in records where record.forumId == forumID {
            let belongsToCurrentAccount = record.accountName == username
            let shouldRemainEnabled = belongsToCurrentAccount
                && record.state != .retiring
            let targetState: PushSubscriptionRecord.State = shouldRemainEnabled
                ? .rotating
                : .retiring

            let retirementCompleted: Bool
            if let retirement = try? markRetiring(
                record,
                username: record.accountName,
                state: targetState
            ) {
                retirementCompleted = await finishRetirement(
                    record: retirement.record,
                    secret: retirement.secret,
                    keychain: retirement.keychain,
                    allowForumFallback: belongsToCurrentAccount
                )
            } else {
                var tombstone = record
                tombstone.state = targetState
                tombstone.updatedAt = Date()
                try? database.savePushSubscription(tombstone)
                retirementCompleted = await finishRetirement(
                    record: tombstone,
                    secret: nil,
                    keychain: nil,
                    allowForumFallback: false
                )
            }

            if shouldRemainEnabled, retirementCompleted {
                shouldEnableFreshGeneration = true
            }
        }

        if shouldEnableFreshGeneration {
            do {
                try await enable(username: username)
            } catch {
                debugLog(
                    "[PushSubscriptionCoordinator] fresh generation enable failed: " +
                        error.localizedDescription
                )
            }
        }
    }

    /// Revoke an old account by endpoint capability only. The current
    /// account's forum credential is deliberately never sent for this path.
    func revokeSubscriptionForDifferentAccount(username: String) async {
        guard let forumID = api.forumID,
              let record = try? database.fetchPushSubscription(
                forumId: forumID,
                accountName: username
              ) else { return }
        retireLocally(record)
        await finishRetirement(
            record: record,
            secret: nil,
            keychain: nil,
            allowForumFallback: false
        )
    }

    /// Immediately disables every subscription for this forum without
    /// destroying the information required for a future authenticated retry.
    /// Used when the forum has already rejected the current credential.
    func retireLocalSubscriptions() {
        guard let forumID = api.forumID,
              let records = try? database.fetchAllPushSubscriptions()
        else { return }
        for record in records where record.forumId == forumID {
            retireLocally(record)
        }
    }

    private func retireLocally(_ record: PushSubscriptionRecord) {
        do {
            _ = try markRetiring(record, username: record.accountName)
        } catch {
            // Even if the shared Keychain item is already unavailable, keep
            // the database tombstone instead of treating the subscription as
            // active or losing the endpoint needed for future diagnosis.
            var retiring = record
            retiring.state = .retiring
            retiring.updatedAt = Date()
            do {
                try database.savePushSubscription(retiring)
            } catch {
                debugLog(
                    "[PushSubscriptionCoordinator] failed to retire local subscription: " +
                        error.localizedDescription
                )
            }
        }
    }

    private typealias Retirement = (
        record: PushSubscriptionRecord,
        secret: StoredWebPushSubscription,
        keychain: PushKeychainStore
    )

    private func markRetiring(
        _ record: PushSubscriptionRecord,
        username: String,
        state: PushSubscriptionRecord.State = .retiring
    ) throws -> Retirement {
        let keychain = try PushKeychainStore(
            accessGroup: PushConfiguration.loadKeychainAccessGroup()
        )
        let secret = try loadSecret(
            record.subscriptionID,
            username: username,
            from: keychain
        )
        let mutedSecret = secret.settingDeliveryEnabled(false)
        if secret.deliveryEnabled {
            try keychain.save(mutedSecret)
        }

        var retiring = record
        retiring.state = state
        retiring.updatedAt = Date()
        do {
            try database.savePushSubscription(retiring)
        } catch {
            if secret.deliveryEnabled {
                try? keychain.save(secret)
            }
            throw error
        }
        return (retiring, mutedSecret, keychain)
    }

    @discardableResult
    private func finishRetirement(
        record: PushSubscriptionRecord,
        secret: StoredWebPushSubscription?,
        keychain: PushKeychainStore?,
        allowForumFallback: Bool = true
    ) async -> Bool {
        if record.expiresAt > Date() {
            if await revokeAtRelay(record) {
                if record.state != .rotating {
                    cleanupRetirement(record: record, keychain: keychain)
                }
                return true
            }
            guard allowForumFallback, let secret else { return false }
            let failedEndpoints = await failedUnsubscriptions(
                [record.endpoint] + record.supersededEndpoints,
                secret: secret
            )
            if let firstFailedEndpoint = failedEndpoints.first {
                var retry = record
                retry.endpoint = firstFailedEndpoint
                retry.supersededEndpoints = Array(failedEndpoints.dropFirst())
                retry.updatedAt = Date()
                try? database.savePushSubscription(retry)
                return false
            }
        }

        if record.state != .rotating {
            cleanupRetirement(record: record, keychain: keychain)
        }
        return true
    }

    private func revokeAtRelay(_ record: PushSubscriptionRecord) async -> Bool {
        do {
            let configuration = try PushConfiguration.load()
            try await PushRelayAPI(baseURL: configuration.relayBaseURL)
                .revokeEndpoint(record.endpoint)
            return true
        } catch {
            debugLog(
                "[PushSubscriptionCoordinator] relay revocation failed: " +
                    error.localizedDescription
            )
            return false
        }
    }

    private func cleanupRetirement(
        record: PushSubscriptionRecord,
        keychain providedKeychain: PushKeychainStore?
    ) {
        let keychain = providedKeychain ?? (try? PushKeychainStore(
            accessGroup: PushConfiguration.loadKeychainAccessGroup()
        ))
        do {
            try keychain?.delete(subscriptionID: record.subscriptionID)
            try database.deletePushSubscription(subscriptionID: record.subscriptionID)
        } catch {
            debugLog(
                "[PushSubscriptionCoordinator] retirement cleanup failed: " +
                    error.localizedDescription
            )
        }
    }

    private func failedUnsubscriptions(
        _ endpoints: [String],
        secret: StoredWebPushSubscription
    ) async -> [String] {
        var failed: [String] = []
        var attempted = Set<String>()
        for endpoint in endpoints {
            guard !endpoint.isEmpty,
                  attempted.insert(endpoint).inserted else { continue }
            do {
                try await api.unsubscribePush(
                    endpoint: endpoint,
                    p256dh: secret.keyMaterial.p256dh,
                    auth: secret.keyMaterial.auth
                )
            } catch {
                failed.append(endpoint)
                debugLog(
                    "[PushSubscriptionCoordinator] endpoint unsubscribe failed: " +
                        error.localizedDescription
                )
            }
        }
        return failed
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
