//
//  SportsAPIService.swift
//  ZapRemote
//
//  Serverless live-game monitor — polls ESPN's public summary API and triggers
//  LG TV rewind macros when break indicators are detected.
//
//  Architecture:
//    ESPN game summary (HTTPS) → SportsAPIService → TVController
//

import Combine
import Foundation

// MARK: - Monitoring Status

enum SportsAPIMonitoringStatus: String, Sendable, Equatable {
    case idle
    case monitoring
    case polling
    case error

    var displayLabel: String {
        switch self {
        case .idle: "ESPN monitor idle"
        case .monitoring: "ESPN live monitor active"
        case .polling: "Polling ESPN game feed…"
        case .error: "ESPN monitor error"
        }
    }
}

// MARK: - ESPN Summary Models

private struct ESPNSummaryResponse: Decodable, Sendable {
    let header: ESPNGameHeader?
    let drives: ESPNDrivesPayload?
    let keyEvents: [ESPNPlay]?
}

private struct ESPNGameHeader: Decodable, Sendable {
    let competitions: [ESPNCompetitionSummary]?
}

private struct ESPNCompetitionSummary: Decodable, Sendable {
    let status: ESPNEventStatus?
}

private struct ESPNDrivesPayload: Decodable, Sendable {
    let previous: [ESPNDrive]?
    let current: ESPNDrive?
}

private struct ESPNDrive: Decodable, Sendable {
    let plays: [ESPNPlay]?
}

private struct ESPNPlay: Decodable, Sendable {
    let id: String?
    let text: String?
    let wallclock: String?
    let type: ESPNPlayType?

    var snapshot: ESPNPlaySnapshot {
        ESPNPlaySnapshot(
            id: id,
            text: text,
            wallclock: wallclock,
            typeText: type?.text,
            typeAbbreviation: type?.abbreviation
        )
    }
}

private struct ESPNPlayType: Decodable, Sendable {
    let id: String?
    let text: String?
    let abbreviation: String?
}

private struct ESPNEventStatus: Decodable, Sendable {
    let clock: Double?
    let displayClock: String?
    let period: Int?
    let detail: String?
    let shortDetail: String?
    let type: ESPNStatusType
}

private struct ESPNStatusType: Decodable, Sendable {
    let id: String?
    let name: String
    let state: String?
    let completed: Bool?
    let description: String?
    let detail: String?
    let shortDetail: String?
}

// MARK: - Kickoff Verification Gate

/// Blocks ESPN "ghost clocks" (scheduled-time ticks before the TV broadcast kicks off).
private enum KickoffVerificationGate {

    private static let kickoffKeywords = [
        "kickoff", "kick off", "kick-off",
        "match started", "match begins", "match underway",
        "whistle", "underway",
        "tip-off", "tipoff", "tip off",
        "game start", "starts with",
        "opening play", "first play",
        "face-off", "faceoff",
        "possession",
    ]

    private static let preMatchFluffKeywords = [
        "lineup", "line-up", "national anthem", "anthem",
        "formation", "warm-up", "warm up", "coin toss", "toss",
        "pregame", "pre-game", "pre game",
    ]

    private static let preGameStatusNames: Set<String> = [
        "STATUS_SCHEDULED",
        "STATUS_DELAYED",
        "STATUS_POSTPONED",
        "STATUS_CANCELED",
        "STATUS_CANCELLED",
    ]

    static func verify(status: ESPNEventStatus?, plays: [ESPNPlay]) -> Bool {
        guard let status else { return false }

        let state = status.type.state?.lowercased() ?? ""
        let statusName = status.type.name.uppercased()

        if state == "pre" || preGameStatusNames.contains(statusName) {
            return false
        }

        if status.type.completed == true || state == "post" || statusName == "STATUS_FINAL" {
            return plays.contains(where: isSubstantivePlay)
        }

        let substantivePlays = plays.filter(isSubstantivePlay)
        guard !substantivePlays.isEmpty else { return false }

        if substantivePlays.contains(where: indicatesKickoffOrLiveAction) {
            return true
        }

        if substantivePlays.contains(where: hasWallclock) {
            return true
        }

        if state == "in" || statusName == "STATUS_IN_PROGRESS" {
            return true
        }

        return false
    }

    private static func isSubstantivePlay(_ play: ESPNPlay) -> Bool {
        let text = normalizedPlayText(play)
        guard text.count >= 3 else { return false }
        if preMatchFluffKeywords.contains(where: { text.contains($0) }) { return false }
        return true
    }

    private static func indicatesKickoffOrLiveAction(_ play: ESPNPlay) -> Bool {
        let text = normalizedPlayText(play)
        return kickoffKeywords.contains { text.contains($0) }
    }

    private static func hasWallclock(_ play: ESPNPlay) -> Bool {
        guard let wallclock = play.wallclock?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !wallclock.isEmpty
    }

