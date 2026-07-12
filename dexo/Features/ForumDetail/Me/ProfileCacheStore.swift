import Foundation

/// Persists the small amount of data needed to render the current user's
/// profile without waiting for the network.
final class ProfileCacheStore {
    struct Entry: Codable {
        let username: String
        let profile: DiscourseUserProfile
        let summary: DiscourseUserSummary?
        let cachedAt: Date

        var isFresh: Bool {
            Date().timeIntervalSince(cachedAt) < ProfileCacheStore.ttl
        }
    }

    static let shared = ProfileCacheStore()
    private static let ttl: TimeInterval = 10 * 60
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for baseURL: String) -> Entry? {
        guard let data = defaults.data(forKey: key(for: baseURL)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func save(profile: DiscourseUserProfile, summary: DiscourseUserSummary?, for baseURL: String) {
        let entry = Entry(
            username: profile.username,
            profile: profile,
            summary: summary,
            cachedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: key(for: baseURL))
    }

    func remove(for baseURL: String) {
        defaults.removeObject(forKey: key(for: baseURL))
    }

    private func key(for baseURL: String) -> String {
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "me.profile.cache.\(normalized)"
    }
}
