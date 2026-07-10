import Foundation

struct TopicDraft: Codable {
    var title: String
    var body: String
    var categoryId: Int?
    var tags: [String]

    var isEmpty: Bool {
        title.isEmpty && body.isEmpty && categoryId == nil && tags.isEmpty
    }
}

enum TopicDraftStore {
    private static func key(for baseURL: String) -> String {
        "compose.draft.\(baseURL)"
    }

    static func load(baseURL: String) -> TopicDraft? {
        guard let data = UserDefaults.standard.data(forKey: key(for: baseURL)),
              let draft = try? JSONDecoder().decode(TopicDraft.self, from: data),
              !draft.isEmpty
        else { return nil }
        return draft
    }

    static func save(_ draft: TopicDraft, baseURL: String) {
        guard !draft.isEmpty,
              let data = try? JSONEncoder().encode(draft)
        else {
            clear(baseURL: baseURL)
            return
        }
        UserDefaults.standard.set(data, forKey: key(for: baseURL))
    }

    static func clear(baseURL: String) {
        UserDefaults.standard.removeObject(forKey: key(for: baseURL))
    }
}

import Perception

@Perceptible
final class TopicComposerViewModel {
    var title: String = ""
    var body: String = ""
    var selectedCategory: DiscourseCategory?
    var selectedTags: [String] = []
    var categories: [DiscourseCategory] = []
    var tagSuggestions: [DiscourseTag] = []
    var isSubmitting = false
    var isUploadingImage = false
    var errorMessage: String?

    var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedCategory != nil
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    var hasUnsavedChanges: Bool {
        !title.isEmpty || !body.isEmpty || selectedCategory != nil || !selectedTags.isEmpty
    }

    private let api: DiscourseAPI

    init(api: DiscourseAPI) {
        self.api = api
    }

    func loadCategories() async {
        do {
            let list = try await api.fetchAllCategories()
            categories = list.categoryList.categories
        } catch {
            // Non-critical — user can retry
        }
    }

    func searchTags(query: String) async {
        let categoryId = selectedCategory?.id
        do {
            tagSuggestions = try await api.searchTags(query: query, categoryId: categoryId)
        } catch {
            tagSuggestions = []
        }
    }

    func submit() async throws -> Int {
        guard let categoryId = selectedCategory?.id else { return -1 }
        let raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let topicTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        isSubmitting = true
        defer { isSubmitting = false }

        let response = try await api.createTopic(
            title: topicTitle,
            categoryId: categoryId,
            raw: raw,
            tags: selectedTags
        )
        return response.id
    }

    func uploadImage(data: Data, filename: String) async throws -> DiscourseUploadResponse {
        isUploadingImage = true
        defer { isUploadingImage = false }
        return try await api.uploadImage(data: data, filename: filename)
    }

    // MARK: - Draft

    func currentDraft() -> TopicDraft {
        TopicDraft(
            title: title,
            body: body,
            categoryId: selectedCategory?.id,
            tags: selectedTags
        )
    }

    func loadDraft() -> TopicDraft? {
        TopicDraftStore.load(baseURL: api.baseURL)
    }

    func saveDraft() {
        TopicDraftStore.save(currentDraft(), baseURL: api.baseURL)
    }

    func clearDraft() {
        TopicDraftStore.clear(baseURL: api.baseURL)
    }

    /// Recursively searches loaded `categories` (and their subcategories) for an id.
    func findCategory(id: Int) -> DiscourseCategory? {
        for cat in categories {
            if cat.id == id { return cat }
            if let subs = cat.subcategoryList {
                for sub in subs where sub.id == id { return sub }
            }
        }
        return nil
    }
}
