//
//  SportHighlight.swift
//  ZapRemote
//
//  Ranked Highlight Loop Engine — ESPN play snapshots with interest scoring
//  and precision rewind window math for commercial-break targeting.
//

import Foundation

// MARK: - SportHighlight

/// A single ESPN play parsed into a ranked highlight candidate.
struct SportHighlight: Identifiable, Equatable, Sendable {
    let id: String
    let playDescription: String
    let apiTimestamp: Date
    let interestRank: Int
    /// Match-clock elapsed seconds when the event happened (football-data minute-based).
    /// `0` means unknown — fall back to `apiTimestamp` wall-clock rewind.
    let matchElapsedSeconds: Int
    /// For merged sequences (foul → free kick → shot): wall-clock span from start to outcome.
    let sequenceSpanSeconds: Int
    /// ESPN display clock when available (e.g. `12'`, `45'+2'`).
    let matchClockLabel: String

    init(
        id: String,
        playDescription: String,
        apiTimestamp: Date,
        interestRank: Int,
        matchElapsedSeconds: Int = 0,
        sequenceSpanSeconds: Int = 0,
        matchClockLabel: String = ""
    ) {
        self.id = id
        self.playDescription = playDescription
        self.apiTimestamp = apiTimestamp
        self.interestRank = interestRank
        self.matchElapsedSeconds = matchElapsedSeconds
        self.sequenceSpanSeconds = sequenceSpanSeconds
        self.matchClockLabel = matchClockLabel
    }

    var rankLabel: String {
        switch interestRank {
        case 3: "Max"
        case 2: "Medium"
        default: "Low"
        }
    }

    /// Prefer ESPN's display clock; fall back to elapsed — soccer-style `67'` or `m:ss`.
    var matchMinuteLabel: String {
        displayClockLabel(sport: .resolve(sportPath: "soccer/eng.1"))
    }

    func displayClockLabel(sport: SportProfile) -> String {
        let trimmed = matchClockLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard matchElapsedSeconds > 0 else { return "—" }
        if sport.clockMode == .countUp {
            return "\(matchElapsedSeconds / 60)'"
        }
        return GameClockSyncEngine.formatMatchClock(seconds: matchElapsedSeconds)
    }

    /// When this play airs on the user's delayed TV feed (wall-clock).
    func userTVAirDate(streamDelaySeconds: Double) -> Date {
        GameClockSyncEngine.userTVAirDate(
            liveEventDate: apiTimestamp,
            streamDelaySeconds: streamDelaySeconds
        )
    }

    /// How long ago this play aired on the user's TV, not ESPN live.
    func ageOnUserTV(now: Date = Date(), streamDelaySeconds: Double) -> TimeInterval {
        GameClockSyncEngine.ageOnUserTV(
            livePlayDate: apiTimestamp,
            now: now,
            streamDelaySeconds: streamDelaySeconds
        )
    }
}

// MARK: - Raw Play Input

/// Minimal ESPN play fields required for highlight ranking.
struct ESPNPlaySnapshot: Sendable {
    let id: String?
    let text: String?
    let wallclock: String?
    let typeText: String?
    let typeAbbreviation: String?
    /// Match elapsed seconds from ESPN play clock (soccer `12'` → 720).
    let matchElapsedSeconds: Int
    /// Raw ESPN display clock (`12'`, `45'+2'`).
    let matchClockLabel: String

    init(
        id: String?,
        text: String?,
        wallclock: String?,
        typeText: String?,
        typeAbbreviation: String?,
        matchElapsedSeconds: Int = 0,
        matchClockLabel: String = ""
    ) {
        self.id = id
        self.text = text
        self.wallclock = wallclock
        self.typeText = typeText
        self.typeAbbreviation = typeAbbreviation
        self.matchElapsedSeconds = matchElapsedSeconds
        self.matchClockLabel = matchClockLabel
    }
}

// MARK: - Ranked Highlight Loop Engine

enum SportHighlightEngine {

