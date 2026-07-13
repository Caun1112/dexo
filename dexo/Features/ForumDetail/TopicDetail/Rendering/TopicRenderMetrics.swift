import Foundation
import os.signpost

nonisolated enum TopicRenderMetrics {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "dexo", category: "TopicRendering")

    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try work()
    }

    static func event(_ name: StaticString, _ message: StaticString = "") {
        os_signpost(.event, log: log, name: name, "%{public}s", String(describing: message))
    }
}
