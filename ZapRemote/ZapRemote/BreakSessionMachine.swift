//
//  BreakSessionMachine.swift
//  ZapRemote
//
//  Single source of truth for the commercial-break → highlight → Go Live lifecycle.
//  Phase 0: reliability over speed — one rewind, one hold, one return per break.
//

import Combine
import Foundation

/// Explicit phases for the break session. UI flags derive from this — do not add parallel latches.
enum BreakSessionPhase: String, Equatable, Sendable {
    case idle
    case armed
    case rewinding
    case holding
    case returning
    case cooldown
    case error
}

/// Snapshot of numbers for one break cycle — written once, logged at every transition.
struct BreakSessionLedger: Equatable, Sendable {
    var streamDelaySeconds: Double = 0
    var highlightDescription: String = ""
    var highlightRank: Int = 0
    var computedRewindSeconds: Int = 0
    var snappedRewindSeconds: Int = 0
    var rewindClicks: Int = 0
    var watchSeconds: TimeInterval = 0
    /// Wall time spent after rewind lands — used so return math still works if the session resets.
    var actualHeldSeconds: TimeInterval = 0
    var forwardClicks: Int = 0
    var errorReason: String = ""
}

/// Owns break lifecycle transitions. All TV macros for a break go through this machine.
@MainActor
final class BreakSessionMachine: ObservableObject {

    @Published private(set) var phase: BreakSessionPhase = .idle
    @Published private(set) var ledger = BreakSessionLedger()
    @Published private(set) var lastErrorMessage: String = ""

    /// Fixed hold after rewind lands (Phase 0 — one conservative window).
    static let defaultWatchSeconds: TimeInterval = 45
    /// Refuse new Ad taps briefly after Go Live so the scrub bar can settle.
    static let cooldownSeconds: TimeInterval = 3

    var isBreakActive: Bool {
        switch phase {
        case .idle, .cooldown, .error: false
        default: true
        }
    }

    var isRewinding: Bool { phase == .rewinding }
    var isHolding: Bool { phase == .holding }
    var isReturningToLive: Bool { phase == .returning }
    var canAcceptAdTap: Bool { phase == .idle }
    var canAcceptGoLiveTap: Bool {
        phase == .holding || phase == .rewinding || phase == .returning
    }

    // MARK: - Transitions

    /// IDLE → ARMED (or ERROR if preconditions fail).
    @discardableResult
    func arm(
        streamDelaySeconds: Double,
        highlightDescription: String,
        highlightRank: Int,
        computedRewindSeconds: Int,
        snappedRewindSeconds: Int,
        rewindClicks: Int,
        watchSeconds: TimeInterval = BreakSessionMachine.defaultWatchSeconds
    ) -> Bool {
        guard phase == .idle else {
            log("arm rejected — phase=\(phase.rawValue)")
            return false
        }

        var next = BreakSessionLedger()
        next.streamDelaySeconds = streamDelaySeconds
        next.highlightDescription = highlightDescription
        next.highlightRank = highlightRank
        next.computedRewindSeconds = computedRewindSeconds
        next.snappedRewindSeconds = snappedRewindSeconds
        next.rewindClicks = rewindClicks
        next.watchSeconds = watchSeconds
        ledger = next
        lastErrorMessage = ""
        transition(to: .armed, event: "AdTapped")
        return true
    }

    /// ARMED → REWINDING once the TV macro is about to start.
    @discardableResult
    func beginRewind() -> Bool {
        guard phase == .armed else {
            log("beginRewind rejected — phase=\(phase.rawValue)")
            return false
        }
        transition(to: .rewinding, event: "PreconditionsOK")
        return true
    }

    /// REWINDING → HOLDING after ENTER confirmed / macro finished.
    @discardableResult
    func beginHold(actualRewindClicks: Int) -> Bool {
        guard phase == .rewinding else {
            log("beginHold rejected — phase=\(phase.rawValue)")
            return false
        }
        ledger.rewindClicks = max(0, actualRewindClicks)
        transition(to: .holding, event: "RewindComplete")
        return true
    }

    /// Snapshot how long the highlight has been playing (survives idle resets).
    func recordHeldSeconds(_ seconds: TimeInterval) {
        ledger.actualHeldSeconds = max(ledger.actualHeldSeconds, max(0, seconds))
    }

    /// HOLDING (or queued from REWINDING) → RETURNING.
    @discardableResult
    func beginReturn(forwardClicks: Int) -> Bool {
        guard phase == .holding || phase == .rewinding else {
            log("beginReturn rejected — phase=\(phase.rawValue)")
            return false
        }
        ledger.forwardClicks = max(0, forwardClicks)
        transition(to: .returning, event: phase == .holding ? "WatchTimerElapsed" : "GoLiveQueued")
        return true
    }

    /// RETURNING → COOLDOWN after Go Live macro finishes.
    @discardableResult
    func beginCooldown() -> Bool {
        guard phase == .returning else {
            log("beginCooldown rejected — phase=\(phase.rawValue)")
            return false
        }
        transition(to: .cooldown, event: "ReturnComplete")
        return true
    }

    /// COOLDOWN / ERROR → IDLE.
    func resetToIdle() {
        ledger = BreakSessionLedger()
        lastErrorMessage = ""
        transition(to: .idle, event: "Reset")
    }

    /// Any phase → ERROR, then caller should recover to IDLE.
    func fail(_ reason: String) {
        ledger.errorReason = reason
        lastErrorMessage = reason
        transition(to: .error, event: "Error")
        log("ERROR — \(reason) | \(sessionLogLine())")
    }

    // MARK: - Logging

    func sessionLogLine() -> String {
        let h = ledger.highlightDescription.prefix(40)
        return [
            "phase=\(phase.rawValue)",
            "delay=\(Int(ledger.streamDelaySeconds.rounded()))s",
            "rank=\(ledger.highlightRank)",
            "computed=\(ledger.computedRewindSeconds)s",
            "snapped=\(ledger.snappedRewindSeconds)s",
            "rewindClicks=\(ledger.rewindClicks)",
            "watch=\(Int(ledger.watchSeconds))s",
            "forwardClicks=\(ledger.forwardClicks)",
            "highlight=\"\(h)\""
        ].joined(separator: " ")
    }

    private func transition(to next: BreakSessionPhase, event: String) {
        let previous = phase
        phase = next
        log("\(previous.rawValue) → \(next.rawValue) [\(event)] | \(sessionLogLine())")
    }

    private func log(_ message: String) {
        print("🧭 BreakSession: \(message)")
    }
}
