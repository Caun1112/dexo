import Foundation
import Perception
import UIKit

/// Tunables for a ReadBoost run. Mirrors the knobs the original userscript
/// exposed so the pacing can be tuned per forum without a rebuild.
struct ReadBoostConfig: Equatable {
    var baseDelay: Int = 2500
    var randomDelayRange: Int = 800
    var minReqSize: Int = 8
    var maxReqSize: Int = 20
    var minReadTime: Int = 800
    var maxReadTime: Int = 3000
    var autoStart: Bool = false
    var startFromCurrent: Bool = false
    var hasAgreed: Bool = false

    static let defaults = ReadBoostConfig()

    /// Clamp every field into a range the server will accept, keeping the
    /// min/max pairs ordered even when the user typed them the other way round.
    func normalized() -> ReadBoostConfig {
        var result = self
        result.baseDelay = min(max(baseDelay, 0), 600_000)
        result.randomDelayRange = min(max(randomDelayRange, 0), 600_000)
        result.minReqSize = min(max(minReqSize, 1), 200)
        result.maxReqSize = min(max(maxReqSize, result.minReqSize), 300)
        result.minReadTime = min(max(minReadTime, 100), 60_000)
        result.maxReadTime = min(max(maxReadTime, result.minReadTime), 120_000)
        return result
    }
}

enum ReadBoostStatus {
    case idle
    case running
    case stopping
    case completed
    case failed
    /// Cloudflare intercepted a batch; the run is paused while the user clears
    /// the challenge, and resumes on its own if they don't.
    case awaitingChallenge
}

extension Notification.Name {
    /// Posted when a ReadBoost batch hits a Cloudflare challenge. The topic
    /// screen listens and opens the challenge page so the user can tap through.
    static let readBoostChallengeRequired = Notification.Name("readBoostChallengeRequired")
}

/// Drives the ReadBoost batch upload of `/topics/timings`.
///
/// A single app-wide instance: a run outlives the topic screen that started it,
/// so leaving the topic (or backgrounding the app) doesn't abort the sweep.
@Perceptible
final class ReadBoostManager {
    static let shared = ReadBoostManager()

    /// Retries per batch before the whole run fails. Deliberately generous —
    /// linux.do answers bursts of timing POSTs with sporadic 429s.
    static let maxBatchRetries = 6
    /// Pause between retries of the same batch.
    private static let retryDelayMilliseconds = 2000
    /// How long a Cloudflare pause waits for the user before resuming anyway.
    /// Long enough to solve the challenge by hand, short enough that a run
    /// left unattended in the background keeps making progress.
    private static let challengeWaitMilliseconds = 90_000

    private let defaults: UserDefaults

    private(set) var config: ReadBoostConfig
    private(set) var status: ReadBoostStatus = .idle
    private(set) var message: String = String(localized: "readboost.title")
    private(set) var topicId: Int?
    private(set) var totalReplies: Int = 0
    /// Highest post number confirmed uploaded in this run.
    private(set) var processedEnd: Int = 0
    private(set) var errorDescription: String?

