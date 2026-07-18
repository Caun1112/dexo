import XCTest
@testable import dexo

final class HTTPConnectRequestParserTests: XCTestCase {
    func testParsesDomainAndPort() throws {
        let request = try HTTPConnectRequestParser.parse(
            Data("CONNECT linux.do:443 HTTP/1.1\r\nHost: linux.do:443\r\n\r\n".utf8)
        )

        XCTAssertEqual(request, .init(host: "linux.do", port: 443))
    }

    func testParsesBracketedIPv6Address() throws {
        let request = try HTTPConnectRequestParser.parse(
            Data("CONNECT [2606:4700:20::6814:10ea]:8443 HTTP/1.1\r\n\r\n".utf8)
        )

        XCTAssertEqual(request, .init(host: "2606:4700:20::6814:10ea", port: 8443))
    }

    func testRejectsNonConnectMethod() {
        XCTAssertThrowsError(
            try HTTPConnectRequestParser.parse(Data("GET https://linux.do/ HTTP/1.1\r\n\r\n".utf8))
        ) { error in
            XCTAssertEqual(error as? HTTPConnectRequestParser.ParseError, .unsupportedMethod)
        }
    }

    func testRejectsMalformedAuthorities() {
        let invalidAuthorities = [
            "linux.do",
            "linux.do:0",
            "linux.do:65536",
            "linux.do:not-a-port",
            "2606:4700:20::6814:10ea:443",
            "[2606:4700:20::6814:10ea]443",
        ]

        for authority in invalidAuthorities {
            XCTAssertThrowsError(
                try HTTPConnectRequestParser.parse(
                    Data("CONNECT \(authority) HTTP/1.1\r\n\r\n".utf8)
                ),
                "Expected \(authority) to be rejected"
            ) { error in
                XCTAssertEqual(error as? HTTPConnectRequestParser.ParseError, .invalidAuthority)
            }
        }
    }
}

final class HTTPProxyRequestParserTests: XCTestCase {
    func testParsesFragmentedRequestBody() throws {
        var parser = HTTPProxyRequestParser()
        try parser.append(Data("POST /session HTTP/1.1\r\nHost: linux.do\r\nContent-Length: 5\r\n\r\nhe".utf8))

        XCTAssertNil(try parser.nextRequest())

        try parser.append(Data("llo".utf8))
        let request = try XCTUnwrap(parser.nextRequest())
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/session")
        XCTAssertEqual(request.values(forHeader: "host"), ["linux.do"])
        XCTAssertEqual(request.body, Data("hello".utf8))
    }

    func testParsesPipelinedRequests() throws {
        var parser = HTTPProxyRequestParser()
        try parser.append(Data(
            "GET /one HTTP/1.1\r\nHost: linux.do\r\n\r\n"
                .appending("GET /two HTTP/1.1\r\nHost: linux.do\r\nConnection: close\r\n\r\n")
                .utf8
        ))

        XCTAssertEqual(try parser.nextRequest()?.target, "/one")
        XCTAssertEqual(try parser.nextRequest()?.target, "/two")
        XCTAssertNil(try parser.nextRequest())
    }

    func testRejectsChunkedRequestBody() throws {
        var parser = HTTPProxyRequestParser()
        try parser.append(Data(
            "POST /upload HTTP/1.1\r\nHost: linux.do\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
        ))

        XCTAssertThrowsError(try parser.nextRequest()) { error in
            XCTAssertEqual(
                error as? HTTPProxyRequestParser.ParseError,
                .unsupportedTransferEncoding
            )
        }
    }
}

final class HTTPProxyResponseHeaderTests: XCTestCase {
    func testKeepsExpiresDateCommaInsideSingleCookie() {
        let header = "cf_clearance=value; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Secure; HttpOnly"

        XCTAssertEqual(
            HTTPProxyResponseHeader.splitCombinedSetCookieHeader(header),
            [header]
        )
    }

    func testSplitsFlattenedCookiesWithoutLosingAttributes() {
        let header = "cf_clearance=value; Secure; SameSite=None; Partitioned, __cf_bm=other; Path=/; Secure"

        XCTAssertEqual(
            HTTPProxyResponseHeader.splitCombinedSetCookieHeader(header),
            [
                "cf_clearance=value; Secure; SameSite=None; Partitioned",
                "__cf_bm=other; Path=/; Secure",
            ]
        )
    }

    func testKeepsCommaInsideQuotedCookieValue() {
        let header = "example=\"one,two\"; Path=/, second=value; Secure"

        XCTAssertEqual(
            HTTPProxyResponseHeader.splitCombinedSetCookieHeader(header),
            [
                "example=\"one,two\"; Path=/",
                "second=value; Secure",
            ]
        )
    }

    func testExtractsCookieNameWithoutValue() {
        XCTAssertEqual(
            HTTPProxyResponseHeader.cookieName(from: " cf_clearance=secret; Secure"),
            "cf_clearance"
        )
    }
}
