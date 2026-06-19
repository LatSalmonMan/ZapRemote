//
//  SportsMatch.swift
//  ZapRemote
//
//  Lightweight model representing a live sporting event that can be
//  assigned to the primary or secondary TV stream.
//

import SwiftUI

// MARK: - SportsMatch

struct SportsMatch: Identifiable, Hashable {
    let id: UUID
    let teamA: String
    let teamB: String
    let league: String
    var isCommercialActive: Bool = false

    /// Full matchup headline for cards and lists.
    var matchupTitle: String {
        "\(teamA) vs \(teamB)"
    }

    /// SF Symbol for the match's sport category.
    var sportIcon: String {
        switch league {
        case "La Liga", "English Premier League", "World Cup":
            "soccerball"
        case "NBA":
            "basketball"
        case "MLB":
            "baseball"
        default:
            "sportscourt"
        }
    }

    /// League-aware accent for stream slots and picker rows.
    var accentColor: Color {
        switch league {
        case "La Liga", "English Premier League", "World Cup":
            Color(red: 0.20, green: 0.78, blue: 0.45)
        case "NBA":
            Color(red: 1.0, green: 0.55, blue: 0.20)
        case "MLB":
            Color(red: 0.90, green: 0.30, blue: 0.35)
        default:
            Color.white.opacity(0.6)
        }
    }

    // MARK: Mock Data

    /// Four active live matches available for stream assignment.
    static let activeMatches: [SportsMatch] = [
        SportsMatch(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000001")!,
            teamA: "Real Madrid",
            teamB: "Barcelona",
            league: "La Liga"
        ),
        SportsMatch(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000002")!,
            teamA: "Boston Celtics",
            teamB: "Miami Heat",
            league: "NBA"
        ),
        SportsMatch(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000003")!,
            teamA: "Manchester City",
            teamB: "Liverpool",
            league: "English Premier League"
        ),
        SportsMatch(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000004")!,
            teamA: "LA Dodgers",
            teamB: "SF Giants",
            league: "MLB"
        )
    ]
}
