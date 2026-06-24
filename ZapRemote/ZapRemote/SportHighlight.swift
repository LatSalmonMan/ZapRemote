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

    /// Pre-play buffer — land earlier so the full highlight (not just the tail) is visible.
    static let prePlayPaddingSeconds: Double = 28.0
    /// Post-play buffer — end of the targeting window after the play finishes.
    static let postPlayPaddingSeconds: Double = 15.0
    static let recentHighlightWindowSeconds: TimeInterval = 8 * 60
    static let maxCommercialBreakHighlights = 3
    static let minSpacingBetweenHighlightsSeconds: Double = 12

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

    /// Touchdown / Interception / Fumble = 3, Sack / Pass 20+ yds = 2, else 1.
    static func interestRank(for play: ESPNPlaySnapshot) -> Int {
        let haystack = [
            play.text,
            play.typeText,
            play.typeAbbreviation
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if containsKeyword(in: haystack, keywords: ["touchdown", "interception", "fumble"]) {
            return 3
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

    /// Prefers touchdowns / turnovers / big plays; falls back to any recent play.
    static func bestHighlightForCommercialSkip(
        from highlights: [SportHighlight],
        now: Date = Date(),
        streamDelaySeconds: Double = 0
    ) -> SportHighlight? {
        let notable = highlights.filter { $0.interestRank >= 2 }
        return bestHighlight(
            from: notable.isEmpty ? highlights : notable,
            now: now,
            streamDelaySeconds: streamDelaySeconds
        )
    }

    /// Up to three notable plays for a commercial-break binge — oldest first for playback.
    static func commercialBreakPlaylist(
        from highlights: [SportHighlight],
        streamDelaySeconds: Double,
        maxItems: Int = maxCommercialBreakHighlights,
        now: Date = Date()
    ) -> [SportHighlight] {
        let notable = highlights.filter { $0.interestRank >= 2 }
        let pool = notable.isEmpty ? highlights : notable
        let recent = pool.filter {
            $0.ageOnUserTV(now: now, streamDelaySeconds: streamDelaySeconds) <= recentHighlightWindowSeconds
        }
        let ranked = (recent.isEmpty ? pool : recent).sorted {
            if $0.interestRank != $1.interestRank { return $0.interestRank > $1.interestRank }
            return $0.apiTimestamp > $1.apiTimestamp
        }

        var seen = Set<String>()
        var picks: [SportHighlight] = []
        for highlight in ranked {
            guard seen.insert(highlight.id).inserted else { continue }
            picks.append(highlight)
            if picks.count >= maxItems { break }
        }

        let chronological = picks.sorted { $0.apiTimestamp < $1.apiTimestamp }
        guard chronological.count >= 2 else { return chronological }

        var spaced: [SportHighlight] = [chronological[0]]
        for highlight in chronological.dropFirst() {
            guard let last = spaced.last else { continue }
            let gap = highlight.apiTimestamp.timeIntervalSince(last.apiTimestamp)
            if gap >= minSpacingBetweenHighlightsSeconds {
                spaced.append(highlight)
            }
        }
        return spaced
    }

    /// Seconds to skip forward on the DVR bar from an earlier highlight to a later one.
    static func forwardSecondsBetween(earlier: SportHighlight, later: SportHighlight) -> Int {
        max(1, Int(later.apiTimestamp.timeIntervalSince(earlier.apiTimestamp).rounded()))
    }

    // MARK: Precision Rewind

    /// How far back the TV player should skip to land before the highlight.
    /// ESPN timestamps are live; the user's TV feed lags by `streamDelaySeconds`.
    /// A play at live 14:23 lands on the user's TV at ~14:31 when delay is 8s.
    static func finalRewindSeconds(
        highlightDate: Date,
        streamDelaySeconds: Double,
        now: Date = Date()
    ) -> Int {
        let tvAge = GameClockSyncEngine.ageOnUserTV(
            livePlayDate: highlightDate,
            now: now,
            streamDelaySeconds: streamDelaySeconds
        )
        let rewind = tvAge + prePlayPaddingSeconds
        return max(1, Int(rewind.rounded()))
    }

    // MARK: - Private

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