    /// Pre-play buffer — land earlier so buildup is visible before the ESPN log point.
    static let prePlayPaddingSeconds: Double = 28.0
    /// Default post-play buffer after the ESPN log timestamp (reaction, chaos, VAR aftermath).
    static let postPlayPaddingSeconds: Double = 22.0
    /// Legacy fallback only — commercial breaks use the full pre-break play log.
    static let recentHighlightWindowSeconds: TimeInterval = 8 * 60

    /// Goals / TDs first, then big plays, then any real action since kickoff.
    static func preBreakHighlightPool(from highlights: [SportHighlight]) -> [SportHighlight] {
        let top = highlights.filter { $0.interestRank >= 3 }
        if !top.isEmpty { return top }
        let notable = highlights.filter { $0.interestRank >= 2 }
        if !notable.isEmpty { return notable }
        return highlights.filter { $0.interestRank >= 1 }
    }

    // MARK: Parsing

    /// Scans an ESPN `plays` array, parses ISO-8601 wallclocks, and assigns interest ranks.
    /// Soccer: free-kick sequences (foul → award → kick/shot) are merged into one highlight.
    static func parseHighlights(
        from plays: [ESPNPlaySnapshot],
        sport: SportProfile = .resolve(sportPath: "soccer/eng.1"),
        parseWallclock: (String) -> Date?
    ) -> [SportHighlight] {
        let raw: [SportHighlight] = plays.compactMap { play in
            guard let wallclock = play.wallclock,
                  let timestamp = parseWallclock(wallclock) else { return nil }

            let description = play.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let playDescription = (description?.isEmpty == false) ? description! : "Play"

            if isBroadcastFiller(playDescription: playDescription, play: play) {
                return nil
            }

            let stableID = play.id ?? "\(timestamp.timeIntervalSince1970)-\(playDescription.prefix(24))"

            return SportHighlight(
                id: stableID,
                playDescription: playDescription,
                apiTimestamp: timestamp,
                interestRank: interestRank(for: play, sport: sport),
                matchElapsedSeconds: play.matchElapsedSeconds,
                matchClockLabel: play.matchClockLabel
            )
        }

        if sport.mergesSetPieceSequences {
            return mergeSetPieceSequences(raw)
        }
        // Other sports: keep list-worthy plays only (no soccer set-piece glue).
        return raw.filter { isListWorthy($0) }
    }

    /// Collapse foul → “wins free kick” → kick/shot into one tap (how it started → how it turned out).
    /// Stops at the first real outcome so the next foul doesn't get glued on.
    static func mergeSetPieceSequences(_ highlights: [SportHighlight]) -> [SportHighlight] {
        let sorted = highlights.sorted {
            if $0.apiTimestamp != $1.apiTimestamp { return $0.apiTimestamp < $1.apiTimestamp }
            return setPieceSortKey($0) < setPieceSortKey($1)
        }
        guard !sorted.isEmpty else { return [] }

        var result: [SportHighlight] = []
        var consumed = Set<String>()
        let window: TimeInterval = 75

        for (index, start) in sorted.enumerated() {
            if consumed.contains(start.id) { continue }

            let startText = start.playDescription.lowercased()
            guard isBareFoul(startText) || isFreeKickAwardOnly(startText) else {
                if isListWorthy(start) {
                    result.append(start)
                }
                continue
            }

            var cluster = [start]
            consumed.insert(start.id)
            var sawOutcome = false

            for next in sorted[(index + 1)...] {
                if consumed.contains(next.id) { continue }
                let gap = next.apiTimestamp.timeIntervalSince(cluster[0].apiTimestamp)
                if gap > window { break }

                let nextText = next.playDescription.lowercased()

                // Throw-ins are not free-kick outcomes — stop the set-piece cluster.
                if isThrowIn(nextText) {
                    break
                }

                if isSetPieceOutcome(nextText) {
                    cluster.append(next)
                    consumed.insert(next.id)
                    sawOutcome = true
                    break
                }

                if !sawOutcome, isFreeKickAwardOnly(nextText) || isBareFoul(nextText) {
                    // Pair foul + award only (same set piece), not a later unrelated foul.
                    if gap <= 20 {
                        cluster.append(next)
                        consumed.insert(next.id)
                        continue
                    }
                    break
                }

                // Unrelated play — end this set piece.
                break
            }

            if cluster.count == 1, isFreeKickAwardOnly(startText) {
                // Confirmed free-kick award with no outcome yet.
                result.append(
                    SportHighlight(
                        id: "fk-\(start.id)",
                        playDescription: "Free kick — \(shorten(start.playDescription))",
                        apiTimestamp: start.apiTimestamp,
                        interestRank: 2,
                        matchElapsedSeconds: start.matchElapsedSeconds,
                        sequenceSpanSeconds: 35,
                        matchClockLabel: start.matchClockLabel
                    )
                )
            } else if cluster.count == 1, isBareFoul(startText) {
                // Bare foul alone — do NOT call it a free kick (may be nothing / throw-in next).
                // Keep out of the Home list until a free-kick award or outcome arrives.
                continue
            } else if cluster.count >= 2 || sawOutcome {
                result.append(mergedFreeKickHighlight(from: cluster))
            } else if isListWorthy(start) {
                result.append(start)
            }
        }

        // Anything never consumed (shots, goals, cards, corners) already added above
        // when it wasn't a foul/award starter. Re-add any leftover list-worthy plays.
        for item in sorted where !consumed.contains(item.id) {
            if isListWorthy(item), !result.contains(where: { $0.id == item.id }) {
                result.append(item)
            }
        }

        return result.sorted { $0.apiTimestamp < $1.apiTimestamp }
    }

