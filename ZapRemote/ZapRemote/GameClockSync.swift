//
//  GameClockSync.swift
//  ZapRemote
//
//  Hue Sports Live–style sync: match ESPN's live game clock to what's on your TV.
//

import Foundation

// MARK: - Clock Mode

enum GameClockMode: Sendable {
    /// NFL / NBA — clock counts down within each period.
    case countDown
    /// Soccer — match clock counts up.
    case countUp
}

// MARK: - ESPN Game Clock

/// Parsed in-game clock from ESPN's summary API.
struct ESPNGameClock: Equatable, Sendable {
    let period: Int
    /// Seconds within the period (remaining for countdown sports, elapsed for count-up).
    let clockSeconds: Int
    let displayClock: String
    let isInProgress: Bool

    var periodAndClockLabel: String {
        "\(periodLabel) \(displayClock)"
    }

    var periodLabel: String = "Q1"

    func adjustingClock(by delta: Int, sportPath: String) -> ESPNGameClock? {
        let mode = GameClockSyncEngine.clockMode(for: sportPath)
        var next = clockSeconds + delta
        guard next >= 0 else { return nil }

        switch mode {
        case .countDown:
            let maxPeriod = GameClockSyncEngine.periodLengthSeconds(sportPath: sportPath, period: period)
            next = min(next, maxPeriod)
        case .countUp:
            guard next <= 3_600 else { return nil }
        }

        let display: String
        switch mode {
        case .countDown:
            display = GameClockSyncEngine.formatCountdownClock(seconds: next)
        case .countUp:
            display = GameClockSyncEngine.formatSoccerMinute(seconds: next)
        }

        return ESPNGameClock(
            period: period,
            clockSeconds: next,
            displayClock: display,
            isInProgress: isInProgress,
            periodLabel: periodLabel
        )
    }

    /// What your delayed TV feed should show for a given broadcast delay.
    func tvPreview(delaySeconds: Int, mode: GameClockMode, sportPath: String) -> ESPNGameClock? {
        switch mode {
        case .countDown:
            return adjustingClock(by: delaySeconds, sportPath: sportPath)
        case .countUp:
            return adjustingClock(by: -delaySeconds, sportPath: sportPath)
        }
    }
}

// MARK: - Sync Engine

enum GameClockSyncEngine {

    static let minBroadcastDelaySeconds = 3
    static let maxBroadcastDelaySeconds = 300

    /// How long ago a play aired on the user's delayed TV feed (not ESPN live).
    static func ageOnUserTV(
        livePlayDate: Date,
        now: Date = Date(),
        streamDelaySeconds: Double
    ) -> TimeInterval {
        max(0, now.timeIntervalSince(livePlayDate) - streamDelaySeconds)
    }

    /// Wall-clock moment when a live ESPN event appears on the user's TV.
    static func userTVAirDate(liveEventDate: Date, streamDelaySeconds: Double) -> Date {
        liveEventDate.addingTimeInterval(streamDelaySeconds)
    }

    /// In-period game clock on the user's TV (e.g. ESPN 14:23 → your 14:31 when 8s behind).
    static func userTVInPeriodClockSeconds(
        liveClockSeconds: Int,
        delaySeconds: Int,
        mode: GameClockMode
    ) -> Int {
        switch mode {
        case .countDown:
            return min(3_600, liveClockSeconds + delaySeconds)
        case .countUp:
            return max(0, liveClockSeconds - delaySeconds)
        }
    }

    static func clockMode(for sportPath: String) -> GameClockMode {
        let path = sportPath.lowercased()
        if path.contains("soccer") || path.contains("fifa") {
            return .countUp
        }
        return .countDown
    }

    static func periodShortName(_ period: Int, sportPath: String) -> String {
        let path = sportPath.lowercased()
        if path.contains("soccer") || path.contains("fifa") {
            return period <= 1 ? "1H" : "2H"
        }
        if period <= 0 { return "—" }
        if period <= 4 { return "Q\(period)" }
        return "OT"
    }

