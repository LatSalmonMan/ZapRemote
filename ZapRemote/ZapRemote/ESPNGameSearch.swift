//
//  ESPNGameSearch.swift
//  ZapRemote
//
//  Natural-language-ish game lookup via ESPN search + live scoreboards.
//

import Foundation

// MARK: - Result

struct ESPNGameSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let eventID: String
    /// e.g. `football/nfl` or `soccer/fifa.world`
    let sportPath: String
    let title: String
    let statusLabel: String
    let isLive: Bool

    var selectionSummary: String {
        "\(title) · \(statusLabel)"
    }
}

enum ESPNGameSearchError: LocalizedError {
    case network(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail): "ESPN search failed — \(detail)"
        }
    }
}

// MARK: - ESPNGameSearchService

enum ESPNGameSearchService {

    private static let featuredScoreboards: [(sport: String, league: String, label: String)] = [
        ("football", "nfl", "NFL"),
        ("soccer", "fifa.world", "FIFA World Cup"),
        ("soccer", "usa.1", "MLS"),
        ("basketball", "nba", "NBA"),
        ("baseball", "mlb", "MLB"),
        ("hockey", "nhl", "NHL"),
        ("football", "college-football", "College Football"),
        ("basketball", "mens-college-basketball", "Men's College Basketball"),
    ]

    /// All live games across featured leagues (no query needed).
    static func liveGamesToday() async -> [ESPNGameSearchResult] {
        var results: [ESPNGameSearchResult] = []
        var seen = Set<String>()

        for board in featuredScoreboards {
            do {
                let games = try await fetchScoreboard(
                    sport: board.sport,
                    league: board.league,
                    boardLabel: board.label,
                    dates: scoreboardDateRange(pastDays: 1, futureDays: 1),
                    matchingTokens: []
                )
                for game in games where game.isLive && seen.insert(game.eventID).inserted {
                    results.append(game)
                }
            } catch {
                continue
            }
        }

        return sortResults(results)
    }

    static func search(query: String) async throws -> [ESPNGameSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [ESPNGameSearchResult] = []
        var seenIDs = Set<String>()
        var lastError: Error?

        do {
            let searchItems = try await fetchSearchItems(query: trimmed)
            for item in searchItems.prefix(8) {
                if item.type == "team", let teamID = item.id, let sport = item.sport {
                    let league = item.league ?? item.defaultLeagueSlug ?? ""
                    let teamGames = await fetchTeamEventResults(
                        sport: sport,
                        league: league,
                        teamID: teamID,
                        query: trimmed
                    )
                    for game in teamGames where seenIDs.insert(game.eventID).inserted {
                        results.append(game)
                    }
                }

                let boardResults = await gamesForSearchItem(item, query: trimmed)
                for game in boardResults where seenIDs.insert(game.eventID).inserted {
                    results.append(game)
                }
            }
        } catch {
            lastError = error
        }

        let tokens = tokenize(trimmed)
        let dateRange = scoreboardDateRange(pastDays: 14, futureDays: 14)

        for board in featuredScoreboards {
            do {
                let boardResults = try await fetchScoreboard(
                    sport: board.sport,
                    league: board.league,
                    boardLabel: board.label,
                    dates: dateRange,
                    matchingTokens: tokens
                )
                for game in boardResults where seenIDs.insert(game.eventID).inserted {
                    results.append(game)
                }
            } catch {
                lastError = error
            }
        }

        if results.isEmpty, let lastError {
            throw lastError
        }

        return sortResults(results)
    }

    // MARK: - Search API

    private struct SearchResponse: Decodable {
        let items: [SearchItem]?
    }

    private struct SearchItem: Decodable {
        let id: String?
        let type: String?
        let displayName: String?
        let sport: String?
        let league: String?
        let defaultLeagueSlug: String?
        let location: String?
        let name: String?
    }

    private static func fetchSearchItems(query: String) async throws -> [SearchItem] {
        var components = URLComponents(string: "https://site.web.api.espn.com/apis/common/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "15"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ESPNGameSearchError.network("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ESPNGameSearchError.network("HTTP \(http.statusCode)")
        }
        return (try JSONDecoder().decode(SearchResponse.self, from: data).items) ?? []
    }

