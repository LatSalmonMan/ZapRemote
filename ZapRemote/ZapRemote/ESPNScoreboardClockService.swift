//
//  ESPNScoreboardClockService.swift
//  ZapRemote
//
//  Seeds the local match clock from ESPN's scoreboard API (one-shot, not polled).
//

import Foundation

enum ESPNScoreboardClockService {

    enum FetchError: LocalizedError {
        case invalidSportPath
        case network(String)
        case eventNotFound

        var errorDescription: String? {
            switch self {
            case .invalidSportPath: "Invalid ESPN sport path"
            case .network(let detail): "Scoreboard request failed — \(detail)"
            case .eventNotFound: "Game not found on ESPN scoreboard"
            }
        }
    }

    /// Fetches the current game clock for `eventID` from the league scoreboard endpoint.
    static func fetchClock(eventID: String, sportPath: String) async throws -> ESPNGameClock? {
        let trimmedID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = sportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedPath.isEmpty else { return nil }

        let parts = trimmedPath.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw FetchError.invalidSportPath }

        let sport = parts[0]
        let league = parts[1]
        let dates = scoreboardDateRange(pastDays: 3, futureDays: 3)

        var components = URLComponents(
            string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/scoreboard"
        )!
        components.queryItems = [
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = components.url else { throw FetchError.network("invalid URL") }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw FetchError.network("HTTP \(http.statusCode)")
        }

        let scoreboard = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
        guard let event = (scoreboard.events ?? []).first(where: { $0.id.value == trimmedID }) else {
            throw FetchError.eventNotFound
        }

        return parseClock(from: event, sportPath: trimmedPath)
    }

    // MARK: - Parse

    private static func parseClock(from event: ScoreboardEvent, sportPath: String) -> ESPNGameClock? {
        let status = event.competitions?.first?.status
        let type = status?.type

        return GameClockSyncEngine.parseClock(
            period: status?.period,
            clock: status?.clock,
            displayClock: status?.displayClock,
            state: type?.state,
            sportPath: sportPath,
            statusDetail: type?.detail ?? type?.shortDetail
        )
    }

    private static func scoreboardDateRange(pastDays: Int, futureDays: Int) -> String {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -pastDays, to: now) ?? now
        let end = calendar.date(byAdding: .day, value: futureDays, to: now) ?? now
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }

    // MARK: - Scoreboard JSON

    private struct ScoreboardResponse: Decodable {
        let events: [ScoreboardEvent]?
    }

    private struct ScoreboardEvent: Decodable {
        let id: FlexibleID
        let competitions: [ScoreboardCompetition]?
    }

    private struct ScoreboardCompetition: Decodable {
        let status: ScoreboardStatus?
    }

    private struct ScoreboardStatus: Decodable {
        let clock: Double?
        let displayClock: String?
        let period: Int?
        let type: ScoreboardStatusType
    }

    private struct ScoreboardStatusType: Decodable {
        let state: String?
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
}