    /// Foul/award first, then outcome — stable order when wallclocks match.
    private static func setPieceSortKey(_ highlight: SportHighlight) -> Int {
        let t = highlight.playDescription.lowercased()
        if isBareFoul(t) { return 0 }
        if isFreeKickAwardOnly(t) { return 1 }
        if isSetPieceOutcome(t) { return 2 }
        return 3
    }

    private static func isSetPieceOutcome(_ haystack: String) -> Bool {
        containsKeyword(
            in: haystack,
            keywords: [
                "attempt", "shot on", "shot blocked", "blocked",
                "saved", "save ", "header", "cross",
                "goal!", "goal ", "scores", "corner"
            ]
        )
    }

    private static func isSetPieceRelated(_ haystack: String) -> Bool {
        isBareFoul(haystack) || isFreeKickAwardOnly(haystack) || isSetPieceOutcome(haystack)
            || haystack.contains("free kick") || haystack.contains("free-kick")
    }

    /// What belongs in the Home highlight list.
    static func isListWorthy(_ highlight: SportHighlight) -> Bool {
        let t = highlight.playDescription.lowercased()
        if isOpeningCeremony(highlight) { return false }
        if t.isEmpty { return false }
        if isThrowIn(t) { return false }
        if t.contains("delay in match") || t.contains("delay over") { return false }
        if t.contains("lineups are announced") { return false }
        if t.contains("drinks break") { return false }
        // Bare fouls alone are merge fodder — not list rows (avoids "everything is a free kick").
        if isBareFoul(t), !isFreeKickAwardOnly(t), !t.contains("free kick"), !t.contains("free-kick") {
            return false
        }
        if highlight.interestRank >= 2 { return true }
        if isFreeKickAwardOnly(t) { return true }
        if t.contains("handball") || t.contains("offside") { return true }
        return false
    }

    /// Throw-ins / foul throws — not free kicks (ESPN "Foul throw" was matching foul → Free kick).
    private static func isThrowIn(_ haystack: String) -> Bool {
        containsKeyword(
            in: haystack,
            keywords: [
                "throw-in", "throw in", "throwin",
                "foul throw", "foul-throw", "illegal throw"
            ]
        )
    }

