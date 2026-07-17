//
//  SportProfile.swift
//  ZapRemote
//
//  Single source of truth for sport differences. Built from ESPN `sportPath`
//  when the user picks a game (`selectMonitoredGame`).
//

import Foundation

enum SportKind: String, Sendable, Equatable, CaseIterable {
    case soccer
    case americanFootball
    case basketball
    case hockey
    case baseball
    case unknown
}

/// Behavior + copy for the currently tracked sport.
struct SportProfile: Equatable, Sendable {
    let kind: SportKind
    let sportPath: String

    // MARK: Resolve

    static func resolve(sportPath: String) -> SportProfile {
        let path = sportPath.lowercased()
        let kind: SportKind
        if path.contains("soccer") || path.contains("fifa") || path.contains("football-data") {
            kind = .soccer
        } else if path.contains("basketball") {
            kind = .basketball
        } else if path.contains("hockey") {
            kind = .hockey
        } else if path.contains("baseball") {
            kind = .baseball
        } else if path.contains("football") {
            // ESPN American football: football/nfl, football/college-football
            kind = .americanFootball
        } else {
            kind = .unknown
        }
        return SportProfile(kind: kind, sportPath: sportPath)
    }

    // MARK: Clock

    var clockMode: GameClockMode {
        switch kind {
        case .soccer: .countUp
        case .americanFootball, .basketball, .hockey, .baseball, .unknown: .countDown
        }
    }

    var displayName: String {
        switch kind {
        case .soccer: "Soccer"
        case .americanFootball: "Football"
        case .basketball: "Basketball"
        case .hockey: "Hockey"
        case .baseball: "Baseball"
        case .unknown: "Sports"
        }
    }

    /// Regulation period length (seconds). OT uses same length as a stub.
    func periodLengthSeconds(period: Int = 1) -> Int {
        _ = period
        switch kind {
        case .soccer: return 45 * 60
        case .basketball: return 12 * 60
        case .hockey: return 20 * 60
        case .americanFootball: return 15 * 60
        case .baseball: return 60 * 60 // no continuous clock; clamp only
        case .unknown: return 15 * 60
        }
    }

    func periodShortName(_ period: Int) -> String {
        switch kind {
        case .soccer:
            return period <= 1 ? "1H" : "2H"
        case .baseball:
            return period > 0 ? "Inn \(period)" : "—"
        case .americanFootball, .basketball, .hockey, .unknown:
            if period <= 0 { return "—" }
            if period <= 4 { return "Q\(period)" }
            return "OT"
        }
    }

    /// One elapsed match timer from ESPN period + in-period clock.
    func elapsedGameSeconds(period: Int, clockSeconds: Int) -> Int {
        let p = max(1, period)
        switch kind {
        case .soccer:
            let half = periodLengthSeconds()
            return p <= 1 ? clockSeconds : half + clockSeconds
        case .basketball, .americanFootball, .hockey, .unknown:
            let length = periodLengthSeconds()
            guard length > 0 else { return max(0, clockSeconds) }
            let remaining = min(max(0, clockSeconds), length)
            let elapsedInPeriod = length - remaining
            return (p - 1) * length + elapsedInPeriod
        case .baseball:
            // No continuous clock — treat as unknown elapsed.
            return 0
        }
    }

    var usesSoccerStylePlayClock: Bool { kind == .soccer }

    // MARK: Breaks / commercials

    /// Soccer: only confirmed halftime. NFL/NBA: TV timeouts count.
    var handsFreeRequiresHalftimeOnly: Bool { kind == .soccer }

    /// Generic rewind when highlights aren't available yet.
    var commercialBreakSeconds: Double {
        switch kind {
        case .soccer: return 180 // HT / long pod
        case .americanFootball: return 150
        case .basketball: return 90
        case .hockey: return 120
        case .baseball: return 120
        case .unknown: return 150
        }
    }

    var minBreakPollsBeforeAutoSkip: Int {
        kind == .soccer ? 3 : 2
    }

    // MARK: Highlights

    /// Soccer free-kick foul→kick merges. Off for other sports.
    var mergesSetPieceSequences: Bool { kind == .soccer }

    var rank3Keywords: [String] {
        switch kind {
        case .soccer:
            return ["red card", "sent off", "penalty scored", "penalty goal"]
        case .americanFootball:
            return ["touchdown", "interception", "fumble", "pick six", "pick-six"]
        case .basketball:
            return ["dunk", "alley-oop", "buzzer", "game-winner", "game winner", "three-point", "3-pointer"]
        case .hockey:
            return ["goal", "hat trick", "hat-trick", "power play goal", "short-handed"]
        case .baseball:
            return ["home run", "grand slam", "grandslam", "strikeout"]
        case .unknown:
            return ["touchdown", "goal", "home run"]
        }
    }

    var rank2Keywords: [String] {
        switch kind {
        case .soccer:
            return [
                "yellow card", "saved", "save ", "shot on", "shot blocked",
                "attempt", "corner kick", "corner",
                "free kick", "free-kick", "freekick",
                "penalty", "header", "var", "handball"
            ]
        case .americanFootball:
            return [
                "sack", "field goal", "forced fumble", "big play",
                "completion", "rush", "pass to", "first down"
            ]
        case .basketball:
            return [
                "steal", "block", "fast break", "and-one", "and one",
                "free throw", "layup", "jumper", "triple"
            ]
        case .hockey:
            return ["save", "shot", "power play", "penalty", "hit ", "breakaway"]
        case .baseball:
            return ["double", "triple", "stolen base", "rbi", "walk-off", "walk off"]
        case .unknown:
            return ["score", "foul", "penalty", "shot"]
        }
    }

    // MARK: UI copy

    var waitingForStartBanner: String {
        switch kind {
        case .soccer: return "Waiting for kickoff…"
        case .basketball: return "Waiting for tip-off…"
        case .hockey: return "Waiting for puck drop…"
        case .americanFootball: return "Waiting for kickoff…"
        case .baseball: return "Waiting for first pitch…"
        case .unknown: return "Waiting for start…"
        }
    }

    var startEventNoun: String {
        switch kind {
        case .soccer, .americanFootball: return "kickoff"
        case .basketball: return "tip-off"
        case .hockey: return "puck drop"
        case .baseball: return "first pitch"
        case .unknown: return "start"
        }
    }

    var highlightEmptyHint: String {
        switch kind {
        case .soccer: return "goals / cards / free kicks"
        case .americanFootball: return "touchdowns / turnovers / big plays"
        case .basketball: return "dunks / threes / steals"
        case .hockey: return "goals / saves / power plays"
        case .baseball: return "homers / strikeouts / scoring plays"
        case .unknown: return "notable plays"
        }
    }

    var systemImageName: String {
        switch kind {
        case .soccer: return "soccerball"
        case .americanFootball: return "football"
        case .basketball: return "basketball"
        case .hockey: return "hockey.puck"
        case .baseball: return "baseball"
        case .unknown: return "sportscourt"
        }
    }

    var breakStatusHint: String {
        switch kind {
        case .soccer: return "Halftime — pick a highlight"
        case .americanFootball, .basketball: return "Break / timeout — pick a highlight"
        case .hockey: return "Intermission — pick a highlight"
        case .baseball: return "Break — pick a highlight"
        case .unknown: return "Break — pick a highlight"
        }
    }
}
