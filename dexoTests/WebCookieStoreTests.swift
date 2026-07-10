import XCTest
@testable import dexo

final class WebCookieStoreTests: XCTestCase {
    func testDomainCookieRequiresDotBoundary() {
        XCTAssertTrue(WebCookieStore.cookieDomain(".example.com", matchesHost: "forum.example.com"))
        XCTAssertTrue(WebCookieStore.cookieDomain(".example.com", matchesHost: "example.com"))
        XCTAssertFalse(WebCookieStore.cookieDomain(".example.com", matchesHost: "notexample.com"))
        XCTAssertFalse(WebCookieStore.cookieDomain(".example.com", matchesHost: "example.com.evil.test"))
    }

    func testHostOnlyCookieRequiresExactHost() {
        XCTAssertTrue(WebCookieStore.cookieDomain("forum.example.com", matchesHost: "forum.example.com"))
        XCTAssertFalse(WebCookieStore.cookieDomain("forum.example.com", matchesHost: "sub.forum.example.com"))
    }

    func testDomainMatchingIsCaseInsensitive() {
        XCTAssertTrue(WebCookieStore.cookieDomain(".Example.COM", matchesHost: "Forum.Example.com"))
    }
}
