import XCTest
@testable import dexo

final class ForumURLPolicyTests: XCTestCase {
    func testNormalizeAddsHTTPSAndCanonicalizesHostAndTrailingSlash() throws {
        XCTAssertEqual(
            try ForumURLPolicy.normalize("  Forum.Example.COM/  "),
            "https://forum.example.com"
        )
    }

    func testNormalizePreservesHTTPSPortAndSubpath() throws {
        XCTAssertEqual(
            try ForumURLPolicy.normalize("https://Forum.Example.com:8443/community///"),
            "https://forum.example.com:8443/community"
        )
    }

    func testNormalizeRejectsHTTPAndOtherExplicitSchemes() {
        assertValidationError(.insecureScheme, for: "http://forum.example.com")
        assertValidationError(.insecureScheme, for: "ftp://forum.example.com")
    }

    func testNormalizeRejectsCredentialsQueryAndFragment() {
        assertValidationError(
            .credentialsNotAllowed,
            for: "https://user:secret@forum.example.com"
        )
        assertValidationError(
            .queryNotAllowed,
            for: "https://forum.example.com?token=secret"
        )
        assertValidationError(
            .fragmentNotAllowed,
            for: "https://forum.example.com#latest"
        )
    }

    func testNormalizeRejectsEmptyMalformedAndHostlessValues() {
        assertValidationError(.empty, for: " \n ")
        assertValidationError(.invalidURL, for: "https:/forum.example.com")
        assertValidationError(.invalidURL, for: "https://")
        assertValidationError(.invalidURL, for: "https://forum example.com")
    }

    func testHTTPSUpgradeCandidatePreservesPortAndSubpathWithoutCredentials() throws {
        XCTAssertEqual(
            try ForumURLPolicy.httpsUpgradeCandidate(
                from: "http://Forum.Example.com:8080/community/"
            ),
            "https://forum.example.com:8080/community"
        )
        XCTAssertFalse(ForumURLPolicy.canUpgradeToHTTPS("https://forum.example.com"))
        XCTAssertFalse(ForumURLPolicy.canUpgradeToHTTPS("http://user:secret@forum.example.com"))
    }

    func testIsSecureUsesTheSameValidationRules() {
        XCTAssertTrue(ForumURLPolicy.isSecure("https://forum.example.com/community"))
        XCTAssertFalse(ForumURLPolicy.isSecure("http://forum.example.com"))
        XCTAssertFalse(ForumURLPolicy.isSecure("forum.example.com"))
        XCTAssertFalse(ForumURLPolicy.isSecure(" https://forum.example.com "))
        XCTAssertFalse(ForumURLPolicy.isSecure("https://forum.example.com?token=secret"))
    }

    func testRequestPolicyAllowsOnlyTheForumOrigin() throws {
        let baseURL = "https://forum.example.com:8443/community"

        XCTAssertTrue(ForumURLPolicy.allowsRequest(
            try XCTUnwrap(URL(string: "https://forum.example.com:8443/latest.json?page=1")),
            for: baseURL
        ))
        XCTAssertFalse(ForumURLPolicy.allowsRequest(
            try XCTUnwrap(URL(string: "https://cdn.example.com/latest.json")),
            for: baseURL
        ))
        XCTAssertFalse(ForumURLPolicy.allowsRequest(
            try XCTUnwrap(URL(string: "https://forum.example.com/latest.json")),
            for: baseURL
        ))
        XCTAssertFalse(ForumURLPolicy.allowsRequest(
            try XCTUnwrap(URL(string: "http://forum.example.com:8443/latest.json")),
            for: baseURL
        ))
    }

    func testLinuxDoMessageBusIsTheOnlyCrossOriginException() throws {
        let messageBusURL = try XCTUnwrap(URL(string: "https://ping.ldstatic.com/message-bus/client/poll"))

        XCTAssertTrue(ForumURLPolicy.allowsRequest(messageBusURL, for: "https://linux.do"))
        XCTAssertFalse(ForumURLPolicy.allowsRequest(messageBusURL, for: "https://linux.do.evil.example"))
        XCTAssertFalse(ForumURLPolicy.allowsRequest(messageBusURL, for: "https://example.com/linux.do"))
        XCTAssertFalse(ForumURLPolicy.allowsRequest(
            try XCTUnwrap(URL(string: "https://other.ldstatic.com/message-bus/client/poll")),
            for: "https://linux.do"
        ))
    }

    private func assertValidationError(
        _ expected: ForumURLPolicy.ValidationError,
        for value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ForumURLPolicy.normalize(value),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ForumURLPolicy.ValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
