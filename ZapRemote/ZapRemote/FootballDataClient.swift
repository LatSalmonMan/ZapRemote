//
//  FootballDataClient.swift
//  ZapRemote
//
//  football-data.org v4 client — soccer matches, live minute, goals & bookings.
//  Auth: X-Auth-Token (set in Settings). Respect rate limits (~10/min free).
//

import Foundation

// MARK: - Storage

enum FootballDataStorageKey {
    static let apiToken = "zapremote.footballdata.apiToken"
}

// MARK: - Errors

enum FootballDataError: LocalizedError {
    case missingToken
    case invalidURL
    case httpStatus(Int, String?)
    case decode(Error)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Add your football-data.org API token in Settings"
        case .invalidURL:
            "Invalid football-data.org URL"
        case .httpStatus(let code, let body):
            "football-data.org HTTP \(code)\(body.map { " — \($0)" } ?? "")"
        case .decode(let error):
            "football-data.org decode failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - Models

struct FDCompetition: Decodable, Sendable, Hashable {
    let id: Int
    let name: String?
    let code: String?
}

struct FDTeam: Decodable, Sendable, Hashable {
    let id: Int
    let name: String?
    let shortName: String?
    let tla: String?
}

struct FDScore: Decodable, Sendable {
    let fullTime: FDScorePair?
    let halfTime: FDScorePair?
}

struct FDScorePair: Decodable, Sendable {
    let home: Int?
    let away: Int?
}

struct FDGoal: Decodable, Sendable, Identifiable {
    let minute: Int?
    let injuryTime: Int?
    let type: String?
    let team: FDTeam?
    let scorer: FDPerson?
    let assist: FDPerson?
    let score: FDScorePair?

    var id: String {
        "goal-\(minute ?? 0)-\(injuryTime ?? 0)-\(scorer?.id ?? 0)-\(team?.id ?? 0)"
    }
}

struct FDBooking: Decodable, Sendable, Identifiable {
    let minute: Int?
    let injuryTime: Int?
    let team: FDTeam?
    let player: FDPerson?
    let card: String?

    var id: String {
        "card-\(minute ?? 0)-\(injuryTime ?? 0)-\(player?.id ?? 0)-\(card ?? "")"
    }
}

struct FDPerson: Decodable, Sendable {
    let id: Int?
    let name: String?
}

struct FDMatch: Decodable, Sendable, Identifiable {
    let id: Int
    let utcDate: String?
    let status: String?
    let minute: Int?
    let injuryTime: Int?
    let matchday: Int?
    let competition: FDCompetition?
    let homeTeam: FDTeam?
    let awayTeam: FDTeam?
    let score: FDScore?
    let goals: [FDGoal]?
    let bookings: [FDBooking]?

    var title: String {
        let home = homeTeam?.shortName ?? homeTeam?.name ?? "Home"
        let away = awayTeam?.shortName ?? awayTeam?.name ?? "Away"
        return "\(home) vs \(away)"
    }

    var isLive: Bool {
        let s = status?.uppercased() ?? ""
        return s == "IN_PLAY" || s == "PAUSED" || s == "LIVE"
    }

    var isFinished: Bool {
        status?.uppercased() == "FINISHED"
    }

    /// Approximate elapsed match seconds from football-data minute fields.
    var elapsedMatchSeconds: Int {
        let base = max(0, minute ?? 0) * 60
        let injury = max(0, injuryTime ?? 0) * 60
        return base + injury
    }

    var statusLabel: String {
        switch status?.uppercased() {
        case "IN_PLAY":
            if let m = minute { return "\(m)'" }
            return "Live"
        case "PAUSED": return "HT"
        case "FINISHED": return "FT"
        case "TIMED", "SCHEDULED": return "Upcoming"
        default: return status ?? "—"
        }
    }
}

struct FDMatchesResponse: Decodable, Sendable {
    let matches: [FDMatch]?
}

struct FDMatchListEnvelope: Decodable, Sendable {
    let matches: [FDMatch]?
    // Single-match endpoint returns the match object at root — handled separately.
}

// MARK: - Game pick result (UI)

struct FootballDataGameResult: Identifiable, Equatable, Sendable {
    let id: String
    let matchID: Int
    let title: String
    let statusLabel: String
    let leagueLabel: String
    let isLive: Bool

    var selectionSummary: String {
        "\(title) · \(statusLabel)"
    }
}

// MARK: - Client

enum FootballDataClient {

    private static let baseURL = URL(string: "https://api.football-data.org/v4")!

    /// Competitions we surface first (free-tier friendly codes).
    static let preferredCompetitionCodes = [
        "PL", "CL", "BL1", "SA", "PD", "FL1", "DED", "PPL", "ELC", "WC", "EC", "BSA"
    ]

    static var apiToken: String {
        get {
            (UserDefaults.standard.string(forKey: FootballDataStorageKey.apiToken) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                     forKey: FootballDataStorageKey.apiToken)
        }
    }

    static var hasAPIToken: Bool { !apiToken.isEmpty }

    // MARK: Requests

    static func fetchLiveAndTodayMatches() async throws -> [FootballDataGameResult] {
        try requireToken()
        let today = Self.dayString(Date())
        let matches = try await fetchMatches(queryItems: [
            URLQueryItem(name: "dateFrom", value: today),
            URLQueryItem(name: "dateTo", value: today)
        ])
        return matches
            .map(toGameResult)
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
                return lhs.title < rhs.title
            }
    }

