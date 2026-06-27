//
//  AdEventService.swift
//  ZapRemote
//
//  Client event bridge — receives cloud ad-detection WebSocket events and
//  executes LG TV rewind / live-return macros via TVController.
//
//  Architecture:
//    Cloud detector (1 feed) → WebSocket fan-out → AdEventService → TVController
//

import Combine
import Foundation

// MARK: - Bridge Status

enum AdEventBridgeStatus: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var displayLabel: String {
        switch self {
        case .disconnected: "Cloud brain offline"
        case .connecting: "Connecting to cloud brain…"
        case .connected: "Cloud brain connected"
        case .reconnecting: "Reconnecting to cloud brain…"
        }
    }
}

// MARK: - AdEventService

@MainActor
final class AdEventService: ObservableObject {

    // MARK: Published State

    @Published private(set) var bridgeStatus: AdEventBridgeStatus = .disconnected
    @Published private(set) var lastEventSummary: String = "Awaiting cloud events"
    @Published private(set) var lastProcessedAt: Date?
    @Published private(set) var isAdBreakActive = false

    /// Reads TV offset from SportsAPIService — single source of truth.
    private var streamDelayOffsetSeconds: Int {
        Int(sportsAPIService?.streamDelaySeconds.rounded() ?? 0)
    }

    @Published var subscribedGameID: String {
        didSet {
            UserDefaults.standard.set(subscribedGameID, forKey: AdEventStorageKey.subscribedGameID)
        }
    }

    // MARK: Configuration

    /// Default dev endpoint — replace with production `wss://` URL.
    @Published var cloudWebSocketURLString: String {
        didSet {
            UserDefaults.standard.set(cloudWebSocketURLString, forKey: AdEventStorageKey.cloudWebSocketURL)
        }
    }

    private let detectionLatencySeconds = 2
    private let minimumReconnectDelaySeconds: UInt64 = 3

    // MARK: Private

    private weak var tvController: TVController?
    weak var sportsAPIService: SportsAPIService?
    private var webSocketSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldMaintainConnection = false

    /// True when a detector URL is saved and usable.
    var isCloudURLConfigured: Bool {
        hasConfiguredDetectorURL
    }

    /// True when a detector URL is saved.
    var hasConfiguredDetectorURL: Bool {
        !cloudWebSocketURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Init

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        webSocketSession = URLSession(configuration: configuration)

        subscribedGameID = UserDefaults.standard.string(
            forKey: AdEventStorageKey.subscribedGameID
        ) ?? ""

        cloudWebSocketURLString = UserDefaults.standard.string(
            forKey: AdEventStorageKey.cloudWebSocketURL
        ) ?? ""
    }

    deinit {
        receiveLoopTask?.cancel()
        reconnectTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: Binding

    /// Attach the TV actuator — call once at app launch.
    func configure(tvController: TVController) {
        self.tvController = tvController
    }

    // MARK: Connection Lifecycle

    /// Opens the cloud WebSocket and begins listening for ad events.
    func startListening() {
        let trimmed = cloudWebSocketURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bridgeStatus = .disconnected
            lastEventSummary = "Optional — set Mac detector URL in Settings"
            return
        }

        guard let url = URL(string: trimmed) else {
            lastEventSummary = "Invalid cloud WebSocket URL"
            print("❌ AdEventService: invalid URL \(trimmed)")
            return
        }

        #if !targetEnvironment(simulator)
        if Self.isLoopbackWebSocketURL(trimmed) {
            bridgeStatus = .disconnected
            lastEventSummary = "127.0.0.1 only works in Simulator — use ws://YOUR-MAC-IP:8787"
            print("⚠️ AdEventService: skipping loopback URL on physical device")
            return
        }
        #endif

        shouldMaintainConnection = true
        reconnectTask?.cancel()
        connect(to: url)
    }

    /// Re-opens the cloud socket if it dropped while we should still be listening.
    func ensureConnectionHealth() {
        guard shouldMaintainConnection else { return }
        guard bridgeStatus != .connected, bridgeStatus != .connecting else { return }
        startListening()
    }

    /// Stops listening and tears down the cloud socket.
    func stopListening() {
        shouldMaintainConnection = false
        reconnectTask?.cancel()
        receiveLoopTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        bridgeStatus = .disconnected
        lastEventSummary = "Cloud brain disconnected"
    }

    // MARK: Simulator / QA

    /// Injects a local `ad_start` without the cloud server — for simulator testing.
    func simulateAdStart(
        suggestedRewindSeconds: Int = 120,
        confidence: Double = 0.95
    ) {
        let event = AdCloudEvent(
            event: AdCloudEventType.adStart.rawValue,
            gameID: subscribedGameID.isEmpty ? "simulator-game" : subscribedGameID,
            channel: "ESPN",
            broadcastTs: Date().timeIntervalSince1970,
            suggestedRewindSeconds: suggestedRewindSeconds,
            confidence: confidence,
            signals: ["simulated"]
        )
        Task { await handle(event) }
    }

    /// Injects a local `game_live` return signal.
    func simulateGameLive() {
        let event = AdCloudEvent(
            event: AdCloudEventType.gameLive.rawValue,
            gameID: subscribedGameID.isEmpty ? "simulator-game" : subscribedGameID,
            channel: "ESPN",
            broadcastTs: Date().timeIntervalSince1970,
            suggestedRewindSeconds: 0,
            confidence: 1.0,
            signals: ["simulated"]
        )
        Task { await handle(event) }
    }

    // MARK: - Event Handling

