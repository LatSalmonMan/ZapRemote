//
//  AdCloudEvent.swift
//  ZapRemote
//
//  Cloud brain → phone payload contract for live ad detection.
//

import Foundation

// MARK: - Event Types

enum AdCloudEventType: String, Codable, Sendable {
    case adStart = "ad_start"
    case gameLive = "game_live"
}

// MARK: - Payload

/// JSON envelope broadcast by the centralized detection server.
///
/// Example `ad_start`:
/// ```json
/// {
///   "event": "ad_start",
///   "game_id": "nfl-snf-2026-wk1",
///   "channel": "ESPN",
///   "broadcast_ts": 1718543400.120,
///   "suggested_rewind_seconds": 120,
///   "confidence": 0.92,
///   "signals": ["scte35", "black_frame"]
/// }
/// ```
struct AdCloudEvent: Codable, Sendable, Equatable {
    let event: String
    var gameID: String?
    var channel: String?
    var broadcastTs: Double?
    var suggestedRewindSeconds: Int?
    var confidence: Double?
    var signals: [String]?

    enum CodingKeys: String, CodingKey {
        case event
        case gameID = "game_id"
        case channel
        case broadcastTs = "broadcast_ts"
        case suggestedRewindSeconds = "suggested_rewind_seconds"
        case confidence
        case signals
    }

    var eventType: AdCloudEventType? {
        AdCloudEventType(rawValue: event)
    }

    /// Minimum confidence required before executing automation on-device.
    static let automationConfidenceThreshold = 0.70
}

// MARK: - Lag Sync

/// Per-user stream delay calibration applied to cloud rewind suggestions.
struct AdLagSyncProfile: Sendable {
    /// Seconds the user's streaming app lags behind true broadcast time.
    var streamDelayOffsetSeconds: Int
    /// Estimated cloud→phone delivery latency subtracted from rewind depth.
    var detectionLatencySeconds: Int

    static let `default` = AdLagSyncProfile(
        streamDelayOffsetSeconds: 0,
        detectionLatencySeconds: 2
    )

    /// `effectiveRewind = suggested + streamDelay - detectionLatency`
    func effectiveRewindSeconds(suggested: Int) -> Int {
        max(1, suggested + streamDelayOffsetSeconds - detectionLatencySeconds)
    }
}

enum AdEventStorageKey {
    static let streamDelayOffset = "zapremote.ad.streamDelayOffsetSeconds"
    static let subscribedGameID = "zapremote.ad.subscribedGameID"
    static let cloudWebSocketURL = "zapremote.ad.cloudWebSocketURL"
}
