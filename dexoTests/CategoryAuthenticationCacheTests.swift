import XCTest
@testable import dexo

@MainActor
final class CategoryAuthenticationCacheTests: XCTestCase {
    func testAuthenticationChangesInvalidateAnonymousAndRestrictedCategoryCaches() async throws {
        enum CredentialState {
            case anonymous
            case authenticated
            case loggedOut
        }

        var state = CredentialState.anonymous
        var firstPageRequests = 0
        let api = DiscourseAPI(
            testingBaseURL: "https://forum.example.com",
            categoryPageLoader: { page in
                guard page == 1 else { return Self.list([]) }
                firstPageRequests += 1
                switch state {
                case .anonymous, .loggedOut:
                    return Self.list([Self.category(id: 1, name: "Public")])
                case .authenticated:
                    return Self.list([
                        Self.category(id: 1, name: "Public"),
                        Self.category(id: 2, name: "Restricted"),
                    ])
                }
            }
        )

        let anonymous = try await api.fetchAllCategories()
        XCTAssertEqual(anonymous.categoryList.categories.map(\.id), [1])
        _ = try await api.fetchAllCategories()
        XCTAssertEqual(firstPageRequests, 1, "second anonymous read should use the cache")

        state = .authenticated
        postAuthenticationChange()
        let authenticated = try await api.fetchAllCategories()
        XCTAssertEqual(authenticated.categoryList.categories.map(\.id), [1, 2])
        XCTAssertEqual(firstPageRequests, 2)

        state = .loggedOut
        postAuthenticationChange()
        let loggedOut = try await api.fetchAllCategories()
        XCTAssertEqual(loggedOut.categoryList.categories.map(\.id), [1])
        XCTAssertEqual(firstPageRequests, 3)
    }

    private func postAuthenticationChange() {
        NotificationCenter.default.post(
            name: .discourseAuthDidChange,
            object: nil,
            userInfo: ["baseURL": "https://forum.example.com"]
        )
    }

    private static func list(_ categories: [DiscourseCategory]) -> DiscourseCategoryList {
        DiscourseCategoryList(categoryList: .init(categories: categories))
    }

    private static func category(id: Int, name: String) -> DiscourseCategory {
        DiscourseCategory(id: id, name: name, slug: "category-\(id)")
    }
}
