import UIKit

import Perception

@Perceptible
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Appearance

    enum AppearanceMode: Int, CaseIterable {
        case system = 0
        case light = 1
        case dark = 2

        var title: String {
            switch self {
            case .system: return String(localized: "appearance.system")
            case .light: return String(localized: "appearance.light")
            case .dark: return String(localized: "appearance.dark")
            }
        }

        var userInterfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: "appearanceMode")) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    func applyAppearance() {
        let style = appearanceMode.userInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    // MARK: - General

    var autoOpenLastForum: Bool {
        get { defaults.bool(forKey: "autoOpenLastForum") }
        set { defaults.set(newValue, forKey: "autoOpenLastForum") }
    }

    var lastOpenedForumId: Int64? {
        get {
            guard defaults.object(forKey: "lastOpenedForumId") != nil else { return nil }
            return Int64(defaults.integer(forKey: "lastOpenedForumId"))
        }
        set {
            if let value = newValue {
                defaults.set(Int(value), forKey: "lastOpenedForumId")
            } else {
                defaults.removeObject(forKey: "lastOpenedForumId")
            }
        }
    }

    var hasShownAutoOpenPrompt: Bool {
        get { defaults.bool(forKey: "hasShownAutoOpenPrompt") }
        set { defaults.set(newValue, forKey: "hasShownAutoOpenPrompt") }
    }

    // MARK: - Theme

    var selectedThemeId: String {
        get { defaults.string(forKey: "selectedThemeId") ?? "default" }
        set { defaults.set(newValue, forKey: "selectedThemeId") }
    }

    var customThemeSchemes: [CustomThemeScheme] {
        get {
            guard let data = defaults.data(forKey: "customThemeSchemes"),
                  let schemes = try? JSONDecoder().decode([CustomThemeScheme].self, from: data)
            else { return [] }
            return schemes
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "customThemeSchemes")
            }
        }
    }

    func customThemeScheme(id: String) -> CustomThemeScheme? {
        customThemeSchemes.first { $0.id == id }
    }

    func saveCustomThemeScheme(_ scheme: CustomThemeScheme) {
        var schemes = customThemeSchemes
        if let idx = schemes.firstIndex(where: { $0.id == scheme.id }) {
            schemes[idx] = scheme
        } else {
            schemes.append(scheme)
        }
        customThemeSchemes = schemes
    }

    func deleteCustomThemeScheme(id: String) {
        var schemes = customThemeSchemes
        schemes.removeAll { $0.id == id }
        customThemeSchemes = schemes
    }

    // MARK: - Font Size

    /// Whether to follow the system Dynamic Type setting.
    var followSystemFontSize: Bool {
        get {
            // Default to true if key has never been set
            if defaults.object(forKey: "followSystemFontSize") == nil { return true }
            return defaults.bool(forKey: "followSystemFontSize")
        }
        set { defaults.set(newValue, forKey: "followSystemFontSize") }
    }

    /// Font size level: -3 … +4, where 0 is the default.
    var fontSizeLevel: Int {
        get { defaults.integer(forKey: "fontSizeLevel") }
        set { defaults.set(newValue, forKey: "fontSizeLevel") }
    }

    /// Scale factor derived from the app-level font size setting.
    var appFontScale: CGFloat {
        switch fontSizeLevel {
        case -3: return 0.82
        case -2: return 0.88
        case -1: return 0.94
        case  0: return 1.0
        case  1: return 1.08
        case  2: return 1.16
        case  3: return 1.25
        case  4: return 1.35
        default: return 1.0
        }
    }

    // MARK: - Boost Display

    enum TopicRenderingMode: Int, CaseIterable {
        case virtualized = 0
        case legacy = 1

        var title: String {
            switch self {
            case .virtualized: return String(localized: "settings.topic_rendering.virtualized")
            case .legacy: return String(localized: "settings.topic_rendering.legacy")
            }
        }
    }

    /// New installs use block-level virtualization. The preference is read
    /// when a topic controller is created; changing it never hot-swaps an open
    /// detail screen.
    var topicRenderingMode: TopicRenderingMode {
        get { TopicRenderingMode(rawValue: defaults.integer(forKey: "topicRenderingMode")) ?? .virtualized }
        set { defaults.set(newValue.rawValue, forKey: "topicRenderingMode") }
    }

    enum BoostDisplayMode: Int, CaseIterable {
        case danmaku = 0
        case expand = 1

        var title: String {
            switch self {
            case .expand: return String(localized: "settings.boost_display.expand")
            case .danmaku: return String(localized: "settings.boost_display.danmaku")
            }
        }
    }

    /// Whether the topic detail page should default to the indented tree
    /// rendering. Persisted between launches so the user doesn't have to flip
    /// the nav-bar toggle every time they open a topic.
    var topicTreeMode: Bool {
        get { defaults.bool(forKey: "topicTreeMode") }
        set { defaults.set(newValue, forKey: "topicTreeMode") }
    }

    /// Sort order for the nested tree endpoint. One of "top", "new", "old".
    /// Persists the user's last choice across topic opens.
    var topicTreeSort: String {
        get { defaults.string(forKey: "topicTreeSort") ?? "top" }
        set { defaults.set(newValue, forKey: "topicTreeSort") }
    }

    var boostDisplayMode: BoostDisplayMode {
        get { BoostDisplayMode(rawValue: defaults.integer(forKey: "boostDisplayMode")) ?? .danmaku }
        set { defaults.set(newValue.rawValue, forKey: "boostDisplayMode") }
    }

    // MARK: - DNS over HTTPS

    enum DoHProvider: Int, CaseIterable {
        case cloudflare = 0
        case google = 1
        case quad9 = 2
        case alidns = 3
        case custom = 4

        var title: String {
            switch self {
            case .cloudflare: return "Cloudflare (1.1.1.1)"
            case .google: return "Google (8.8.8.8)"
            case .quad9: return "Quad9 (9.9.9.9)"
            case .alidns: return "AliDNS (223.5.5.5)"
            case .custom: return String(localized: "doh.provider.custom")
            }
        }

        var url: String {
            switch self {
            case .cloudflare: return "https://1.1.1.1/dns-query"
            case .google: return "https://8.8.8.8/resolve"
            case .quad9: return "https://9.9.9.9:5053/dns-query"
            case .alidns: return "https://dns.alidns.com/resolve"
            case .custom: return ""
            }
        }
    }

    var dohEnabled: Bool {
        get { defaults.bool(forKey: "dohEnabled") }
        set { defaults.set(newValue, forKey: "dohEnabled") }
    }

    var dohProvider: DoHProvider {
        get { DoHProvider(rawValue: defaults.integer(forKey: "dohProvider")) ?? .cloudflare }
        set { defaults.set(newValue.rawValue, forKey: "dohProvider") }
    }

    var dohCustomURL: String {
        get { defaults.string(forKey: "dohCustomURL") ?? "" }
        set { defaults.set(newValue, forKey: "dohCustomURL") }
    }

    var dohServerURL: String {
        if dohProvider == .custom {
            return dohCustomURL
        }
        return dohProvider.url
    }
}
