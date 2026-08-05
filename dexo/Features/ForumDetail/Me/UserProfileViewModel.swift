import Foundation

import Perception

@Perceptible
final class UserProfileViewModel {
    enum LocalBlockToggleResult: Equatable {
        case blocked
        case unblocked
        case limitReached
    }

    var userProfile: DiscourseUserProfile?
    var summary: DiscourseUserSummary?
    var isLoading = false
    var isUpdatingFollow = false
    var isFollowing = false
    var errorMessage: String?

    private let api: DiscourseAPI
    let username: String

    /// Whether the current user is viewing their own profile.
    var isOwnProfile: Bool {
        let myUsername = AuthManager.shared.username(for: api.baseURL)
        return myUsername == username
    }

    var canSendMessage: Bool {
        userProfile?.canSendPrivateMessageToUser == true
    }

    /// The follow plugin is intentionally exposed only for linux.do profiles.
    /// A followed user remains actionable even if `can_follow` is false.
    var showsFollowButton: Bool {
        api.isLinuxDo
            && !isOwnProfile
            && (userProfile?.canFollow == true || isFollowing)
    }

    var showsLocalBlockButton: Bool {
        userProfile != nil && !isOwnProfile
    }

    var isLocallyBlocked: Bool {
        _ = AppSettings.shared.localBlocklistRevision
        return AppSettings.shared.isUserLocallyBlocked(
            username: username,
            baseURL: api.baseURL
        )
    }

    init(api: DiscourseAPI, username: String) {
        self.api = api
        self.username = username
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let profile = try await api.fetchUserProfile(username: username)
            let userSummary = try? await api.fetchUserSummary(username: username)
            userProfile = profile
            summary = userSummary
            isFollowing = profile.isFollowed == true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func toggleFollow() async throws {
        guard api.isLinuxDo, !isOwnProfile, showsFollowButton, !isUpdatingFollow else { return }

        let wasFollowing = isFollowing
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }

        if wasFollowing {
            try await api.unfollowUser(username: username)
        } else {
            try await api.followUser(username: username)
        }
        isFollowing = !wasFollowing
    }

    func toggleLocalBlock() -> LocalBlockToggleResult {
        if isLocallyBlocked {
            AppSettings.shared.unblockUserLocally(username: username, baseURL: api.baseURL)
            return .unblocked
        }

        switch AppSettings.shared.blockUserLocally(username: username, baseURL: api.baseURL) {
        case .added, .alreadyBlocked:
            return .blocked
        case .limitReached:
            return .limitReached
        }
    }
}
