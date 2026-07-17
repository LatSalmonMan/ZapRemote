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
    let commentary: [ESPNCommentaryItem]?
}

private struct ESPNCommentaryItem: Decodable, Sendable {
    let text: String?
    let play: ESPNPlay?
    let time: ESPNCommentaryTime?
}

private struct ESPNCommentaryTime: Decodable, Sendable {
    let value: Double?
    let displayValue: String?
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
    let period: ESPNPlayPeriod?
    let clock: ESPNPlayClock?

    func snapshot(sportPath: String) -> ESPNPlaySnapshot {
        let profile = SportProfile.resolve(sportPath: sportPath)
        return ESPNPlaySnapshot(
            id: id,
            text: text,
            wallclock: wallclock,
            typeText: type?.text,
            typeAbbreviation: type?.abbreviation ?? type?.type,
            matchElapsedSeconds: Self.inferredMatchElapsedSeconds(
                period: period,
                clock: clock,
                profile: profile
            ),
            matchClockLabel: clock?.displayValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    /// Match-clock elapsed for minute-based rewind (sport-aware).
    private static func inferredMatchElapsedSeconds(
        period: ESPNPlayPeriod?,
        clock: ESPNPlayClock?,
        profile: SportProfile
    ) -> Int {
        let periodNumber = max(1, period?.number ?? 1)
        let display = clock?.displayValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if profile.usesSoccerStylePlayClock {
            if !display.isEmpty, let fromDisplay = parseSoccerDisplayClock(display) {
                return fromDisplay
            }
            if let value = clock?.value, value > 0 {
                let halfSeconds = Int(value.rounded())
                if periodNumber >= 2 {
                    return 45 * 60 + halfSeconds
                }
                return halfSeconds
            }
            return 0
        }

        // Countdown sports: display/value is time remaining in the period.
        let remaining: Int? = {
            if !display.isEmpty, let parsed = GameClockSyncEngine.parseClockString(display) {
                return parsed
            }
            if let value = clock?.value, value > 0 {
                return Int(value.rounded())
            }
            return nil
        }()
        guard let remaining else { return 0 }
        return profile.elapsedGameSeconds(period: periodNumber, clockSeconds: remaining)
    }

    private static func parseSoccerDisplayClock(_ display: String) -> Int? {
        // "12'", "45'+2'", "90'+5"
        let cleaned = display.replacingOccurrences(of: " ", with: "")
        let parts = cleaned.split(separator: "+", maxSplits: 1).map(String.init)
        guard let mainPart = parts.first else { return nil }
        let mainDigits = mainPart.filter(\.isNumber)
        guard let mainMinute = Int(mainDigits), mainMinute >= 0 else { return nil }
        var total = mainMinute * 60
        if parts.count > 1 {
            let stoppageDigits = parts[1].filter(\.isNumber)
            if let stoppage = Int(stoppageDigits) {
                total += stoppage * 60
            }
        }
        return total
    }
}

private struct ESPNPlayPeriod: Decodable, Sendable {
    let number: Int?
}

private struct ESPNPlayClock: Decodable, Sendable {
    let value: Double?
    let displayValue: String?
}

private struct ESPNPlayType: Decodable, Sendable {
    let id: String?
    let text: String?
    let abbreviation: String?
    /// Soccer slug e.g. `free-kick`, `yellow-card` (ESPN field name is `type`).
    let type: String?
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
        "second half begins", "2nd half begins", "second half underway",
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
        "tv timeout"
        // Not hydration / water / cooling — match clock keeps running (stoppage).
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

    /// Soccer: hands-free only on confirmed halftime. NFL/NBA/etc.: any commercial break.
    static func isHandsFreeCommercialBreak(
        status: ESPNEventStatus?,
        latestPlay: ESPNPlay?,
        sportPath: String
    ) -> Bool {
        guard isCommercialBreak(status: status, latestPlay: latestPlay) else { return false }

        let profile = SportProfile.resolve(sportPath: sportPath)
        guard profile.handsFreeRequiresHalftimeOnly else { return true }

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

    /// Sport differences for the game the user selected (clock, breaks, highlights, copy).
    var activeSportProfile: SportProfile {
        SportProfile.resolve(sportPath: monitoredSportPath.isEmpty ? sportPath : monitoredSportPath)
    }

    var kickoffWaitBanner: String { activeSportProfile.waitingForStartBanner }

    /// UI + sync gate — `true` only after ESPN play log confirms real kickoff.
    @Published private(set) var isMatchPhysicallyActive: Bool = false

    /// Bypass kickoff / live gates — synthetic clock + rewinds for off-air testing.
    @Published private(set) var isNonLiveTestModeEnabled: Bool = false

    /// Finished / VOD game — user seeds Match Clock to their TV minute (no live ESPN tick).
    var isReplayOffsetMode: Bool {
        hasMonitoredGame && !isTrackedGameLive
    }

    /// Match Clock UI for live and replay (user-set minute that ticks).
    var usesLiveStyleMatchClock: Bool {
        hasMonitoredGame
    }

    /// Highlight rewind via match minute (replay) or wall-clock (live).
    var supportsTimestampHighlightRewinds: Bool {
        if isNonLiveTestModeEnabled { return true }
        if isTrackedGameLive { return true }
        // Replay: unlocked once the user sets the TV minute.
        return isReplayOffsetMode && hasSyncedStreamLag && matchElapsedBaseCapturedAt != nil
    }

    /// Active game is sourced from football-data.org (not ESPN).
    var usesFootballData: Bool {
        sportPath.lowercased().contains("football-data")
            || monitoredSportPath.lowercased().contains("football-data")
    }

    /// Match clock + TV offset tuning.
    var allowsStreamOffsetCalibration: Bool {
        hasMonitoredGame
    }

    /// Phase 0: manual Ad only — ESPN must not fire TV macros (reliability).
    var isHandsFreeAutomationEnabled: Bool { false }

    /// Auto Go Live when the highlight hold finishes — core product behavior.
    @Published private(set) var autoReturnToLiveAfterHighlight: Bool = true

    /// Single source of truth for break → highlight → Go Live (see `plan.md`).
    let breakSession = BreakSessionMachine()

    // MARK: Spec State

    private var hasTriggeredThisBreak = false
    private var gameID: String = ""
    private var sportPath: String = ""

    // MARK: Private

    private weak var tvController: TVController?
    private var pollingTimer: Timer?
    private var matchClockUITimer: Timer?
    private let pollIntervalSeconds: TimeInterval = 2
    /// Caps generic TV skip macros when no ESPN highlight is available.
    private let maxGenericSkipSeconds = 120
    private var lastBreakPlayID: String?
    private var scheduledReturnToLiveTask: Task<Void, Never>?
    /// ESPN game-time base — elapsed seconds in the match when `matchElapsedBaseCapturedAt` was set.
    private var matchElapsedBaseSeconds: Int = 0
    private var matchElapsedBaseCapturedAt: Date?
    /// Paused only during ESPN stoppages (halftime, timeout) — not during normal live play.
    private var isMatchClockPaused: Bool = false
    /// Replay highlight session: match elapsed frozen at pause (TV returns here).
    private var replayClockFrozenElapsed: Int = 0
    /// When the highlight hold started — VOD plays forward during hold, so return subtracts this.
    private var highlightHoldStartedAt: Date?
    /// Prevents overlapping auto / manual return macros (double RIGHT spam = huge overshoot).
    private var isAutoReturnInFlight = false
    /// Blocks ESPN from re-anchoring elapsed time while the user is tuning TV offset.
    private var offsetCalibrationHoldUntil: Date?
    /// Wall time when ESPN first confirmed kickoff — TV clock starts after `streamDelaySeconds`.
    private var matchKickoffConfirmedAt: Date?
    /// Last ESPN period applied to the local ticker (1 = 1H, 2 = 2H).
    private var lastSyncedESPNPeriod: Int = 0
    /// Delayed clock seed (kickoff / 2H → 45:00) so the phone matches the delayed TV feed.
    private var pendingMatchClockApply: PendingMatchClockApply?
    @Published private(set) var pendingAutoGoLive = false
    /// Seconds to watch the highlight after the skip macro — longer for big plays.
    private let baseHighlightWatchSeconds: TimeInterval = 45

    private struct PendingMatchClockApply {
        let elapsedSeconds: Int
        let applyAt: Date
        let paused: Bool
        let reason: String
    }

    /// Tracks how far behind TV live we are during a commercial-break highlight session.
    private var activeBreakStartedAt: Date?
    private var activeBreakInitialRewindSeconds: Int = 0
    private var currentBehindSeconds: Int = 0
    private var behindPositionUpdatedAt: Date?
    private var lastSummaryPollAt: Date?
    private var consecutiveBreakPolls = 0
    private let minBreakPollsBeforeAutoSkip = 2
    private var breakSessionObservation: AnyCancellable?

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

        let storedGameID = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredGameID) ?? ""
        gameID = storedGameID.trimmingCharacters(in: .whitespacesAndNewlines)
        monitoredGameID = gameID

        hasSyncedStreamLag = UserDefaults.standard.bool(forKey: SportsAPIStorageKey.hasSyncedStreamLag)
            && !gameID.isEmpty

        let storedSportPath = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredSportPath)
        sportPath = (storedSportPath?.isEmpty == false) ? storedSportPath! : ""
        monitoredSportPath = sportPath

        monitoredGameLabel = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredGameLabel) ?? ""

