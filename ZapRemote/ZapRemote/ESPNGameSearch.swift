//
//  ESPNGameSearch.swift
//  ZapRemote
//
//  Game lookup via ESPN search + scoreboards (soccer-first).
//

import Foundation

// MARK: - Result

struct ESPNGameSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let eventID: String
    /// e.g. `football/nfl` or `soccer/eng.1`
    let sportPath: String
    let title: String
    let statusLabel: String
    let leagueLabel: String
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

// MARK: - Scoreboard registry

private struct ScoreboardSpec: Sendable {
    let sport: String
    let league: String
    let label: String
}

// MARK: - ESPNGameSearchService

enum ESPNGameSearchService {

    /// Soccer leagues searched first — most ZapRemote users watch football/soccer on TV.
    private static let soccerScoreboards: [ScoreboardSpec] = [
        ScoreboardSpec(sport: "soccer", league: "fifa.world", label: "FIFA World Cup"),
        ScoreboardSpec(sport: "soccer", league: "fifa.worldq.conmebol", label: "WCQ CONMEBOL"),
        ScoreboardSpec(sport: "soccer", league: "fifa.worldq.uefa", label: "WCQ UEFA"),
        ScoreboardSpec(sport: "soccer", league: "fifa.worldq.concacaf", label: "WCQ Concacaf"),
        ScoreboardSpec(sport: "soccer", league: "fifa.cwc", label: "Club World Cup"),
        ScoreboardSpec(sport: "soccer", league: "uefa.champions", label: "Champions League"),
        ScoreboardSpec(sport: "soccer", league: "uefa.europa", label: "Europa League"),
        ScoreboardSpec(sport: "soccer", league: "usa.1", label: "MLS"),
        ScoreboardSpec(sport: "soccer", league: "eng.1", label: "Premier League"),
        ScoreboardSpec(sport: "soccer", league: "esp.1", label: "La Liga"),
        ScoreboardSpec(sport: "soccer", league: "ger.1", label: "Bundesliga"),
        ScoreboardSpec(sport: "soccer", league: "ita.1", label: "Serie A"),
        ScoreboardSpec(sport: "soccer", league: "fra.1", label: "Ligue 1"),
        ScoreboardSpec(sport: "soccer", league: "mex.1", label: "Liga MX"),
        ScoreboardSpec(sport: "soccer", league: "bra.1", label: "Brasileirão"),
        ScoreboardSpec(sport: "soccer", league: "arg.1", label: "Liga Profesional"),
        ScoreboardSpec(sport: "soccer", league: "usa.nwsl", label: "NWSL"),
        ScoreboardSpec(sport: "soccer", league: "eng.fa", label: "FA Cup"),
        ScoreboardSpec(sport: "soccer", league: "uefa.nations", label: "UEFA Nations League"),
    ]

    private static let usSportsScoreboards: [ScoreboardSpec] = [
        ScoreboardSpec(sport: "football", league: "nfl", label: "NFL"),
        ScoreboardSpec(sport: "basketball", league: "nba", label: "NBA"),
        ScoreboardSpec(sport: "baseball", league: "mlb", label: "MLB"),
        ScoreboardSpec(sport: "hockey", league: "nhl", label: "NHL"),
        ScoreboardSpec(sport: "football", league: "college-football", label: "College Football"),
        ScoreboardSpec(sport: "basketball", league: "mens-college-basketball", label: "Men's CBB"),
        ScoreboardSpec(sport: "basketball", league: "womens-college-basketball", label: "Women's CBB"),
        ScoreboardSpec(sport: "baseball", league: "college-baseball", label: "College Baseball"),
    ]

    private static var allScoreboards: [ScoreboardSpec] {
        soccerScoreboards + usSportsScoreboards
    }

    private static func scoreboards(forSport sport: String?) -> [ScoreboardSpec] {
        guard let sport else { return allScoreboards }
        if sport == "soccer" { return soccerScoreboards }
        return allScoreboards.filter { $0.sport == sport }
    }

    // MARK: - Public