    private static func normalizedPlayText(_ play: ESPNPlay) -> String {
        [play.text, play.type?.text, play.type?.abbreviation]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Break Classification

private enum ESPNBreakClassifier {
    static let breakStatusNames: Set<String> = [
        "STATUS_HALFTIME",
        "STATUS_TV_TIMEOUT",
        "STATUS_END_PERIOD",
        "STATUS_END_OF_PERIOD",
        "STATUS_INTERMISSION"
    ]

    private static let breakKeywords = [
        "commercial",
        "halftime",
        "half time",
        "half-time",
        "status_half",
        "end of period",
        "tv timeout",
        "hydration",
        "water break",
        "cooling break"
    ]

    private static let activePlayKeywords = [
        "in progress",
        "status_in_progress",
        "rush",
        "pass",
        "kickoff",
        "punt",
        "field goal",
        "touchdown",
        "interception",
        "fumble",
        "sack",
        "shot on",
        "corner kick",
        "free kick",
        "goal kick",
        "cross",
        "header"
    ]

    static func isCommercialBreak(status: ESPNEventStatus?, latestPlay: ESPNPlay?) -> Bool {
        if let status, isBreakStatus(status) {
            return true
        }
        return isBreakPlay(latestPlay)
    }

    static func isActivePlay(status: ESPNEventStatus?, latestPlay: ESPNPlay?) -> Bool {
        guard !isCommercialBreak(status: status, latestPlay: latestPlay) else { return false }

        if let status {
            let typeName = status.type.name.uppercased()
            if typeName == "STATUS_IN_PROGRESS" {
                return true
            }
            if status.type.state?.lowercased() == "in" {
                return true
            }
        }

        if let latestPlay {
            let haystack = playHaystack(latestPlay)
            if activePlayKeywords.contains(where: { haystack.contains($0) }) {
                return true
            }
            if haystack.contains("in progress") {
                return true
            }
        }

        return false
    }

    private static func isBreakStatus(_ status: ESPNEventStatus) -> Bool {
        let typeName = status.type.name.uppercased()
        if breakStatusNames.contains(typeName) {
            return true
        }

        let haystack = [
            status.type.description,
            status.type.detail,
            status.type.shortDetail,
            status.detail,
            status.shortDetail
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return breakKeywords.contains { haystack.contains($0) }
    }

    private static func isBreakPlay(_ play: ESPNPlay?) -> Bool {
        guard let play else { return false }
        let haystack = playHaystack(play)
        return breakKeywords.contains { haystack.contains($0) }
    }

    private static func playHaystack(_ play: ESPNPlay) -> String {
        [
            play.text,
            play.type?.text,
            play.type?.abbreviation,
            play.type?.id
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    /// Soccer: hands-free only on confirmed halftime — not hydration, timeouts, or end-of-period blips.
    static func isHandsFreeCommercialBreak(
        status: ESPNEventStatus?,
        latestPlay: ESPNPlay?,
        sportPath: String
    ) -> Bool {
        guard isCommercialBreak(status: status, latestPlay: latestPlay) else { return false }

        let path = sportPath.lowercased()
        guard path.contains("soccer") || path.contains("fifa") else { return true }

        var haystack = ""
        if let status {
            let typeName = status.type.name.uppercased()
            if typeName == "STATUS_HALFTIME" || typeName == "STATUS_INTERMISSION" {
                return true
            }
            haystack += [
                status.type.description,
                status.type.detail,
                status.type.shortDetail,
                status.detail,
                status.shortDetail,
                status.type.name
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        }
        if let latestPlay {
            haystack += " " + playHaystack(latestPlay)
        }

        if haystack.contains("halftime") || haystack.contains("half time") || haystack.contains("half-time") {
            return true
        }
        if haystack.contains("end of half") || haystack.contains("end of 1st half") || haystack.contains("end of first half") {
            return true
        }

        return false
    }
}

// MARK: - Timeline Calibration (Hue Entertainment Area Latency)

/// Persistent Hue-style stream lag offset — mirrors `@AppStorage("user_stream_delay")`.
enum TimelineCalibrationStorage {
    static let userStreamDelayKey = "user_stream_delay"
}

// MARK: - SportsAPIService

@MainActor
final class SportsAPIService: ObservableObject {

    // MARK: Published State

    /// Hue Entertainment Area latency offset — bound to Settings slider & highlight rewind math.
    /// Persisted under `TimelineCalibrationStorage.userStreamDelayKey` (`user_stream_delay`).
    @Published var streamDelaySeconds: Double = 0.0 {
        didSet {
            applyTimelineCalibrationOffset()
        }
    }

    /// TV offset: negative = TV ahead of ESPN, positive = TV behind, zero = matched.
    static let settingsSliderDelayRange: ClosedRange<Double> = -300...600
    static let settingsSliderStep: Double = 1.0

    /// SwiftUI binding surface — mirrors `gameID`.
    @Published var monitoredGameID: String = "" {
        didSet {
            gameID = monitoredGameID.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(gameID, forKey: SportsAPIStorageKey.monitoredGameID)
        }
    }

    @Published var monitoredSportPath: String = "" {
        didSet {
            sportPath = monitoredSportPath.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(sportPath, forKey: SportsAPIStorageKey.monitoredSportPath)
        }
    }

    @Published var monitoredGameLabel: String = "" {
        didSet {
            UserDefaults.standard.set(monitoredGameLabel, forKey: SportsAPIStorageKey.monitoredGameLabel)
        }
    }

    @Published private(set) var gameSearchResults: [ESPNGameSearchResult] = []
    @Published private(set) var isSearchingGames = false
    @Published private(set) var gameSearchStatus: String = ""

    @Published private(set) var monitoringStatus: SportsAPIMonitoringStatus = .idle
    @Published private(set) var lastStatusSummary: String = "Awaiting ESPN polling start"
    @Published private(set) var lastProcessedAt: Date?
    @Published private(set) var isBreakActive = false
    @Published private(set) var activityLog: [String] = []
    @Published private(set) var hasSyncedStreamLag: Bool = false
    @Published private(set) var lastHighlightTarget: String = ""
    @Published private(set) var rankedHighlights: [SportHighlight] = []
    @Published private(set) var commercialBreakPlaylist: [SportHighlight] = []
    @Published private(set) var commercialBreakHighlightIndex: Int = 0
    @Published private(set) var isCommercialBreakLoopActive = false
    @Published private(set) var selectedHighlightRank: Int = 0
    @Published private(set) var lastPlannedRewindSeconds: Int = 0
    @Published private(set) var liveGameClock: ESPNGameClock?
    @Published private(set) var liveGameClockLabel: String = "—"
    @Published private(set) var tickingGameClock: TickingGameClock?
    @Published private(set) var isTrackedGameLive: Bool = false
    @Published private(set) var latestESPNPlayLabel: String = ""

    static let kickoffWaitClockDisplay = "00:00"
    static let kickoffWaitBanner = "Waiting for kickoff…"

    /// UI + sync gate — `true` only after ESPN play log confirms real kickoff.
    @Published private(set) var isMatchPhysicallyActive: Bool = false

    /// Bypass kickoff / live gates — synthetic clock + rewinds for off-air testing.
    @Published private(set) var isNonLiveTestModeEnabled: Bool = false

    /// VOD / replay / finished — no live tick; user sets `streamDelaySeconds` only.
    var isReplayOffsetMode: Bool {
        hasMonitoredGame && !isTrackedGameLive
    }

    /// Match Clock (live sync) vs TV Delay (replay offset only).
    var usesLiveStyleMatchClock: Bool {
        isTrackedGameLive || isNonLiveTestModeEnabled
    }

    /// ESPN wall-clock highlight math only works during a live broadcast.
    var supportsTimestampHighlightRewinds: Bool {
        isTrackedGameLive && !isReplayOffsetMode
    }

    /// Match clock + TV offset tuning.
    var allowsStreamOffsetCalibration: Bool {
        guard hasMonitoredGame else { return false }
        if isReplayOffsetMode || isTrackedGameLive { return true }
        return matchElapsedBaseCapturedAt != nil
    }

    /// Always on — hands-free is the product, not a setting.
    var isHandsFreeAutomationEnabled: Bool { true }

    /// Auto Go Live when the highlight reel finishes — core product behavior.
    @Published private(set) var autoReturnToLiveAfterHighlight: Bool = true

    // MARK: Spec State

    private var hasTriggeredThisBreak = false
    private var gameID: String = ""
    private var sportPath: String = ""

    // MARK: Private

    private weak var tvController: TVController?
    private var pollingTimer: Timer?
    private var matchClockUITimer: Timer?
    private let pollIntervalSeconds: TimeInterval = 2
    /// Typical NFL timeout / ad-pod length on linear TV — fallback when no plays parse.
    private let commercialBreakSeconds: Double = 150
    /// Caps generic TV skip macros when no ESPN highlight is available.
    private let maxGenericSkipSeconds = 120
    private var lastBreakPlayID: String?
    private var scheduledReturnToLiveTask: Task<Void, Never>?
    /// ESPN game-time base — elapsed seconds in the match when `matchElapsedBaseCapturedAt` was set.
    private var matchElapsedBaseSeconds: Int = 0
    private var matchElapsedBaseCapturedAt: Date?
    /// Paused only during ESPN stoppages (halftime, timeout) — not during normal live play.
    private var isMatchClockPaused: Bool = false
    /// Blocks ESPN from re-anchoring elapsed time while the user is tuning TV offset.
    private var offsetCalibrationHoldUntil: Date?
    @Published private(set) var pendingAutoGoLive = false
    /// Seconds to watch the highlight after the skip macro — longer for big plays.
    private let baseHighlightWatchSeconds: TimeInterval = 45

    /// Tracks how far behind TV live we are during a commercial-break highlight session.
    private var activeBreakStartedAt: Date?
    private var activeBreakInitialRewindSeconds: Int = 0
    private var currentBehindSeconds: Int = 0
    private var behindPositionUpdatedAt: Date?
    private var lastSummaryPollAt: Date?
    private var consecutiveBreakPolls = 0
    private let minBreakPollsBeforeAutoSkip = 2

    private static let iso8601Standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: Init

    init() {
        if let calibrated = UserDefaults.standard.object(
            forKey: TimelineCalibrationStorage.userStreamDelayKey
        ) as? Double {
            streamDelaySeconds = calibrated
        } else if let legacy = UserDefaults.standard.object(
            forKey: SportsAPIStorageKey.streamDelaySeconds
        ) as? Double {
            streamDelaySeconds = legacy
            UserDefaults.standard.set(legacy, forKey: TimelineCalibrationStorage.userStreamDelayKey)
        }

        hasSyncedStreamLag = UserDefaults.standard.bool(forKey: SportsAPIStorageKey.hasSyncedStreamLag)
            && !gameID.isEmpty

        let storedGameID = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredGameID) ?? ""
        gameID = storedGameID.trimmingCharacters(in: .whitespacesAndNewlines)
        monitoredGameID = gameID

        let storedSportPath = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredSportPath)
        sportPath = (storedSportPath?.isEmpty == false) ? storedSportPath! : ""
        monitoredSportPath = sportPath

        monitoredGameLabel = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredGameLabel) ?? ""

        if UserDefaults.standard.object(forKey: SportsAPIStorageKey.monitoredGameIsLive) != nil {
            isTrackedGameLive = UserDefaults.standard.bool(forKey: SportsAPIStorageKey.monitoredGameIsLive)
        }

        restoreMatchElapsedClockIfNeeded()

        isNonLiveTestModeEnabled = UserDefaults.standard.bool(forKey: SportsAPIStorageKey.nonLiveTestMode)
        if isNonLiveTestModeEnabled, hasMonitoredGame {
            activateNonLiveTestSession()
        } else if hasMonitoredGame, isTrackedGameLive, matchElapsedBaseCapturedAt == nil {
            startLocalMatchClock(atSeconds: 0)
        }
    }

    deinit {
        pollingTimer?.invalidate()
        matchClockUITimer?.invalidate()
    }

    // MARK: - Rewind Target

    /// Last-resort rewind when ESPN plays cannot be parsed (no ranked highlight available).
    var commercialRewindTargetSeconds: Int {
        let total = streamDelaySeconds + commercialBreakSeconds + SportHighlightEngine.prePlayPaddingSeconds
        return min(maxGenericSkipSeconds, max(1, Int(total.rounded())))
    }

    // MARK: Binding

    func configure(tvController: TVController) {
        self.tvController = tvController
    }

    // MARK: - Game Search

    func searchGames(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await showLiveGames()
            return
        }

        isSearchingGames = true
        gameSearchStatus = "Searching ESPN for \"\(trimmed)\"…"
        defer { isSearchingGames = false }

        do {
            let results = try await ESPNGameSearchService.search(query: trimmed)
            gameSearchResults = results
            gameSearchStatus = results.isEmpty
                ? "No games found — try a team (Argentina) or league (Premier League)"
                : "Found \(results.count) game(s) — tap one to track"
        } catch {
            gameSearchResults = []
            gameSearchStatus = error.localizedDescription
        }
    }

    func showLiveGames() async {
        isSearchingGames = true
        gameSearchStatus = "Loading live games…"
        defer { isSearchingGames = false }

        let results = await ESPNGameSearchService.liveGamesToday()
        gameSearchResults = results
        gameSearchStatus = results.isEmpty
            ? "No live games right now — search by team or league"
            : "Live now — tap a game to track"
    }

    func selectMonitoredGame(_ result: ESPNGameSearchResult) {
        monitoredSportPath = result.sportPath
        monitoredGameID = result.eventID
        monitoredGameLabel = result.selectionSummary
        gameSearchResults = []
        gameSearchStatus = "Tracking \(result.title)"
        lastStatusSummary = "Now tracking \(result.title)"
        appendActivity("Selected game — \(result.title)")

        tickingGameClock = nil
        liveGameClock = nil
        clearMatchElapsedClock()
        isMatchPhysicallyActive = false
        offsetCalibrationHoldUntil = nil
        isTrackedGameLive = result.isLive
        UserDefaults.standard.set(result.isLive, forKey: SportsAPIStorageKey.monitoredGameIsLive)
        liveGameClockLabel = result.isLive ? Self.kickoffWaitClockDisplay : "Replay"
        resetBreakSkipLatch()
        hasSyncedStreamLag = false
        UserDefaults.standard.set(false, forKey: SportsAPIStorageKey.hasSyncedStreamLag)

        stopGamePolling()
        startGamePolling()

        if result.isLive {
            Task { await bootstrapClockFromScoreboard() }
        }

        if isNonLiveTestModeEnabled {
            startLocalMatchClock(atSeconds: 0)
            hasSyncedStreamLag = true
            UserDefaults.standard.set(true, forKey: SportsAPIStorageKey.hasSyncedStreamLag)
        } else if !result.isLive {
            isMatchPhysicallyActive = false
            liveGameClockLabel = "Replay"
        }
    }

    // MARK: - Local match clock (always available)

    /// Starts (or restarts) the ticking match clock at `atSeconds` — no kickoff or live feed required.
    func startLocalMatchClock(atSeconds seconds: Int = 0) {
        guard hasMonitoredGame else { return }
        isMatchPhysicallyActive = true
        isMatchClockPaused = false
        let now = Self.alignedToWholeSecond(Date())
        matchElapsedBaseSeconds = max(0, seconds)
        matchElapsedBaseCapturedAt = now
        persistMatchElapsedClock()
        startMatchClockUITimer()
        liveGameClockLabel = formatElapsedClock(matchElapsedBaseSeconds)
    }

    /// Shifts the ESPN match clock +/− (sets game time directly, TV line follows via offset).
    func nudgeESPNMatchClock(by seconds: Int, at date: Date = Date()) {
        guard seconds != 0, hasMonitoredGame else { return }
        if matchElapsedBaseCapturedAt == nil {
            startLocalMatchClock(atSeconds: 0)
        }
        let current = espnElapsedSeconds(at: date) ?? matchElapsedBaseSeconds
        let next = max(0, current + seconds)
        let now = Self.alignedToWholeSecond(Date())
        matchElapsedBaseSeconds = next
        matchElapsedBaseCapturedAt = now
        isMatchPhysicallyActive = true
        persistMatchElapsedClock()
        startMatchClockUITimer()
        liveGameClockLabel = formatElapsedClock(next)
        markOffsetCalibrationInProgress()
    }

    func canNudgeESPNMatchClock(by seconds: Int, at date: Date = Date()) -> Bool {
        guard seconds != 0, hasMonitoredGame else { return false }
        if seconds < 0 {
            let current = espnElapsedSeconds(at: date) ?? matchElapsedBaseSeconds
            return current + seconds >= 0
        }
        return true
    }

    // MARK: - Non-live test mode

    func setNonLiveTestModeEnabled(_ enabled: Bool) {
        guard enabled != isNonLiveTestModeEnabled else { return }
        isNonLiveTestModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SportsAPIStorageKey.nonLiveTestMode)

        if enabled {
            activateNonLiveTestSession()
            appendActivity("Non-live test mode on — synthetic clock, rewinds unlocked")
        } else {
            if !isTrackedGameLive {
                isMatchPhysicallyActive = false
                clearMatchElapsedClock()
                liveGameClockLabel = isReplayOffsetMode ? "Replay" : Self.kickoffWaitClockDisplay
            }
            hasSyncedStreamLag = streamDelaySeconds != 0
                || UserDefaults.standard.bool(forKey: SportsAPIStorageKey.hasSyncedStreamLag)
            appendActivity("Non-live test mode off")
        }
    }

    /// Clears the per-break latch so the next commercial can trigger one skip cycle.
    private func resetBreakSkipLatch() {
        hasTriggeredThisBreak = false
        isBreakActive = false
        lastBreakPlayID = nil
        consecutiveBreakPolls = 0
        pendingAutoGoLive = false
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        scheduledReturnToLiveTask?.cancel()
        scheduledReturnToLiveTask = nil
        clearBreakPlaybackState()
    }

    /// Synthetic clock for off-air testing — same as `startLocalMatchClock` if not already ticking.
    private func activateNonLiveTestSession() {
        guard isNonLiveTestModeEnabled, hasMonitoredGame else { return }

        offsetCalibrationHoldUntil = nil
        hasSyncedStreamLag = true
        UserDefaults.standard.set(true, forKey: SportsAPIStorageKey.hasSyncedStreamLag)

        if matchElapsedBaseCapturedAt == nil {
            startLocalMatchClock(atSeconds: 0)
        } else {
            isMatchPhysicallyActive = true
            startMatchClockUITimer()
        }

        lastStatusSummary = "Test mode — set clock to any time with +/−"
    }

    /// Manual rewind test from Settings — does not require ESPN break detection.
    func triggerTestRewind(seconds: Int = 120) {
        guard isNonLiveTestModeEnabled else { return }
        guard let tvController else {
            lastStatusSummary = "Connect TV first"
            return
        }
        guard tvController.isConnected else {
            lastStatusSummary = "Connect TV first"
            return
        }
        let snapped = tvController.snappedRewindSeconds(targetSeconds: seconds)
        lastPlannedRewindSeconds = snapped
        lastStatusSummary = "Test rewind \(snapped)s…"
        _ = tvController.triggerRewindMacro(targetSeconds: snapped)
    }

    // MARK: - Match Elapsed Clock (synced to ESPN game time, ticks locally)

    /// Anchor for 1 Hz UI ticks — aligned to when ESPN game time was last seeded.
    var matchClockTickAnchor: Date? {
        matchElapsedBaseCapturedAt
    }

    private static func alignedToWholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    /// Seconds elapsed in the match per ESPN — ticks every second during live play.
    func espnElapsedSeconds(at date: Date = Date()) -> Int? {
        guard let capturedAt = matchElapsedBaseCapturedAt else { return nil }
        if isMatchClockPaused {
            return max(0, matchElapsedBaseSeconds)
        }
        let delta = Int(floor(date.timeIntervalSince(capturedAt)))
        return max(0, matchElapsedBaseSeconds + delta)
    }

    /// TV timeline = ESPN elapsed minus user offset (negative offset = TV ahead).
    func tvElapsedSeconds(at date: Date = Date()) -> Int? {
        guard espnElapsedSeconds(at: date) != nil else { return nil }
        return max(0, rawTvElapsedSeconds(at: date))
    }

    /// Unclamped TV elapsed — used for nudge bounds.
    func rawTvElapsedSeconds(at date: Date = Date()) -> Int {
        guard let elapsed = espnElapsedSeconds(at: date) else { return 0 }
        return elapsed - Int(streamDelaySeconds.rounded())
    }

    /// Moves the TV match clock +/− without touching ESPN. +1 raises TV, −1 lowers TV.
    func nudgeTVClockDisplay(by seconds: Int, at date: Date = Date()) {
        guard seconds != 0 else { return }
        nudgeStreamDelay(by: -seconds)
    }

    func canNudgeTVClockDisplay(by seconds: Int, at date: Date = Date()) -> Bool {
        guard seconds != 0, allowsStreamOffsetCalibration else { return false }
        guard canNudgeStreamDelay(by: -seconds) else { return false }
        if seconds < 0 {
            let tv = rawTvElapsedSeconds(at: date)
            return tv > 0 && tv + seconds >= 0
        }
        return true
    }

    private func formatElapsedClock(_ seconds: Int) -> String {
        GameClockSyncEngine.formatMatchClock(seconds: seconds)
    }

    /// One-shot scoreboard fetch — seeds match clock from ESPN's live game time.
    func bootstrapClockFromScoreboard() async {
        guard hasMonitoredGame else {
            liveGameClockLabel = "Choose a game first"
            return
        }
        if isReplayOffsetMode {
            liveGameClockLabel = "Replay"
            return
        }
        await syncMatchClockFromScoreboard(force: true)
        if isMatchPhysicallyActive {
            liveGameClockLabel = espnAPIClockDisplay()
        } else {
            liveGameClockLabel = Self.kickoffWaitClockDisplay
        }
    }

    func resyncClockFromScoreboard() async {
        await bootstrapClockFromScoreboard()
    }

    private func restoreMatchElapsedClockIfNeeded() {
        guard hasMonitoredGame else { return }
        let persistedID = UserDefaults.standard.string(forKey: SportsAPIStorageKey.matchClockGameID) ?? ""
        guard persistedID == gameID else { return }

        let capturedTS = UserDefaults.standard.double(forKey: SportsAPIStorageKey.matchElapsedBaseCapturedAt)
        guard capturedTS > 0 else { return }

        matchElapsedBaseSeconds = UserDefaults.standard.integer(
            forKey: SportsAPIStorageKey.matchElapsedBaseSeconds
        )
        matchElapsedBaseCapturedAt = Date(timeIntervalSince1970: capturedTS)
        isMatchClockPaused = false
        isMatchPhysicallyActive = true
        liveGameClockLabel = formatElapsedClock(espnElapsedSeconds() ?? matchElapsedBaseSeconds)
        startMatchClockUITimer()
    }

    private func persistMatchElapsedClock() {
        guard hasMonitoredGame, let capturedAt = matchElapsedBaseCapturedAt else { return }
        UserDefaults.standard.set(matchElapsedBaseSeconds, forKey: SportsAPIStorageKey.matchElapsedBaseSeconds)
        UserDefaults.standard.set(capturedAt.timeIntervalSince1970, forKey: SportsAPIStorageKey.matchElapsedBaseCapturedAt)
        UserDefaults.standard.set(gameID, forKey: SportsAPIStorageKey.matchClockGameID)
    }

    private func clearMatchElapsedClock() {
        matchElapsedBaseSeconds = 0
        matchElapsedBaseCapturedAt = nil
        isMatchClockPaused = false
        stopMatchClockUITimer()
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.matchElapsedBaseSeconds)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.matchElapsedBaseCapturedAt)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.matchClockGameID)
    }

    private func startMatchClockUITimer() {
        stopMatchClockUITimer()
        guard isMatchPhysicallyActive, matchElapsedBaseCapturedAt != nil else { return }

        matchClockUITimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickMatchClockDisplay()
            }
        }
        if let matchClockUITimer {
            RunLoop.main.add(matchClockUITimer, forMode: .common)
        }
        tickMatchClockDisplay()
    }

    private func stopMatchClockUITimer() {
        matchClockUITimer?.invalidate()
        matchClockUITimer = nil
    }

    private func tickMatchClockDisplay() {
        guard isMatchPhysicallyActive, !isReplayOffsetMode else {
            stopMatchClockUITimer()
            return
        }
        guard let elapsed = espnElapsedSeconds() else { return }
        let label = formatElapsedClock(elapsed)
        if liveGameClockLabel != label {
            liveGameClockLabel = label
        }
    }

    private func parseClock(from summary: ESPNSummaryResponse) -> ESPNGameClock? {
        let status = summary.header?.competitions?.first?.status
        return GameClockSyncEngine.parseClock(
            period: status?.period,
            clock: status?.clock,
            displayClock: status?.displayClock,
            state: status?.type.state,
            sportPath: sportPath,
            statusDetail: status?.type.detail ?? status?.type.shortDetail
        )
    }

    private func applyESPNGameClock(
        _ clock: ESPNGameClock,
        source: String,
        force: Bool = false,
        paused: Bool = false
    ) {
        let espnElapsed = GameClockSyncEngine.elapsedGameSeconds(from: clock, sportPath: sportPath)
        let now = Self.alignedToWholeSecond(Date())
        isMatchClockPaused = paused
        liveGameClock = clock

        // User is tuning TV offset — keep local ESPN tick steady; only offset changes TV.
        if !force, !paused,
           let holdUntil = offsetCalibrationHoldUntil,
           Date() < holdUntil,
           matchElapsedBaseCapturedAt != nil {
            if let elapsed = espnElapsedSeconds(at: now) {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
            startMatchClockUITimer()
            return
        }

        if paused {
            matchElapsedBaseSeconds = espnElapsed
            matchElapsedBaseCapturedAt = now
            liveGameClockLabel = formatElapsedClock(espnElapsed)
            persistMatchElapsedClock()
            stopMatchClockUITimer()
            return
        }

        // Initial seed or forced resync only — never drift-correct during live play.
        guard force || matchElapsedBaseCapturedAt == nil else {
            startMatchClockUITimer()
            if let elapsed = espnElapsedSeconds(at: now) {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
            return
        }

        matchElapsedBaseSeconds = espnElapsed
        matchElapsedBaseCapturedAt = now
        liveGameClockLabel = formatElapsedClock(espnElapsed)
        persistMatchElapsedClock()
        startMatchClockUITimer()
        appendActivity("Match clock from ESPN (\(source)) — \(formatElapsedClock(espnElapsed))")
    }

    private func syncMatchClockFromScoreboard(force: Bool = false, paused: Bool = false) async {
        guard hasMonitoredGame, !isReplayOffsetMode else { return }
        do {
            if let clock = try await ESPNScoreboardClockService.fetchClock(
                eventID: gameID,
                sportPath: sportPath
            ) {
                applyESPNGameClock(clock, source: "scoreboard", force: force, paused: paused)
            }
        } catch {
            print("⚠️ SportsAPIService: scoreboard clock sync failed — \(error.localizedDescription)")
        }
    }

    private func syncMatchClockFromSummary(
        _ summary: ESPNSummaryResponse,
        force: Bool = false,
        paused: Bool = false
    ) {
        guard hasMonitoredGame, !isReplayOffsetMode else { return }
        guard let clock = parseClock(from: summary) else { return }
        applyESPNGameClock(clock, source: "summary", force: force, paused: paused)
    }

    private func beginKickoffElapsedClockFallback() {
        let now = Self.alignedToWholeSecond(Date())
        matchElapsedBaseSeconds = 0
        matchElapsedBaseCapturedAt = now
        isMatchClockPaused = false
        liveGameClockLabel = formatElapsedClock(0)
        persistMatchElapsedClock()
        startMatchClockUITimer()
        appendActivity("Kickoff — clock 00:00 (ESPN seed unavailable)")
        markStreamLagSynced()
    }

    /// Fine-tunes TV offset (± seconds). Negative = TV ahead of ESPN.
    func nudgeStreamDelay(by seconds: Int) {
        guard allowsStreamOffsetCalibration, seconds != 0 else { return }
        let current = Int(streamDelaySeconds.rounded())
        let next = current + seconds
        let lower = Int(Self.settingsSliderDelayRange.lowerBound)
        let upper = Int(Self.settingsSliderDelayRange.upperBound)
        streamDelaySeconds = Double(min(upper, max(lower, next)))
        markOffsetCalibrationInProgress()
        markStreamLagSynced()
    }

    private func markOffsetCalibrationInProgress() {
        offsetCalibrationHoldUntil = Date().addingTimeInterval(30)
    }

    func canNudgeStreamDelay(by seconds: Int) -> Bool {
        guard allowsStreamOffsetCalibration, seconds != 0 else { return false }
        let current = Int(streamDelaySeconds.rounded())
        let next = current + seconds
        return next >= Int(Self.settingsSliderDelayRange.lowerBound)
            && next <= Int(Self.settingsSliderDelayRange.upperBound)
    }

    static func formatStreamDelayOffset(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value > 0 { return "+\(value)s" }
        if value < 0 { return "\(value)s" }
        return "0s"
    }

    var streamDelayOffsetLabel: String {
        Self.formatStreamDelayOffset(streamDelaySeconds)
    }

    /// Caps bogus wall-clock math (replay / wrong delay) — prevents rewinding to DVR start.
    private static let maxSanityRewindSeconds = 45 * 60

    /// Universal highlight rewind from an ESPN ISO-8601 wallclock + `streamDelaySeconds`.
    func calculatedRewindSeconds(for highlight: SportHighlight, now: Date = Date()) -> Int {
        guard supportsTimestampHighlightRewinds else {
            return tvController?.snappedSkipSeconds(targetSeconds: maxGenericSkipSeconds) ?? maxGenericSkipSeconds
        }
        let raw = SportHighlightEngine.finalRewindSeconds(
            highlightDate: highlight.apiTimestamp,
            streamDelaySeconds: streamDelaySeconds,
            now: now
        )
        if raw > Self.maxSanityRewindSeconds {
            print("⚠️ SportsAPIService: rewind \(raw)s capped — sync Match Clock or pick a live game")
            return tvController?.snappedSkipSeconds(targetSeconds: commercialRewindTargetSeconds)
                ?? commercialRewindTargetSeconds
        }
        return raw
    }

    private func applyScoreboardClock(_ clock: ESPNGameClock) {
        applyESPNGameClock(clock, source: "scoreboard", force: true)
    }

    // MARK: - Clock Display (elapsed 00:00 + TV delay offset)

    /// ESPN elapsed match clock — zero delay, ticks from kickoff.
    func espnAPIClockDisplay(at date: Date = Date()) -> String {
        if isReplayOffsetMode, !isNonLiveTestModeEnabled, matchElapsedBaseCapturedAt == nil {
            return "Replay"
        }
        guard let elapsed = espnElapsedSeconds(at: date) else {
            return Self.kickoffWaitClockDisplay
        }
        return formatElapsedClock(elapsed)
    }

    /// What your TV should show — ESPN elapsed minus `streamDelaySeconds`.
    func calibratedTVTimelineDisplay(at date: Date = Date()) -> String {
        if isReplayOffsetMode, !isNonLiveTestModeEnabled, matchElapsedBaseCapturedAt == nil {
            return Self.formatStreamDelayOffset(streamDelaySeconds)
        }
        guard let tvSeconds = tvElapsedSeconds(at: date) else {
            return Self.kickoffWaitClockDisplay
        }
        return formatElapsedClock(tvSeconds)
    }

    func espnClockDisplay(at date: Date = Date()) -> String? {
        espnAPIClockDisplay(at: date)
    }

    func espnLiveClockDisplay(at date: Date = Date()) -> String? {
        guard isMatchPhysicallyActive else { return nil }
        return espnAPIClockDisplay(at: date)
    }

    func espnElapsedHint(at date: Date = Date()) -> String? {
        guard let elapsed = espnElapsedSeconds(at: date) else { return nil }
        return "\(formatElapsedClock(elapsed)) elapsed"
    }

    func broadcastGameClockDisplay(delaySeconds: Int, at date: Date = Date()) -> String? {
        guard isMatchPhysicallyActive, let elapsed = espnElapsedSeconds(at: date) else { return nil }
        let tvSeconds = max(0, Int(floor(Double(elapsed) - Double(delaySeconds))))
        return formatElapsedClock(tvSeconds)
    }

    func tvClockDisplay(delaySeconds: Int, at date: Date = Date()) -> String? {
        broadcastGameClockDisplay(delaySeconds: delaySeconds, at: date)
    }

    func uiGameClockDisplay(at date: Date = Date()) -> String {
        calibratedTVTimelineDisplay(at: date)
    }

    func syncedTimelineClockDisplay(at date: Date = Date()) -> String {
        calibratedTVTimelineDisplay(at: date)
    }

    var streamingLagOffsetReadout: String {
        let seconds = Int(streamDelaySeconds.rounded())
        if isReplayOffsetMode {
            if seconds > 0 {
                return "Replay: TV is \(seconds)s behind ESPN on highlight rewinds."
            }
            if seconds < 0 {
                return "Replay: TV is \(-seconds)s ahead of ESPN on highlight rewinds."
            }
            return "Set offset — + if TV is behind, − if TV is ahead."
        }
        guard isMatchPhysicallyActive else {
            return Self.kickoffWaitBanner
        }
        if seconds > 0 {
            return "TV is \(seconds)s behind ESPN. Tap + if TV is slower, − if TV is ahead."
        }
        if seconds < 0 {
            return "TV is \(-seconds)s ahead of ESPN. Tap − to raise the TV clock."
        }
        return "Tap + if your TV is behind, − if your TV is ahead."
    }

    /// User's TV timeline — when a live ESPN moment appears on their screen.
    func userTVAirDate(forLiveEvent liveDate: Date) -> Date {
        GameClockSyncEngine.userTVAirDate(
            liveEventDate: liveDate,
            streamDelaySeconds: streamDelaySeconds
        )
    }

    /// Persists TV offset (`user_stream_delay`) for highlight rewind math.
    private func applyTimelineCalibrationOffset() {
        let clamped = min(
            max(Self.settingsSliderDelayRange.lowerBound, streamDelaySeconds.rounded()),
            Self.settingsSliderDelayRange.upperBound
        )
        if clamped != streamDelaySeconds {
            streamDelaySeconds = clamped
            return
        }

        UserDefaults.standard.set(streamDelaySeconds, forKey: TimelineCalibrationStorage.userStreamDelayKey)
    }

    private func markStreamLagSynced() {
        guard allowsStreamOffsetCalibration, !hasSyncedStreamLag else { return }
        hasSyncedStreamLag = true
        UserDefaults.standard.set(true, forKey: SportsAPIStorageKey.hasSyncedStreamLag)
    }

    /// Call after slider or ± adjusts delay so highlight rewind can run.
    func acknowledgeStreamDelayCalibration() {
        markOffsetCalibrationInProgress()
        markStreamLagSynced()
    }

    // MARK: - Live Broadcast Polling

    /// Starts ESPN polling — requires a chosen game ID.
    func startGamePolling() {
        let trimmedID = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = sportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            monitoringStatus = .idle
            lastStatusSummary = "Choose a game to start ESPN monitoring"
            return
        }
        guard !trimmedPath.isEmpty else {
            monitoringStatus = .idle
            lastStatusSummary = "Choose a game — ESPN sport path missing"
            return
        }
        gameID = trimmedID
        sportPath = trimmedPath

        stopGamePolling()

        hasTriggeredThisBreak = false
        isBreakActive = false
        monitoringStatus = .monitoring
        lastStatusSummary = "Polling ESPN game \(gameID)"
        appendActivity("Started polling game \(gameID)")

        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollGameSummary()
            }
        }

        if let pollingTimer {
            RunLoop.main.add(pollingTimer, forMode: .common)
        }

        Task {
            if isTrackedGameLive, let elapsed = espnElapsedSeconds() {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
            await pollGameSummary()
            if isTrackedGameLive, isMatchPhysicallyActive, matchElapsedBaseCapturedAt == nil {
                await syncMatchClockFromScoreboard(force: true)
            }
        }
    }

    /// Restarts ESPN polling if iOS suspended timers while the phone was locked.
    func ensureGamePollingActive() {
        guard hasMonitoredGame else { return }
        guard pollingTimer == nil else { return }
        startGamePolling()
    }

    func stopGamePolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        cancelScheduledReturnToLive()
        pendingAutoGoLive = false
        monitoringStatus = .idle
        isBreakActive = false
        hasTriggeredThisBreak = false
        lastBreakPlayID = nil
        lastStatusSummary = "ESPN polling stopped"
        appendActivity("Polling stopped")
    }

    // MARK: - Compatibility Aliases

    func startLiveGameMonitoring(gameID: String) {
        let trimmedID = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            lastStatusSummary = "Enter an ESPN game ID in Settings"
            monitoringStatus = .idle
            return
        }
        self.gameID = trimmedID
        monitoredGameID = trimmedID
        startGamePolling()
    }

    func stopLiveGameMonitoring() {
        stopGamePolling()
    }

    // MARK: - Network Poll

    private func pollGameSummary() async {
        monitoringStatus = .polling

        do {
            let summary = try await fetchGameSummary()
            lastSummaryPollAt = Date()
            await evaluateSummary(summary)
        } catch let decodingError as DecodingError {
            monitoringStatus = .error
            lastStatusSummary = "ESPN JSON parse error"
            print("❌ SportsAPIService decode error: \(decodingError)")
        } catch {
            monitoringStatus = .error
            lastStatusSummary = "ESPN network error — retrying"
            print("❌ SportsAPIService network error: \(error.localizedDescription)")
        }
    }

    private func fetchGameSummary() async throws -> ESPNSummaryResponse {
        let url = Self.gameSummaryURL(gameID: gameID, sportPath: sportPath)
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SportsAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SportsAPIError.httpStatus(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ESPNSummaryResponse.self, from: data)
    }

    private static func gameSummaryURL(gameID: String, sportPath: String) -> URL {
        URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sportPath)/summary?event=\(gameID)")!
    }

    // MARK: - Evaluation

    /// Confirms real kickoff via ESPN play log — blocks ghost pre-game clocks.
    private func refreshKickoffVerification(from summary: ESPNSummaryResponse) async {
        if isNonLiveTestModeEnabled, hasMonitoredGame {
            activateNonLiveTestSession()
            return
        }

        if isReplayOffsetMode || Self.isGameFinished(summary) {
            if matchElapsedBaseCapturedAt == nil {
                startLocalMatchClock(atSeconds: 0)
            }
            return
        }

        let wasActive = isMatchPhysicallyActive
        let plays = allPlays(from: summary)
        let status = summary.header?.competitions?.first?.status
        let verified = KickoffVerificationGate.verify(status: status, plays: plays)

        isMatchPhysicallyActive = verified

        guard verified else {
            if matchElapsedBaseCapturedAt == nil {
                startLocalMatchClock(atSeconds: 0)
            }
            if hasSyncedStreamLag {
                // keep lag sync — user may have calibrated before ESPN confirms kickoff
            } else if isTrackedGameLive {
                lastStatusSummary = Self.kickoffWaitBanner
            }
            return
        }

        if !wasActive {
            lastStatusSummary = "Kickoff — loading match clock from ESPN"
            markStreamLagSynced()
        } else {
            startMatchClockUITimer()
            if let elapsed = espnElapsedSeconds() {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
        }
    }

    private func reconcileLiveMatchClock(from summary: ESPNSummaryResponse, paused: Bool) async {
        guard isMatchPhysicallyActive, isTrackedGameLive, !isReplayOffsetMode else { return }

        let wasPaused = isMatchClockPaused

        if matchElapsedBaseCapturedAt == nil {
            await syncMatchClockFromScoreboard(force: true, paused: paused)
            if matchElapsedBaseCapturedAt == nil {
                syncMatchClockFromSummary(summary, force: true, paused: paused)
            }
            if matchElapsedBaseCapturedAt == nil {
                beginKickoffElapsedClockFallback()
            }
            return
        }

        if paused {
            syncMatchClockFromSummary(summary, force: true, paused: true)
        } else if wasPaused {
            syncMatchClockFromSummary(summary, force: true, paused: false)
        } else {
            if let clock = parseClock(from: summary) {
                let espnElapsed = GameClockSyncEngine.elapsedGameSeconds(from: clock, sportPath: sportPath)
                if let local = espnElapsedSeconds(), abs(espnElapsed - local) > 90 {
                    syncMatchClockFromSummary(summary, force: true, paused: false)
                }
            }
            startMatchClockUITimer()
            if let elapsed = espnElapsedSeconds() {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
        }
    }

    private func evaluateSummary(_ summary: ESPNSummaryResponse) async {
        lastProcessedAt = Date()
        monitoringStatus = .monitoring
        isTrackedGameLive = Self.isGameLive(summary)
        UserDefaults.standard.set(isTrackedGameLive, forKey: SportsAPIStorageKey.monitoredGameIsLive)

        let status = summary.header?.competitions?.first?.status
        let latestPlay = extractLatestPlay(from: summary)
        let clockPaused = ESPNBreakClassifier.isCommercialBreak(status: status, latestPlay: latestPlay)
        let handsFreeBreak = ESPNBreakClassifier.isHandsFreeCommercialBreak(
            status: status,
            latestPlay: latestPlay,
            sportPath: sportPath
        )

        await refreshKickoffVerification(from: summary)
        await reconcileLiveMatchClock(from: summary, paused: clockPaused)
        _ = refreshRankedHighlightCounters(from: summary)

        if let text = latestPlay?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            latestESPNPlayLabel = text
        }
        let statusLabel = status?.type.description ?? status?.type.name ?? latestPlay?.text ?? "Unknown"

        // Don't let ESPN poll churn break state while the highlight reel is running.
        if isCommercialBreakLoopActive {
            isBreakActive = true
            lastStatusSummary = "Highlight reel \(commercialBreakHighlightIndex)/\(max(commercialBreakPlaylist.count, 1))…"
            return
        }

        if hasTriggeredThisBreak && (pendingAutoGoLive || tvController?.isExecutingMacro == true || tvController?.isMacroRunning == true) {
            isBreakActive = true
            return
        }

        if clockPaused {
            lastBreakPlayID = latestPlay?.id
            isBreakActive = true

            if handsFreeBreak {
                consecutiveBreakPolls += 1
            } else {
                consecutiveBreakPolls = 0
            }

            let minPolls = sportPath.lowercased().contains("soccer") ? 3 : minBreakPollsBeforeAutoSkip

            if handsFreeBreak,
               supportsTimestampHighlightRewinds,
               consecutiveBreakPolls >= minPolls,
               !hasTriggeredThisBreak {
                await triggerAutomaticAdSkip(source: "ESPN auto")
            } else if handsFreeBreak, !hasTriggeredThisBreak {
                if supportsTimestampHighlightRewinds {
                    lastStatusSummary = "Break detected — confirming (\(consecutiveBreakPolls)/\(minPolls))…"
                } else {
                    lastStatusSummary = "Replay — tap Ad on TV for a test skip"
                }
            } else if !handsFreeBreak, !hasTriggeredThisBreak {
                lastStatusSummary = "Waiting for halftime…"
            }
            return
        }

        consecutiveBreakPolls = 0

        if ESPNBreakClassifier.isActivePlay(status: status, latestPlay: latestPlay) {
            let macroInFlight = tvController?.isMacroRunning == true
                || tvController?.isExecutingMacro == true
            if macroInFlight, hasTriggeredThisBreak || isBreakActive {
                lastStatusSummary = "Skipping ad on TV — macro in progress"
                return
            }

            if isCommercialBreakLoopActive || pendingAutoGoLive {
                appendActivity("Play resumed mid-highlight — jumping to live")
                await abortHighlightPlaybackAndReturnToLive(reason: "Play resumed on ESPN")
                return
            }

            if hasTriggeredThisBreak || isBreakActive {
                let shouldReturnToLive = (tvController?.lastRewindClickCount ?? 0) > 0
                resetBreakSkipLatch()
                lastStatusSummary = "Active play — \(statusLabel)"
                appendActivity("Play resumed — returning to live")
                print("🟢 SportsAPIService: play resumed — break latch cleared")

                if shouldReturnToLive, let tvController {
                    await returnToLiveAfterBreak(reason: "ESPN play resumed")
                }
            } else {
                lastStatusSummary = "In progress — \(statusLabel)"
            }
            return
        }

        if hasTriggeredThisBreak {
            isBreakActive = true
            return
        }

        isBreakActive = false
        lastStatusSummary = statusLabel
    }

    // MARK: - Ad Skip (manual or cloud-detected)

    /// ESPN timeout / cloud `ad_start` — runs the same macro as the manual button.
    private func triggerAutomaticAdSkip(source: String) async {
        guard !hasTriggeredThisBreak, !isCommercialBreakLoopActive, !pendingAutoGoLive else { return }
        guard let tvController else { return }

        guard hasSyncedStreamLag else {
            lastStatusSummary = "Sync Match Clock first — tap ± until TV matches your screen"
            return
        }

        guard allowsStreamOffsetCalibration else {
            lastStatusSummary = Self.kickoffWaitBanner
            return
        }

        guard tvController.isConnected else {
            lastStatusSummary = "Ad detected — connect TV for auto-skip"
            return
        }

        guard !tvController.isExecutingMacro else { return }

        let rewindSeconds = await resolveAdSkipRewindSeconds(preferCached: true)
        await executeAdSkipRewind(rewindSeconds: rewindSeconds, source: source)
    }

    /// User saw an ad on TV — rewind to the best recent ESPN highlight play.
    /// Works in test mode without lag sync or live plays (generic TV skip).
    func skipAdToHighlights() async {
        guard let tvController else {
            lastStatusSummary = "Ad skip failed — TV not configured"
            return
        }

        if isCommercialBreakLoopActive || tvController.isExecutingMacro || tvController.isMacroRunning {
            lastStatusSummary = "Skip already running — wait for it to finish"
            tvController.statusMessage = lastStatusSummary
            return
        }

        if hasTriggeredThisBreak {
            lastStatusSummary = "Already skipped this break — wait for play to resume or tap Go Live"
            return
        }

        guard tvController.isConnected else {
            let message = "Connect your TV first, then try again."
            lastStatusSummary = message
            tvController.statusMessage = message
            appendActivity("Ad skip blocked — TV offline")
            return
        }

        if supportsTimestampHighlightRewinds, !hasSyncedStreamLag {
            lastStatusSummary = "Open Match Clock — tap ± until TV matches your screen"
            tvController.statusMessage = lastStatusSummary
            return
        }

        let rewindSeconds = await resolveAdSkipRewindSeconds()
        await executeAdSkipRewind(rewindSeconds: rewindSeconds, source: "Ad on TV")
    }

    /// Picks ranked ESPN highlight rewind, generic fallback, or a fixed test skip.
    private func resolveAdSkipRewindSeconds(preferCached: Bool = false) async -> Int {
        let cacheIsFresh = lastSummaryPollAt.map { Date().timeIntervalSince($0) < 10 } ?? false
        if (preferCached || cacheIsFresh),
           hasSyncedStreamLag,
           lastPlannedRewindSeconds > 0 {
            let snapped = tvController?.snappedRewindSeconds(targetSeconds: lastPlannedRewindSeconds)
                ?? lastPlannedRewindSeconds
            return snapped
        }

        var selectedHighlight: SportHighlight?
        if let summary = try? await fetchGameSummary() {
            isTrackedGameLive = Self.isGameLive(summary)

            if Self.isGameFinished(summary) {
                lastStatusSummary = "Game already ended — generic skip (pick a live game for real highlights)"
                appendActivity("Replay mode — can't sync ESPN time to your TV position")
                lastPlannedRewindSeconds = maxGenericSkipSeconds
                let snapped = tvController?.snappedSkipSeconds(targetSeconds: maxGenericSkipSeconds) ?? maxGenericSkipSeconds
                lastPlannedRewindSeconds = snapped
                return snapped
            }

            selectedHighlight = refreshRankedHighlightCounters(from: summary)
        }

        let raw: Int
        if hasSyncedStreamLag, let selectedHighlight, lastPlannedRewindSeconds > 0 {
            raw = lastPlannedRewindSeconds
            let rankLabel = selectedHighlight.interestRank >= 3 ? "Max" : (selectedHighlight.interestRank >= 2 ? "Med" : "Low")
            lastStatusSummary = "ESPN highlight (\(rankLabel)) — \(lastHighlightTarget)"
            appendActivity("Targeting — \(lastHighlightTarget)")
        } else if hasSyncedStreamLag {
            raw = commercialRewindTargetSeconds
            lastPlannedRewindSeconds = raw
            lastStatusSummary = "No ESPN highlights yet — generic \(raw)s skip"
            appendActivity("No plays found — generic TV skip")
        } else {
            raw = 120
            lastPlannedRewindSeconds = raw
            lastStatusSummary = "Sync game clock first — using generic 120s test skip"
            appendActivity("Generic 120s skip — match clocks for highlight targeting")
        }

        let usesHighlight = selectedHighlight != nil && hasSyncedStreamLag && lastPlannedRewindSeconds > 0
        let capped = usesHighlight ? raw : min(raw, maxGenericSkipSeconds)
        let snapped = usesHighlight
            ? (tvController?.snappedRewindSeconds(targetSeconds: capped) ?? capped)
            : (tvController?.snappedSkipSeconds(targetSeconds: capped) ?? capped)
        lastPlannedRewindSeconds = snapped
        return snapped
    }

    /// Cloud ad detector fired — same ranked highlight targeting as the manual button.
    /// `hasTriggeredThisBreak` plus `TVController.isExecutingMacro` prevent re-entry loops.
    func skipAdFromCloudDetection(fallbackRewindSeconds: Int) async {
        guard !hasTriggeredThisBreak, !isCommercialBreakLoopActive else {
            print("🛑 SportsAPIService: cloud ad-detect ignored — break already in progress")
            return
        }
        let rewindSeconds = await resolveAdSkipRewindSeconds(preferCached: true)
        let useSeconds = max(rewindSeconds, tvController?.snappedSkipSeconds(targetSeconds: fallbackRewindSeconds) ?? fallbackRewindSeconds)
        await executeAdSkipRewind(rewindSeconds: useSeconds, source: "Cloud ad detect")
    }

    /// Cloud detector says game is live again — return after TV feed catches up.
    func resumeFromCloudGameLive() async {
        if isCommercialBreakLoopActive || pendingAutoGoLive {
            await abortHighlightPlaybackAndReturnToLive(reason: "Cloud game_live")
            return
        }

        let shouldReturnToLive = (tvController?.lastRewindClickCount ?? 0) > 0
            || currentBehindSeconds > 0
        hasTriggeredThisBreak = false
        isBreakActive = false
        lastBreakPlayID = nil

        guard shouldReturnToLive else {
            lastStatusSummary = "Game live — no rewind to undo"
            return
        }

        await returnToLiveAfterBreak(reason: "Cloud game_live")
    }

    private func executeAdSkipRewind(rewindSeconds: Int, source: String) async {
        guard let tvController else {
            lastStatusSummary = "Ad skip failed — TV not connected"
            return
        }

        if supportsTimestampHighlightRewinds, !hasSyncedStreamLag {
            lastStatusSummary = "Sync Match Clock first — highlights need TV delay"
            tvController.statusMessage = lastStatusSummary
            return
        }

        if supportsTimestampHighlightRewinds,
           !commercialBreakPlaylist.isEmpty,
           let first = commercialBreakPlaylist.first {
            let planned = calculatedRewindSeconds(for: first)
            if planned > Self.maxSanityRewindSeconds {
                lastStatusSummary = "Match Clock looks wrong (\(planned)s rewind) — re-sync TV ±"
                tvController.statusMessage = lastStatusSummary
                appendActivity("Skip blocked — Match Clock out of sync")
                return
            }
        }

        hasTriggeredThisBreak = true
        isBreakActive = true

        if tvController.isExecutingMacro || isCommercialBreakLoopActive {
            let message = "Rewind already running — wait a few sec."
            lastStatusSummary = message
            tvController.statusMessage = message
            appendActivity("Ad skip blocked — macro lock active")
            isBreakActive = false
            hasTriggeredThisBreak = false
            return
        }

        if tvController.currentAppID.isEmpty, !tvController.preferredStreamingAppID.isEmpty {
            Task { await tvController.fetchActiveAppID() }
        }

        if supportsTimestampHighlightRewinds, !commercialBreakPlaylist.isEmpty {
            await runCommercialBreakHighlightLoop(source: source)
        } else {
            await executeSingleHighlightSkip(rewindSeconds: rewindSeconds, source: source)
        }
    }

    private func executeSingleHighlightSkip(rewindSeconds: Int, source: String) async {
        guard let tvController else { return }

        let highlight = lastHighlightTarget.isEmpty ? "generic skip" : lastHighlightTarget
        let rankLabel = selectedHighlightRank > 0 ? "R\(selectedHighlightRank)" : "—"
        let secondsPerClick = tvController.secondsPerSkipClick()
        let snapped = tvController.snappedRewindSeconds(targetSeconds: rewindSeconds)
        let skipClicks = snapped / secondsPerClick
        lastStatusSummary = "\(source) — \(rankLabel) → \(highlight) (\(skipClicks)×\(secondsPerClick)s)"
        appendActivity("\(source) → \(skipClicks) skips on TV")
        tvController.statusMessage = "Sending \(skipClicks)×\(secondsPerClick)s skip…"

        let started = tvController.triggerRewindMacro(targetSeconds: snapped)
        if started {
            beginBreakPlayback(rewindSeconds: snapped)
            await tvController.waitForMacroCycleToFinish()
            await tvController.updateHighlightReelBanner(index: 1, total: 1)
            let watchRank = max(1, selectedHighlightRank)
            let placeholder = SportHighlight(
                id: "single-skip",
                playDescription: lastHighlightTarget.isEmpty ? "Highlight" : lastHighlightTarget,
                apiTimestamp: Date(),
                interestRank: watchRank
            )
            await waitHighlightPlayback(for: placeholder)
            await returnToLiveAfterHighlightReel(tvController: tvController)
        } else {
            isBreakActive = false
            hasTriggeredThisBreak = false
            lastStatusSummary = tvController.statusMessage
            appendActivity("Ad skip failed — \(tvController.statusMessage)")
        }
    }

    /// Cycles ranked plays in chronological order until the break ends.
    private func runCommercialBreakHighlightLoop(source: String) async {
        guard let tvController else { return }

        let playlist = commercialBreakPlaylist
        guard !playlist.isEmpty else {
            await executeSingleHighlightSkip(
                rewindSeconds: lastPlannedRewindSeconds,
                source: source
            )
            return
        }

        isCommercialBreakLoopActive = true
        pendingAutoGoLive = autoReturnToLiveAfterHighlight
        scheduledReturnToLiveTask?.cancel()

        lastStatusSummary = "\(source) — \(playlist.count) plays"
        appendActivity("\(source) → \(playlist.count)× highlight reel")
        tvController.statusMessage = "Commercial break — \(playlist.count) plays…"

        scheduledReturnToLiveTask = Task { [weak self] in
            guard let self, let tvController = self.tvController else { return }

            defer {
                self.isCommercialBreakLoopActive = false
            }

            for index in playlist.indices {
                guard !Task.isCancelled, self.isBreakActive else { break }

                let highlight = playlist[index]
                let displayIndex = index + 1
                var previousHighlight: SportHighlight? = index > 0 ? playlist[index - 1] : nil

                self.commercialBreakHighlightIndex = displayIndex
                self.selectedHighlightRank = highlight.interestRank
                self.lastHighlightTarget = highlight.playDescription

                await tvController.updateHighlightReelBanner(
                    index: displayIndex,
                    total: playlist.count
                )

                if index == 0 {
                    let rewind = self.calculatedRewindSeconds(for: highlight)
                    self.lastPlannedRewindSeconds = tvController.snappedRewindSeconds(targetSeconds: rewind)
                    guard tvController.triggerRewindMacro(
                        highlightDate: highlight.apiTimestamp,
                        streamDelaySeconds: self.streamDelaySeconds,
                        highlightBannerIndex: displayIndex,
                        highlightBannerTotal: playlist.count
                    ) else {
                        self.finishCommercialBreakLoop(success: false, message: tvController.statusMessage)
                        return
                    }
                    await tvController.waitForMacroCycleToFinish()
                    self.beginBreakPlayback(rewindSeconds: self.lastPlannedRewindSeconds)
                } else if let earlier = previousHighlight {
                    let watchedEarlier = self.highlightLoopWatchDuration(for: earlier)
                    let forward = SportHighlightEngine.forwardSecondsToNextHighlight(
                        earlier: earlier,
                        later: highlight,
                        watchedSeconds: watchedEarlier
                    )
                    let snapped = tvController.snappedRewindSeconds(targetSeconds: forward)
                    let ok = await tvController.skipForwardOnScrubBar(
                        targetSeconds: snapped,
                        unlimitedClicks: true
                    )
                    guard ok else {
                        self.finishCommercialBreakLoop(success: false, message: "Forward skip failed")
                        return
                    }
                    self.updateBehindAfterForward(seconds: snapped)
                    await tvController.waitForMacroCycleToFinish()
                }

                let label = highlight.playDescription.prefix(36)
                self.lastStatusSummary = "Highlight \(displayIndex)/\(playlist.count) — \(label)"
                self.appendActivity("Watching — \(label)")

                await self.waitHighlightPlayback(for: highlight)

                guard !Task.isCancelled, self.isBreakActive else { break }
            }

            guard !Task.isCancelled else { return }

            self.commercialBreakHighlightIndex = playlist.count
            self.lastStatusSummary = "Reel complete — returning to live…"
            self.appendActivity("Reel complete → Go Live")
            await self.returnToLiveAfterHighlightReel(tvController: tvController)
        }
    }

    private func returnToLiveAfterHighlightReel(tvController: TVController) async {
        let clicks = calculatedGoLiveForwardClicks()
        guard clicks > 0 else {
            finishCommercialBreakLoop(success: false, message: "Go Live skipped — nothing to catch up")
            return
        }

        clearBreakPlaybackState()
        await tvController.executeGoLiveMacro(forwardClicks: clicks)
        await tvController.endHighlightReelBanner()
        finishCommercialBreakLoop(success: true, message: "Back to live")
    }

    private func beginBreakPlayback(rewindSeconds: Int) {
        activeBreakStartedAt = activeBreakStartedAt ?? Date()
        activeBreakInitialRewindSeconds = max(activeBreakInitialRewindSeconds, rewindSeconds)
        currentBehindSeconds = rewindSeconds
        behindPositionUpdatedAt = Date()
    }

    private func updateBehindAfterForward(seconds: Int) {
        currentBehindSeconds = max(0, currentBehindSeconds - seconds)
        behindPositionUpdatedAt = Date()
    }

    /// DVR lag + wall-clock drift since last scrub move — fixes landing ~30s behind live.
    private func calculatedGoLiveForwardClicks() -> Int {
        guard let tvController else { return 0 }
        let secondsPerClick = tvController.secondsPerSkipClick()
        let wallDrift = Int(Date().timeIntervalSince(behindPositionUpdatedAt ?? Date()))
        let totalBehind = max(currentBehindSeconds, activeBreakInitialRewindSeconds) + wallDrift
        let timeBased = (totalBehind + secondsPerClick - 1) / secondsPerClick
        let ledger = tvController.lastRewindClickCount
        return max(ledger, timeBased) + 2
    }

    private func clearBreakPlaybackState() {
        activeBreakStartedAt = nil
        activeBreakInitialRewindSeconds = 0
        currentBehindSeconds = 0
        behindPositionUpdatedAt = nil
    }

    private func abortHighlightPlaybackAndReturnToLive(reason: String) async {
        scheduledReturnToLiveTask?.cancel()
        scheduledReturnToLiveTask = nil

        guard let tvController else {
            clearBreakPlaybackState()
            pendingAutoGoLive = false
            isCommercialBreakLoopActive = false
            commercialBreakHighlightIndex = 0
            hasTriggeredThisBreak = false
            isBreakActive = false
            lastBreakPlayID = nil
            return
        }

        await tvController.endHighlightReelBanner()

        while tvController.isMacroRunning || tvController.isExecutingMacro {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let clicks = calculatedGoLiveForwardClicks()
        pendingAutoGoLive = false
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        hasTriggeredThisBreak = false
        isBreakActive = false
        lastBreakPlayID = nil

        guard clicks > 0 else {
            clearBreakPlaybackState()
            lastStatusSummary = "\(reason) — nothing to catch up"
            return
        }

        lastStatusSummary = "\(reason) — returning to live (\(clicks)× forward)"
        appendActivity("\(reason) → Go Live")
        clearBreakPlaybackState()
        await tvController.executeGoLiveMacro(forwardClicks: clicks)
    }

    private func returnToLiveAfterBreak(reason: String) async {
        guard let tvController else { return }

        while tvController.isMacroRunning || tvController.isExecutingMacro {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let clicks = calculatedGoLiveForwardClicks()
        guard clicks > 0 else {
            clearBreakPlaybackState()
            return
        }

        lastStatusSummary = "\(reason) — returning to live (\(clicks)× forward)"
        appendActivity("\(reason) → Go Live")
        clearBreakPlaybackState()
        await tvController.executeGoLiveMacro(forwardClicks: clicks)
    }

    private func finishCommercialBreakLoop(success: Bool, message: String) {
        pendingAutoGoLive = false
        // Keep hasTriggeredThisBreak latched until ESPN play resumes — stops re-trigger during same break.
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        clearBreakPlaybackState()
        lastStatusSummary = message
        if !success, let tvController {
            Task { await tvController.endHighlightReelBanner() }
            appendActivity("Highlight loop stopped — \(message)")
            resetBreakSkipLatch()
        }
    }

    /// Waits for the rewind macro to finish, lets the highlight play, then Go Live.
    private func scheduleReturnToLiveAfterHighlight() {
        scheduledReturnToLiveTask?.cancel()

        let watchSeconds = highlightWatchDuration(for: selectedHighlightRank)
        scheduledReturnToLiveTask = Task { [weak self] in
            guard let self, let tvController = self.tvController else { return }

            while tvController.isMacroRunning || tvController.isExecutingMacro {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, pendingAutoGoLive else { return }

            lastStatusSummary = "Highlight playing — Go Live in \(Int(watchSeconds))s"
            appendActivity("Watching highlight → auto Go Live in \(Int(watchSeconds))s")
            tvController.statusMessage = "Watching highlight ~\(Int(watchSeconds))s…"

            try? await Task.sleep(nanoseconds: UInt64(watchSeconds * 1_000_000_000))
            guard !Task.isCancelled, pendingAutoGoLive else { return }

            if !isBreakActive {
                await abortHighlightPlaybackAndReturnToLive(reason: "Commercial ended during highlight")
                return
            }

            await returnToLiveAfterBreak(reason: "Highlight window ended")

            pendingAutoGoLive = false
        }
    }

    private func highlightWatchDuration(for rank: Int) -> TimeInterval {
        switch rank {
        case 3: baseHighlightWatchSeconds + 25
        case 2: baseHighlightWatchSeconds + 12
        default: baseHighlightWatchSeconds + 5
        }
    }

    /// Shorter watch windows during multi-highlight loops so we advance before filler airs.
    private func highlightLoopWatchDuration(for highlight: SportHighlight) -> TimeInterval {
        let override = UserDefaults.standard.double(forKey: SportsAPIStorageKey.highlightWatchSeconds)
        if override > 0 {
            return override
        }
        return SportHighlightEngine.reelWatchSeconds(for: highlight)
    }

    /// Waits while the on-TV reel banner stays up (banner managed by caller).
    private func waitHighlightPlayback(for highlight: SportHighlight) async {
        let watchSeconds = highlightLoopWatchDuration(for: highlight)
        tvController?.statusMessage = "Watching — \(Int(watchSeconds))s"
        try? await Task.sleep(nanoseconds: UInt64(watchSeconds * 1_000_000_000))
    }

    private static func isGameLive(_ summary: ESPNSummaryResponse) -> Bool {
        guard let status = summary.header?.competitions?.first?.status else { return false }
        if status.type.state?.lowercased() == "in" { return true }
        return status.type.name.uppercased() == "STATUS_IN_PROGRESS"
    }

    private static func isGameFinished(_ summary: ESPNSummaryResponse) -> Bool {
        guard let status = summary.header?.competitions?.first?.status else { return false }
        if status.type.completed == true { return true }
        let state = status.type.state?.lowercased()
        return state == "post" || status.type.name.uppercased() == "STATUS_FINAL"
    }

    private func cancelScheduledReturnToLive() {
        scheduledReturnToLiveTask?.cancel()
        scheduledReturnToLiveTask = nil
        pendingAutoGoLive = false
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        clearBreakPlaybackState()
    }

    // MARK: - Ranked Highlight Loop Engine

    func plannedHighlightRewindSeconds() async -> Int? {
        guard hasSyncedStreamLag, allowsStreamOffsetCalibration else { return nil }
        guard let summary = try? await fetchGameSummary() else { return nil }
        return rankedHighlightRewindSeconds(from: summary)
    }

    func lastHighlightPlayDescription() -> String? {
        lastHighlightTarget.isEmpty ? nil : lastHighlightTarget
    }

    /// Parses ESPN plays, ranks them, selects the top highlight, and computes precision rewind.
    private func rankedHighlightRewindSeconds(from summary: ESPNSummaryResponse) -> Int? {
        guard hasSyncedStreamLag, allowsStreamOffsetCalibration else { return nil }
        guard let best = refreshRankedHighlightCounters(from: summary) else { return nil }

        print(
            "🎯 Ranked Highlight Loop: rank \(best.interestRank) \"\(best.playDescription)\" "
            + "→ rewind \(lastPlannedRewindSeconds)s "
            + "(lead=\(Int(TimelineOffsetEngine.rewindLeadSeconds))s, "
            + "lag=\(Int(streamDelaySeconds.rounded()))s)"
        )

        return lastPlannedRewindSeconds
    }

    /// Keeps Home dashboard rank/skip counters live while ESPN polling runs.
    @discardableResult
    private func refreshRankedHighlightCounters(from summary: ESPNSummaryResponse) -> SportHighlight? {
        let snapshots = allPlays(from: summary).map(\.snapshot)
        let highlights = SportHighlightEngine.parseHighlights(from: snapshots) { parseESPNWallclock($0) }

        rankedHighlights = highlights.sorted {
            if $0.interestRank != $1.interestRank { return $0.interestRank > $1.interestRank }
            return $0.apiTimestamp > $1.apiTimestamp
        }

        commercialBreakPlaylist = supportsTimestampHighlightRewinds
            ? SportHighlightEngine.commercialBreakPlaylist(
                from: highlights,
                streamDelaySeconds: streamDelaySeconds
            )
            : []

        guard supportsTimestampHighlightRewinds else {
            if let best = highlights.max(by: { lhs, rhs in
                if lhs.interestRank != rhs.interestRank { return lhs.interestRank < rhs.interestRank }
                return lhs.apiTimestamp < rhs.apiTimestamp
            }) {
                lastHighlightTarget = best.playDescription
                selectedHighlightRank = best.interestRank
            }
            lastPlannedRewindSeconds = maxGenericSkipSeconds
            return nil
        }

        guard let best = SportHighlightEngine.bestHighlightForCommercialSkip(
            from: highlights,
            streamDelaySeconds: streamDelaySeconds
        ) else {
            selectedHighlightRank = 0
            lastPlannedRewindSeconds = 0
            return nil
        }

        lastHighlightTarget = best.playDescription
        selectedHighlightRank = best.interestRank
        lastPlannedRewindSeconds = calculatedRewindSeconds(for: best)

        return best
    }

    /// Fallback when scoreboard seed fails — summary API clock (not used during normal polling).
    private func refreshLiveGameClock(from summary: ESPNSummaryResponse) {
        let status = summary.header?.competitions?.first?.status
        let parsed = GameClockSyncEngine.parseClock(
            period: status?.period,
            clock: status?.clock,
            displayClock: status?.displayClock,
            state: status?.type.state,
            sportPath: sportPath,
            statusDetail: status?.type.detail ?? status?.type.shortDetail
        )
        liveGameClock = parsed

        guard let clock = parsed else {
            tickingGameClock = nil
            if let shortDetail = status?.type.shortDetail, !shortDetail.isEmpty {
                liveGameClockLabel = shortDetail
            } else {
                liveGameClockLabel = status?.type.description ?? "—"
            }
            return
        }

        let mode = GameClockSyncEngine.clockMode(for: sportPath)
        let now = Date()

        if !clock.isInProgress {
            tickingGameClock = TickingGameClock(
                anchor: clock,
                mode: mode,
                sportPath: sportPath,
                capturedAt: now
            )
            liveGameClockLabel = tickingGameClock?.liveDisplay(at: now) ?? clock.periodAndClockLabel
            return
        }

        // Keep local ticking between polls — only re-anchor when ESPN drifts or period changes.
        if let existing = tickingGameClock,
           existing.mode == mode,
           existing.sportPath == sportPath {
            let predicted = existing.liveClock(at: now)
            if predicted.period == clock.period {
                let drift = abs(predicted.clockSeconds - clock.clockSeconds)
                if drift <= 3 {
                    liveGameClockLabel = existing.liveDisplay(at: now)
                    return
                }
            }
        }

        tickingGameClock = TickingGameClock(
            anchor: clock,
            mode: mode,
            sportPath: sportPath,
            capturedAt: now
        )
        liveGameClockLabel = tickingGameClock?.liveDisplay(at: now) ?? clock.periodAndClockLabel
    }

    private func allPlays(from summary: ESPNSummaryResponse) -> [ESPNPlay] {
        if let keyEvents = summary.keyEvents, !keyEvents.isEmpty {
            return keyEvents
        }
        var plays: [ESPNPlay] = []
        if let previousDrives = summary.drives?.previous {
            for drive in previousDrives {
                plays.append(contentsOf: drive.plays ?? [])
            }
        }
        if let currentPlays = summary.drives?.current?.plays {
            plays.append(contentsOf: currentPlays)
        }
        return plays
    }

    // MARK: - Simulator / QA

    func simulateHalftimeBreak() {
        Task { await skipAdToHighlights() }
    }

    func simulatePlayResumed() {
        hasTriggeredThisBreak = false
        isBreakActive = false
        lastBreakPlayID = nil
        lastStatusSummary = "Simulated play resumed — debounce reset"
    }

    /// User tapped Go Live — clear break state and dismiss the on-TV highlight chip.
    func clearBreakForManualGoLive() {
        cancelScheduledReturnToLive()
        resetBreakSkipLatch()
        if let tvController {
            Task { await tvController.endHighlightReelBanner() }
        }
    }

    var hasMonitoredGame: Bool {
        !gameID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Helpers

    private func extractLatestPlay(from summary: ESPNSummaryResponse) -> ESPNPlay? {
        if let keyEvents = summary.keyEvents, let last = keyEvents.last {
            return last
        }
        if let currentPlays = summary.drives?.current?.plays, let last = currentPlays.last {
            return last
        }

        if let previousDrives = summary.drives?.previous,
           let lastDrive = previousDrives.last,
           let lastPlay = lastDrive.plays?.last {
            return lastPlay
        }

        return nil
    }

    private func parseESPNWallclock(_ string: String) -> Date? {
        if let date = Self.iso8601Standard.date(from: string) {
            return date
        }
        return Self.iso8601Fractional.date(from: string)
    }

    private func appendActivity(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        activityLog.insert("[\(formatter.string(from: Date()))] \(message)", at: 0)
        if activityLog.count > 12 {
            activityLog.removeLast()
        }
    }
}

// MARK: - HighlightRewindPlanning

extension SportsAPIService: HighlightRewindPlanning {}

// MARK: - Errors

private enum SportsAPIError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid ESPN response"
        case .httpStatus(let code):
            "ESPN returned HTTP \(code)"
        }
    }
}

// MARK: - Storage Keys

enum SportsAPIStorageKey {
    static let streamDelaySeconds = "zapremote.sports.streamDelaySeconds"
    static let monitoredGameID = "zapremote.sports.monitoredGameID"
    static let monitoredSportPath = "zapremote.sports.monitoredSportPath"
    static let monitoredGameLabel = "zapremote.sports.monitoredGameLabel"
    static let monitoredGameIsLive = "zapremote.sports.monitoredGameIsLive"
    static let matchElapsedBaseSeconds = "zapremote.sports.matchElapsedBaseSeconds"
    static let matchElapsedBaseCapturedAt = "zapremote.sports.matchElapsedBaseCapturedAt"
    static let matchClockGameID = "zapremote.sports.matchClockGameID"
    static let hasSyncedStreamLag = "zapremote.sports.hasSyncedStreamLag"
    static let handsFreeAutomation = "zapremote.sports.handsFreeAutomation"
    static let autoReturnToLiveAfterHighlight = "zapremote.sports.autoReturnToLiveAfterHighlight"
    /// 0 = auto (rank-based). Set in Settings for testing multi-highlight timing.
    static let highlightWatchSeconds = "zapremote.sports.highlightWatchSeconds"
    /// Off-air testing — synthetic clock, skip kickoff / lag gates.
    static let nonLiveTestMode = "zapremote.sports.nonLiveTestMode"
}
