import Foundation

public struct ForumNotificationMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let baseURL: String
    public let domain: String
    public let iconFileName: String?
    public let iconSourceURL: String?

    public init(
        name: String,
        baseURL: String,
        domain: String,
        iconFileName: String?,
        iconSourceURL: String?
    ) {
        self.name = name
        self.baseURL = baseURL
        self.domain = domain
        self.iconFileName = iconFileName
        self.iconSourceURL = iconSourceURL
    }
}

public enum ForumNotificationMetadataStoreError: Error {
    case invalidConfiguration
    case containerUnavailable
    case invalidFileName
}

public struct ForumNotificationMetadataStore: Sendable {
    private let appGroupIdentifier: String

    public init(appGroupIdentifier: String) throws {
        guard !appGroupIdentifier.isEmpty,
              !appGroupIdentifier.contains("$(") else {
            throw ForumNotificationMetadataStoreError.invalidConfiguration
        }
        self.appGroupIdentifier = appGroupIdentifier
    }

    public func loadAll() throws -> [ForumNotificationMetadata] {
        let indexURL = try containerURL().appendingPathComponent("ForumPushMetadata.json")
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return try JSONDecoder().decode([ForumNotificationMetadata].self, from: data)
    }

    public func metadata(forBaseURL baseURL: URL) throws -> ForumNotificationMetadata? {
        guard let expected = Self.normalizedBaseURL(baseURL) else { return nil }
        return try loadAll().first { metadata in
            guard let candidate = URL(string: metadata.baseURL) else { return false }
            return Self.normalizedBaseURL(candidate) == expected
        }
    }

    public func save(_ metadata: [ForumNotificationMetadata]) throws {
        let data = try JSONEncoder().encode(metadata)
        let indexURL = try containerURL().appendingPathComponent("ForumPushMetadata.json")
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func saveIcon(_ data: Data, fileName: String) throws -> URL {
        let url = try iconURL(fileName: fileName, createDirectory: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    public func iconURL(for metadata: ForumNotificationMetadata) throws -> URL? {
        guard let fileName = metadata.iconFileName else { return nil }
        let url = try iconURL(fileName: fileName, createDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func removeUnreferencedIcons(keeping fileNames: Set<String>) throws {
        let directory = try iconsDirectory(create: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for file in files where !fileNames.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func iconURL(fileName: String, createDirectory: Bool) throws -> URL {
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.contains("/") else {
            throw ForumNotificationMetadataStoreError.invalidFileName
        }
        return try iconsDirectory(create: createDirectory).appendingPathComponent(fileName)
    }

    private func iconsDirectory(create: Bool) throws -> URL {
        let directory = try containerURL().appendingPathComponent(
            "ForumNotificationIcons",
            isDirectory: true
        )
        if create {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    private func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw ForumNotificationMetadataStoreError.containerUnavailable
        }
        return url
    }

    private static func normalizedBaseURL(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }
}
