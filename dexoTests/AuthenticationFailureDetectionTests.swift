import Foundation
import XCTest

@testable import dexo

final class AuthenticationFailureDetectionTests: XCTestCase {
    func testUnauthorizedStatusExpiresAuthenticationWithoutBody() {
        XCTAssertTrue(isDiscourseAuthenticationFailure(statusCode: 401, data: nil))
    }

    func testNotLoggedInResponseExpiresAuthentication() throws {
        let data = try XCTUnwrap(
            #"{"errors":["You need to log in"],"error_type":"not_logged_in"}"#
                .data(using: .utf8)
        )

        XCTAssertTrue(isDiscourseAuthenticationFailure(statusCode: 403, data: data))
    }

    func testInvalidAccessDoesNotExpireAuthentication() throws {
        let data = try XCTUnwrap(
            #"{"errors":["You are not permitted"],"error_type":"invalid_access"}"#
                .data(using: .utf8)
        )

        XCTAssertFalse(isDiscourseAuthenticationFailure(statusCode: 403, data: data))
    }

    func testGenericForbiddenDoesNotExpireAuthentication() throws {
        let data = try XCTUnwrap(#"{"errors":["Forbidden"]}"#.data(using: .utf8))

        XCTAssertFalse(isDiscourseAuthenticationFailure(statusCode: 403, data: data))
    }
}
