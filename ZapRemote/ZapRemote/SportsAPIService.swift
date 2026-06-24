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
        "sack"
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
}

// MARK: - SportsAPIService

@MainActor
final class SportsAPIService: ObservableObject {

    // MARK: Published State

    /// Global broadcast lag — bound directly to Settings slider and highlight rewind math.
    @Published var streamDelaySeconds: Double = 0.0 {
        didSet {
            persistStreamDelaySeconds()
        }
    }

    /// Settings Hue-sync slider range (seconds behind live ESPN).
    static let settingsSliderDelayRange: ClosedRange<Double> = 0...60
    static let settingsSliderStep: Double = 1.0

    /// SwiftUI binding surface — mirrors `gameID`.
    @Published var monitoredGameID: String = "401547417" {
        didSet {
            gameID = monitoredGameID.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(gameID, forKey: SportsAPIStorageKey.monitoredGameID)
        }
    }

    @Published var monitoredSportPath: String = "football/nfl" {
        didSet {
            let trimmed = monitoredSportPath.trimmingCharacters(in: .whitespacesAndNewlines)
            sportPath = trimmed.isEmpty ? "football/nfl" : trimmed
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

    /// When on, ESPN stoppages + cloud `ad_start` trigger the skip macro automatically.
    @Published var isHandsFreeAutomationEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isHandsFreeAutomationEnabled, forKey: SportsAPIStorageKey.handsFreeAutomation)
        }
    }

    /// After a highlight skip, wait then auto Go Live so you can verify the rewind worked.
    @Published var autoReturnToLiveAfterHighlight: Bool = true {
        didSet {
            UserDefaults.standard.set(autoReturnToLiveAfterHighlight, forKey: SportsAPIStorageKey.autoReturnToLiveAfterHighlight)
        }
    }

    // MARK: Spec State

    private var hasTriggeredThisBreak = false
    private var gameID: String = "401547417"
    private var sportPath: String = "football/nfl"

    // MARK: Private

    private weak var tvController: TVController?
    private var pollingTimer: Timer?
    private let pollIntervalSeconds: TimeInterval = 4
    /// Typical NFL timeout / ad-pod length on linear TV — fallback when no plays parse.
    private let commercialBreakSeconds: Double = 150
    /// Caps generic TV skip macros when no ESPN highlight is available.
    private let maxGenericSkipSeconds = 120
    /// Caps highlight-targeted skips — longer rewinds are OK when ESPN picks a real play.
    private let maxHighlightSkipSeconds = 210
    private var lastBreakPlayID: String?
    private var scheduledReturnToLiveTask: Task<Void, Never>?
    @Published private(set) var pendingAutoGoLive = false
    /// Seconds to watch the highlight after the skip macro — longer for big plays.
    private let baseHighlightWatchSeconds: TimeInterval = 45

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
        streamDelaySeconds = UserDefaults.standard.object(
            forKey: SportsAPIStorageKey.streamDelaySeconds
        ) as? Double ?? 0.0

        hasSyncedStreamLag = UserDefaults.standard.bool(forKey: SportsAPIStorageKey.hasSyncedStreamLag)

        let storedGameID = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredGameID) ?? ""
        gameID = storedGameID.trimmingCharacters(in: .whitespacesAndNewlines)
        monitoredGameID = gameID

        let storedSportPath = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredSportPath)
        sportPath = (storedSportPath?.isEmpty == false) ? storedSportPath! : "football/nfl"
        monitoredSportPath = sportPath

        monitoredGameLabel = UserDefaults.standard.string(forKey: SportsAPIStorageKey.monitoredGameLabel) ?? ""

        if UserDefaults.standard.object(forKey: SportsAPIStorageKey.handsFreeAutomation) != nil {
            isHandsFreeAutomationEnabled = UserDefaults.standard.bool(
                forKey: SportsAPIStorageKey.handsFreeAutomation
            )
        }

        if UserDefaults.standard.object(forKey: SportsAPIStorageKey.autoReturnToLiveAfterHighlight) != nil {
            autoReturnToLiveAfterHighlight = UserDefaults.standard.bool(
                forKey: SportsAPIStorageKey.autoReturnToLiveAfterHighlight
            )
        }
    }

    deinit {
        pollingTimer?.invalidate()
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
                ? "No games found — try just \"Argentina\" or \"Chiefs\""
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
            ? "No live games right now — search by team name"
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
    }

    // MARK: - Automated Delay Sync

    // MARK: - Stream Lag Sync (Hue-style game clock)

    /// User matched the +/- clock to their TV — offset is the broadcast delay.
    func confirmStreamDelay(_ delaySeconds: Int) {
        let clamped = max(0, min(delaySeconds, GameClockSyncEngine.maxBroadcastDelaySeconds))
        applyStreamDelaySync(Double(clamped), method: "matched TV clock")
    }

    func espnClockDisplay(at date: Date = Date()) -> String? {
        espnLiveClockDisplay(at: date)
    }

    /// True live game clock from ESPN — zero broadcast delay.
    func espnLiveClockDisplay(at date: Date = Date()) -> String? {
        tickingGameClock?.liveDisplay(at: date)
    }

    func espnElapsedHint(at date: Date = Date()) -> String? {
        guard let ticker = tickingGameClock else { return nil }
        let clock = ticker.liveClock(at: date)
        return GameClockSyncEngine.elapsedMinutesLabel(from: clock, sportPath: sportPath)
    }

    /// Game clock shifted by broadcast delay — what your TV feed shows.
    func broadcastGameClockDisplay(delaySeconds: Int, at date: Date = Date()) -> String? {
        tickingGameClock?.tvDisplay(delaySeconds: delaySeconds, at: date)
    }

    func tvClockDisplay(delaySeconds: Int, at date: Date = Date()) -> String? {
        broadcastGameClockDisplay(delaySeconds: delaySeconds, at: date)
    }

    /// Home / settings: after sync, show the delayed clock (matches TV); before sync, ESPN live.
    func uiGameClockDisplay(at date: Date = Date()) -> String {
        syncedTimelineClockDisplay(at: date)
    }

    /// App timeline for Hue-style sync — shifts with `streamDelaySeconds` as the slider moves.
    func syncedTimelineClockDisplay(at date: Date = Date()) -> String {
        let delay = Int(streamDelaySeconds.rounded())
        if delay > 0, let broadcast = broadcastGameClockDisplay(delaySeconds: delay, at: date) {
            return broadcast
        }
        if let live = espnLiveClockDisplay(at: date) {
            return live
        }
        return liveGameClockLabel
    }

    /// Formatted offset readout for the Settings delay panel.
    var streamOffsetReadout: String {
        "Current Stream Offset: \(Int(streamDelaySeconds.rounded())) seconds behind real-time broadcast."
    }

    /// User's TV timeline — when a live ESPN moment appears on their screen.
    func userTVAirDate(forLiveEvent liveDate: Date) -> Date {
        GameClockSyncEngine.userTVAirDate(
            liveEventDate: liveDate,
            streamDelaySeconds: streamDelaySeconds
        )
    }

    private func applyStreamDelaySync(_ delay: Double, method: String) {
        streamDelaySeconds = delay
        lastStatusSummary = "Synced — TV is \(Int(delay.rounded()))s behind ESPN live"
        appendActivity("Lag synced via \(method) — \(Int(delay.rounded()))s")

        print("📡 SportsAPIService: streamDelaySeconds = \(delay)s (\(method))")

        guard let tvController else { return }
        Task {
            await tvController.sendLGTVToastNotification(
                message: "ZapRemote: Synced — \(Int(delay.rounded()))s behind live"
            )
        }
    }

    private func persistStreamDelaySeconds() {
        UserDefaults.standard.set(streamDelaySeconds, forKey: SportsAPIStorageKey.streamDelaySeconds)
        let isSynced = streamDelaySeconds > 0
        if hasSyncedStreamLag != isSynced {
            hasSyncedStreamLag = isSynced
            UserDefaults.standard.set(isSynced, forKey: SportsAPIStorageKey.hasSyncedStreamLag)
        }
    }

    /// Legacy fallback — estimates lag from the latest play wallclock.
    @discardableResult
    func syncStreamDelay(apiPlayWallclockString: String) -> Bool {
        guard let apiDateTime = parseESPNWallclock(apiPlayWallclockString) else {
            lastStatusSummary = "Invalid ESPN wallclock string"
            print("❌ SportsAPIService: could not parse wallclock \"\(apiPlayWallclockString)\"")
            return false
        }

        let raw = Date().timeIntervalSince(apiDateTime)
        let minDelay = Double(GameClockSyncEngine.minBroadcastDelaySeconds)
        let maxDelay = Double(GameClockSyncEngine.maxBroadcastDelaySeconds)

        guard raw >= minDelay else {
            lastStatusSummary = "Play just hit ESPN — wait until you see it on TV, then tap again"
            appendActivity("Play sync too early — wait for play on TV")
            return false
        }
        guard raw <= maxDelay else {
            lastStatusSummary = "Play is too old for sync — use −/+ to set delay manually"
            appendActivity("Play sync rejected — play too old (\(Int(raw.rounded()))s)")
            return false
        }

        applyStreamDelaySync(raw, method: "latest play wallclock")
        return true
    }

    /// Precise delay: tap when the latest ESPN play is on your TV right now.
    @discardableResult
    func syncStreamDelayFromLatestPlay() async -> Bool {
        do {
            let summary = try await fetchGameSummary()

            if Self.isGameFinished(summary) {
                let message = "Game is over — play sync won't work on replays. Use −/+ to set delay."
                lastStatusSummary = message
                tvController?.statusMessage = message
                appendActivity("Play sync blocked — game finished")
                return false
            }

            guard let latestPlay = extractLatestPlay(from: summary),
                  let wallclock = latestPlay.wallclock else {
                let message = "Game hasn't started — no plays yet. Set delay with −/+ instead."
                lastStatusSummary = message
                tvController?.statusMessage = message
                appendActivity("Play sync blocked — no ESPN plays yet")
                return false
            }
            let playText = latestPlay.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Latest play"
            latestESPNPlayLabel = playText
            guard syncStreamDelay(apiPlayWallclockString: wallclock) else { return false }
            lastStatusSummary = "Play sync — \(Int(streamDelaySeconds.rounded()))s delay (\"\(playText.prefix(40))…\")"
            return true
        } catch {
            let message = "Sync failed — \(error.localizedDescription)"
            lastStatusSummary = message
            tvController?.statusMessage = message
            print("❌ SportsAPIService sync error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Live Broadcast Polling

    /// Starts ESPN polling — requires a chosen game ID.
    func startGamePolling() {
        let trimmedID = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            monitoringStatus = .idle
            lastStatusSummary = "Choose a game to start ESPN monitoring"
            return
        }
        gameID = trimmedID

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

        Task { await pollGameSummary() }
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

    private func evaluateSummary(_ summary: ESPNSummaryResponse) async {
        lastProcessedAt = Date()
        monitoringStatus = .monitoring
        isTrackedGameLive = Self.isGameLive(summary)
        refreshLiveGameClock(from: summary)
        _ = refreshRankedHighlightCounters(from: summary)

        let status = summary.header?.competitions?.first?.status
        let latestPlay = extractLatestPlay(from: summary)
        if let text = latestPlay?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            latestESPNPlayLabel = text
        }
        let statusLabel = status?.type.description ?? status?.type.name ?? latestPlay?.text ?? "Unknown"

        if ESPNBreakClassifier.isCommercialBreak(status: status, latestPlay: latestPlay) {
            lastBreakPlayID = latestPlay?.id
            isBreakActive = true
            if isHandsFreeAutomationEnabled {
                await triggerAutomaticAdSkip(source: "ESPN auto")
            } else {
                lastStatusSummary = "Game stopped on ESPN — tap Ad on my TV"
            }
            return
        }

        if ESPNBreakClassifier.isActivePlay(status: status, latestPlay: latestPlay) {
            let macroInFlight = tvController?.isMacroRunning == true
                || tvController?.isExecutingMacro == true
            if macroInFlight, hasTriggeredThisBreak || isBreakActive {
                lastStatusSummary = "Skipping ad on TV — macro in progress"
                return
            }

            if hasTriggeredThisBreak || isBreakActive {
                let shouldReturnToLive = (tvController?.lastRewindClickCount ?? 0) > 0
                hasTriggeredThisBreak = false
                isBreakActive = false
                lastBreakPlayID = nil
                lastStatusSummary = pendingAutoGoLive
                    ? "Play resumed — highlight playing, Go Live scheduled"
                    : "Active play — \(statusLabel)"
                if !pendingAutoGoLive {
                    appendActivity("Play resumed — returning to live")
                    print("🟢 SportsAPIService: play resumed — debounce reset")
                }

                if shouldReturnToLive, let tvController, isHandsFreeAutomationEnabled,
                   !autoReturnToLiveAfterHighlight, !pendingAutoGoLive {
                    let feedCatchUpSeconds = streamDelaySeconds
                    Task {
                        if feedCatchUpSeconds > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(feedCatchUpSeconds * 1_000_000_000))
                        }
                        guard !self.isBreakActive else { return }
                        await tvController.executeGoLiveMacro()
                    }
                }
            } else {
                lastStatusSummary = "In progress — \(statusLabel)"
            }
            return
        }

        isBreakActive = false
        lastStatusSummary = statusLabel
    }

    // MARK: - Ad Skip (manual or cloud-detected)

    /// ESPN timeout / cloud `ad_start` — runs the same macro as the manual button.
    private func triggerAutomaticAdSkip(source: String) async {
        guard !hasTriggeredThisBreak, !isCommercialBreakLoopActive else { return }
        guard let tvController else { return }

        guard hasSyncedStreamLag else {
            lastStatusSummary = "Match TV clock first — then hands-free can skip"
            return
        }

        guard tvController.isConnected else {
            lastStatusSummary = "Ad detected — connect TV for auto-skip"
            return
        }

        guard !tvController.isExecutingMacro else { return }

        let rewindSeconds = await resolveAdSkipRewindSeconds()
        await executeAdSkipRewind(rewindSeconds: rewindSeconds, source: source)
    }

    /// User saw an ad on TV — rewind to the best recent ESPN highlight play.
    /// Works in test mode without lag sync or live plays (generic TV skip).
    func skipAdToHighlights() async {
        guard let tvController else {
            lastStatusSummary = "Ad skip failed — TV not configured"
            return
        }

        guard tvController.isConnected else {
            let message = "Connect your TV first, then try again."
            lastStatusSummary = message
            tvController.statusMessage = message
            appendActivity("Ad skip blocked — TV offline")
            return
        }

        let rewindSeconds = await resolveAdSkipRewindSeconds()
        await executeAdSkipRewind(rewindSeconds: rewindSeconds, source: "Ad on TV")
    }

    /// Picks ranked ESPN highlight rewind, generic fallback, or a fixed test skip.
    private func resolveAdSkipRewindSeconds() async -> Int {
        var selectedHighlight: SportHighlight?
        if let summary = try? await fetchGameSummary() {
            refreshLiveGameClock(from: summary)
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
        let maxCap = usesHighlight ? maxHighlightSkipSeconds : maxGenericSkipSeconds
        let capped = min(raw, maxCap)
        let snapped = tvController?.snappedSkipSeconds(targetSeconds: capped) ?? capped
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
        guard isHandsFreeAutomationEnabled else {
            lastStatusSummary = "Cloud ad detected — enable hands-free in Settings"
            return
        }
        let rewindSeconds = await resolveAdSkipRewindSeconds()
        let useSeconds = max(rewindSeconds, tvController?.snappedSkipSeconds(targetSeconds: fallbackRewindSeconds) ?? fallbackRewindSeconds)
        await executeAdSkipRewind(rewindSeconds: useSeconds, source: "Cloud ad detect")
    }

    /// Cloud detector says game is live again — return after TV feed catches up.
    func resumeFromCloudGameLive() async {
        if pendingAutoGoLive || isCommercialBreakLoopActive {
            lastStatusSummary = "Highlight reel playing — Go Live scheduled"
            appendActivity("Ignored cloud game_live during highlight loop")
            return
        }
        let shouldReturnToLive = (tvController?.lastRewindClickCount ?? 0) > 0
        hasTriggeredThisBreak = false
        isBreakActive = false
        lastBreakPlayID = nil
        lastStatusSummary = "Game live — returning to live edge"
        appendActivity("Cloud game_live — waiting for TV feed")

        guard shouldReturnToLive, let tvController else { return }

        if streamDelaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(streamDelaySeconds * 1_000_000_000))
        }
        await tvController.executeGoLiveMacro()
    }

    private func executeAdSkipRewind(rewindSeconds: Int, source: String) async {
        hasTriggeredThisBreak = true
        isBreakActive = true

        guard let tvController else {
            lastStatusSummary = "Ad skip failed — TV not connected"
            return
        }

        if tvController.isExecutingMacro || isCommercialBreakLoopActive {
            let message = "Rewind already running — wait ~10 sec."
            lastStatusSummary = message
            tvController.statusMessage = message
            appendActivity("Ad skip blocked — macro lock active")
            isBreakActive = false
            hasTriggeredThisBreak = false
            return
        }

        await tvController.fetchActiveAppID()

        if commercialBreakPlaylist.count >= 2, hasSyncedStreamLag {
            await runCommercialBreakHighlightLoop(source: source)
            return
        }

        await executeSingleHighlightSkip(rewindSeconds: rewindSeconds, source: source)
    }

    private func executeSingleHighlightSkip(rewindSeconds: Int, source: String) async {
        guard let tvController else { return }

        let highlight = lastHighlightTarget.isEmpty ? "generic skip" : lastHighlightTarget
        let rankLabel = selectedHighlightRank > 0 ? "R\(selectedHighlightRank)" : "—"
        let secondsPerClick = tvController.secondsPerSkipClick()
        let snapped = tvController.snappedSkipSeconds(targetSeconds: rewindSeconds)
        let skipClicks = snapped / secondsPerClick
        lastStatusSummary = "\(source) — \(rankLabel) → \(highlight) (\(skipClicks)×\(secondsPerClick)s)"
        appendActivity("\(source) → \(skipClicks) skips on TV")
        tvController.statusMessage = "Sending \(skipClicks)×\(secondsPerClick)s skip…"

        let started = tvController.triggerRewindMacro(targetSeconds: snapped)
        if started {
            if autoReturnToLiveAfterHighlight {
                pendingAutoGoLive = true
                scheduleReturnToLiveAfterHighlight(savedClickCount: skipClicks)
            }
            Task {
                await tvController.sendLGTVToastNotification(
                    message: "ZapRemote: \(skipClicks)×\(secondsPerClick)s skip"
                )
            }
        } else {
            isBreakActive = false
            hasTriggeredThisBreak = false
            lastStatusSummary = tvController.statusMessage
            appendActivity("Ad skip failed — \(tvController.statusMessage)")
        }
    }

    /// Plays up to three ESPN highlights during a commercial break, then returns to live.
    private func runCommercialBreakHighlightLoop(source: String) async {
        guard let tvController else { return }

        let playlist = commercialBreakPlaylist
        guard playlist.count >= 2 else {
            await executeSingleHighlightSkip(
                rewindSeconds: lastPlannedRewindSeconds,
                source: source
            )
            return
        }

        isCommercialBreakLoopActive = true
        pendingAutoGoLive = autoReturnToLiveAfterHighlight
        scheduledReturnToLiveTask?.cancel()

        lastStatusSummary = "\(source) — \(playlist.count) highlight reel"
        appendActivity("\(source) → \(playlist.count)× highlight loop")
        tvController.statusMessage = "Commercial break — \(playlist.count) highlights…"

        Task {
            await tvController.sendLGTVToastNotification(
                message: "ZapRemote: \(playlist.count) highlights during break"
            )
        }

        scheduledReturnToLiveTask = Task { [weak self] in
            guard let self, let tvController = self.tvController else { return }

            defer {
                self.isCommercialBreakLoopActive = false
                self.commercialBreakHighlightIndex = 0
            }

            for (index, highlight) in playlist.enumerated() {
                guard !Task.isCancelled, self.isBreakActive else { return }

                self.commercialBreakHighlightIndex = index + 1
                self.selectedHighlightRank = highlight.interestRank
                self.lastHighlightTarget = highlight.playDescription

                if index == 0 {
                    let rewind = SportHighlightEngine.finalRewindSeconds(
                        highlightDate: highlight.apiTimestamp,
                        streamDelaySeconds: self.streamDelaySeconds
                    )
                    let capped = min(rewind, self.maxHighlightSkipSeconds)
                    let snapped = tvController.snappedSkipSeconds(targetSeconds: capped)
                    self.lastPlannedRewindSeconds = snapped
                    guard tvController.triggerRewindMacro(targetSeconds: snapped) else {
                        self.finishCommercialBreakLoop(success: false, message: tvController.statusMessage)
                        return
                    }
                    await tvController.waitForMacroCycleToFinish()
                } else {
                    let earlier = playlist[index - 1]
                    let forward = SportHighlightEngine.forwardSecondsBetween(earlier: earlier, later: highlight)
                    let snapped = tvController.snappedSkipSeconds(targetSeconds: forward)
                    let ok = await tvController.skipForwardOnScrubBar(targetSeconds: snapped)
                    guard ok else {
                        self.finishCommercialBreakLoop(success: false, message: "Forward skip failed")
                        return
                    }
                    await tvController.waitForMacroCycleToFinish()
                }

                let label = highlight.playDescription.prefix(36)
                self.lastStatusSummary = "Highlight \(index + 1)/\(playlist.count) — \(label)"
                self.appendActivity("Watching — \(label)")

                let watchSeconds = self.highlightWatchDuration(for: highlight.interestRank)
                tvController.statusMessage = "Highlight \(index + 1)/\(playlist.count) ~\(Int(watchSeconds))s"
                try? await Task.sleep(nanoseconds: UInt64(watchSeconds * 1_000_000_000))
                guard !Task.isCancelled, self.isBreakActive else { return }
            }

            guard !Task.isCancelled else { return }

            if self.pendingAutoGoLive {
                guard tvController.lastRewindClickCount > 0 else {
                    self.finishCommercialBreakLoop(success: false, message: "Go Live skipped — no rewind ledger")
                    return
                }
                self.lastStatusSummary = "Returning to live after \(playlist.count) highlights"
                self.appendActivity("Auto Go Live — highlight reel ended")
                await tvController.executeGoLiveMacro()
                self.finishCommercialBreakLoop(success: true, message: "Back to live after \(playlist.count) highlights")
            } else {
                self.finishCommercialBreakLoop(success: true, message: "Watched \(playlist.count) highlights — tap Go Live")
            }
        }
    }

    private func finishCommercialBreakLoop(success: Bool, message: String) {
        pendingAutoGoLive = false
        hasTriggeredThisBreak = false
        isBreakActive = false
        isCommercialBreakLoopActive = false
        commercialBreakHighlightIndex = 0
        lastBreakPlayID = nil
        lastStatusSummary = message
        if !success {
            appendActivity("Highlight loop stopped — \(message)")
        }
    }

    /// Waits for the rewind macro to finish, lets the highlight play, then Go Live.
    private func scheduleReturnToLiveAfterHighlight(savedClickCount: Int) {
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

            if tvController.lastRewindClickCount == 0, savedClickCount > 0 {
                tvController.restoreRewindClickCount(savedClickCount)
            }
            guard tvController.lastRewindClickCount > 0 else {
                lastStatusSummary = "Go Live skipped — no rewind clicks to undo"
                pendingAutoGoLive = false
                return
            }

            lastStatusSummary = "Returning to live after highlight"
            appendActivity("Auto Go Live — highlight window ended")
            await tvController.executeGoLiveMacro()

            pendingAutoGoLive = false
            hasTriggeredThisBreak = false
            isBreakActive = false
            lastBreakPlayID = nil
        }
    }

    private func highlightWatchDuration(for rank: Int) -> TimeInterval {
        switch rank {
        case 3: baseHighlightWatchSeconds + 15
        case 2: baseHighlightWatchSeconds + 5
        default: baseHighlightWatchSeconds
        }
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
    }

    // MARK: - Ranked Highlight Loop Engine

    func plannedHighlightRewindSeconds() async -> Int? {
        guard hasSyncedStreamLag else { return nil }
        guard let summary = try? await fetchGameSummary() else { return nil }
        return rankedHighlightRewindSeconds(from: summary)
    }

    func lastHighlightPlayDescription() -> String? {
        lastHighlightTarget.isEmpty ? nil : lastHighlightTarget
    }

    /// Parses ESPN plays, ranks them, selects the top highlight, and computes precision rewind.
    private func rankedHighlightRewindSeconds(from summary: ESPNSummaryResponse) -> Int? {
        guard hasSyncedStreamLag else { return nil }
        guard let best = refreshRankedHighlightCounters(from: summary) else { return nil }

        print(
            "🎯 Ranked Highlight Loop: rank \(best.interestRank) \"\(best.playDescription)\" "
            + "→ rewind \(lastPlannedRewindSeconds)s (pre=\(Int(SportHighlightEngine.prePlayPaddingSeconds))s, "
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

        commercialBreakPlaylist = SportHighlightEngine.commercialBreakPlaylist(
            from: highlights,
            streamDelaySeconds: streamDelaySeconds
        )

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
        let calculated = SportHighlightEngine.finalRewindSeconds(
            highlightDate: best.apiTimestamp,
            streamDelaySeconds: streamDelaySeconds
        )
        lastPlannedRewindSeconds = min(calculated, maxHighlightSkipSeconds)

        return best
    }

    private func refreshLiveGameClock(from summary: ESPNSummaryResponse) {
        let status = summary.header?.competitions?.first?.status
        let parsed = GameClockSyncEngine.parseClock(
            period: status?.period,
            clock: status?.clock,
            displayClock: status?.displayClock,
            state: status?.type.state,
            sportPath: sportPath
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
        if let existing = tickingGameClock, existing.mode == mode {
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

    /// User tapped Go Live — clear break state so the button isn't blocked.
    func clearBreakForManualGoLive() {
        cancelScheduledReturnToLive()
        hasTriggeredThisBreak = false
        isBreakActive = false
        lastBreakPlayID = nil
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
    static let hasSyncedStreamLag = "zapremote.sports.hasSyncedStreamLag"
    static let handsFreeAutomation = "zapremote.sports.handsFreeAutomation"
    static let autoReturnToLiveAfterHighlight = "zapremote.sports.autoReturnToLiveAfterHighlight"
}
