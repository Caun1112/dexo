import Foundation

/// Product-level topic feed semantics. The underlying Discourse route is an
/// implementation detail: both activity and creation feeds use `/latest`, but
/// the latter asks the server to order by `created_at` before pagination.
enum TopicFeedMode: String, CaseIterable, Equatable {
    case activity
    case created
    case hot
    case top

    var timestampKind: TopicTimestampKind {
        self == .created ? .created : .activity
    }

    var listPathComponent: String {
        switch self {
        case .activity, .created:
            return "latest"
        case .hot:
            return "hot"
        case .top:
            return "top"
        }
    }

    var orderQueryValue: String? {
        self == .created ? "created" : nil
    }
}