    private static func mergedFreeKickHighlight(from cluster: [SportHighlight]) -> SportHighlight {
        let first = cluster[0]
        let last = cluster[cluster.count - 1]
        let span = max(0, Int(last.apiTimestamp.timeIntervalSince(first.apiTimestamp).rounded()))

        let foul = cluster.first { isBareFoul($0.playDescription.lowercased()) }
        let award = cluster.first { isFreeKickAwardOnly($0.playDescription.lowercased()) }
        let outcome = cluster.last(where: {
            let t = $0.playDescription.lowercased()
            return !isBareFoul(t) && !isFreeKickAwardOnly(t)
        }) ?? last

        var parts: [String] = []
        if let foul {
            parts.append(shorten(foul.playDescription))
        }
        if let award {
            parts.append(shorten(award.playDescription))
        }
        let outcomeText = shorten(outcome.playDescription)
        if parts.last != outcomeText {
            parts.append(outcomeText)
        }

        // Only label "Free kick" when ESPN said so — otherwise it's just a foul sequence.
        let hasFreeKickLanguage = cluster.contains {
            let t = $0.playDescription.lowercased()
            return isFreeKickAwardOnly(t) || t.contains("free kick") || t.contains("free-kick") || t.contains("freekick")
        }
        let prefix = hasFreeKickLanguage ? "Free kick" : "Foul"
        let description = "\(prefix) — \(parts.joined(separator: " → "))"
        let rank = max(2, cluster.map(\.interestRank).max() ?? 2)
        let elapsed = cluster.map(\.matchElapsedSeconds).filter { $0 > 0 }.min() ?? 0
        let clockLabel = cluster.map(\.matchClockLabel).first { !$0.isEmpty } ?? ""

        return SportHighlight(
            id: "fk-\(first.id)-\(last.id)",
            playDescription: description,
            apiTimestamp: first.apiTimestamp,
            interestRank: rank,
            matchElapsedSeconds: elapsed,
            sequenceSpanSeconds: max(span, 25),
            matchClockLabel: clockLabel
        )
    }

    private static func shorten(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 72 { return trimmed }
        return String(trimmed.prefix(69)) + "…"
    }

    // MARK: Ranking

