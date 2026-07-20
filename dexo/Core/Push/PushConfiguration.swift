import Foundation

struct PushConfiguration: Sendable {
    let relayBaseURL: URL
    let keychainAccessGroup: String
    let apnsEnvironment: String

    static func load(bundle: Bundle = .main) throws -> PushConfiguration {
        let keychainAccessGroup = try loadKeychainAccessGroup(bundle: bundle)
        guard let host = bundle.object(forInfoDictionaryKey: "DexoPushRelayHost") as? String,
              !host.isEmpty,
              !host.contains("://"),
              !host.contains("/"),
              !host.contains("?"),
              !host.contains("#"),
              let relayBaseURL = URL(string: "https://\(host)"),
              relayBaseURL.host == host,
              let apnsEnvironment = bundle.object(
                forInfoDictionaryKey: "DexoAPNSEnvironment"
              ) as? String,
              ["development", "production"].contains(apnsEnvironment) else {
            throw PushSubscriptionError.notConfigured
        }
        return PushConfiguration(
            relayBaseURL: relayBaseURL,
            keychainAccessGroup: keychainAccessGroup,
            apnsEnvironment: apnsEnvironment
        )
    }

    static func loadKeychainAccessGroup(bundle: Bundle = .main) throws -> String {
        guard let keychainAccessGroup = bundle.object(
            forInfoDictionaryKey: "DexoPushKeychainAccessGroup"
        ) as? String,
              !keychainAccessGroup.isEmpty,
              !keychainAccessGroup.contains("$(") else {
            throw PushSubscriptionError.notConfigured
        }
        return keychainAccessGroup
    }
}