    static func liveGamesToday() async -> [ESPNGameSearchResult] {
        var results: [ESPNGameSearchResult] = []
        var seen = Set<String>()

        for board in allScoreboards {
            guard let games = try? await fetchScoreboard(
                spec: board,
                dates: scoreboardDateRange(pastDays: 1, futureDays: 1),
                matchingTokens: [],
                teamID: nil
            ) else { continue }

            for game in games where game.isLive && seen.insert(game.eventID).inserted {
                results.append(game)
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
        var searchedSports = Set<String>()

        func append(_ games: [ESPNGameSearchResult]) {
            for game in games where seenIDs.insert(game.eventID).inserted {
                results.append(game)
            }
        }

        do {
            let searchItems = try await fetchSearchItems(query: trimmed)

            for item in searchItems.prefix(12) {
                guard let sport = item.sport else { continue }
                searchedSports.insert(sport)

                if item.type == "team", let teamID = item.id {
                    let teamGames = await gamesForTeam(
                        sport: sport,
                        league: item.league ?? item.defaultLeagueSlug,
                        teamID: teamID,
                        teamLabel: teamDisplayName(item),
                        query: trimmed
                    )
                    append(teamGames)
                }

                if item.type == "league" {
                    let league = item.league ?? item.defaultLeagueSlug ?? ""
                    guard !league.isEmpty else { continue }
                    let spec = ScoreboardSpec(
                        sport: sport,
                        league: league,
                        label: item.displayName ?? league
                    )
                    if let boardResults = try? await fetchScoreboard(
                        spec: spec,
                        dates: scoreboardDateRange(pastDays: 21, futureDays: 21),
                        matchingTokens: [],
                        teamID: nil
                    ) {
                        append(boardResults)
                    }
                }

                let boardResults = await gamesForSearchItem(item, query: trimmed)
                append(boardResults)
            }
        } catch {
            lastError = error
        }

        let tokens = tokenize(trimmed)
        let boardsToScan = boardsToScanForFallback(
            query: trimmed,
            tokens: tokens,
            searchedSports: searchedSports
        )

        await withTaskGroup(of: [ESPNGameSearchResult].self) { group in
            for board in boardsToScan {
                group.addTask {
                    (try? await fetchScoreboard(
                        spec: board,
                        dates: scoreboardDateRange(pastDays: 21, futureDays: 21),
                        matchingTokens: tokens,
                        teamID: nil
                    )) ?? []
                }
            }
            for await batch in group {
                append(batch)
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
        let abbreviation: String?
    }

    private static func fetchSearchItems(query: String) async throws -> [SearchItem] {
        var components = URLComponents(string: "https://site.web.api.espn.com/apis/common/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "20"),
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

    private static func teamDisplayName(_ item: SearchItem) -> String {
        [item.location, item.name, item.displayName, item.abbreviation]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func gamesForSearchItem(_ item: SearchItem, query: String) async -> [ESPNGameSearchResult] {
        guard let sport = item.sport, let league = item.league ?? item.defaultLeagueSlug else { return [] }

        let matchQuery = item.type == "team" ? teamDisplayName(item) : query
        let tokens = tokenize(matchQuery.isEmpty ? query : matchQuery)
        let spec = ScoreboardSpec(sport: sport, league: league, label: item.displayName ?? league)

        return (try? await fetchScoreboard(
            spec: spec,
            dates: scoreboardDateRange(pastDays: 21, futureDays: 21),
            matchingTokens: tokens,
            teamID: nil
        )) ?? []
    }

    // MARK: - Team games

    private static func gamesForTeam(
        sport: String,
        league: String?,
        teamID: String,
        teamLabel: String,
        query: String
    ) async -> [ESPNGameSearchResult] {
        var results: [ESPNGameSearchResult] = []
        var seen = Set<String>()
        let dateRange = scoreboardDateRange(pastDays: 21, futureDays: 21)
        let boards = prioritizeBoards(scoreboards(forSport: sport), primaryLeague: league)

        func ingest(_ games: [ESPNGameSearchResult]) {
            for game in games where seen.insert(game.eventID).inserted {
                results.append(game)
            }
        }

        await withTaskGroup(of: [ESPNGameSearchResult].self) { group in
            for board in boards {
                group.addTask {
                    (try? await fetchScoreboard(
                        spec: board,
                        dates: dateRange,
                        matchingTokens: [],
                        teamID: teamID
                    )) ?? []
                }
            }
            for await batch in group {
                ingest(batch)
            }
        }

        if results.isEmpty {
            for board in boards.prefix(8) {
                let scheduled = await fetchSiteTeamSchedule(
                    sport: sport,
                    league: board.league,
                    teamID: teamID,
                    boardLabel: board.label
                )
                ingest(scheduled)
                if !results.isEmpty { break }
            }
        }

        return results
    }

    private static func prioritizeBoards(_ boards: [ScoreboardSpec], primaryLeague: String?) -> [ScoreboardSpec] {
        guard let primaryLeague, !primaryLeague.isEmpty else { return boards }
        var ordered = boards
        if let index = ordered.firstIndex(where: { $0.league == primaryLeague }) {
            let primary = ordered.remove(at: index)
            ordered.insert(primary, at: 0)
        } else {
            ordered.insert(
                ScoreboardSpec(sport: boards.first?.sport ?? "soccer", league: primaryLeague, label: primaryLeague),
                at: 0
            )
        }
        return ordered
    }

    private static func fetchSiteTeamSchedule(
        sport: String,
        league: String,
        teamID: String,
        boardLabel: String
    ) async -> [ESPNGameSearchResult] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/teams/\(teamID)/schedule") else {
            return []
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let schedule = try? JSONDecoder().decode(ScoreboardResponse.self, from: data) else {
            return []
        }

        return (schedule.events ?? []).compactMap { event in
            mapEvent(event, sport: sport, league: league, boardLabel: boardLabel)
        }
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
        let competitors: [ScoreboardCompetitor]?
    }

    private struct ScoreboardCompetitor: Decodable {
        let team: ScoreboardTeam?
    }

    private struct ScoreboardTeam: Decodable {
        let id: FlexibleID
        let displayName: String?
        let abbreviation: String?
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

    private static func fetchScoreboard(
        spec: ScoreboardSpec,
        dates: String,
        matchingTokens: [String],
        teamID: String?
    ) async throws -> [ESPNGameSearchResult] {
        var components = URLComponents(
            string: "https://site.api.espn.com/apis/site/v2/sports/\(spec.sport)/\(spec.league)/scoreboard"
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
            throw ESPNGameSearchError.network("HTTP \(http.statusCode) for \(spec.league)")
        }

        let scoreboard = try JSONDecoder().decode(ScoreboardResponse.self, from: data)

        return (scoreboard.events ?? []).compactMap { event in
            if let teamID, !eventIncludesTeam(event, teamID: teamID) {
                return nil
            }

            let haystack = [
                event.name,
                event.shortName,
                spec.label,
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            if !matchingTokens.isEmpty, !matchesQuery(haystack: haystack, tokens: matchingTokens) {
                return nil
            }

            return mapEvent(event, sport: spec.sport, league: spec.league, boardLabel: spec.label)
        }
    }

    private static func eventIncludesTeam(_ event: ScoreboardEvent, teamID: String) -> Bool {
        guard let competitors = event.competitions?.first?.competitors else { return false }
        return competitors.contains { $0.team?.id.value == teamID }
    }

    private static func mapEvent(
        _ event: ScoreboardEvent,
        sport: String,
        league: String,
        boardLabel: String
    ) -> ESPNGameSearchResult? {
        let status = event.competitions?.first?.status?.type
        let state = status?.state?.lowercased() ?? ""
        let isLive = state == "in" || status?.name.uppercased() == "STATUS_IN_PROGRESS"
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
            leagueLabel: boardLabel,
            isLive: isLive
        )
    }

    // MARK: - Fallback board selection

    private static let soccerQueryHints: Set<String> = [
        "soccer", "football", "futbol", "mls", "liga", "premier", "champions",
        "argentina", "brazil", "mexico", "barcelona", "madrid", "liverpool",
        "world", "copa", "uefa", "fifa", "messi", "ronaldo"
    ]

    private static func boardsToScanForFallback(
        query: String,
        tokens: [String],
        searchedSports: Set<String>
    ) -> [ScoreboardSpec] {
        if searchedSports.contains("soccer") || looksLikeSoccerQuery(query, tokens: tokens) {
            return soccerScoreboards + usSportsScoreboards
        }
        if searchedSports.contains("football") && !searchedSports.contains("soccer") {
            return usSportsScoreboards.filter { $0.sport == "football" } + soccerScoreboards
        }
        return allScoreboards
    }

    private static func looksLikeSoccerQuery(_ query: String, tokens: [String]) -> Bool {
        let lower = query.lowercased()
        if soccerQueryHints.contains(where: { lower.contains($0) }) { return true }
        return tokens.contains(where: { soccerQueryHints.contains($0) })
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
        "game", "games", "today", "tonight", "live", "match", "vs", "the", "at", "my", "fc"
    ]

    private static func matchesQuery(haystack: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        if tokens.count == 1 {
            return haystack.contains(tokens[0])
        }
        return tokens.filter { $0.count >= 3 }.allSatisfy { haystack.contains($0) }
            || tokens.allSatisfy { haystack.contains($0) }
    }

    private static func sortResults(_ results: [ESPNGameSearchResult]) -> [ESPNGameSearchResult] {
        results.sorted { lhs, rhs in
            if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
            if lhs.sportPath.hasPrefix("soccer") != rhs.sportPath.hasPrefix("soccer") {
                return lhs.sportPath.hasPrefix("soccer") && !rhs.sportPath.hasPrefix("soccer")
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