    private static func gamesForSearchItem(_ item: SearchItem, query: String) async -> [ESPNGameSearchResult] {
        guard let sport = item.sport, let league = item.league ?? item.defaultLeagueSlug else { return [] }

        let teamLabel = [item.location, item.name, item.displayName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let matchQuery = item.type == "team" && !teamLabel.isEmpty ? teamLabel : query
        let tokens = tokenize(matchQuery)

        return (try? await fetchScoreboard(
            sport: sport,
            league: league,
            boardLabel: league,
            dates: scoreboardDateRange(pastDays: 14, futureDays: 14),
            matchingTokens: tokens
        )) ?? []
    }

    // MARK: - Team events (core API)

    private struct CoreListResponse: Decodable {
        let items: [CoreRef]?
    }

    private struct CoreRef: Decodable {
        let ref: String

        enum CodingKeys: String, CodingKey {
            case ref = "$ref"
        }
    }

    private struct CoreEventDetail: Decodable {
        let id: FlexibleID
        let name: String?
        let shortName: String?
        let competitions: [CoreCompetition]?
    }

    private struct CoreCompetition: Decodable {
        let status: ScoreboardStatus?
    }

    private struct FlexibleID: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let int = try? container.decode(Int.self) {
                value = String(int)
            } else {
                value = ""
            }
        }
    }

    private static func fetchTeamEventResults(
        sport: String,
        league: String,
        teamID: String,
        query: String
    ) async -> [ESPNGameSearchResult] {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/\(sport)/teams/\(teamID)/events?limit=30") else {
            return []
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let list = try? JSONDecoder().decode(CoreListResponse.self, from: data),
              let items = list.items else {
            return []
        }

        let tokens = tokenize(query)
        var results: [ESPNGameSearchResult] = []

        for item in items.prefix(20) {
            let refURLString = item.ref.replacingOccurrences(of: "http://", with: "https://")
            guard let refURL = URL(string: refURLString),
                  let (eventData, eventResponse) = try? await URLSession.shared.data(from: refURL),
                  let eventHTTP = eventResponse as? HTTPURLResponse,
                  (200...299).contains(eventHTTP.statusCode),
                  let event = try? JSONDecoder().decode(CoreEventDetail.self, from: eventData) else {
                continue
            }

            let haystack = [event.name, event.shortName]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            guard matchesQuery(haystack: haystack, tokens: tokens) else { continue }

            let status = event.competitions?.first?.status?.type
            let state = status?.state?.lowercased() ?? ""
            let isLive = state == "in"
            let statusLabel = status?.shortDetail
                ?? status?.description
                ?? status?.detail
                ?? (isLive ? "Live" : "Scheduled")

            let eventID = event.id.value
            guard !eventID.isEmpty, !league.isEmpty else { continue }

            results.append(
                ESPNGameSearchResult(
                    id: "\(sport)/\(league)/\(eventID)",
                    eventID: eventID,
                    sportPath: "\(sport)/\(league)",
                    title: event.shortName ?? event.name ?? "Game \(eventID)",
                    statusLabel: statusLabel,
                    isLive: isLive
                )
            )
        }

        return results
    }

    // MARK: - Scoreboard

    private struct ScoreboardResponse: Decodable {
        let events: [ScoreboardEvent]?
    }

    private struct ScoreboardEvent: Decodable {
        let id: FlexibleID
        let name: String?
        let shortName: String?
        let competitions: [ScoreboardCompetition]?
    }

    private struct ScoreboardCompetition: Decodable {
        let status: ScoreboardStatus?
    }

    private struct ScoreboardStatus: Decodable {
        let type: ScoreboardStatusType
    }

    private struct ScoreboardStatusType: Decodable {
        let name: String
        let state: String?
        let description: String?
        let detail: String?
        let shortDetail: String?
    }

    private static func fetchScoreboard(
        sport: String,
        league: String,
        boardLabel: String,
        dates: String,
        matchingTokens: [String]
    ) async throws -> [ESPNGameSearchResult] {
        var components = URLComponents(
            string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/scoreboard"
        )!
        components.queryItems = [
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ESPNGameSearchError.network("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ESPNGameSearchError.network("HTTP \(http.statusCode) for \(league)")
        }

        let scoreboard = try JSONDecoder().decode(ScoreboardResponse.self, from: data)

        return (scoreboard.events ?? []).compactMap { event in
            let haystack = [
                event.name,
                event.shortName,
                boardLabel,
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            if !matchingTokens.isEmpty, !matchesQuery(haystack: haystack, tokens: matchingTokens) {
                return nil
            }

            let status = event.competitions?.first?.status?.type
            let state = status?.state?.lowercased() ?? ""
            let isLive = state == "in"
            let statusLabel = status?.shortDetail
                ?? status?.description
                ?? status?.detail
                ?? (isLive ? "Live" : "Scheduled")

            let eventID = event.id.value
            guard !eventID.isEmpty else { return nil }

            return ESPNGameSearchResult(
                id: "\(sport)/\(league)/\(eventID)",
                eventID: eventID,
                sportPath: "\(sport)/\(league)",
                title: event.shortName ?? event.name ?? "Game \(eventID)",
                statusLabel: statusLabel,
                isLive: isLive
            )
        }
    }

    // MARK: - Dates

    private static func scoreboardDateRange(pastDays: Int, futureDays: Int) -> String {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -pastDays, to: now) ?? now
        let end = calendar.date(byAdding: .day, value: futureDays, to: now) ?? now
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }

    // MARK: - Matching

    private static func tokenize(_ query: String) -> [String] {
        query
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "game", "games", "today", "tonight", "live", "match", "vs", "the", "at", "my"
    ]

    private static func matchesQuery(haystack: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        if tokens.count == 1 {
            return haystack.contains(tokens[0])
        }
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private static func sortResults(_ results: [ESPNGameSearchResult]) -> [ESPNGameSearchResult] {
        results.sorted { lhs, rhs in
            if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