    private var runTask: Task<Void, Never>?
    private var shouldStop = false
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// Set when the user finishes (or dismisses) the challenge page, so a
    /// paused run picks up immediately instead of waiting out the timeout.
    private var challengeCleared = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = Self.loadConfig(from: defaults)
    }

    init(testingDefaults defaults: UserDefaults) {
        self.defaults = defaults
        config = Self.loadConfig(from: defaults)
    }

    var isRunning: Bool {
        status == .running || status == .stopping || status == .awaitingChallenge
    }

    /// Fraction of the topic uploaded so far, or nil before the first batch lands.
    var progress: Double? {
        guard totalReplies > 0, processedEnd > 0 else { return nil }
        return min(max(Double(processedEnd) / Double(totalReplies), 0), 1)
    }

    /// Rounded percentage for the compact nav-bar / bottom-bar readouts.
    var progressPercent: Int? {
        progress.map { Int(($0 * 100).rounded()) }
    }

    // MARK: - Config persistence

    private enum Key {
        static let baseDelay = "readBoostBaseDelay"
        static let randomDelayRange = "readBoostRandomDelayRange"
        static let minReqSize = "readBoostMinReqSize"
        static let maxReqSize = "readBoostMaxReqSize"
        static let minReadTime = "readBoostMinReadTime"
        static let maxReadTime = "readBoostMaxReadTime"
        static let autoStart = "readBoostAutoStart"
        static let startFromCurrent = "readBoostStartFromCurrent"
        static let hasAgreed = "readBoostHasAgreed"
    }

    private static func loadConfig(from defaults: UserDefaults) -> ReadBoostConfig {
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        var config = ReadBoostConfig(
            baseDelay: int(Key.baseDelay, ReadBoostConfig.defaults.baseDelay),
            randomDelayRange: int(Key.randomDelayRange, ReadBoostConfig.defaults.randomDelayRange),
            minReqSize: int(Key.minReqSize, ReadBoostConfig.defaults.minReqSize),
            maxReqSize: int(Key.maxReqSize, ReadBoostConfig.defaults.maxReqSize),
            minReadTime: int(Key.minReadTime, ReadBoostConfig.defaults.minReadTime),
            maxReadTime: int(Key.maxReadTime, ReadBoostConfig.defaults.maxReadTime),
            autoStart: defaults.bool(forKey: Key.autoStart),
            startFromCurrent: defaults.bool(forKey: Key.startFromCurrent),
            hasAgreed: defaults.bool(forKey: Key.hasAgreed)
        )
        config = config.normalized()
        return config
    }

    func save(config newConfig: ReadBoostConfig) {
        let normalized = newConfig.normalized()
        defaults.set(normalized.baseDelay, forKey: Key.baseDelay)
        defaults.set(normalized.randomDelayRange, forKey: Key.randomDelayRange)
        defaults.set(normalized.minReqSize, forKey: Key.minReqSize)
        defaults.set(normalized.maxReqSize, forKey: Key.maxReqSize)
        defaults.set(normalized.minReadTime, forKey: Key.minReadTime)
        defaults.set(normalized.maxReadTime, forKey: Key.maxReadTime)
        defaults.set(normalized.autoStart, forKey: Key.autoStart)
        defaults.set(normalized.startFromCurrent, forKey: Key.startFromCurrent)
        defaults.set(normalized.hasAgreed, forKey: Key.hasAgreed)
        config = normalized
        errorDescription = nil
    }

    func acceptRisk() {
        var updated = config
        updated.hasAgreed = true
        save(config: updated)
    }

    func resetConfig() {
        var defaultsConfig = ReadBoostConfig.defaults
        defaultsConfig.hasAgreed = config.hasAgreed
        save(config: defaultsConfig)
    }

    // MARK: - Run control

    /// Begin a sweep over `totalReplies` posts of `topicId`.
    /// - Parameter currentPosition: floor the reader is on, used when
    ///   `config.startFromCurrent` is set.
    func start(api: DiscourseAPI, topicId: Int, currentPosition: Int, totalReplies: Int) {
        guard !isRunning else {
            message = String(localized: "readboost.status.already_running")
            return
        }
        guard config.hasAgreed else {
            fail(with: String(localized: "readboost.status.needs_consent"))
            return
        }
        guard totalReplies > 0 else {
            fail(with: String(localized: "readboost.status.no_posts"))
            return
        }
        guard AuthManager.shared.isAuthenticated(for: api.baseURL) else {
            fail(with: String(localized: "readboost.status.login_required"))
            return
        }
        guard ForumPolicy.tracksReadTimings(baseURL: api.baseURL) else {
            fail(with: String(localized: "readboost.status.timings_disabled"))
            return
        }

        let config = config.normalized()
        let startPosition = config.startFromCurrent
            ? min(max(currentPosition, 1), totalReplies)
            : 1

        shouldStop = false
        status = .running
        message = String(localized: "readboost.status.starting")
        self.topicId = topicId
        self.totalReplies = totalReplies
        processedEnd = startPosition - 1
        errorDescription = nil
        beginBackgroundTask()

        runTask = Task { [weak self] in
            await self?.run(
                api: api,
                topicId: topicId,
                startPosition: startPosition,
                totalReplies: totalReplies,
                config: config
            )
        }
    }

    func stop() {
        guard isRunning else { return }
        shouldStop = true
        status = .stopping
        message = String(localized: "readboost.status.stopping")
    }

    private func run(
        api: DiscourseAPI,
        topicId: Int,
        startPosition: Int,
        totalReplies: Int,
        config: ReadBoostConfig
    ) async {
        var cursor = startPosition
        while cursor <= totalReplies {
            if shouldStop { break }
            let batchSize = Int.random(in: config.minReqSize ... config.maxReqSize)
            let start = cursor
            let end = min(cursor + batchSize - 1, totalReplies)
            let outcome = await sendBatch(
                api: api,
                topicId: topicId,
                start: start,
                end: end,
                totalReplies: totalReplies,
                config: config
            )
            switch outcome {
            case .stopped:
                finish(status: .idle, message: String(localized: "readboost.status.stopped"))
                return
            case .failed(let statusCode):
                errorDescription = statusCode.map { String(localized: "readboost.error.http \($0)") }
                finish(status: .failed, message: String(localized: "readboost.status.failed"))
                return
            case .success:
                cursor = end + 1
            }
        }

        if shouldStop {
            finish(status: .idle, message: String(localized: "readboost.status.stopped"))
        } else {
            processedEnd = totalReplies
            finish(status: .completed, message: String(localized: "readboost.status.completed"))
        }
    }

    private enum BatchOutcome {
        case success
        case stopped
        case failed(statusCode: Int?)
    }

    private func sendBatch(
        api: DiscourseAPI,
        topicId: Int,
        start: Int,
        end: Int,
        totalReplies: Int,
        config: ReadBoostConfig
    ) async -> BatchOutcome {
        var remainingRetries = Self.maxBatchRetries
        // Clearing a challenge buys a free retry, but only a few — otherwise a
        // forum that challenges every single request would loop forever.
        var freeChallengeRetries = 3
        while true {
            if shouldStop { return .stopped }

            var timings: [Int: Int] = [:]
            for postNumber in start ... end {
                timings[postNumber] = Int.random(in: config.minReadTime ... config.maxReadTime)
            }
            let count = end - start + 1
            let topicTime = Int.random(
                in: (config.minReadTime * count) ... (config.maxReadTime * count)
            )

            let result = await api.postReadBoostTimings(
                topicId: topicId,
                topicTime: topicTime,
                timings: timings
            )
            if shouldStop { return .stopped }

            if result.isSuccess {
                processedEnd = end
                let percent = Int((Double(end) / Double(totalReplies) * 100).rounded())
                message = String(localized: "readboost.status.processing \(start) \(end) \(percent)")
                let delay = config.baseDelay + Int.random(in: 0 ... max(config.randomDelayRange, 0))
                if await sleepCheckingStop(milliseconds: delay) { return .stopped }
                return .success
            }

            // Cloudflare: ask the UI to open the challenge page, then hold this
            // batch until the user clears it — or until the wait times out, so
            // an unattended run still resumes on its own.
            if result.needsChallenge {
                status = .awaitingChallenge
                message = String(localized: "readboost.status.challenge")
                challengeCleared = false
                NotificationCenter.default.post(name: .readBoostChallengeRequired, object: self)
                let stopped = await waitForChallenge()
                if stopped { return .stopped }
                status = .running
                // A cleared challenge doesn't count against the retry budget —
                // the batch never really failed, it was intercepted.
                if challengeCleared, freeChallengeRetries > 0 {
                    challengeCleared = false
                    freeChallengeRetries -= 1
                    continue
                }
                challengeCleared = false
            }

            guard remainingRetries > 0 else {
                return .failed(statusCode: result.statusCode)
            }
            remainingRetries -= 1
            message = String(localized: "readboost.status.retrying \(start) \(end) \(remainingRetries)")
            if await sleepCheckingStop(milliseconds: Self.retryDelayMilliseconds) {
                return .stopped
            }
        }
    }

    /// Called by the UI once the challenge page closes, so the paused batch
    /// retries right away rather than sitting out the remaining wait.
    ///
    /// Clearing the challenge also restores linux.do read-time reporting: a
    /// Cloudflare interception is exactly what trips the auto-shutdown, and
    /// making the user go re-arm a switch they never touched is pure friction.
    func challengeDidResolve() {
        AppSettings.shared.linuxDoReadTimingsEnabled = true
        guard status == .awaitingChallenge else { return }
        challengeCleared = true
    }

    /// Hold a batch while the user works through the Cloudflare page.
    /// Returns true when the run should stop.
    private func waitForChallenge() async -> Bool {
        var remaining = Self.challengeWaitMilliseconds
        while remaining > 0 {
            if shouldStop { return true }
            if challengeCleared { return false }
            let step = min(200, remaining)
            try? await Task.sleep(for: .milliseconds(step))
            remaining -= step
        }
        return shouldStop
    }

    /// Sleep in short slices so a stop request lands promptly instead of after
    /// the full inter-batch delay. Returns true when the run should stop.
    private func sleepCheckingStop(milliseconds: Int) async -> Bool {
        var remaining = milliseconds
        while remaining > 0 {
            if shouldStop { return true }
            let step = min(100, remaining)
            try? await Task.sleep(for: .milliseconds(step))
            remaining -= step
        }
        return shouldStop
    }

    private func fail(with message: String) {
        status = .failed
        self.message = message
    }

    private func finish(status: ReadBoostStatus, message: String) {
        self.status = status
        self.message = message
        shouldStop = false
        runTask = nil
        endBackgroundTask()
    }

    // MARK: - Background continuation

    /// Keep the sweep alive for the extra wall-clock iOS grants after the app
    /// leaves the foreground, instead of stalling the moment it's backgrounded.
    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "ReadBoost") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
}
