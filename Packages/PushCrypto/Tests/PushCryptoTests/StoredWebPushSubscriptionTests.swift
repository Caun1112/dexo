import Foundation
import Testing
@testable import PushCrypto

@Test func legacyStoredSubscriptionDefaultsToDeliveryEnabled() throws {
    let subscription = try makeSubscription()
    let encoded = try JSONEncoder().encode(subscription)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "deliveryEnabled")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(
        StoredWebPushSubscription.self,
        from: legacyData
    )

    #expect(decoded.deliveryEnabled)
}

@Test func retiredStoredSubscriptionRoundTripsWithoutLosingKeys() throws {
    let active = try makeSubscription()
    let retired = active.settingDeliveryEnabled(false)

    let data = try JSONEncoder().encode(retired)
    let decoded = try JSONDecoder().decode(
        StoredWebPushSubscription.self,
        from: data
    )

    #expect(!decoded.deliveryEnabled)
    #expect(decoded.subscriptionID == active.subscriptionID)
    #expect(decoded.keyMaterial == active.keyMaterial)
}

private func makeSubscription() throws -> StoredWebPushSubscription {
    StoredWebPushSubscription(
        subscriptionID: "test-subscription",
        forumBaseURL: try #require(URL(string: "https://forum.example.com")),
        forumUsername: "alice",
        keyMaterial: try WebPushKeyMaterial.generate()
    )
}
