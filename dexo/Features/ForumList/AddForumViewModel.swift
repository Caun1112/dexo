import Foundation

import Perception

@Perceptible
final class AddForumViewModel {
    var urlString = ""
    var isLoading = false
    var errorMessage: String?

    func addForum() async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "add_forum.error.empty_url")
            return false
        }

        let normalized: String
        do {
            normalized = try ForumURLPolicy.normalize(trimmed)
        } catch ForumURLPolicy.ValidationError.insecureScheme {
            errorMessage = String(localized: "add_forum.error.https_required")
            return false
        } catch {
            errorMessage = String(localized: "add_forum.error.invalid_url")
            return false
        }

        isLoading = true
        errorMessage = nil

        do {
            let tempForum = ForumInstance.new(title: "", baseURL: normalized)
            let api = DiscourseAPI(forum: tempForum)
            let info = try await api.fetchBasicInfo()

            var forum = ForumInstance.new(
                title: info.title,
                baseURL: normalized,
                iconURL: resolveIconURL(base: normalized, info: info)
            )
            forum.sortOrder = (try? DatabaseManager.shared.nextForumSortOrder()) ?? 0
            try DatabaseManager.shared.saveForum(&forum)
            isLoading = false
            return true
        } catch {
            errorMessage = String(localized: "add_forum.error.connect \(error.localizedDescription)")
            isLoading = false
            return false
        }
    }

    private func resolveIconURL(base: String, info: DiscourseBasicInfo) -> String? {
        // Prefer apple touch icon (180x180) > logo > favicon
        guard let path = info.appleTouchIconURL ?? info.logoURL ?? info.faviconURL else { return nil }
        if path.hasPrefix("//") {
            return "https:" + path
        }
        if let url = URL(string: path), url.scheme != nil {
            return url.scheme?.lowercased() == "https" ? url.absoluteString : nil
        }
        return path.hasPrefix("/") ? base + path : base + "/" + path
    }
}
