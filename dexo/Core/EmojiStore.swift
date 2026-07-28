import CryptoKit
import Foundation

enum EmojiStore {
    private static let cacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("EmojiCacheV3", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let aliasToName: [String: String] = {
        guard let url = Bundle.main.url(forResource: "aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        var result: [String: String] = [:]
        for (name, aliases) in map {
            for alias in aliases {
                result[alias] = name
            }
        }
        return result
    }()

    // Built once after load/fetch; queried per cell
    private(set) static var lookupMap: [String: String] = [:]
    private(set) static var groupedEntries: [String: [DiscourseEmojiEntry]] = [:]
    private(set) static var loadedBaseURL: String?

    static func load(for baseURL: String, assetBaseURL: String) -> Bool {
        let file = cacheFile(for: baseURL)
        guard let data = try? Data(contentsOf: file),
              let groups = try? JSONDecoder().decode([String: [DiscourseEmojiEntry]].self, from: data)
        else { return false }
        install(groups, for: baseURL, assetBaseURL: assetBaseURL)
        return true
    }

    static func save(
        _ groups: [String: [DiscourseEmojiEntry]],
        for baseURL: String,
        assetBaseURL: String
    ) {
        let resolvedGroups = resolve(groups, assetBaseURL: assetBaseURL)
        installResolved(resolvedGroups, for: baseURL)
        let file = cacheFile(for: baseURL)
        guard let data = try? JSONEncoder().encode(resolvedGroups) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func url(for code: String) -> String? {
        let name = aliasToName[code] ?? code
        return lookupMap[name]
    }

    static func lookup(for code: String) -> String? {
        return lookupMap[code]
    }

    static func catalogGroups() -> [DiscourseEmojiGroup] {
        let preferredOrder = [
            "smileys_&_emotion",
            "people_&_body",
            "animals_&_nature",
            "food_&_drink",
            "activities",
            "travel_&_places",
            "objects",
            "symbols",
            "flags",
            "default",
        ]
        let order = Dictionary(uniqueKeysWithValues: preferredOrder.enumerated().map { ($1, $0) })
        return groupedEntries
            .map { DiscourseEmojiGroup(id: $0.key, emojis: $0.value) }
            .sorted {
                let lhs = order[$0.id] ?? preferredOrder.count
                let rhs = order[$1.id] ?? preferredOrder.count
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
    }

    private static func install(
        _ groups: [String: [DiscourseEmojiEntry]],
        for baseURL: String,
        assetBaseURL: String
    ) {
        installResolved(resolve(groups, assetBaseURL: assetBaseURL), for: baseURL)
    }

    private static func installResolved(
        _ groups: [String: [DiscourseEmojiEntry]],
        for baseURL: String
    ) {
        groupedEntries = groups
        loadedBaseURL = baseURL
        var map: [String: String] = [:]
        for entry in groups.values.joined() {
            map[entry.name] = entry.url
        }
        lookupMap = map
    }

    private static func resolve(
        _ groups: [String: [DiscourseEmojiEntry]],
        assetBaseURL: String
    ) -> [String: [DiscourseEmojiEntry]] {
        groups.mapValues { entries in
            entries.map { entry in
                DiscourseEmojiEntry(
                    name: entry.name,
                    url: resolvedURL(entry.url, assetBaseURL: assetBaseURL),
                    searchAliases: entry.searchAliases,
                    group: entry.group,
                    tonable: entry.tonable
                )
            }
        }
    }

    private static func resolvedURL(_ rawURL: String, assetBaseURL: String) -> String {
        if rawURL.hasPrefix("https://") || rawURL.hasPrefix("http://") {
            return rawURL
        }
        if rawURL.hasPrefix("//") {
            return "https:\(rawURL)"
        }
        let base = assetBaseURL.hasSuffix("/") ? String(assetBaseURL.dropLast()) : assetBaseURL
        return rawURL.hasPrefix("/") ? base + rawURL : base + "/" + rawURL
    }

    private static func cacheFile(for baseURL: String) -> URL {
        let hash = SHA256.hash(data: Data(baseURL.utf8))
        let prefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(prefix).json")
    }
}