    /// Formats seconds remaining in a period (NFL/NBA countdown).
    static func formatCountdownClock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainder = clamped % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// Soccer-style minute display from elapsed seconds in period.
    static func formatSoccerMinute(seconds: Int) -> String {
        let minutes = max(0, seconds / 60)
        return "\(minutes)'"
    }

    static func periodLengthSeconds(sportPath: String, period: Int) -> Int {
        let path = sportPath.lowercased()
        if path.contains("soccer") || path.contains("fifa") { return 45 * 60 }
        if path.contains("basketball") { return 12 * 60 }
        if path.contains("hockey") { return 20 * 60 }
        return 15 * 60
    }

    static func formatClock(seconds: Int) -> String {
        formatCountdownClock(seconds: seconds)
    }

    static func parseClockString(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Soccer style: `67'`, `45'+2'`, `90'+4`
        if trimmed.contains("'") {
            let stripped = trimmed.replacingOccurrences(of: "'", with: "")
            if stripped.contains("+") {
                let parts = stripped.split(separator: "+", maxSplits: 1)
                guard let baseMinutes = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
                let stoppage = parts.count > 1 ? (Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
                return (baseMinutes + stoppage) * 60
            }
            if let minutes = Int(stripped) {
                return minutes * 60
            }
        }

        if let numeric = Int(trimmed), numeric >= 0 {
            return numeric
        }

        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              minutes >= 0, seconds >= 0, seconds < 60 else {
            return nil
        }
        return minutes * 60 + seconds
    }

    /// Builds a live clock snapshot from ESPN `status` fields.
    static func parseClock(
        period: Int?,
        clock: Double?,
        displayClock: String?,
        state: String?,
        sportPath: String
    ) -> ESPNGameClock? {
        var resolvedPeriod = period ?? 0
        let mode = clockMode(for: sportPath)
        if resolvedPeriod <= 0 {
            let path = sportPath.lowercased()
            if path.contains("soccer") || path.contains("fifa") {
                resolvedPeriod = 1
            } else if path.contains("football") || path.contains("basketball") || path.contains("hockey") {
                resolvedPeriod = 1
            }
        }
        let maxPeriod = periodLengthSeconds(sportPath: sportPath, period: max(resolvedPeriod, 1))

        let seconds: Int?
        // Prefer ESPN's display string (Q3 8:45) over the raw `clock` number — it is often wrong.
        if let displayClock,
           let parsed = parseClockString(displayClock),
           parsed > 0 {
            seconds = mode == .countDown ? min(parsed, maxPeriod) : parsed
        } else if let clock, clock > 0 {
            let asInt = Int(clock.rounded())
            if mode == .countDown {
                seconds = asInt <= maxPeriod ? asInt : nil
            } else {
                seconds = asInt
            }
        } else {
            seconds = nil
        }

        guard let clockSeconds = seconds else { return nil }

        if resolvedPeriod <= 0 {
            let path = sportPath.lowercased()
            if path.contains("soccer") || path.contains("fifa") {
                resolvedPeriod = clockSeconds > 45 * 60 ? 2 : 1
            } else if path.contains("football") || path.contains("basketball") || path.contains("hockey") {
                resolvedPeriod = 1
            }
        }
        guard resolvedPeriod > 0 else { return nil }

        let label = periodShortName(resolvedPeriod, sportPath: sportPath)
        let display: String
        switch mode {
        case .countDown:
            display = formatCountdownClock(seconds: min(clockSeconds, maxPeriod))
        case .countUp:
            if let rawDisplay = displayClock?.trimmingCharacters(in: .whitespacesAndNewlines),
               rawDisplay.contains("'") {
                display = rawDisplay
            } else {
                display = formatSoccerMinute(seconds: clockSeconds)
            }
        }

        let inProgress = state?.lowercased() == "in"
            || (state?.lowercased() != "post" && state?.lowercased() != "pre" && clockSeconds > 0)

        return ESPNGameClock(
            period: resolvedPeriod,
            clockSeconds: clockSeconds,
            displayClock: display,
            isInProgress: inProgress,
            periodLabel: label
        )
    }

    /// Computes broadcast delay when the user matches period + clock from their TV.
    static func streamDelaySeconds(
        espn: ESPNGameClock,
        tvPeriod: Int,
        tvClockSeconds: Int,
        mode: GameClockMode
    ) -> Double? {
        guard espn.period == tvPeriod else { return nil }

        let delay: Int
        switch mode {
        case .countDown:
            delay = tvClockSeconds - espn.clockSeconds
        case .countUp:
            delay = espn.clockSeconds - tvClockSeconds
        }

        guard delay >= 0, delay <= maxBroadcastDelaySeconds else { return nil }
        return Double(delay)
    }

    static func displayLabel(for clock: ESPNGameClock) -> String {
        clock.periodAndClockLabel
    }

    /// Match clock format — `93:44`, ticks up every second during live play.
    static func formatMatchClock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainder = clamped % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// Normalizes ESPN period clocks into one elapsed match timer (count-up).
    static func elapsedGameSeconds(from clock: ESPNGameClock, sportPath: String) -> Int {
        let path = sportPath.lowercased()
        if path.contains("soccer") || path.contains("fifa") {
            let halfLength = 45 * 60
            return clock.period <= 1 ? clock.clockSeconds : halfLength + clock.clockSeconds
        }
        if path.contains("basketball") {
            let periodLength = 12 * 60
            let elapsedInPeriod = periodLength - clock.clockSeconds
            return (clock.period - 1) * periodLength + elapsedInPeriod
        }
        let periodLength = 15 * 60
        let elapsedInPeriod = periodLength - clock.clockSeconds
        return (clock.period - 1) * periodLength + elapsedInPeriod
    }

    static func elapsedMinutesLabel(from clock: ESPNGameClock, sportPath: String) -> String {
        let elapsed = elapsedGameSeconds(from: clock, sportPath: sportPath)
        return "\(formatMatchClock(seconds: elapsed)) elapsed"
    }
}

// MARK: - Ticking Game Clock

/// Live ESPN game clock — ticks between API polls while the game clock is running.
struct TickingGameClock: Equatable, Sendable {
    let anchor: ESPNGameClock
    let mode: GameClockMode
    let sportPath: String
    let capturedAt: Date

