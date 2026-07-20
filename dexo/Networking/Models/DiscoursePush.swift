import Foundation

struct DiscoursePushSiteSettings: Decodable {
    let enableDesktopPushNotifications: Bool?
    let vapidPublicKeyBytes: String?

    enum CodingKeys: String, CodingKey {
        case enableDesktopPushNotifications = "enable_desktop_push_notifications"
        case vapidPublicKeyBytes = "vapid_public_key_bytes"
    }

    func validatedVAPIDPublicKey() throws -> Data {
        guard enableDesktopPushNotifications == true, let vapidPublicKeyBytes else {
            throw PushSubscriptionError.forumUnsupported
        }
        let values = vapidPublicKeyBytes.split(separator: "|", omittingEmptySubsequences: false)
        guard values.count == 65 else { throw PushSubscriptionError.invalidForumKey }
        let bytes = try values.map { value -> UInt8 in
            guard let byte = UInt8(value) else { throw PushSubscriptionError.invalidForumKey }
            return byte
        }
        guard bytes.first == 0x04 else { throw PushSubscriptionError.invalidForumKey }
        return Data(bytes)
    }
}

struct EmptyDiscourseResponse: Decodable {}
