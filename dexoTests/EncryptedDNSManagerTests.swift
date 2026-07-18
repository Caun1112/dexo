import XCTest
@testable import dexo

final class EncryptedDNSManagerTests: XCTestCase {
    func testNormalizationAddsHTTPSScheme() {
        XCTAssertEqual(
            EncryptedDNSManager.normalizedServerURL(" edge.47258.xyz/linuxdo ")?.absoluteString,
            "https://edge.47258.xyz/linuxdo"
        )
    }

    func testNormalizationPreservesHTTPSPathPortAndQuery() {
        XCTAssertEqual(
            EncryptedDNSManager.normalizedServerURL(
                "https://dns.example.com:8443/dns-query?token=value"
            )?.absoluteString,
            "https://dns.example.com:8443/dns-query?token=value"
        )
    }

    func testNormalizationRejectsUnsafeOrMalformedEndpoints() {
        XCTAssertNil(EncryptedDNSManager.normalizedServerURL(""))
        XCTAssertNil(EncryptedDNSManager.normalizedServerURL("http://dns.example.com/dns-query"))
        XCTAssertNil(EncryptedDNSManager.normalizedServerURL("https://user:password@dns.example.com/dns-query"))
        XCTAssertNil(EncryptedDNSManager.normalizedServerURL("https://dns.example.com/dns-query#fragment"))
        XCTAssertNil(EncryptedDNSManager.normalizedServerURL("https://"))
    }
}
