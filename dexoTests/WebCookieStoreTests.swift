import Foundation
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

    func testCloudflareCookieHeaderExcludesWebLoginSession() throws {
        let cookies = try [
            makeCookie(name: "_t", value: "web-session"),
            makeCookie(name: "cf_clearance", value: "clearance"),
            makeCookie(name: "__cf_bm", value: "bot-management"),
            makeCookie(name: "unrelated", value: "ignored"),
        ]

        XCTAssertEqual(
            WebCookieStore.cloudflareCookieHeader(from: cookies),
            "__cf_bm=bot-management; cf_clearance=clearance"
        )
    }

    func testCloudflareCookieNameFilterCoversChallengeCookiesOnly() {
        XCTAssertTrue(WebCookieStore.isCloudflareCookieName("CF_CLEARANCE"))
        XCTAssertTrue(WebCookieStore.isCloudflareCookieName("cf_chl_2"))
        XCTAssertTrue(WebCookieStore.isCloudflareCookieName("_cfuvid"))
        XCTAssertFalse(WebCookieStore.isCloudflareCookieName("_t"))
        XCTAssertFalse(WebCookieStore.isCloudflareCookieName("session"))
    }

    private func makeCookie(name: String, value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .domain: "linux.do",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
        ]))
    }
}