    static func fetchMatches(competitionCode: String) async throws -> [FootballDataGameResult] {
        try requireToken()
        let path = "competitions/\(competitionCode)/matches"
        let envelope: FDMatchesResponse = try await get(path: path, queryItems: [
            URLQueryItem(name: "status", value: "LIVE,IN_PLAY,PAUSED,TIMED,SCHEDULED")
        ])
        return (envelope.matches ?? []).map(toGameResult)
    }

    static func fetchMatch(id: Int) async throws -> FDMatch {
        try requireToken()
        // Unfold goals + bookings when the plan allows deep data.
        return try await get(
            path: "matches/\(id)",
            queryItems: [],
            extraHeaders: [
                "X-Unfold-Goals": "true",
                "X-Unfold-Bookings": "true"
            ]
        )
    }

    // MARK: Private

    private static func fetchMatches(queryItems: [URLQueryItem]) async throws -> [FDMatch] {
        let envelope: FDMatchesResponse = try await get(path: "matches", queryItems: queryItems)
        return envelope.matches ?? []
    }

    private static func toGameResult(_ match: FDMatch) -> FootballDataGameResult {
        FootballDataGameResult(
            id: String(match.id),
            matchID: match.id,
            title: match.title,
            statusLabel: match.statusLabel,
            leagueLabel: match.competition?.name ?? match.competition?.code ?? "Soccer",
            isLive: match.isLive
        )
    }

    private static func requireToken() throws {
        guard hasAPIToken else { throw FootballDataError.missingToken }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw FootballDataError.invalidURL }

        // Honor football-data rate-limit headers before firing.
        if let wait = await RateLimiter.shared.secondsUntilAllowed() {
            print("⏳ football-data: waiting \(wait)s for rate limit")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }

        var request = URLRequest(url: url)
        request.setValue(apiToken, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FootballDataError.httpStatus(-1, nil)
        }

        await RateLimiter.shared.ingest(headers: http.allHeaderFields)

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(160)) }
            throw FootballDataError.httpStatus(http.statusCode, body)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FootballDataError.decode(error)
        }
    }
}

// MARK: - Rate limit (from response headers)

/// Tracks `x-requests-available-minute` and `X-RequestCounter-Reset` from football-data.org.
private actor RateLimiter {
    static let shared = RateLimiter()

    private var availableThisMinute: Int = 10
    private var resetAt: Date = .distantPast

    func ingest(headers: [AnyHashable: Any]) {
        func intValue(_ key: String) -> Int? {
            if let value = headers[key] as? Int { return value }
            if let value = headers[key] as? String { return Int(value) }
            // URLSession lowercases some header keys
            let lower = key.lowercased()
            for (k, v) in headers {
                guard String(describing: k).lowercased() == lower else { continue }
                if let i = v as? Int { return i }
                if let s = v as? String { return Int(s) }
            }
            return nil
        }

        if let available = intValue("x-requests-available-minute") {
            availableThisMinute = available
        }
        if let reset = intValue("X-RequestCounter-Reset") ?? intValue("x-requestcounter-reset") {
            resetAt = Date().addingTimeInterval(TimeInterval(max(0, reset)))
        }
    }

    /// Seconds to wait before next request, or nil if allowed now.
    func secondsUntilAllowed() -> Int? {
        if availableThisMinute > 0 { return nil }
        let wait = Int(ceil(resetAt.timeIntervalSinceNow))
        return wait > 0 ? wait : 1
    }
}

// MARK: - Highlight parsing

enum FootballDataHighlightParser {

    /// Converts goals + bookings into ranked highlights with match-elapsed seconds.
    static func highlights(from match: FDMatch) -> [SportHighlight] {
        var items: [SportHighlight] = []

        for goal in match.goals ?? [] {
            guard let minute = goal.minute else { continue }
            let injury = goal.injuryTime ?? 0
            let elapsed = minute * 60 + injury * 60
            let scorer = goal.scorer?.name ?? "Player"
            let team = goal.team?.shortName ?? goal.team?.name ?? "Team"
            let kind = (goal.type ?? "GOAL").uppercased()
            let text: String
            if kind.contains("PENALTY") {
                text = "Penalty — \(scorer) (\(team))"
            } else if kind.contains("OWN") {
                text = "Own goal — \(scorer) (\(team))"
            } else {
                text = "Goal — \(scorer) (\(team))"
            }
            items.append(
                SportHighlight(
                    id: goal.id,
                    playDescription: text,
                    apiTimestamp: Date(), // unused for minute-based rewind
                    interestRank: 3,
                    matchElapsedSeconds: elapsed
                )
            )
        }

        for booking in match.bookings ?? [] {
            guard let minute = booking.minute else { continue }
            let injury = booking.injuryTime ?? 0
            let elapsed = minute * 60 + injury * 60
            let player = booking.player?.name ?? "Player"
            let team = booking.team?.shortName ?? booking.team?.name ?? "Team"
            let card = (booking.card ?? "").uppercased()
            let isRed = card.contains("RED")
            let text = isRed
                ? "Red card — \(player) (\(team))"
                : "Yellow card — \(player) (\(team))"
            items.append(
                SportHighlight(
                    id: booking.id,
                    playDescription: text,
                    apiTimestamp: Date(),
                    interestRank: isRed ? 3 : 2,
                    matchElapsedSeconds: elapsed
                )
            )
        }

        return items.sorted {
            if $0.matchElapsedSeconds != $1.matchElapsedSeconds {
                return $0.matchElapsedSeconds < $1.matchElapsedSeconds
            }
            return $0.interestRank > $1.interestRank
        }
    }
}