    /// Sport-aware interest score. Soccer goals via dedicated detector; other sports use profile keywords.
    static func interestRank(
        for play: ESPNPlaySnapshot,
        sport: SportProfile = .resolve(sportPath: "soccer/eng.1")
    ) -> Int {
        let haystack = [
            play.text,
            play.typeText,
            play.typeAbbreviation
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if sport.kind == .soccer, isThrowIn(haystack) {
            return 1
        }

        if sport.kind == .soccer, isSoccerGoal(in: haystack) {
            return 3
        }
        if containsKeyword(in: haystack, keywords: sport.rank3Keywords) {
            return 3
        }

        // Soccer: award-only / bare foul — kept for merging, not shown alone.
        if sport.mergesSetPieceSequences,
           isFreeKickAwardOnly(haystack) || isBareFoul(haystack) {
            return 1
        }

        if containsKeyword(in: haystack, keywords: sport.rank2Keywords) {
            return 2
        }

        if sport.kind == .americanFootball,
           haystack.contains("sack") || (passingYards(in: haystack) ?? 0) >= 20 {
            return 2
        }

        return 1
    }

    /// "Yamal wins a free kick…" — foul award, not the ball being struck.
    private static func isFreeKickAwardOnly(_ haystack: String) -> Bool {
        if isThrowIn(haystack) { return false }
        let awardPhrases = [
            "wins a free kick", "won a free kick", "awarded a free kick",
            "earns a free kick", "earned a free kick", "awarded free kick"
        ]
        return awardPhrases.contains { haystack.contains($0) }
    }

    private static func isBareFoul(_ haystack: String) -> Bool {
        // "Foul by X" without a shot/card/goal — usually pairs with a free-kick award line.
        // Exclude foul throws / throw-ins — those are not free-kick fouls.
        if isThrowIn(haystack) { return false }
        guard haystack.contains("foul") else { return false }
        if containsKeyword(
            in: haystack,
            keywords: ["yellow", "red card", "penalty", "shot", "goal", "attempt", "throw"]
        ) {
            return false
        }
        return haystack.contains("foul by") || haystack.hasPrefix("foul")
            || (haystack.contains("type") && haystack.contains("foul"))
    }

    // MARK: Selection

    /// Highest-ranked highlight in the recent window on the **user's TV timeline**.
    static func bestHighlight(
        from highlights: [SportHighlight],
        now: Date = Date(),
        streamDelaySeconds: Double = 0,
        within recentWindow: TimeInterval = recentHighlightWindowSeconds
    ) -> SportHighlight? {
        guard !highlights.isEmpty else { return nil }

        let recent = highlights.filter {
            $0.ageOnUserTV(now: now, streamDelaySeconds: streamDelaySeconds) <= recentWindow
        }
        let pool = recent.isEmpty ? highlights : recent

        return pool.max { lhs, rhs in
            if lhs.interestRank != rhs.interestRank {
                return lhs.interestRank < rhs.interestRank
            }
            return lhs.apiTimestamp < rhs.apiTimestamp
        }
    }

    /// First reel item — chronological open (usually earliest goal), not the newest play.
    static func bestHighlightForCommercialSkip(
        from highlights: [SportHighlight],
        now: Date = Date(),
        streamDelaySeconds: Double = 0
    ) -> SportHighlight? {
        commercialBreakPlaylist(
            from: highlights,
            streamDelaySeconds: streamDelaySeconds,
            now: now
        ).first
    }

    /// Soccer: goals first (chronological), then rank-2 plays after the first goal — no kickoff openers.
    static func commercialBreakPlaylist(
        from highlights: [SportHighlight],
        streamDelaySeconds: Double,
        now: Date = Date()
    ) -> [SportHighlight] {
        _ = now
        _ = streamDelaySeconds
        var seen = Set<String>()

        func uniqueChronological(_ list: [SportHighlight]) -> [SportHighlight] {
            list
                .filter { !isOpeningCeremony($0) }
                .sorted {
                    if $0.apiTimestamp != $1.apiTimestamp { return $0.apiTimestamp < $1.apiTimestamp }
                    return $0.interestRank > $1.interestRank
                }
                .filter { seen.insert($0.id).inserted }
        }

        let goals = uniqueChronological(highlights.filter { $0.interestRank >= 3 })
        if !goals.isEmpty {
            let anchor = goals[0].apiTimestamp
            let bigPlays = uniqueChronological(
                highlights.filter { $0.interestRank == 2 && $0.apiTimestamp >= anchor }
            )
            let goalIDs = Set(goals.map(\.id))
            let merged = goals + bigPlays.filter { !goalIDs.contains($0.id) }
            return dedupeReplayClusters(merged)
        }

        let notable = uniqueChronological(highlights.filter { $0.interestRank >= 2 })
        if !notable.isEmpty { return dedupeReplayClusters(notable) }
        return dedupeReplayClusters(uniqueChronological(highlights.filter { $0.interestRank >= 1 }))
    }

    /// Drops ESPN duplicate log lines for the same TV moment (replay / VAR confirm right after the live play).
    private static func dedupeReplayClusters(_ playlist: [SportHighlight]) -> [SportHighlight] {
        guard !playlist.isEmpty else { return [] }
        var kept: [SportHighlight] = []
        for item in playlist {
            if let previous = kept.last {
                let gap = item.apiTimestamp.timeIntervalSince(previous.apiTimestamp)
                if gap < 90, item.interestRank <= previous.interestRank {
                    continue
                }
            }
            kept.append(item)
        }
        return kept
    }

    private static let openingCeremonyKeywords = [
        "kickoff", "kick off", "kick-off", "match begins", "first half begins",
        "start of match", "starts the match", "opening whistle", "underway"
    ]

    static func isOpeningCeremony(_ highlight: SportHighlight) -> Bool {
        let haystack = highlight.playDescription.lowercased()
        return openingCeremonyKeywords.contains { haystack.contains($0) }
    }

    /// Seconds to skip forward on the DVR bar from an earlier highlight to a later one.
    static func forwardSecondsBetween(earlier: SportHighlight, later: SportHighlight) -> Int {
        max(1, Int(later.apiTimestamp.timeIntervalSince(earlier.apiTimestamp).rounded()))
    }

    /// How long to stay on each reel item after the rewind lands (play + aftermath on TV).
    static func reelWatchSeconds(for highlight: SportHighlight) -> TimeInterval {
        if highlight.sequenceSpanSeconds > 0 {
            // Merged foul → kick → outcome: cover the whole span plus a little aftermath.
            return Double(highlight.sequenceSpanSeconds) + postPlayWatchSeconds(for: highlight) + 8
        }
        let actionOnTV: Double = 14
        return actionOnTV + postPlayWatchSeconds(for: highlight)
    }

    /// Extra seconds after the logged moment — longer for cards, penalties, and big incidents.
    static func postPlayWatchSeconds(for highlight: SportHighlight) -> Double {
        let haystack = highlight.playDescription.lowercased()
        if haystack.contains("red card") || haystack.contains("sent off") || haystack.contains("ejected") {
            return 42
        }
        if haystack.contains("var") || haystack.contains("video review") || haystack.contains("penalty") {
            return 36
        }
        // Free-kick takes need time for the wall + strike + rebound.
        if haystack.contains("free kick") || haystack.contains("free-kick") || haystack.contains("corner") {
            return 28
        }
        if highlight.interestRank >= 3 { return 32 }
        if highlight.interestRank >= 2 { return 26 }
        return postPlayPaddingSeconds
    }

    /// Extra pre-roll so we land before the ESPN log point (not on the exact second).
    static func leadInSeconds(for highlight: SportHighlight) -> Double {
        let haystack = highlight.playDescription.lowercased()
        if highlight.sequenceSpanSeconds > 0
            || haystack.contains("free kick")
            || haystack.contains("free-kick")
            || haystack.contains("corner") {
            return prePlayPaddingSeconds + 14
        }
        if highlight.interestRank >= 3 {
            return prePlayPaddingSeconds + 12
        }
        return prePlayPaddingSeconds + 6
    }

    /// Forward skip after watching `earlier` — land a little before the next highlight's buildup.
    static func forwardSecondsToNextHighlight(
        earlier: SportHighlight,
        later: SportHighlight,
        watchedSeconds: TimeInterval
    ) -> Int {
        let gap = later.apiTimestamp.timeIntervalSince(earlier.apiTimestamp)
        let consumedFromEarlierStart = max(0, watchedSeconds - prePlayPaddingSeconds)
        let forward = gap - consumedFromEarlierStart + (prePlayPaddingSeconds * 0.55)
        return max(20, Int(forward.rounded()))
    }

    // MARK: Precision Rewind

    /// Universal timestamp rewind — see `TimelineOffsetEngine.rewindSeconds`.
    static func finalRewindSeconds(
        highlightDate: Date,
        streamDelaySeconds: Double,
        now: Date = Date()
    ) -> Int {
        TimelineOffsetEngine.rewindSeconds(
            highlightDate: highlightDate,
            streamDelaySeconds: streamDelaySeconds,
            now: now
        )
    }

    // MARK: - Private

    private static let broadcastFillerKeywords = [
        "replay", "instant replay", "video review", "var review", "var check",
        "booth review", "fox replay", "highlights from", "commercial",
        "hydration", "water break", "cooling break", "end of half",
        "end of period", "halftime report", "studio",
        "replay shows", "shown again", "look again", "after review",
        "upon further review", "confirmed after", "overturned after",
        "delay in match", "delay over", "drinks break", "lineups are announced"
    ]

    private static func isSoccerGoal(in haystack: String) -> Bool {
        if haystack.contains("goal kick") || haystack.contains("no goal") {
            return false
        }
        return haystack.contains("goal") || haystack.contains("scores on") || haystack.contains(" scores")
    }

    private static func isBroadcastFiller(playDescription: String, play: ESPNPlaySnapshot) -> Bool {
        let haystack = [
            playDescription,
            play.typeText,
            play.typeAbbreviation
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if haystack.contains("type") && haystack.contains("replay") { return true }
        if let abbrev = play.typeAbbreviation?.lowercased(), abbrev == "replay" { return true }

        return broadcastFillerKeywords.contains { haystack.contains($0) }
    }

    private static func containsKeyword(in haystack: String, keywords: [String]) -> Bool {
        keywords.contains { haystack.contains($0) }
    }

    private static func passingYards(in text: String) -> Int? {
        let patterns = [
            #"pass for (\d+)\s*(?:yd|yard)"#,
            #"(\d+)[-\s]*yard pass"#,
            #"(\d+)\s*yd pass"#,
            #"pass.*?(\d+)\s*(?:yd|yard)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let yardsRange = Range(match.range(at: 1), in: text),
                  let yards = Int(text[yardsRange]) else {
                continue
            }
            return yards
        }
        return nil
    }
}