    private func handle(_ event: AdCloudEvent) async {
        lastProcessedAt = Date()

        if !subscribedGameID.isEmpty,
           let gameID = event.gameID,
           gameID != subscribedGameID {
            lastEventSummary = "Ignored event for \(gameID) (subscribed: \(subscribedGameID))"
            print("ℹ️ AdEventService: ignoring event for unsubscribed game \(gameID)")
            return
        }

        switch event.eventType {
        case .adStart:
            await handleAdStart(event)
        case .gameLive:
            await handleGameLive(event)
        case .none:
            lastEventSummary = "Unknown event: \(event.event)"
            print("⚠️ AdEventService: unknown event type \(event.event)")
        }
    }

    private func handleAdStart(_ event: AdCloudEvent) async {
        let confidence = event.confidence ?? 1.0
        guard confidence >= AdCloudEvent.automationConfidenceThreshold else {
            lastEventSummary = "Ad signal below confidence threshold (\(confidence))"
            print("ℹ️ AdEventService: suppressed low-confidence ad_start (\(confidence))")
            return
        }

        isAdBreakActive = true

        let suggested = event.suggestedRewindSeconds ?? 120
        let lagProfile = AdLagSyncProfile(
            streamDelayOffsetSeconds: streamDelayOffsetSeconds,
            detectionLatencySeconds: detectionLatencySeconds
        )
        let effectiveRewind = lagProfile.effectiveRewindSeconds(suggested: suggested)

        let signalList = (event.signals ?? []).joined(separator: ", ")
        lastEventSummary = "Commercial detected — rewinding \(effectiveRewind)s"
        print("🚨 AdEventService: ad_start — effective rewind \(effectiveRewind)s (signals: \(signalList))")

        guard let tvController else {
            lastEventSummary = "No TVController bound"
            return
        }

        if let sportsAPIService {
            await sportsAPIService.skipAdFromCloudDetection(fallbackRewindSeconds: effectiveRewind)
            return
        }

        tvController.statusMessage = "Commercial detected — rewinding \(effectiveRewind)s…"
        _ = tvController.triggerRewindMacro(targetSeconds: effectiveRewind)
    }

    private func handleGameLive(_ event: AdCloudEvent) async {
        isAdBreakActive = false
        lastEventSummary = "Game live — returning to live stream"
        print("🟢 AdEventService: game_live — jump to live")

        guard let tvController else {
            lastEventSummary = "No TVController bound"
            return
        }

        if let sportsAPIService {
            await sportsAPIService.resumeFromCloudGameLive()
            return
        }

        tvController.statusMessage = "Game is live — returning to live stream"
        await tvController.sendLGTVToastNotification(message: "ZapRemote: Back to live action")
        await tvController.returnToLiveEdgeWhenReady()
    }

    // MARK: - WebSocket Transport

    private func connect(to url: URL) {
        receiveLoopTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        bridgeStatus = bridgeStatus == .reconnecting ? .reconnecting : .connecting

        let socket = webSocketSession.webSocketTask(with: url)
        webSocketTask = socket
        socket.resume()
        sendDetectorConfiguration(on: socket)

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop(on: socket, url: url)
        }
    }

    /// Pushes the monitored game + sport path so the Mac detector polls the right ESPN feed.
    func syncDetectorConfiguration() {
        guard let socket = webSocketTask else { return }
        sendDetectorConfiguration(on: socket)
    }

    private func receiveLoop(on socket: URLSessionWebSocketTask, url: URL) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard let data = message.data else { continue }

                if bridgeStatus != .connected {
                    bridgeStatus = .connected
                    lastEventSummary = "Listening for cloud ad events"
                    print("✅ AdEventService: connected to \(url.absoluteString)")
                }

                if Self.isDetectorHandshake(data) {
                    lastEventSummary = "Cloud ad detector online"
                    continue
                }

                let event = try JSONDecoder().decode(AdCloudEvent.self, from: data)
                await handle(event)
            } catch {
                if Task.isCancelled { break }

                print("❌ AdEventService receive error: \(error.localizedDescription)")
                bridgeStatus = .reconnecting
                lastEventSummary = "Cloud connection lost — reconnecting…"
                scheduleReconnect()
                break
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldMaintainConnection else { return }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.minimumReconnectDelaySeconds ?? 3) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.shouldMaintainConnection else { return }
            await MainActor.run {
                self.startListening()
            }
        }
    }

    // MARK: - Defaults

    /// Local detector (`detector/` folder) — use Mac LAN IP on a physical iPhone.
    static let defaultDetectorWebSocketURL = "ws://127.0.0.1:8787"

    private static func isDetectorHandshake(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else { return false }
        return event == "detector_hello"
    }

    private func sendDetectorConfiguration(on socket: URLSessionWebSocketTask) {
        let gameID = subscribedGameID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sportPath = sportsAPIService?.monitoredSportPath
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !gameID.isEmpty, !sportPath.isEmpty else { return }

        let payload: [String: String] = [
            "event": "client_config",
            "game_id": gameID,
            "sport_path": sportPath,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }

        socket.send(.string(text)) { error in
            if let error {
                print("⚠️ AdEventService: failed to send detector config — \(error.localizedDescription)")
            } else {
                print("📡 AdEventService: sent detector config \(sportPath) game \(gameID)")
            }
        }
    }

    private static func isLoopbackWebSocketURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

// MARK: - WebSocket Message Helpers

private extension URLSessionWebSocketTask.Message {
    var data: Data? {
        switch self {
        case .string(let text): text.data(using: .utf8)
        case .data(let data): data
        @unknown default: nil
        }
    }
}