        if UserDefaults.standard.object(forKey: SportsAPIStorageKey.monitoredGameIsLive) != nil {
            isTrackedGameLive = UserDefaults.standard.bool(forKey: SportsAPIStorageKey.monitoredGameIsLive)
        }

        restoreMatchElapsedClockIfNeeded()

        // Drop yesterday’s match before restoring test-mode clocks / polling.
        expireStaleMonitoredGameIfNeeded()

        isNonLiveTestModeEnabled = UserDefaults.standard.bool(forKey: SportsAPIStorageKey.nonLiveTestMode)
        if isNonLiveTestModeEnabled, hasMonitoredGame {
            activateNonLiveTestSession()
        }

        breakSessionObservation = breakSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        pollingTimer?.invalidate()
        matchClockUITimer?.invalidate()
    }

    // MARK: - Rewind Target

    /// Last-resort rewind when ESPN plays cannot be parsed (no ranked highlight available).
    var commercialRewindTargetSeconds: Int {
        let total = streamDelaySeconds
            + activeSportProfile.commercialBreakSeconds
            + SportHighlightEngine.prePlayPaddingSeconds
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

    private static func espnResult(from fd: FootballDataGameResult) -> ESPNGameSearchResult {
        ESPNGameSearchResult(
            id: fd.id,
            eventID: String(fd.matchID),
            sportPath: "soccer/football-data",
            title: fd.title,
            statusLabel: fd.statusLabel,
            leagueLabel: fd.leagueLabel,
            isLive: fd.isLive
        )
    }

    func selectMonitoredGame(_ result: ESPNGameSearchResult) {
        let profile = SportProfile.resolve(sportPath: result.sportPath)
        // Phase 0: soccer only — keep the product promise honest.
        guard profile.kind == .soccer else {
            gameSearchStatus = "Soccer only for now — NFL comes later"
            lastStatusSummary = "Pick a soccer game (NFL later)"
            appendActivity("Blocked non-soccer pick — \(result.title)")
            return
        }

        monitoredSportPath = result.sportPath
        monitoredGameID = result.eventID
        monitoredGameLabel = result.selectionSummary
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SportsAPIStorageKey.monitoredGameSelectedAt)
        gameSearchResults = []
        gameSearchStatus = "Tracking \(result.title)"
        lastStatusSummary = "Now tracking \(result.title)"
        appendActivity("Selected soccer — \(result.title)")

        tickingGameClock = nil
        liveGameClock = nil
        clearMatchElapsedClock()
        isMatchPhysicallyActive = false
        offsetCalibrationHoldUntil = nil
        matchKickoffConfirmedAt = nil
        lastSyncedESPNPeriod = 0
        pendingMatchClockApply = nil
        isTrackedGameLive = result.isLive
        UserDefaults.standard.set(result.isLive, forKey: SportsAPIStorageKey.monitoredGameIsLive)
        liveGameClockLabel = Self.kickoffWaitClockDisplay
        resetBreakSkipLatch()
        hasSyncedStreamLag = false
        UserDefaults.standard.set(false, forKey: SportsAPIStorageKey.hasSyncedStreamLag)
        rankedHighlights = []
        commercialBreakPlaylist = []
        lastHighlightTarget = ""
        selectedHighlightRank = 0
        lastPlannedRewindSeconds = 0
        activityLog = []

        stopGamePolling()
        startGamePolling()

        // Load the full highlight list immediately (don't wait for the 2s poll).
        Task { await refreshHighlightsNow() }

        if result.isLive {
            Task { await bootstrapClockFromScoreboard() }
        }

        if isNonLiveTestModeEnabled {
            startLocalMatchClock(atSeconds: 0)
            hasSyncedStreamLag = true
            UserDefaults.standard.set(true, forKey: SportsAPIStorageKey.hasSyncedStreamLag)
        } else if !result.isLive {
            isMatchPhysicallyActive = false
            liveGameClockLabel = Self.kickoffWaitClockDisplay
            lastStatusSummary = "Set the minute your replay is on"
        }
    }

    /// Clears the tracked match, highlights, and clock — fresh Home until you pick again.
    func clearMonitoredGame(reason: String = "Cleared tracked game") {
        stopGamePolling()
        cancelScheduledReturnToLive()
        resetBreakSkipLatch()
        breakSession.resetToIdle()

        monitoredGameID = ""
        monitoredGameLabel = ""
        monitoredSportPath = ""
        gameID = ""
        sportPath = ""

        isTrackedGameLive = false
        hasSyncedStreamLag = false
        isMatchPhysicallyActive = false
        isMatchClockPaused = false
        streamDelaySeconds = 0
        tickingGameClock = nil
        liveGameClock = nil
        clearMatchElapsedClock()
        liveGameClockLabel = Self.kickoffWaitClockDisplay
        lastStatusSummary = reason

        rankedHighlights = []
        commercialBreakPlaylist = []
        lastHighlightTarget = ""
        selectedHighlightRank = 0
        lastPlannedRewindSeconds = 0
        activityLog = []
        gameSearchResults = []
        gameSearchStatus = ""

        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.monitoredGameID)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.monitoredGameLabel)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.monitoredSportPath)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.monitoredGameIsLive)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.monitoredGameSelectedAt)
        UserDefaults.standard.set(false, forKey: SportsAPIStorageKey.hasSyncedStreamLag)
        UserDefaults.standard.removeObject(forKey: TimelineCalibrationStorage.userStreamDelayKey)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.streamDelaySeconds)

        appendActivity(reason)
    }

    /// Same-day sessions stay (live or evening replay). Next calendar day → wipe stale state.
    @discardableResult
    func expireStaleMonitoredGameIfNeeded(now: Date = Date()) -> Bool {
        guard hasMonitoredGame else { return false }

        let selectedTS = UserDefaults.standard.double(forKey: SportsAPIStorageKey.monitoredGameSelectedAt)
        let selectedAt: Date
        if selectedTS > 0 {
            selectedAt = Date(timeIntervalSince1970: selectedTS)
        } else if let captured = matchElapsedBaseCapturedAt {
            // Legacy installs with no selection stamp — use clock age.
            selectedAt = captured
        } else {
            // Unknown age + not live → treat as stale so old finals don’t linger.
            if !isTrackedGameLive {
                clearMonitoredGame(reason: "Cleared old match — pick today’s game")
                return true
            }
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: SportsAPIStorageKey.monitoredGameSelectedAt)
            return false
        }

        let calendar = Calendar.current
        let differentDay = !calendar.isDate(selectedAt, inSameDayAs: now)
        let olderThanDay = now.timeIntervalSince(selectedAt) > 20 * 60 * 60
        guard differentDay || olderThanDay else { return false }

        clearMonitoredGame(reason: "Cleared yesterday’s match — pick a new game")
        return true
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

    /// Replay: jump the Match Clock to a match minute and start ticking from there.
    func setReplayMatchMinute(_ minutes: Int) {
        setReplayMatchElapsedSeconds(max(0, minutes) * 60)
    }

    /// Replay: jump the Match Clock to exact elapsed seconds and start ticking.
    func setReplayMatchElapsedSeconds(_ seconds: Int) {
        guard hasMonitoredGame else { return }
        streamDelaySeconds = 0
        startLocalMatchClock(atSeconds: max(0, seconds))
        markStreamLagSynced()
        let label = formatElapsedClock(max(0, seconds))
        lastStatusSummary = "Replay clock \(label) — ticking"
        appendActivity("Replay Match Clock set — \(label)")
    }

    /// Shifts the match clock +/− (sets game time directly; TV line follows via offset on live).
    func nudgeESPNMatchClock(by seconds: Int, at date: Date = Date()) {
        guard seconds != 0, hasMonitoredGame else { return }
        if isReplayOffsetMode {
            let current = espnElapsedSeconds(at: date) ?? matchElapsedBaseSeconds
            setReplayMatchElapsedSeconds(max(0, current + seconds))
            return
        }
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
                liveGameClockLabel = Self.kickoffWaitClockDisplay
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
        if breakSession.phase != .idle {
            breakSession.resetToIdle()
        }
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
        if let pending = pendingMatchClockApply, date < pending.applyAt {
            if pending.reason == "kickoff" {
                return 0
            }
            // 2H pending — TV still on the frozen 1H / HT clock.
            if matchElapsedBaseCapturedAt != nil {
                return max(0, rawTvElapsedSeconds(at: date))
            }
            return 0
        }
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

    /// One-shot clock seed — football-data match minute or ESPN scoreboard.
    func bootstrapClockFromScoreboard() async {
        guard hasMonitoredGame else {
            liveGameClockLabel = "Choose a game first"
            return
        }
        if isReplayOffsetMode {
            liveGameClockLabel = matchElapsedBaseCapturedAt == nil
                ? Self.kickoffWaitClockDisplay
                : espnAPIClockDisplay()
            return
        }
        if usesFootballData {
            await pollFootballDataMatch()
            liveGameClockLabel = isMatchPhysicallyActive
                ? espnAPIClockDisplay()
                : Self.kickoffWaitClockDisplay
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
        if isReplayOffsetMode {
            streamDelaySeconds = 0
            markStreamLagSynced()
        }
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
        matchKickoffConfirmedAt = nil
        lastSyncedESPNPeriod = 0
        pendingMatchClockApply = nil
        replayClockFrozenElapsed = 0
        highlightHoldStartedAt = nil
        stopMatchClockUITimer()
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.matchElapsedBaseSeconds)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.matchElapsedBaseCapturedAt)
        UserDefaults.standard.removeObject(forKey: SportsAPIStorageKey.matchClockGameID)
    }

    private func startMatchClockUITimer() {
        stopMatchClockUITimer()
        guard isMatchPhysicallyActive || pendingMatchClockApply != nil else { return }

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
        flushPendingMatchClockApplyIfNeeded()

        guard isMatchPhysicallyActive, matchElapsedBaseCapturedAt != nil else {
            if pendingMatchClockApply == nil {
                stopMatchClockUITimer()
            }
            return
        }
        guard let elapsed = espnElapsedSeconds() else { return }
        let label = formatElapsedClock(elapsed)
        if liveGameClockLabel != label {
            liveGameClockLabel = label
        }
    }

    /// True once kickoff should be visible on the delayed TV (not just on ESPN).
    var hasKickoffReachedUserTV: Bool {
        guard isMatchPhysicallyActive else { return false }
        if isNonLiveTestModeEnabled || isReplayOffsetMode { return true }
        guard hasSyncedStreamLag, streamDelaySeconds > 0 else { return true }
        if let pending = pendingMatchClockApply, pending.reason == "kickoff" {
            return Date() >= pending.applyAt
        }
        if let kickoffAt = matchKickoffConfirmedAt {
            return Date().timeIntervalSince(kickoffAt) >= streamDelaySeconds
        }
        return matchElapsedBaseCapturedAt != nil
    }

    /// Live game selected but TV feed hasn't reached kickoff yet (includes stream delay).
    var isWaitingForKickoffOnTV: Bool {
        isTrackedGameLive && !isReplayOffsetMode && !isNonLiveTestModeEnabled
            && (!isMatchPhysicallyActive || !hasKickoffReachedUserTV)
    }

    private func flushPendingMatchClockApplyIfNeeded(at date: Date = Date()) {
        guard let pending = pendingMatchClockApply, date >= pending.applyAt else { return }
        pendingMatchClockApply = nil
        let now = Self.alignedToWholeSecond(date)
        matchElapsedBaseSeconds = max(0, pending.elapsedSeconds)
        matchElapsedBaseCapturedAt = now
        isMatchClockPaused = pending.paused
        isMatchPhysicallyActive = true
        persistMatchElapsedClock()
        liveGameClockLabel = formatElapsedClock(matchElapsedBaseSeconds)
        appendActivity(
            "TV clock \(pending.reason) — \(formatElapsedClock(matchElapsedBaseSeconds))"
            + (pending.paused ? " (paused)" : "")
        )
        if !pending.paused {
            startMatchClockUITimer()
        }
    }

    private var soccerHalfLengthSeconds: Int { activeSportProfile.periodLengthSeconds() }

    private var isSoccerSport: Bool { activeSportProfile.kind == .soccer }

    /// Stream-delay wait before applying ESPN clock jumps (kickoff / 2H) to the phone ticker.
    private func delayedClockApplyDate(from now: Date = Date()) -> Date? {
        guard hasSyncedStreamLag || streamDelaySeconds > 0 else { return nil }
        let delay = max(0, streamDelaySeconds)
        guard delay >= 1 else { return nil }
        return now.addingTimeInterval(delay)
    }

    /// 2H just started on ESPN — local clock should land on ~45:00 (not keep 1H stoppage).
    private func isSoccerSecondHalfRestart(clock: ESPNGameClock, espnElapsed: Int) -> Bool {
        guard isSoccerSport, clock.period >= 2 else { return false }
        guard espnElapsed <= soccerHalfLengthSeconds + 120 else { return false }
        if lastSyncedESPNPeriod <= 1 { return true }
        if matchElapsedBaseSeconds > soccerHalfLengthSeconds + 30 { return true }
        return false
    }

    private func scheduleOrApplyMatchClock(
        elapsedSeconds: Int,
        period: Int,
        paused: Bool,
        source: String,
        forceImmediate: Bool,
        reason: String
    ) {
        let now = Self.alignedToWholeSecond(Date())
        lastSyncedESPNPeriod = max(lastSyncedESPNPeriod, period)

        if !forceImmediate, !paused, let applyAt = delayedClockApplyDate(from: now) {
            pendingMatchClockApply = PendingMatchClockApply(
                elapsedSeconds: elapsedSeconds,
                applyAt: applyAt,
                paused: false,
                reason: reason
            )
            // Hold the previous half / pre-kickoff display until the delayed TV moment.
            if reason == "kickoff" {
                matchElapsedBaseCapturedAt = nil
                liveGameClockLabel = Self.kickoffWaitClockDisplay
            } else {
                isMatchClockPaused = true
                if let elapsed = espnElapsedSeconds(at: now) {
                    liveGameClockLabel = formatElapsedClock(elapsed)
                }
            }
            let wait = max(1, Int(applyAt.timeIntervalSince(now).rounded()))
            appendActivity("\(reason) on ESPN — TV clock in \(wait)s (\(source))")
            lastStatusSummary = "\(reason) on ESPN — TV clock in \(wait)s"
            startMatchClockUITimer()
            return
        }

        pendingMatchClockApply = nil
        matchElapsedBaseSeconds = elapsedSeconds
        matchElapsedBaseCapturedAt = now
        isMatchClockPaused = paused
        liveGameClockLabel = formatElapsedClock(elapsedSeconds)
        persistMatchElapsedClock()
        if paused {
            stopMatchClockUITimer()
        } else {
            startMatchClockUITimer()
        }
        appendActivity("Match clock \(reason) (\(source)) — \(formatElapsedClock(elapsedSeconds))")
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
        var espnElapsed = GameClockSyncEngine.elapsedGameSeconds(from: clock, sportPath: sportPath)
        let now = Self.alignedToWholeSecond(Date())
        liveGameClock = clock

        // Waiting for a delayed kickoff / 2H apply — don't let mid-poll seeds jump the gun.
        if let pending = pendingMatchClockApply, Date() < pending.applyAt, !force {
            if paused {
                // HT (or other stoppage) while a pending apply is queued — cancel 2H seed if we re-entered break.
                if pending.reason != "kickoff" {
                    pendingMatchClockApply = nil
                }
            } else {
                startMatchClockUITimer()
                return
            }
        }

        // User is tuning TV offset — keep local ESPN tick steady; only offset changes TV.
        if !force, !paused,
           let holdUntil = offsetCalibrationHoldUntil,
           Date() < holdUntil,
           matchElapsedBaseCapturedAt != nil {
            isMatchClockPaused = false
            if let elapsed = espnElapsedSeconds(at: now) {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
            startMatchClockUITimer()
            return
        }

        if paused {
            pendingMatchClockApply = nil
            isMatchClockPaused = true
            matchElapsedBaseSeconds = espnElapsed
            matchElapsedBaseCapturedAt = now
            lastSyncedESPNPeriod = max(lastSyncedESPNPeriod, clock.period)
            liveGameClockLabel = formatElapsedClock(espnElapsed)
            persistMatchElapsedClock()
            stopMatchClockUITimer()
            return
        }

        let secondHalfRestart = isSoccerSecondHalfRestart(clock: clock, espnElapsed: espnElapsed)
        if secondHalfRestart {
            // Official restart is 45:00 — don't keep 1H stoppage (45'+2) into the second half.
            espnElapsed = max(soccerHalfLengthSeconds, min(espnElapsed, soccerHalfLengthSeconds + 60))
            scheduleOrApplyMatchClock(
                elapsedSeconds: espnElapsed,
                period: clock.period,
                paused: false,
                source: source,
                forceImmediate: force && !hasSyncedStreamLag,
                reason: "2H kickoff"
            )
            return
        }

        // Initial seed or forced resync only — never drift-correct during live play.
        guard force || matchElapsedBaseCapturedAt == nil else {
            isMatchClockPaused = false
            lastSyncedESPNPeriod = max(lastSyncedESPNPeriod, clock.period)
            startMatchClockUITimer()
            if let elapsed = espnElapsedSeconds(at: now) {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
            return
        }

        let isInitialKickoffSeed = matchElapsedBaseCapturedAt == nil && espnElapsed < 90
        if isInitialKickoffSeed {
            scheduleOrApplyMatchClock(
                elapsedSeconds: espnElapsed,
                period: max(1, clock.period),
                paused: false,
                source: source,
                forceImmediate: force && !hasSyncedStreamLag,
                reason: "kickoff"
            )
            return
        }

        isMatchClockPaused = false
        pendingMatchClockApply = nil
        matchElapsedBaseSeconds = espnElapsed
        matchElapsedBaseCapturedAt = now
        lastSyncedESPNPeriod = max(lastSyncedESPNPeriod, clock.period)
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
        if matchKickoffConfirmedAt == nil {
            matchKickoffConfirmedAt = Date()
        }
        scheduleOrApplyMatchClock(
            elapsedSeconds: 0,
            period: 1,
            paused: false,
            source: "fallback",
            forceImmediate: !hasSyncedStreamLag,
            reason: "kickoff"
        )
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

    /// Universal highlight rewind — prefers match-minute math, else wall-clock on live.
    func calculatedRewindSeconds(for highlight: SportHighlight, now: Date = Date()) -> Int {
        let lead = SportHighlightEngine.leadInSeconds(for: highlight)

        if highlight.matchElapsedSeconds > 0,
           let tvElapsed = tvElapsedSeconds(at: now) {
            let raw = TimelineOffsetEngine.rewindSeconds(
                tvElapsedSeconds: tvElapsed,
                highlightElapsedSeconds: highlight.matchElapsedSeconds,
                leadSeconds: lead
            )
            if raw > Self.maxSanityRewindSeconds {
                print("⚠️ SportsAPIService: minute rewind \(raw)s capped — re-sync Match Clock")
                return tvController?.snappedSkipSeconds(targetSeconds: commercialRewindTargetSeconds)
                    ?? commercialRewindTargetSeconds
            }
            return raw
        }

        // Wall-clock math is for live broadcasts only (replay timestamps are historical).
        guard supportsTimestampHighlightRewinds, isTrackedGameLive else {
            return tvController?.snappedSkipSeconds(targetSeconds: maxGenericSkipSeconds) ?? maxGenericSkipSeconds
        }
        let raw = TimelineOffsetEngine.rewindSeconds(
            highlightDate: highlight.apiTimestamp,
            streamDelaySeconds: streamDelaySeconds,
            now: now,
            leadSeconds: lead
        )
        if raw > Self.maxSanityRewindSeconds {
            print("⚠️ SportsAPIService: rewind \(raw)s capped — sync Match Clock or pick a live game")
            return tvController?.snappedSkipSeconds(targetSeconds: commercialRewindTargetSeconds)
                ?? commercialRewindTargetSeconds
        }
        return raw
    }

    /// All notable highlights for this game — fouls/free kicks/shots/goals/cards/corners.
    /// Always gated by stream delay so popups appear when the play hits the delayed TV.
    func highlightsBehindTVPosition(at date: Date = Date()) -> [SportHighlight] {
        let candidates = rankedHighlights.filter { SportHighlightEngine.isListWorthy($0) }
        guard !candidates.isEmpty else { return [] }

        let tvElapsed = tvElapsedSeconds(at: date)
        let minAgeOnTV: TimeInterval = 3
        let delay = max(0, streamDelaySeconds)

        // Before Match Clock sync with no delay set: show ESPN-aged plays (full half on load).
        // Once delay is known (synced or slider), hide anything not yet on the TV timeline.
        let enforceTVGate = hasSyncedStreamLag || isNonLiveTestModeEnabled || delay >= 1

        let behind = candidates.filter { highlight in
            let age = highlight.ageOnUserTV(now: date, streamDelaySeconds: delay)
            let needed = minAgeOnTV + Double(max(0, highlight.sequenceSpanSeconds))
            let ageOK = age >= needed

            guard enforceTVGate else {
                // Still require a few seconds after ESPN logs so the list doesn't flicker.
                return age >= minAgeOnTV
            }

            if highlight.matchElapsedSeconds > 0, let tvElapsed {
                let endElapsed = highlight.matchElapsedSeconds + max(0, highlight.sequenceSpanSeconds)
                return endElapsed <= tvElapsed && ageOK
            }
            return ageOK
        }

        return behind.sorted { lhs, rhs in
            if lhs.matchElapsedSeconds > 0, rhs.matchElapsedSeconds > 0,
               lhs.matchElapsedSeconds != rhs.matchElapsedSeconds {
                return lhs.matchElapsedSeconds > rhs.matchElapsedSeconds
            }
            return lhs.apiTimestamp > rhs.apiTimestamp
        }
    }

    /// Force-fetch ESPN plays and rebuild the highlight list (game select / app relaunch).
    func refreshHighlightsNow() async {
        guard hasMonitoredGame else { return }
        if usesFootballData {
            await pollFootballDataMatch()
            return
        }
        do {
            let summary = try await fetchGameSummary()
            lastSummaryPollAt = Date()
            _ = refreshRankedHighlightCounters(from: summary)
            let count = highlightsBehindTVPosition().count
            if count > 0 {
                lastStatusSummary = "\(count) highlight(s) loaded — tap one to rewind"
            } else {
                lastStatusSummary = "No highlights yet — waiting for \(activeSportProfile.highlightEmptyHint)"
            }
            appendActivity("Highlights refreshed — \(rankedHighlights.filter { $0.interestRank >= 2 }.count) notable")
        } catch {
            lastStatusSummary = "Couldn't load highlights — \(error.localizedDescription)"
            print("❌ refreshHighlightsNow: \(error.localizedDescription)")
        }
    }

    /// User tapped a highlight row — rewind, watch, return to prior TV position.
    func rewindToHighlight(_ highlight: SportHighlight) async {
        guard breakSession.canAcceptAdTap else {
            lastStatusSummary = "Already rewinding — wait for it to finish"
            return
        }
        guard let tvController, tvController.isConnected else {
            lastStatusSummary = "Connect your TV first"
            return
        }
        if usesLiveStyleMatchClock, !hasSyncedStreamLag {
            lastStatusSummary = "Sync Match Clock first — tap ± until TV matches"
            return
        }

        lastHighlightTarget = highlight.playDescription
        selectedHighlightRank = highlight.interestRank
        let rewind = calculatedRewindSeconds(for: highlight)
        lastPlannedRewindSeconds = tvController.snappedRewindSeconds(targetSeconds: rewind)
        appendActivity("Tap highlight — \(highlight.matchMinuteLabel) \(highlight.playDescription)")
        await executeAdSkipRewind(rewindSeconds: lastPlannedRewindSeconds, source: "Highlight tap")
    }

    private func applyScoreboardClock(_ clock: ESPNGameClock) {
        applyESPNGameClock(clock, source: "scoreboard", force: true)
    }

    // MARK: - Clock Display (elapsed 00:00 + TV delay offset)

    /// ESPN elapsed match clock — zero delay, ticks from kickoff / user-set replay minute.
    func espnAPIClockDisplay(at date: Date = Date()) -> String {
        if isReplayOffsetMode, !isNonLiveTestModeEnabled, matchElapsedBaseCapturedAt == nil {
            return Self.kickoffWaitClockDisplay
        }
        guard let elapsed = espnElapsedSeconds(at: date) else {
            return Self.kickoffWaitClockDisplay
        }
        return formatElapsedClock(elapsed)
    }

    /// What your TV should show — ESPN elapsed minus `streamDelaySeconds` (replay delay is 0).
    func calibratedTVTimelineDisplay(at date: Date = Date()) -> String {
        if isReplayOffsetMode, !isNonLiveTestModeEnabled, matchElapsedBaseCapturedAt == nil {
            return Self.kickoffWaitClockDisplay
        }
        if let pending = pendingMatchClockApply,
           pending.reason == "kickoff",
           date < pending.applyAt {
            return Self.kickoffWaitClockDisplay
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
        if isReplayOffsetMode {
            if matchElapsedBaseCapturedAt == nil || !hasSyncedStreamLag {
                return "Set the match minute on your TV — clock ticks from there like live."
            }
            return "Replay clock running — ± jumps to a new minute and keeps ticking."
        }
        let seconds = Int(streamDelaySeconds.rounded())
        guard isMatchPhysicallyActive else {
            return kickoffWaitBanner
        }
        if !hasKickoffReachedUserTV {
            let wait = max(1, Int(streamDelaySeconds.rounded()))
            return "Kickoff on ESPN — TV clock starts in ~\(wait)s (your delay)."
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

    /// Starts match polling — ESPN or football-data.org depending on sport path.
    func startGamePolling() {
        let trimmedID = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = sportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            monitoringStatus = .idle
            lastStatusSummary = "Choose a game to start monitoring"
            return
        }
        guard !trimmedPath.isEmpty else {
            monitoringStatus = .idle
            lastStatusSummary = "Choose a game — sport path missing"
            return
        }
        gameID = trimmedID
        sportPath = trimmedPath

        stopGamePolling()

        hasTriggeredThisBreak = false
        isBreakActive = false
        monitoringStatus = .monitoring
        let source = usesFootballData ? "football-data" : "ESPN"
        lastStatusSummary = "Polling \(source) game \(gameID)"
        appendActivity("Started polling \(source) \(gameID)")

        // football-data free tier ~10 req/min — poll slower than ESPN.
        let interval = usesFootballData ? 12.0 : pollIntervalSeconds
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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
        if pollingTimer == nil {
            startGamePolling()
        }
        Task { await refreshHighlightsNow() }
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

        if usesFootballData {
            await pollFootballDataMatch()
            return
        }

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

    private func pollFootballDataMatch() async {
        guard let matchID = Int(gameID) else {
            monitoringStatus = .error
            lastStatusSummary = "Invalid football-data match id"
            return
        }

        do {
            let match = try await FootballDataClient.fetchMatch(id: matchID)
            lastSummaryPollAt = Date()
            await evaluateFootballDataMatch(match)
        } catch {
            monitoringStatus = .error
            lastStatusSummary = error.localizedDescription
            print("❌ football-data poll: \(error.localizedDescription)")
        }
    }

    private func evaluateFootballDataMatch(_ match: FDMatch) async {
        monitoringStatus = .monitoring
        isTrackedGameLive = match.isLive
        UserDefaults.standard.set(match.isLive, forKey: SportsAPIStorageKey.monitoredGameIsLive)

        let status = (match.status ?? "").uppercased()
        if status == "IN_PLAY" || status == "PAUSED" || status == "FINISHED" {
            isMatchPhysicallyActive = true
        } else if !isNonLiveTestModeEnabled {
            isMatchPhysicallyActive = false
            liveGameClockLabel = Self.kickoffWaitClockDisplay
            lastStatusSummary = kickoffWaitBanner
        }

        if isMatchPhysicallyActive {
            let elapsed = match.elapsedMatchSeconds
            if matchElapsedBaseCapturedAt == nil || abs((espnElapsedSeconds() ?? 0) - elapsed) > 90 {
                startLocalMatchClock(atSeconds: elapsed)
            } else if status == "PAUSED" {
                // Hold clock at HT / stoppage without forcing a full reset every poll.
                liveGameClockLabel = formatElapsedClock(espnElapsedSeconds() ?? elapsed)
            } else {
                startMatchClockUITimer()
                if let local = espnElapsedSeconds() {
                    liveGameClockLabel = formatElapsedClock(local)
                }
            }
        }

        let highlights = FootballDataHighlightParser.highlights(from: match)
        rankedHighlights = highlights.sorted {
            if $0.interestRank != $1.interestRank { return $0.interestRank > $1.interestRank }
            return $0.matchElapsedSeconds > $1.matchElapsedSeconds
        }
        commercialBreakPlaylist = highlights

        if let first = highlightsBehindTVPosition().first {
            lastHighlightTarget = first.playDescription
            selectedHighlightRank = first.interestRank
            lastPlannedRewindSeconds = calculatedRewindSeconds(for: first)
        } else if let newest = highlights.last {
            lastHighlightTarget = newest.playDescription
            selectedHighlightRank = newest.interestRank
            lastPlannedRewindSeconds = 0
        }

        if let goalText = highlights.last?.playDescription {
            latestESPNPlayLabel = goalText
        }

        if status == "PAUSED" {
            isBreakActive = true
            lastStatusSummary = "\(activeSportProfile.breakStatusHint) below"
        } else if match.isLive {
            isBreakActive = false
            let behind = highlightsBehindTVPosition().count
            lastStatusSummary = behind > 0
                ? "\(behind) highlight(s) behind your TV clock — tap one"
                : "Live \(match.statusLabel) — waiting for \(activeSportProfile.highlightEmptyHint)"
        } else if match.isFinished {
            lastStatusSummary = "Full time — \(highlights.count) highlight(s)"
        } else {
            lastStatusSummary = match.statusLabel
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
            // Finished / replay — user seeds Match Clock; do not auto-start at 00:00.
            return
        }

        let wasActive = isMatchPhysicallyActive
        let plays = allPlays(from: summary)
        let status = summary.header?.competitions?.first?.status
        let verified = KickoffVerificationGate.verify(status: status, plays: plays)

        isMatchPhysicallyActive = verified

        guard verified else {
            if hasSyncedStreamLag {
                // keep lag sync — user may have calibrated before ESPN confirms kickoff
            } else if isTrackedGameLive {
                lastStatusSummary = kickoffWaitBanner
            }
            return
        }

        if !wasActive {
            matchKickoffConfirmedAt = Date()
            lastStatusSummary = hasSyncedStreamLag && streamDelaySeconds >= 1
                ? "Kickoff on ESPN — TV clock starts in \(Int(streamDelaySeconds.rounded()))s"
                : "Kickoff — loading match clock from ESPN"
        } else {
            startMatchClockUITimer()
            if let elapsed = espnElapsedSeconds() {
                liveGameClockLabel = formatElapsedClock(elapsed)
            }
        }
    }

    private func reconcileLiveMatchClock(from summary: ESPNSummaryResponse, paused: Bool) async {
        guard isMatchPhysicallyActive, isTrackedGameLive, !isReplayOffsetMode else { return }

        flushPendingMatchClockApplyIfNeeded()

        let wasPaused = isMatchClockPaused
        if let pending = pendingMatchClockApply, Date() < pending.applyAt {
            // Hold until delayed kickoff / 2H lands on the TV timeline.
            if paused, pending.reason != "kickoff" {
                pendingMatchClockApply = nil
            } else {
                startMatchClockUITimer()
                return
            }
        }

        if matchElapsedBaseCapturedAt == nil {
            await syncMatchClockFromScoreboard(force: true, paused: paused)
            if matchElapsedBaseCapturedAt == nil, pendingMatchClockApply == nil {
                syncMatchClockFromSummary(summary, force: true, paused: paused)
            }
            if matchElapsedBaseCapturedAt == nil, pendingMatchClockApply == nil {
                beginKickoffElapsedClockFallback()
            }
            return
        }

        if paused {
            syncMatchClockFromSummary(summary, force: true, paused: true)
        } else if wasPaused {
            // Leaving HT / stoppage — force ESPN seed (2H → 45:00 when period advances).
            syncMatchClockFromSummary(summary, force: true, paused: false)
            if matchElapsedBaseCapturedAt == nil, pendingMatchClockApply == nil {
                await syncMatchClockFromScoreboard(force: true, paused: false)
            }
        } else {
            if let clock = parseClock(from: summary) {
                let espnElapsed = GameClockSyncEngine.elapsedGameSeconds(from: clock, sportPath: sportPath)
                if isSoccerSecondHalfRestart(clock: clock, espnElapsed: espnElapsed) {
                    syncMatchClockFromSummary(summary, force: true, paused: false)
                } else if let local = espnElapsedSeconds(), abs(espnElapsed - local) > 90 {
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
        if !isCommercialBreakLoopActive, !breakSession.isBreakActive {
            _ = refreshRankedHighlightCounters(from: summary)
        }

        if let text = latestPlay?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            latestESPNPlayLabel = text
        }
        let statusLabel = status?.type.description ?? status?.type.name ?? latestPlay?.text ?? "Unknown"

        // Highlight / auto-return in progress — ESPN polling must NOT interrupt.
        // Auto Go Live after a highlight is owned only by `forceReturnAfterHighlight` at watch end.
        // (A race here used to wipe the ledger mid-watch and make return no-op.)
        if isCommercialBreakLoopActive
            || breakSession.isBreakActive
            || pendingAutoGoLive
            || (hasTriggeredThisBreak && (tvController?.isMacroRunning == true
                || tvController?.isExecutingMacro == true
                || tvController?.isReturningToLive == true)) {
            isBreakActive = true
            let phase = breakSession.phase.rawValue
            lastStatusSummary = breakSession.phase == .holding
                ? "Watching highlight — \(Int(breakSession.ledger.watchSeconds))s"
                : "Highlight — \(phase)"
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

            let minPolls = activeSportProfile.minBreakPollsBeforeAutoSkip

            if handsFreeBreak,
               isHandsFreeAutomationEnabled,
               supportsTimestampHighlightRewinds,
               consecutiveBreakPolls >= minPolls,
               !hasTriggeredThisBreak {
                await triggerAutomaticAdSkip(source: "ESPN auto")
            } else if handsFreeBreak, !hasTriggeredThisBreak {
                if supportsTimestampHighlightRewinds {
                    if hasSyncedStreamLag {
                        lastStatusSummary = "Break on ESPN — tap Ad on my TV when you see commercials"
                    } else {
                        lastStatusSummary = "Break detected — sync Match Clock, then tap Ad"
                    }
                } else {
                    lastStatusSummary = "Break on ESPN — set Match Clock minute, then tap Ad"
                }
            } else if !handsFreeBreak, !hasTriggeredThisBreak {
                lastStatusSummary = "Waiting for commercial — tap Ad when you see one"
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

            // Do not steal auto-return from an in-flight highlight watch.
            if hasTriggeredThisBreak || isBreakActive || pendingAutoGoLive {
                isBreakActive = true
                lastStatusSummary = "Highlight in progress — auto return when watch ends"
                return
            }

            lastStatusSummary = "In progress — \(statusLabel)"
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
            lastStatusSummary = kickoffWaitBanner
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

    /// User saw an ad on TV — rewind to ONE highlight, hold, then Go Live (Phase 0 FSM).
    func skipAdToHighlights() async {
        guard let tvController else {
            lastStatusSummary = "Ad skip failed — TV not configured"
            return
        }

        guard breakSession.canAcceptAdTap else {
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

        let rewindSeconds = await resolveAdSkipRewindSeconds(preferCached: false)
        await executeAdSkipRewind(rewindSeconds: rewindSeconds, source: "Ad on TV")
    }

    /// Picks ranked ESPN highlight rewind, generic fallback, or a fixed test skip.
    private func resolveAdSkipRewindSeconds(preferCached: Bool = false) async -> Int {
        // Phase 0: always prefer a fresh summary for manual Ad (reliability over cache speed).
        _ = preferCached

        var selectedHighlight: SportHighlight?
        if let summary = try? await fetchGameSummary() {
            isTrackedGameLive = Self.isGameLive(summary)
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

    /// Cloud ad detector — Phase 0: do not auto-fire macros (manual Ad only).
    func skipAdFromCloudDetection(fallbackRewindSeconds: Int) async {
        _ = fallbackRewindSeconds
        lastStatusSummary = "Cloud ad seen — tap Ad on my TV to skip (auto disabled for reliability)"
        appendActivity("Cloud ad ignored — Phase 0 manual trigger only")
        print("🛑 SportsAPIService: cloud ad-detect ignored — Phase 0 manual Ad only")
    }

    /// Cloud detector says game is live again — return after TV feed catches up.
    func resumeFromCloudGameLive() async {
        // Let the highlight watch finish — auto return at end owns the scrub forward.
        if pendingAutoGoLive || breakSession.isHolding || breakSession.isRewinding {
            lastStatusSummary = "Highlight playing — auto return when watch ends"
            return
        }

        if breakSession.isBreakActive {
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

        if supportsTimestampHighlightRewinds, lastPlannedRewindSeconds > 0 {
            let planned = lastPlannedRewindSeconds
            if planned > Self.maxSanityRewindSeconds {
                lastStatusSummary = "Match Clock looks wrong (\(planned)s rewind) — re-sync TV ±"
                tvController.statusMessage = lastStatusSummary
                appendActivity("Skip blocked — Match Clock out of sync")
                return
            }
        }

        guard breakSession.canAcceptAdTap else {
            lastStatusSummary = "Rewind already running — wait a few sec."
            return
        }

        if tvController.isExecutingMacro || tvController.isMacroRunning {
            let message = "Rewind already running — wait a few sec."
            lastStatusSummary = message
            tvController.statusMessage = message
            appendActivity("Ad skip blocked — macro lock active")
            return
        }

        if tvController.currentAppID.isEmpty, !tvController.preferredStreamingAppID.isEmpty {
            Task { await tvController.fetchActiveAppID() }
        }

        // Phase 0: always single highlight — multi-reel deferred for reliability.
        await executeSingleHighlightSkip(rewindSeconds: rewindSeconds, source: source)
    }

    private func executeSingleHighlightSkip(rewindSeconds: Int, source: String) async {
        guard let tvController else { return }

        let highlight = lastHighlightTarget.isEmpty ? "generic skip" : lastHighlightTarget
        let rankLabel = selectedHighlightRank > 0 ? "R\(selectedHighlightRank)" : "—"
        let secondsPerClick = tvController.secondsPerSkipClick()
        let snapped = tvController.snappedRewindSeconds(targetSeconds: rewindSeconds)
        let skipClicks = max(1, snapped / secondsPerClick)
        let watchProbe = SportHighlight(
            id: "watch-probe",
            playDescription: highlight,
            apiTimestamp: Date(),
            interestRank: max(1, selectedHighlightRank)
        )
        let watchSeconds = SportHighlightEngine.reelWatchSeconds(for: watchProbe)

        guard breakSession.arm(
            streamDelaySeconds: streamDelaySeconds,
            highlightDescription: highlight,
            highlightRank: selectedHighlightRank,
            computedRewindSeconds: rewindSeconds,
            snappedRewindSeconds: snapped,
            rewindClicks: skipClicks,
            watchSeconds: watchSeconds
        ) else {
            lastStatusSummary = "Skip already running — wait for it to finish"
            return
        }

        hasTriggeredThisBreak = true
        isBreakActive = true
        // Always auto-return after the watch — this is the product path (manual Go Live is secondary).
        pendingAutoGoLive = true
        lastPlannedRewindSeconds = snapped
        lastStatusSummary = "\(source) — \(rankLabel) → \(highlight) (\(skipClicks)×\(secondsPerClick)s)"
        appendActivity("\(source) → \(skipClicks) skips on TV")
        appendActivity(breakSession.sessionLogLine())
        tvController.statusMessage = "Sending \(skipClicks)×\(secondsPerClick)s skip…"

        guard breakSession.beginRewind() else {
            breakSession.fail("Could not start rewind")
            finishReliableSkip(success: false, message: breakSession.lastErrorMessage)
            return
        }

        pauseReplayMatchClockForHighlightSession()

        await tvController.updateHighlightReelBanner(index: 1, total: 1)
        let started = tvController.triggerRewindMacro(targetSeconds: snapped)
        if !started {
            breakSession.fail(tvController.statusMessage)
            finishReliableSkip(success: false, message: tvController.statusMessage)
            return
        }

        beginBreakPlayback(rewindSeconds: snapped)
        await tvController.waitForMacroKeysToFinish()

        // Prefer clicks actually sent; fall back to planned count.
        let rewindClicksDone: Int = {
            let sent = tvController.lastRewindClickCount
            if sent > 0 { return sent }
            return max(1, skipClicks)
        }()

        // Prefer Settings override when set; otherwise rank-based hold.
        let override = UserDefaults.standard.double(forKey: SportsAPIStorageKey.highlightWatchSeconds)
        let holdSeconds = override > 0 ? override : watchSeconds

        // Wall-clock from rewind land — return math subtracts this.
        highlightHoldStartedAt = Date()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = breakSession.beginHold(actualRewindClicks: rewindClicksDone)
        breakSession.recordHeldSeconds(holdSeconds)

        lastStatusSummary = "Highlight — watching \(Int(holdSeconds))s"
        appendActivity("Watching — \(highlight.prefix(36)) (\(Int(holdSeconds))s) → auto return")
        appendActivity(breakSession.sessionLogLine())
        tvController.statusMessage = "Watching — \(Int(holdSeconds))s, then auto return"

        let watchStarted = Date()
        let deadline = watchStarted.addingTimeInterval(holdSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let highlightSeconds = max(
            holdSeconds,
            highlightHoldStartedAt.map { Date().timeIntervalSince($0) } ?? holdSeconds
        )
        breakSession.recordHeldSeconds(highlightSeconds)

        await forceReturnAfterHighlight(
            tvController: tvController,
            rewindClicks: rewindClicksDone,
            highlightSeconds: highlightSeconds
        )
    }

    /// Auto return once. Math: floor((rewindSec − watched − seekPlaythrough) / spc).
    private func forceReturnAfterHighlight(
        tvController: TVController,
        rewindClicks: Int,
        highlightSeconds: Double
    ) async {
        guard !isAutoReturnInFlight else {
            print("⏩ SportsAPIService: return already in flight — ignoring duplicate")
            return
        }
        isAutoReturnInFlight = true
        defer { isAutoReturnInFlight = false }

        let spc = max(1, tvController.secondsPerSkipClick())
        let spacingMs = StreamingAppSkipProfile.profile(
            for: tvController.currentAppID.isEmpty
                ? tvController.preferredStreamingAppID
                : tvController.currentAppID
        ).clickSpacingMs
        let seekPlaythrough = HighlightReturnMath.estimatedSeekPlaythroughSeconds(
            clicks: rewindClicks,
            spacingMs: spacingMs
        )
        let forwardClicks = HighlightReturnMath.forwardClicks(
            rewindClicks: rewindClicks,
            highlightSeconds: highlightSeconds,
            secondsPerClick: spc,
            rewindSeekPlaythroughSeconds: seekPlaythrough
        )
        let remainingSeconds = max(
            0,
            Int(floor(Double(rewindClicks * spc) - highlightSeconds - seekPlaythrough))
        )

        _ = breakSession.beginReturn(forwardClicks: forwardClicks)
        pendingAutoGoLive = false
        await tvController.endHighlightReelBanner()

        let line =
            "Return — \(rewindClicks)×\(spc)s − \(Int(highlightSeconds))s watch − \(Int(seekPlaythrough))s seek "
            + "→ \(remainingSeconds)s → \(forwardClicks)× RIGHT"
        print("⏩ SportsAPIService: \(line)")
        appendActivity(line)
        lastStatusSummary = "Returning (\(forwardClicks)× forward)…"
        tvController.statusMessage = "Returning (\(forwardClicks)× forward)…"

        await tvController.executeHighlightReturnMacro(forwardClicks: forwardClicks)

        clearBreakPlaybackState()
        highlightHoldStartedAt = nil
        _ = breakSession.beginCooldown()
        finishReliableSkip(
            success: true,
            message: "Back — \(forwardClicks)× RIGHT after \(Int(highlightSeconds))s watch"
        )
        try? await Task.sleep(nanoseconds: UInt64(BreakSessionMachine.cooldownSeconds * 1_000_000_000))
        if breakSession.phase == .cooldown {
            breakSession.resetToIdle()
        }
    }

    private func returnToLiveAfterReliableSkip(tvController: TVController) async {
        let rewindClicks = max(breakSession.ledger.rewindClicks, tvController.lastRewindClickCount, 1)
        let highlightSeconds = breakSession.ledger.watchSeconds > 0
            ? breakSession.ledger.watchSeconds
            : breakSession.ledger.actualHeldSeconds
        await forceReturnAfterHighlight(
            tvController: tvController,
            rewindClicks: rewindClicks,
            highlightSeconds: highlightSeconds
        )
    }

    private func finishReliableSkip(success: Bool, message: String) {
        resumeReplayMatchClockAfterHighlightSession()
        pendingAutoGoLive = false
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        clearBreakPlaybackState()
        lastStatusSummary = message
        if success {
            isBreakActive = false
            // Highlight browser: allow another tap immediately after return.
            hasTriggeredThisBreak = false
        } else {
            Task { await tvController?.endHighlightReelBanner() }
            appendActivity("Skip stopped — \(message)")
            breakSession.fail(message)
            resetBreakSkipLatch()
            breakSession.resetToIdle()
        }
    }

    /// Replay only — freeze match clock at the user's viewing minute while away on a highlight.
    /// On resume, restore that same minute (TV returns there; do not add wall-wait — that desynced the clock).
    private func pauseReplayMatchClockForHighlightSession(at date: Date = Date()) {
        guard isReplayOffsetMode, matchElapsedBaseCapturedAt != nil else { return }
        let frozen = espnElapsedSeconds(at: date) ?? matchElapsedBaseSeconds
        replayClockFrozenElapsed = max(0, frozen)
        matchElapsedBaseSeconds = replayClockFrozenElapsed
        matchElapsedBaseCapturedAt = Self.alignedToWholeSecond(date)
        isMatchClockPaused = true
        liveGameClockLabel = formatElapsedClock(matchElapsedBaseSeconds)
        persistMatchElapsedClock()
        appendActivity("Replay clock paused at \(formatElapsedClock(matchElapsedBaseSeconds))")
    }

    private func resumeReplayMatchClockAfterHighlightSession(at date: Date = Date()) {
        guard isReplayOffsetMode else { return }
        guard isMatchClockPaused || matchElapsedBaseCapturedAt != nil else { return }

        let restore = replayClockFrozenElapsed > 0
            ? replayClockFrozenElapsed
            : (espnElapsedSeconds(at: date) ?? matchElapsedBaseSeconds)
        matchElapsedBaseSeconds = max(0, restore)
        matchElapsedBaseCapturedAt = Self.alignedToWholeSecond(date)
        replayClockFrozenElapsed = 0
        highlightHoldStartedAt = nil
        isMatchClockPaused = false
        persistMatchElapsedClock()
        startMatchClockUITimer()
        liveGameClockLabel = formatElapsedClock(matchElapsedBaseSeconds)
        appendActivity("Replay clock restored at \(liveGameClockLabel)")
    }

    /// Cycles ranked plays — Phase 0: disabled; routes to single highlight.
    private func runCommercialBreakHighlightLoop(source: String) async {
        await executeSingleHighlightSkip(
            rewindSeconds: lastPlannedRewindSeconds,
            source: source
        )
    }

    private func returnToLiveAfterHighlightReel(tvController: TVController) async {
        await returnToLiveAfterReliableSkip(tvController: tvController)
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

    /// Same math as `forceReturnAfterHighlight` — for manual / abort Go Live.
    private func calculatedGoLiveForwardClicks() -> Int {
        guard let tvController else { return 1 }
        let spc = max(1, tvController.secondsPerSkipClick())
        let ledgerClicks: Int = {
            let sent = tvController.lastRewindClickCount
            if sent > 0 { return sent }
            return max(1, breakSession.ledger.rewindClicks)
        }()
        let highlightSeconds: Double = {
            if let started = highlightHoldStartedAt {
                return max(0, Date().timeIntervalSince(started))
            }
            if breakSession.ledger.actualHeldSeconds > 0 {
                return breakSession.ledger.actualHeldSeconds
            }
            return max(0, breakSession.ledger.watchSeconds)
        }()
        let spacingMs = StreamingAppSkipProfile.profile(
            for: tvController.currentAppID.isEmpty
                ? tvController.preferredStreamingAppID
                : tvController.currentAppID
        ).clickSpacingMs
        let seekPlaythrough = HighlightReturnMath.estimatedSeekPlaythroughSeconds(
            clicks: ledgerClicks,
            spacingMs: spacingMs
        )
        return HighlightReturnMath.forwardClicks(
            rewindClicks: ledgerClicks,
            highlightSeconds: highlightSeconds,
            secondsPerClick: spc,
            rewindSeekPlaythroughSeconds: seekPlaythrough
        )
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
            resumeReplayMatchClockAfterHighlightSession()
            clearBreakPlaybackState()
            pendingAutoGoLive = false
            isCommercialBreakLoopActive = false
            commercialBreakHighlightIndex = 0
            hasTriggeredThisBreak = false
            isBreakActive = false
            lastBreakPlayID = nil
            breakSession.resetToIdle()
            return
        }

        await tvController.endHighlightReelBanner()

        while tvController.isMacroRunning || tvController.isExecutingMacro {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        pendingAutoGoLive = false
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        hasTriggeredThisBreak = false
        isBreakActive = false
        lastBreakPlayID = nil

        let rewindClicks = max(breakSession.ledger.rewindClicks, tvController.lastRewindClickCount, 1)
        let highlightSeconds = breakSession.ledger.watchSeconds > 0
            ? breakSession.ledger.watchSeconds
            : (highlightHoldStartedAt.map { Date().timeIntervalSince($0) } ?? breakSession.ledger.actualHeldSeconds)
        await forceReturnAfterHighlight(
            tvController: tvController,
            rewindClicks: rewindClicks,
            highlightSeconds: highlightSeconds
        )
    }

    private func returnToLiveAfterBreak(reason: String) async {
        guard let tvController else { return }

        while tvController.isMacroRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let clicks = calculatedGoLiveForwardClicks()
        lastStatusSummary = "\(reason) — returning to live (\(clicks)× forward)"
        appendActivity("\(reason) → Go Live (\(clicks)× RIGHT)")
        await tvController.executeHighlightReturnMacro(forwardClicks: clicks)
        clearBreakPlaybackState()
    }

    private func finishCommercialBreakLoop(success: Bool, message: String) {
        pendingAutoGoLive = false
        // Keep hasTriggeredThisBreak latched until ESPN play resumes — stops re-trigger during same break.
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        clearBreakPlaybackState()
        lastStatusSummary = message
        if success {
            isBreakActive = false
        } else if let tvController {
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
        _ = highlight
        let override = UserDefaults.standard.double(forKey: SportsAPIStorageKey.highlightWatchSeconds)
        if override > 0 {
            return override
        }
        // Phase 0: one fixed hold — reliability over rank-tuned timing.
        return BreakSessionMachine.defaultWatchSeconds
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
        let profile = activeSportProfile
        let snapshots = allPlays(from: summary).map { $0.snapshot(sportPath: profile.sportPath) }
        let highlights = SportHighlightEngine.parseHighlights(
            from: snapshots,
            sport: profile
        ) { parseESPNWallclock($0) }

        rankedHighlights = highlights.sorted {
            $0.apiTimestamp > $1.apiTimestamp
        }
        print("📋 Highlights loaded: \(highlights.count) list-worthy (from ESPN commentary)")

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

        guard let first = commercialBreakPlaylist.first else {
            selectedHighlightRank = 0
            lastPlannedRewindSeconds = 0
            return nil
        }

        lastHighlightTarget = first.playDescription
        selectedHighlightRank = first.interestRank
        lastPlannedRewindSeconds = calculatedRewindSeconds(for: first)

        return first
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
        // Soccer: keyEvents is sparse (often just kickoff/goals). Commentary embeds
        // full plays with wallclock + free kicks / fouls / shots.
        var byID: [String: ESPNPlay] = [:]
        var order: [String] = []

        func append(_ play: ESPNPlay) {
            let key = play.id
                ?? play.wallclock.map { "wc-\($0)" }
                ?? play.text.map { "tx-\($0.prefix(40))" }
                ?? UUID().uuidString
            if byID[key] == nil {
                order.append(key)
            }
            byID[key] = play
        }

        for item in summary.commentary ?? [] {
            if let play = item.play {
                append(play)
            }
        }
        for play in summary.keyEvents ?? [] {
            append(play)
        }

        if !order.isEmpty {
            return order.compactMap { byID[$0] }
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

    /// Forward clicks needed to catch up after a highlight rewind — call before clearing break state.
    func manualGoLiveForwardClicks() -> Int {
        calculatedGoLiveForwardClicks()
    }

    /// User tapped Go Live — clear break state and dismiss the on-TV highlight chip.
    func clearBreakForManualGoLive() {
        cancelScheduledReturnToLive()
        resetBreakSkipLatch()
        if let tvController {
            Task { await tvController.endHighlightReelBanner() }
        }
    }

    /// Full manual return: compute clicks (while hold timing still exists), scrub forward, restore replay clock.
    func performManualGoLive(tvController: TVController) async {
        guard !isAutoReturnInFlight else {
            tvController.statusMessage = "Already returning…"
            return
        }
        isAutoReturnInFlight = true
        defer { isAutoReturnInFlight = false }

        let clicks = max(1, calculatedGoLiveForwardClicks())
        let watched = highlightHoldStartedAt.map { Date().timeIntervalSince($0) }
            ?? breakSession.ledger.actualHeldSeconds
        clearBreakForManualGoLive()
        appendActivity(
            "Manual Go Live — \(clicks)× RIGHT (−\(Int(max(0, watched)))s watch)"
        )
        await tvController.executeHighlightReturnMacro(forwardClicks: clicks)
        resumeReplayMatchClockAfterHighlightSession()
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
    /// When the user picked the current match — used to drop next-day leftovers.
    static let monitoredGameSelectedAt = "zapremote.sports.monitoredGameSelectedAt"
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
