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

    /// Pre-play buffer — lands the TV ~15s before the highlight snap/huddle.
    static let prePlayPaddingSeconds: Double = 15.0
    /// Post-play buffer — end of the targeting window after the play finishes.
    static let postPlayPaddingSeconds: Double = 15.0
    static let recentHighlightWindowSeconds: TimeInterval = 8 * 60

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

    /// Highest-ranked highlight in the recent window; ties break toward the newest play.
    static func bestHighlight(
        from highlights: [SportHighlight],
        now: Date = Date(),
        within recentWindow: TimeInterval = recentHighlightWindowSeconds
    ) -> SportHighlight? {
        guard !highlights.isEmpty else { return nil }

        let recent = highlights.filter { now.timeIntervalSince($0.apiTimestamp) <= recentWindow }
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
        now: Date = Date()
    ) -> SportHighlight? {
        let notable = highlights.filter { $0.interestRank >= 2 }
        return bestHighlight(from: notable.isEmpty ? highlights : notable, now: now)
    }

    // MARK: Precision Rewind

    /// How far back the TV player should skip to land ~15s before the highlight.
    /// ESPN time is live; the TV feed lags by `streamDelaySeconds`.
    static func finalRewindSeconds(
        highlightDate: Date,
        streamDelaySeconds: Double,
        now: Date = Date()
    ) -> Int {
        let liveAge = now.timeIntervalSince(highlightDate)
        let tvAge = max(0, liveAge - streamDelaySeconds)
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