    func liveClock(at date: Date = Date()) -> ESPNGameClock {
        guard anchor.isInProgress else { return anchor }
        let delta = max(0, Int(date.timeIntervalSince(capturedAt)))
        switch mode {
        case .countDown:
            return anchor.adjustingClock(by: -delta, sportPath: sportPath) ?? anchor
        case .countUp:
            return anchor.adjustingClock(by: delta, sportPath: sportPath) ?? anchor
        }
    }

    func liveDisplay(at date: Date = Date()) -> String {
        display(for: liveClock(at: date))
    }

    func tvDisplay(delaySeconds: Int, at date: Date = Date()) -> String? {
        let live = liveClock(at: date)
        guard let preview = live.tvPreview(delaySeconds: delaySeconds, mode: mode, sportPath: sportPath) else {
            return nil
        }
        return display(for: preview)
    }

    private func display(for clock: ESPNGameClock) -> String {
        switch mode {
        case .countUp:
            if clock.displayClock.contains("'") {
                return clock.periodAndClockLabel
            }
            return "\(clock.periodLabel) \(GameClockSyncEngine.formatSoccerMinute(seconds: clock.clockSeconds))"
        case .countDown:
            let maxPeriod = GameClockSyncEngine.periodLengthSeconds(sportPath: sportPath, period: clock.period)
            let remaining = min(clock.clockSeconds, maxPeriod)
            return "\(clock.periodLabel) \(GameClockSyncEngine.formatCountdownClock(seconds: remaining))"
        }
    }
}
