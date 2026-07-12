import Foundation

import Perception

@Perceptible
final class MeViewModel {
    var currentUser: DiscourseCurrentUser?
    var userProfile: DiscourseUserProfile?
    var summary: DiscourseUserSummary?
    var isLoading = false
    var requiresLogin = false
    var errorMessage: String?

    private let api: DiscourseAPI
    private let cacheStore = ProfileCacheStore.shared

    init(api: DiscourseAPI) {
        self.api = api
    }

    func loadProfile(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let cachedEntry = cacheStore.load(for: api.baseURL)
        let cachedUsername = cachedEntry?.username
        let knownUsername = AuthManager.shared.username(for: api.baseURL)
        let usernameMatches = knownUsername == nil || knownUsername == cachedUsername

        if !forceRefresh, let cachedEntry, usernameMatches {
            apply(profile: cachedEntry.profile, summary: cachedEntry.summary)
            if cachedEntry.isFresh {
                isLoading = false
                return
            }
        }

        do {
            // Prefer the AuthManager cache (populated at login), but fall back
            // to `/session/current.json` when it's empty — `fetchAndCacheUsername`
            // can fail silently (both primary and fallback wrapped in `try?`),
            // leaving the cache unset even though the API key was saved. Without
            // this fallback the profile screen would stay empty after login.
            let username: String
            if let cached = knownUsername {
                username = cached
            } else if let cachedUsername, usernameMatches {
                username = cachedUsername
                AuthManager.shared.setCachedUsername(username, for: api.baseURL)
            } else if api.isLinuxDo {
                // linux.do's /session/current.json returns empty; use notifications instead.
                let notifList = try await api.fetchNotifications()
                guard let resolved = notifList.username else {
                    throw DiscourseAPIError(messages: ["Unable to resolve username"], errorType: "not_logged_in")
                }
                username = resolved
                AuthManager.shared.setCachedUsername(username, for: api.baseURL)
            } else {
                let current = try await api.fetchCurrentUser()
                username = current.username
                AuthManager.shared.setCachedUsername(username, for: api.baseURL)
            }

            async let profileRequest = api.fetchUserProfile(username: username)
            async let summaryRequest = api.fetchUserSummary(username: username)
            let profile = try await profileRequest
            let userSummary = try? await summaryRequest
            apply(profile: profile, summary: userSummary)
            cacheStore.save(profile: profile, summary: userSummary, for: api.baseURL)
        } catch {
            if let apiError = error as? DiscourseAPIError, apiError.isNotLoggedIn || apiError.isForbidden {
                requiresLogin = true
            } else if currentUser == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func reload() async {
        requiresLogin = false
        errorMessage = nil
        await loadProfile(forceRefresh: true)
    }

    func clearCachedProfile() {
        cacheStore.remove(for: api.baseURL)
        currentUser = nil
        userProfile = nil
        summary = nil
    }

    private func apply(profile: DiscourseUserProfile, summary: DiscourseUserSummary?) {
        currentUser = DiscourseCurrentUser(
            id: profile.id,
            username: profile.username,
            name: profile.name,
            avatarTemplate: profile.avatarTemplate,
            unreadNotifications: nil,
            unreadPrivateMessages: nil,
            unreadHighPriorityNotifications: nil
        )
        userProfile = profile
        self.summary = summary
    }
}
