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

    /// Shifts the clock by `delta` game-clock seconds (positive = later on a count-up clock).
    func adjustingClock(by delta: Int) -> ESPNGameClock? {
        let next = clockSeconds + delta
        guard next >= 0, next <= 3_600 else { return nil }

        return ESPNGameClock(
            period: period,
            clockSeconds: next,
            displayClock: GameClockSyncEngine.formatClock(seconds: next),
            isInProgress: isInProgress,
            periodLabel: periodLabel
        )
    }

    /// What your delayed TV feed should show for a given broadcast delay.
    func tvPreview(delaySeconds: Int, mode: GameClockMode) -> ESPNGameClock? {
        switch mode {
        case .countDown:
            // Delayed TV is behind — countdown shows more time remaining.
            return adjustingClock(by: delaySeconds)
        case .countUp:
            // Delayed TV is behind — less match time has elapsed.
            return adjustingClock(by: -delaySeconds)
        }
    }
}

// MARK: - Sync Engine

enum GameClockSyncEngine {

    static let maxBroadcastDelaySeconds = 300

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

    static func formatClock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainder = clamped % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    static func parseClockString(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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
        let resolvedPeriod = period ?? 0
        guard resolvedPeriod > 0 else { return nil }

        let seconds: Int?
        if let clock, clock > 0 {
            seconds = Int(clock.rounded())
        } else if let displayClock, let parsed = parseClockString(displayClock), parsed > 0 {
            seconds = parsed
        } else {
            seconds = nil
        }

        guard let clockSeconds = seconds else { return nil }

        let label = periodShortName(resolvedPeriod, sportPath: sportPath)
        let display = displayClock?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayClock!
            : formatClock(seconds: clockSeconds)

        let inProgress = state?.lowercased() == "in"

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
        // NFL / default — 15-minute quarters, countdown within period.
        let periodLength = 15 * 60
        let elapsedInPeriod = periodLength - clock.clockSeconds
        return (clock.period - 1) * periodLength + elapsedInPeriod
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
            return anchor.adjustingClock(by: -delta) ?? anchor
        case .countUp:
            return anchor.adjustingClock(by: delta) ?? anchor
        }
    }

    func liveDisplay(at date: Date = Date()) -> String {
        display(for: liveClock(at: date))
    }

    func tvDisplay(delaySeconds: Int, at date: Date = Date()) -> String? {
        let live = liveClock(at: date)
        guard let preview = live.tvPreview(delaySeconds: delaySeconds, mode: mode) else { return nil }
        return display(for: preview)
    }

    private func display(for clock: ESPNGameClock) -> String {
        switch mode {
        case .countUp:
            let elapsed = GameClockSyncEngine.elapsedGameSeconds(from: clock, sportPath: sportPath)
            return GameClockSyncEngine.formatMatchClock(seconds: elapsed)
        case .countDown:
            return clock.periodAndClockLabel
        }
    }
}
