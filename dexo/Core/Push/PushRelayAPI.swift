import Foundation

struct PushRelayEndpointRequest: Encodable, Sendable {
    let version: Int
    let apnsToken: String
    let apnsEnvironment: String
    let subscriptionID: String
    let forumBaseURL: String
    let forumVAPIDPublicKey: String

    enum CodingKeys: String, CodingKey {
        case version
        case apnsToken = "apns_token"
        case apnsEnvironment = "apns_environment"
        case subscriptionID = "subscription_id"
        case forumBaseURL = "forum_base_url"
        case forumVAPIDPublicKey = "forum_vapid_public_key"
    }
}

struct PushRelayEndpointResponse: Decodable, Sendable {
    let version: Int
    let endpoint: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case version, endpoint
        case expiresAt = "expires_at"
    }
}

final class PushRelayAPI: Sendable {
    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func createEndpoint(_ input: PushRelayEndpointRequest) async throws -> PushRelayEndpointResponse {
        let url = baseURL.appendingPathComponent("v1/endpoints")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(input)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw PushSubscriptionError.relayRejected
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let output = try decoder.decode(PushRelayEndpointResponse.self, from: data)
        guard output.version == 1,
              output.endpoint.hasPrefix(baseURL.absoluteString + "/v1/webpush/") else {
            throw PushSubscriptionError.relayRejected
        }
        return output
    }
}
