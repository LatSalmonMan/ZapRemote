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

    var rankLabel: String {
        switch interestRank {
        case 3: "Max"
        case 2: "Medium"
        default: "Low"
        }
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
    static func parseHighlights(
        from plays: [ESPNPlaySnapshot],
        parseWallclock: (String) -> Date?
    ) -> [SportHighlight] {
        plays.compactMap { play in
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
                interestRank: interestRank(for: play)
            )
        }
    }

    // MARK: Ranking

    /// Soccer: goal / penalty / red card = 3. NFL: TD / INT / fumble = 3. Big plays = 2.
    static func interestRank(for play: ESPNPlaySnapshot) -> Int {
        let haystack = [
            play.text,
            play.typeText,
            play.typeAbbreviation
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if isSoccerGoal(in: haystack) || containsKeyword(
            in: haystack,
            keywords: ["touchdown", "interception", "fumble", "penalty goal", "red card"]
        ) {
            return 3
        }

        if containsKeyword(
            in: haystack,
            keywords: [
                "yellow card", "saved", "save ", "shot on",
                "corner kick", "free kick", "header"
            ]
        ) {
            return 2
        }

        if haystack.contains("sack") || passingYards(in: haystack) ?? 0 >= 20 {
            return 2
        }

        return 1
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

    /// Best play since kickoff — prefer goals; never open with kickoff ceremony.
    static func bestHighlightForCommercialSkip(
        from highlights: [SportHighlight],
        now: Date = Date(),
        streamDelaySeconds: Double = 0
    ) -> SportHighlight? {
        _ = now
        _ = streamDelaySeconds
        let playlist = commercialBreakPlaylist(
            from: highlights,
            streamDelaySeconds: streamDelaySeconds,
            now: now
        )
        guard !playlist.isEmpty else { return nil }

        return playlist.max { lhs, rhs in
            if lhs.interestRank != rhs.interestRank {
                return lhs.interestRank < rhs.interestRank
            }
            return lhs.apiTimestamp < rhs.apiTimestamp
        }
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
        // ESPN wallclock ≈ when the play is logged — allow the action plus post-play chaos to breathe.
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
        if highlight.interestRank >= 3 { return 32 }
        if highlight.interestRank >= 2 { return 26 }
        return postPlayPaddingSeconds
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
        "upon further review", "confirmed after", "overturned after"
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
