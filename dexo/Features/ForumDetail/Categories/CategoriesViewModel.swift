import Foundation

import Perception

@Perceptible
final class CategoriesViewModel {
    var categories: [DiscourseCategory] = []
    var isLoading = false
    var errorMessage: String?
    var requiresLogin = false

    private let api: DiscourseAPI

    init(api: DiscourseAPI) {
        self.api = api
    }

    func loadCategories(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        requiresLogin = false
        do {
            let result = try await api.fetchAllCategories(forceRefresh: forceRefresh)
            categories = result.categoryList.categories.filter { $0.parentCategoryId == nil }
        } catch {
            if let apiError = error as? DiscourseAPIError, apiError.isNotLoggedIn || apiError.isForbidden {
                requiresLogin = true
            }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
