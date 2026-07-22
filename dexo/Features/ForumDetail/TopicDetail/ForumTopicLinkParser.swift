import Foundation

struct ForumTopicLinkRoute: Equatable {
    let topicId: Int
    let floor: Int?
}

enum ForumTopicLinkParser {
    static func parse(_ url: URL, baseURL: String) -> ForumTopicLinkRoute? {
        guard let baseHost = URL(string: baseURL)?.host,
              let linkHost = url.host,
              linkHost.caseInsensitiveCompare(baseHost) == .orderedSame
        else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        guard let topicIndex = components.firstIndex(of: "t") else { return nil }

        let tail = components.dropFirst(topicIndex + 1)
        guard !tail.isEmpty else { return nil }

        let topicIdIndex: ArraySlice<String>.Index
        if Int(tail[tail.startIndex]) != nil {
            topicIdIndex = tail.startIndex
        } else {
            let index = tail.index(after: tail.startIndex)
            guard index < tail.endIndex else { return nil }
            topicIdIndex = index
        }

        guard let topicId = Int(tail[topicIdIndex]) else { return nil }
        let floorIndex = tail.index(after: topicIdIndex)
        let floor = floorIndex < tail.endIndex ? Int(tail[floorIndex]) : nil
        return ForumTopicLinkRoute(topicId: topicId, floor: floor)
    }
}
