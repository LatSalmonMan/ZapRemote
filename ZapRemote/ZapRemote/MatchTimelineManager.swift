//
//  MatchTimelineManager.swift
//  ZapRemote
//
//  Data engine for tracking live match events and building commercial-break
//  highlight playlists for the media player engine.
//

import Foundation
import Combine

// MARK: - LiveMatchEvent

/// A single notable moment in the currently streaming match.
struct LiveMatchEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    let matchMinute: Int
    let videoTimestampInSeconds: Double
    let eventType: String
    let description: String

    /// Relative priority used when assembling a commercial-break playlist.
    var impactRank: Int {
        switch eventType {
        case "Offside Goal", "Penalty", "Steal & Counter":
            3
        case "Goal", "Red Card", "Buzzer Beater":
            2
        default:
            1
        }
    }
}

// MARK: - MatchTimelineManager

/// Tracks in-game events and produces ordered highlight playlists during commercials.
@MainActor
final class MatchTimelineManager: ObservableObject {

    // MARK: Published State

    /// All notable events recorded for the active match, in chronological order.
    @Published private(set) var activeHighlights: [LiveMatchEvent] = []

    // MARK: Event Types

    private static let commercialBreakImpactTypes: Set<String> = [
        "Offside Goal",
        "Penalty",
        "Steal & Counter",
        "Goal",
        "Red Card",
        "Buzzer Beater"
    ]

    // MARK: Public API

    /// Appends a new highlight and keeps the timeline sorted by match minute.
    func recordEvent(_ event: LiveMatchEvent) {
        guard !activeHighlights.contains(where: { $0.id == event.id }) else { return }
        activeHighlights.append(event)
        sortTimeline()
    }

    /// Replaces the active timeline (e.g., when the user switches primary match).
    func replaceTimeline(with events: [LiveMatchEvent]) {
        activeHighlights = events.sorted { $0.matchMinute < $1.matchMinute }
    }

    /// Clears all tracked events — call when a match ends or the stream resets.
    func resetTimeline() {
        activeHighlights.removeAll()
    }

    /// Filters high-impact events and returns them in chronological playlist order.
    ///
    /// The player engine should seek to each event's `videoTimestampInSeconds`
    /// back-to-back while the primary stream is in a commercial break.
    func fetchHighlightsForCommercialBreak() -> [LiveMatchEvent] {
        activeHighlights
            .filter { $0.impactRank >= 2 || Self.commercialBreakImpactTypes.contains($0.eventType) }
            .sorted { $0.matchMinute < $1.matchMinute }
    }

    // MARK: Demo Data

    /// Seeds the timeline with representative high-impact scenarios (minutes 13, 25, 38).
    func loadDemoTimeline() {
        activeHighlights = Self.demoCommercialBreakHighlights
    }

    // MARK: Private

    private func sortTimeline() {
        activeHighlights.sort { $0.matchMinute < $1.matchMinute }
    }

    /// Mock timeline illustrating commercial-break highlight sequencing.
    static let demoCommercialBreakHighlights: [LiveMatchEvent] = [
        LiveMatchEvent(
            id: UUID(uuidString: "B2000001-0000-4000-8000-000000000001")!,
            matchMinute: 13,
            videoTimestampInSeconds: 782,
            eventType: "Offside Goal",
            description: "VAR overturns the opener — ruled offside by a razor-thin margin."
        ),
        LiveMatchEvent(
            id: UUID(uuidString: "B2000001-0000-4000-8000-000000000002")!,
            matchMinute: 25,
            videoTimestampInSeconds: 1_514,
            eventType: "Penalty",
            description: "Keeper guesses right but the rebound is slammed home."
        ),
        LiveMatchEvent(
            id: UUID(uuidString: "B2000001-0000-4000-8000-000000000003")!,
            matchMinute: 38,
            videoTimestampInSeconds: 2_306,
            eventType: "Steal & Counter",
            description: "Midfield pickpocket springs a three-on-two that finishes top shelf."
        )
    ]
}
