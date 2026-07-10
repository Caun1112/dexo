import XCTest
@testable import dexo

final class AddForumViewModelTests: XCTestCase {
    func testChallengeRequiredIsReturnedForLinuxDo() async {
        let loader: AddForumViewModel.BasicInfoLoader = { _ in
            throw DiscourseAPIError(
                messages: ["Cloudflare challenge required"],
                errorType: "challenge_required"
            )
        }
        let viewModel = AddForumViewModel(basicInfoLoader: loader)
        viewModel.urlString = "https://linux.do"

        let result = await viewModel.addForum()

        guard case .challengeRequired = result else {
            return XCTFail("Expected a Cloudflare challenge result")
        }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(
            viewModel.errorMessage,
            String(localized: "add_forum.error.challenge")
        )
    }

    func testNonLinuxChallengeRemainsAConnectionFailure() async {
        let loader: AddForumViewModel.BasicInfoLoader = { _ in
            throw DiscourseAPIError(
                messages: ["Cloudflare challenge required"],
                errorType: "challenge_required"
            )
        }
        let viewModel = AddForumViewModel(basicInfoLoader: loader)
        viewModel.urlString = "https://example.com"

        let result = await viewModel.addForum()

        guard case .failed = result else {
            return XCTFail("Expected a regular failure for a non-linux.do forum")
        }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.errorMessage?.hasPrefix("Could not connect:") == true)
    }
}
