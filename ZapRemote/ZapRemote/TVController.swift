//
//  TVController.swift
//  ZapRemote
//
//  LG webOS Smart TV automation over local Wi‑Fi WebSockets (SSAP on port 3000).
//
//  Network lifecycle:
//    1. discoverLGTVs()        — LAN discovery (stub → future SSDP/mDNS)
//    2. connectToTV(ip:)      — main WebSocket + hello/register handshake
//    3. requestPairingKey()    — TV on-screen prompt → persisted client-key
//    4. openPointerSocket()    — secondary socket for button/input commands
//    5. fetchActiveAppID()     — foreground app tracking for macro engine
//    6. triggerRewindMacro()   — app-aware LEFT-click automation (isExecutingMacro-locked)
//    7. executeGoLiveMacro()   — native seek-overlay "Jump to Live" reset
//    8. sendLGTVToastNotification() — on-TV toast via createToast SSAP URI
//

import Combine
import Foundation

// MARK: - Shared Types

enum RemoteKey: String, Sendable {
    case up = "KEY_UP"
    case down = "KEY_DOWN"
    case left = "KEY_LEFT"
    case right = "KEY_RIGHT"
    case select = "KEY_ENTER"
    case menu = "KEY_RETURN"

    /// LG pointer-input socket key name.
    var lgSSAPKeyName: String {
        switch self {
        case .up: "UP"
        case .down: "DOWN"
        case .left: "LEFT"
        case .right: "RIGHT"
        case .select: "ENTER"
        case .menu: "BACK"
        }
    }
}

/// Lightweight discovery record surfaced to SwiftUI.
struct DiscoveredLGTV: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let ipAddress: String
}

/// Connection phases for the LG webOS control plane.
enum LGConnectionPhase: Equatable, Sendable {
    case disconnected
    case discovering
    case pairing
    case openingInputSocket
    case ready
}

/// Per-app rewind granularity for the dynamic macro skip engine.
enum StreamingAppSkipProfile: Sendable {
    case youtubeTV      // 15s per LEFT
    case hulu           // 10s per LEFT
    case peacock        // 10s per LEFT
    case unsupported

    var secondsPerClick: Int? {
        switch self {
        case .youtubeTV: 15
        case .hulu, .peacock: 10
        case .unsupported: nil
        }
    }

    /// Delay between skip keys — YouTube TV drops inputs if we fire too fast.
    var clickSpacingMs: Int {
        switch self {
        case .youtubeTV: 500
        case .hulu, .peacock: 400
        case .unsupported: 400
        }
    }

    /// Maps LG `appId` strings to skip behavior.
    static func profile(for appID: String) -> StreamingAppSkipProfile {
        switch appID {
        case "youtube.leanback.ytv.v1": .youtubeTV
        case "hulu": .hulu
        case "com.peacocktv.peacock": .peacock
        default: .unsupported
        }
    }
}

enum TVControllerError: LocalizedError {
    case notConnected
    case pairingRequired
    case unsupportedApp(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "TV WebSocket is not connected."
        case .pairingRequired: "Accept the pairing prompt on your TV."
        case .unsupportedApp(let appID): "Macro skip unsupported for app: \(appID)"
        }
    }
}

// MARK: - TVController

/// Observable controller for LG webOS TVs — pairing, state tracking, and macro automation.
@MainActor
final class TVController: ObservableObject {

    // MARK: 1 — Published State

    @Published var currentAppID: String = ""
    /// Settings → streaming app; used when the TV reports an unsupported foreground app.
    @Published var preferredStreamingAppID: String = ""
    @Published var statusMessage: String = "Disconnected"
    @Published var savedClientKey: String? = nil

    @Published private(set) var connectionPhase: LGConnectionPhase = .disconnected
    @Published private(set) var discoveredLGTVs: [DiscoveredLGTV] = []
    @Published private(set) var selectedLGTV: DiscoveredLGTV?

    // MARK: Private — Network

    private static let webOSPort = 3000
    private static let clientKeyStorageKey = "com.zapremote.lg.clientKey"
    private static let lastTVIPStorageKey = TVControllerStorageKey.lastTVIP
    private static let macroClickSpacingMs = 150
    private static let maxMacroClicks = 14
    /// Hard cooldown held after a rewind macro's trailing PLAY command, before the
    /// `isExecutingMacro` lock releases. Blocks duplicate triggers for 10s so the LG TV
    /// never jams or loops network packets infinitely.
    private static let macroCooldownSeconds: TimeInterval = 10.0
    private static let foregroundPollIntervalSeconds: UInt64 = 2
    private static let discoveryScanSeconds: UInt64 = 5
    private static let pairingTimeoutSeconds: UInt64 = 45

    private let webSocketSession: URLSession
    private var mainWebSocket: URLSessionWebSocketTask?
    private var pointerWebSocket: URLSessionWebSocketTask?

    private var activeIPAddress: String?
    private var receiveLoopTask: Task<Void, Never>?
    private var pointerReceiveLoopTask: Task<Void, Never>?
    private var foregroundPollTask: Task<Void, Never>?
    private var macroSequenceTask: Task<Void, Never>?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var lanDiscovery: UniversalTVBrowser?

    private var pendingSSAPRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var ssapRequestCounter = 0
    private var registerHandshakeSent = false

    /// Exact LEFT clicks from the last rewind — mirrored for return-to-live.
    private(set) var lastRewindClickCount: Int = 0
    @Published private(set) var isMacroRunning = false

    /// THE ANTI-LOOP SAFETY LOCK. True for the entire rewind lifecycle — clicks,
    /// trailing PLAY, and the 10s cooldown — not just the click loop itself.
    /// `triggerRewindMacro` refuses to start while this is true.
    @Published private(set) var isExecutingMacro = false

    // MARK: Init

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        webSocketSession = URLSession(configuration: configuration)

        savedClientKey = UserDefaults.standard.string(forKey: Self.clientKeyStorageKey)
    }

    /// Reconnects to the last paired TV on the same Wi‑Fi.
    func reconnectToSavedTVIfPossible() async {
        guard connectionPhase == .disconnected else { return }
        guard let clientKey = savedClientKey, !clientKey.isEmpty else { return }
        guard let savedIP = UserDefaults.standard.string(forKey: Self.lastTVIPStorageKey),
              !savedIP.isEmpty else { return }

        statusMessage = "Reconnecting to saved TV…"
        await connectToTV(ipAddress: savedIP)
    }

    // MARK: 2 — Local Network Discovery

    /// Scans the LAN for LG webOS TVs via SSDP + Bonjour (`UniversalTVBrowser`).
    func discoverLGTVs() async {
        let ownsConnectionUI = connectionPhase == .disconnected
        if ownsConnectionUI {
            connectionPhase = .discovering
            statusMessage = "Searching for LG TVs on Wi‑Fi…"
        }
        discoveredLGTVs = []

        lanDiscovery?.stopDiscovery()
        let browser = UniversalTVBrowser()
        lanDiscovery = browser
        browser.startDiscovery()

        try? await Task.sleep(nanoseconds: Self.discoveryScanSeconds * 1_000_000_000)

        var results = browser.discoveredDevices
            .filter { Self.isLikelyLGWebOS($0) }
            .map {
                let ip = Self.sanitizedHost($0.address)
                return DiscoveredLGTV(
                    id: ip,
                    name: $0.name,
                    ipAddress: ip
                )
            }

        var seenIPs = Set<String>()
        results = results.filter { seenIPs.insert($0.ipAddress).inserted }

        if let savedIP = UserDefaults.standard.string(forKey: Self.lastTVIPStorageKey),
           !savedIP.isEmpty,
           !seenIPs.contains(savedIP) {
            results.insert(
                DiscoveredLGTV(id: savedIP, name: "Saved LG TV", ipAddress: savedIP),
                at: 0
            )
        }

        browser.stopDiscovery()
        lanDiscovery = nil
        discoveredLGTVs = results

        // A scan started while idle may still be running after the user connects; never
        // clobber an active pairing session or ready control socket when the timer ends.
        guard ownsConnectionUI, connectionPhase == .discovering else {
            print("✅ TVController: LAN scan found \(results.count) TV(s) (connection unchanged)")
            return
        }

        connectionPhase = .disconnected

        if results.isEmpty {
            statusMessage = "No TVs found — enter your TV's IP manually"
            print("ℹ️ TVController: LAN scan found 0 LG webOS TVs")
        } else {
            statusMessage = "Found \(results.count) TV(s) — tap to connect"
            print("✅ TVController: LAN scan found \(results.count) TV(s): \(results.map(\.ipAddress))")
        }
    }

    private static func isLikelyLGWebOS(_ device: UniversalTVDevice) -> Bool {
        if device.lgProtocolType == .webOS { return true }
        let corpus = "\(device.name) \(device.modelName ?? "")".lowercased()
        return corpus.contains("lg") || corpus.contains("webos")
    }

    // MARK: 3 — LG webOS Pairing & Handshake

    /// Opens the primary SSAP WebSocket and runs hello → register → pointer socket.
    func connectToTV(ipAddress: String) async {
        let host = Self.sanitizedHost(ipAddress)
        guard !host.isEmpty else {
            statusMessage = "Invalid IP address."
            return
        }

        await disconnect()
        registerHandshakeSent = false
        activeIPAddress = host
        selectedLGTV = discoveredLGTVs.first(where: { $0.ipAddress == host })
            ?? DiscoveredLGTV(id: host, name: "LG webOS TV", ipAddress: host)

        connectionPhase = .pairing
        statusMessage = "Connecting to \(host)…"

        guard let url = URL(string: "ws://\(host):\(Self.webOSPort)/") else {
            statusMessage = "Invalid WebSocket URL."
            connectionPhase = .disconnected
            return
        }

        let socket = webSocketSession.webSocketTask(with: url)
        mainWebSocket = socket
        socket.resume()

        startReceiveLoop(on: socket)
        sendHello()
        startPairingTimeoutWatchdog()

        // Fallback: some firmware versions skip an explicit hello response.
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard connectionPhase == .pairing, !registerHandshakeSent else { return }
            await requestPairingKey()
        }
    }

    private func startPairingTimeoutWatchdog() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pairingTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.connectionPhase == .pairing || self.connectionPhase == .openingInputSocket else {
                return
            }
            self.statusMessage = "Connection timed out — tap Reset and try again"
            await self.disconnect()
        }
    }

    /// Phase 1 of pairing — sends the LG registration manifest to trigger the on-TV prompt.
    ///
    /// The TV responds with `type: "registered"` and a `client-key` payload we persist
    /// in `savedClientKey` for passwordless reconnects on future launches.
    func requestPairingKey() async {
        guard mainWebSocket != nil else {
            statusMessage = "Not connected — call connectToTV first."
            return
        }

        registerHandshakeSent = true
        statusMessage = "Approve ZapRemote on your LG TV…"

        var payload = Self.registrationPayload
        if let savedClientKey, !savedClientKey.isEmpty {
            payload["client-key"] = savedClientKey
        }

        sendSSAP(envelope: [
            "type": "register",
            "id": "register_0",
            "payload": payload
        ], on: mainWebSocket)
    }

    /// Phase 2 — opens the pointer-input socket after `client-key` is accepted.
    private func openPointerInputSocket() async {
        guard let host = activeIPAddress else { return }

        connectionPhase = .openingInputSocket
        statusMessage = "Opening input channel…"

        do {
            let response = try await ssapRequest(
                uri: "com.webos.service.networkinput/getPointerInputSocket",
                on: mainWebSocket
            )

            guard let socketPath = response["socketPath"] as? String,
                  let inputURL = Self.pointerSocketURL(socketPath, host: host) else {
                statusMessage = "LG input socket unavailable."
                connectionPhase = .disconnected
                return
            }

            let inputSocket = webSocketSession.webSocketTask(with: inputURL)
            pointerWebSocket = inputSocket
            inputSocket.resume()
            startPointerReceiveLoop(on: inputSocket)

            connectionPhase = .ready
            statusMessage = "Connected to \(host)"
            UserDefaults.standard.set(host, forKey: Self.lastTVIPStorageKey)
            pairingTimeoutTask?.cancel()
            startForegroundAppPolling()
            await fetchActiveAppID()

            await sendLGTVToastNotification(
                message: "ZapRemote connected — automation is ready."
            )
        } catch {
            statusMessage = "Input socket failed: \(error.localizedDescription)"
            connectionPhase = .disconnected
        }
    }

    // MARK: 4 — Automatic App Detection

    /// Polls LG foreground app state while connected.
    ///
    /// SSAP URI: `com.webos.applicationManager/getForegroundAppInfo`
    /// Returns `appId` such as `youtube.leanback.ytv.v1`, `hulu`, or `com.peacocktv.peacock`.
    func fetchActiveAppID() async {
        guard connectionPhase == .ready, mainWebSocket != nil else { return }

        do {
            let payload = try await ssapRequest(
                uri: "com.webos.applicationManager/getForegroundAppInfo",
                on: mainWebSocket
            )
            if let appID = payload["appId"] as? String {
                if StreamingAppSkipProfile.profile(for: appID) != .unsupported {
                    currentAppID = appID
                } else if !preferredStreamingAppID.isEmpty {
                    currentAppID = preferredStreamingAppID
                } else {
                    currentAppID = appID
                }
            }
        } catch {
            print("fetchActiveAppID failed: \(error.localizedDescription)")
        }
    }

    private func startForegroundAppPolling() {
        foregroundPollTask?.cancel()
        foregroundPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchActiveAppID()
                try? await Task.sleep(nanoseconds: Self.foregroundPollIntervalSeconds * 1_000_000_000)
            }
        }
    }

    // MARK: 5 — Dynamic Macro Skip Engine

    /// Sends a calculated sequence of LEFT presses to rewind by `targetSeconds`.
    ///
    /// Skip granularity is determined by the active streaming app's `appId`.
    /// Clicks are spaced 120ms apart via `DispatchQueue.main.asyncAfter` to avoid
    /// flooding the TV's input buffer.
    @discardableResult
    func triggerRewindMacro(targetSeconds: Int) -> Bool {
        guard !isExecutingMacro else {
            statusMessage = "Rewind already in progress — wait ~10 sec."
            print("🛑 TVController: triggerRewindMacro ignored — isExecutingMacro is already true")
            return false
        }

        guard connectionPhase == .ready, pointerWebSocket != nil else {
            statusMessage = "TV not ready — reconnect from Home."
            return false
        }

        guard resolvedSecondsPerClick() != nil else {
            let appLabel = currentAppID.isEmpty ? "unknown app" : currentAppID
            statusMessage = "Open YouTube TV, Hulu, or Peacock on your TV (now: \(appLabel))."
            return false
        }

        isExecutingMacro = true
        runPointerMacro(direction: "LEFT", targetSeconds: targetSeconds, actionLabel: "Rewinding")
        return true
    }

    private func resolvedSecondsPerClick() -> Int? {
        if let seconds = StreamingAppSkipProfile.profile(for: currentAppID).secondsPerClick {
            return seconds
        }
        if !preferredStreamingAppID.isEmpty,
           let seconds = StreamingAppSkipProfile.profile(for: preferredStreamingAppID).secondsPerClick {
            return seconds
        }
        return nil
    }

    /// YouTube TV = 15s, Hulu/Peacock = 10s per LEFT/RIGHT skip.
    func secondsPerSkipClick() -> Int {
        resolvedSecondsPerClick() ?? 15
    }

    /// Rounds rewind depth up to whole skip clicks (e.g. 122s → 8×15s = 120s on YouTube TV).
    func snappedSkipSeconds(targetSeconds: Int) -> Int {
        let secondsPerClick = secondsPerSkipClick()
        let clicks = min(
            Self.maxMacroClicks,
            max(1, (targetSeconds + secondsPerClick - 1) / secondsPerClick)
        )
        return clicks * secondsPerClick
    }

    private func resolvedClickSpacingMs() -> Int {
        if let appID = currentAppID.isEmpty ? nil : currentAppID,
           StreamingAppSkipProfile.profile(for: appID) != .unsupported {
            return StreamingAppSkipProfile.profile(for: appID).clickSpacingMs
        }
        if !preferredStreamingAppID.isEmpty {
            return StreamingAppSkipProfile.profile(for: preferredStreamingAppID).clickSpacingMs
        }
        return 450
    }

    /// Returns to the live edge using the exact click count from the last rewind.
    /// Only call once game action is back — jumping to live during a break lands on ads.
    func returnToLiveEdge() {
        guard connectionPhase == .ready, pointerWebSocket != nil else {
            statusMessage = "Connect to the TV before returning to live."
            return
        }

        if isMacroRunning {
            cancelActiveMacro()
            statusMessage = "Stopped skip macro."
            return
        }

        let clicks = lastRewindClickCount
        guard clicks > 0 else {
            statusMessage = "No rewind to undo — wait for a commercial rewind first."
            return
        }

        statusMessage = "Returning to live game (\(clicks) skips forward)…"

        runPointerMacro(
            direction: "RIGHT",
            totalClicks: clicks,
            actionLabel: "Returning to live",
            clearsRewindLedger: true
        )
    }

    /// Waits for an in-flight rewind macro, then returns to live with the stored click count.
    func returnToLiveEdgeWhenReady() async {
        while isMacroRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard lastRewindClickCount > 0 else { return }
        returnToLiveEdge()
    }

    func cancelActiveMacro() {
        macroSequenceTask?.cancel()
        macroSequenceTask = nil
        isMacroRunning = false
        isExecutingMacro = false
    }

    // MARK: 5b — THE "JUMP TO LIVE" RESET MACRO

    /// Returns to the live edge using the exact RIGHT-click count from the last rewind.
    func executeGoLiveMacro() async {
        guard connectionPhase == .ready, pointerWebSocket != nil else {
            statusMessage = "Connect to the TV before jumping to live."
            return
        }

        cancelActiveMacro()

        let clicks = lastRewindClickCount
        guard clicks > 0 else {
            statusMessage = "Nothing to undo — tap Ad on my TV first, then Go Live."
            return
        }

        statusMessage = "Returning to live (\(clicks)× forward)…"
        runPointerMacro(
            direction: "RIGHT",
            totalClicks: clicks,
            actionLabel: "Returning to live",
            clearsRewindLedger: true
        )
    }

    private func runPointerMacro(direction: String, targetSeconds: Int, actionLabel: String) {
        guard let secondsPerClick = resolvedSecondsPerClick() else {
            statusMessage = "Macro disabled — open a supported streaming app on your TV."
            releaseProcessingMacroLock(direction: direction)
            return
        }

        let totalClicks = min(
            Self.maxMacroClicks,
            max(1, (targetSeconds + secondsPerClick - 1) / secondsPerClick)
        )
        guard totalClicks > 0 else {
            statusMessage = "Target too small for \(secondsPerClick)s skip increments."
            releaseProcessingMacroLock(direction: direction)
            return
        }

        runPointerMacro(
            direction: direction,
            totalClicks: totalClicks,
            actionLabel: actionLabel,
            clearsRewindLedger: false
        )
    }

    private func runPointerMacro(
        direction: String,
        totalClicks: Int,
        actionLabel: String,
        clearsRewindLedger: Bool
    ) {
        guard connectionPhase == .ready, pointerWebSocket != nil else {
            statusMessage = "Connect to the TV before running a macro."
            releaseProcessingMacroLock(direction: direction)
            return
        }

        guard totalClicks > 0 else {
            statusMessage = "Macro target must be greater than zero."
            releaseProcessingMacroLock(direction: direction)
            return
        }

        macroSequenceTask?.cancel()
        isMacroRunning = true
        statusMessage = "\(actionLabel) (\(totalClicks)× \(direction))…"

        macroSequenceTask = Task { [weak self] in
            await self?.executeMacroClickSequence(
                direction: direction,
                totalClicks: totalClicks,
                actionLabel: actionLabel,
                clearsRewindLedger: clearsRewindLedger
            )
        }
    }

    private func executeMacroClickSequence(
        direction: String,
        totalClicks: Int,
        actionLabel: String,
        clearsRewindLedger: Bool
    ) async {
        defer {
            isMacroRunning = false
        }

        guard await refreshPointerInputSocket() else {
            statusMessage = "TV input channel lost — tap Reset and reconnect."
            releaseProcessingMacroLock(direction: direction)
            return
        }

        // Center click focuses the video surface without sending DOWN (which browses the grid).
        if direction == "LEFT" {
            sendPointerClick()
            try? await Task.sleep(for: .milliseconds(450))
        }

        let spacingMs = resolvedClickSpacingMs()

        for index in 0..<totalClicks {
            guard !Task.isCancelled, connectionPhase == .ready else {
                releaseProcessingMacroLock(direction: direction)
                return
            }

            print("📺 TVController: macro \(index + 1)/\(totalClicks) → \(direction)")
            sendPointerButton(direction)

            if direction == "LEFT" {
                lastRewindClickCount = index + 1
            }

            if index < totalClicks - 1 {
                try? await Task.sleep(for: .milliseconds(spacingMs))
            }
        }

        if clearsRewindLedger {
            lastRewindClickCount = 0
        }

        // Confirm the scrub position and resume playback (YouTube TV needs OK after skips).
        try? await Task.sleep(for: .milliseconds(400))
        sendPointerButton("ENTER")

        statusMessage = "\(actionLabel) complete — \(totalClicks)× \(direction), confirmed."

        if direction == "LEFT" {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.macroCooldownSeconds) { [weak self] in
                self?.isExecutingMacro = false
            }
        }
    }

    /// Re-opens the pointer-input socket when needed so button presses reach the TV app.
    private func refreshPointerInputSocket() async -> Bool {
        if pointerWebSocket != nil {
            return true
        }

        guard connectionPhase == .ready,
              let host = activeIPAddress,
              let mainWebSocket else { return false }

        do {
            let response = try await ssapRequest(
                uri: "com.webos.service.networkinput/getPointerInputSocket",
                on: mainWebSocket
            )
            guard let socketPath = response["socketPath"] as? String,
                  let inputURL = Self.pointerSocketURL(socketPath, host: host) else {
                return false
            }

            pointerReceiveLoopTask?.cancel()
            pointerWebSocket?.cancel(with: .goingAway, reason: nil)

            let inputSocket = webSocketSession.webSocketTask(with: inputURL)
            pointerWebSocket = inputSocket
            inputSocket.resume()
            startPointerReceiveLoop(on: inputSocket)

            try? await Task.sleep(for: .milliseconds(120))
            return true
        } catch {
            print("❌ TVController: refreshPointerInputSocket failed — \(error.localizedDescription)")
            return false
        }
    }

    private func startPointerReceiveLoop(on socket: URLSessionWebSocketTask) {
        pointerReceiveLoopTask?.cancel()
        pointerReceiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    _ = try await socket.receive()
                } catch {
                    if !Task.isCancelled {
                        print("ℹ️ TVController: pointer socket receive ended — \(error.localizedDescription)")
                    }
                    break
                }
            }
            await MainActor.run {
                if self?.pointerWebSocket === socket {
                    self?.pointerWebSocket = nil
                }
            }
        }
    }

    /// Releases the rewind safety lock immediately. Only meaningful for the LEFT
    /// (rewind) direction — RIGHT/live-return macros don't touch `isExecutingMacro`.
    private func releaseProcessingMacroLock(direction: String) {
        guard direction == "LEFT" else { return }
        isExecutingMacro = false
    }

    // MARK: 6 — On-Screen Toast Banner (LG webOS SSAP)

    /// Pushes an on-screen toast banner to the paired LG TV.
    ///
    /// LG webOS notification protocol (main WebSocket port 3000):
    /// 1. App must be paired (`connectionPhase == .ready`) on the primary SSAP socket.
    /// 2. Send a JSON **text frame** (not the pointer-input socket) with this envelope:
    /// ```json
    /// {
    ///   "type": "request",
    ///   "id": "ssap_req_<n>",
    ///   "uri": "ssap://system.notifications/createToast",
    ///   "payload": {
    ///     "message": "<user-facing string>",
    ///     "iconData": ""
    ///   }
    /// }
    /// ```
    /// 3. `iconData` accepts a base64-encoded image string when we add custom toast icons.
    /// 4. TV renders the toast overlay; response arrives on the same socket with matching `id`.
    func sendLGTVToastNotification(message: String) async {
        guard isConnected, mainWebSocket != nil else {
            statusMessage = "Notification failed: TV disconnected"
            print("❌ sendLGTVToastNotification failed — TV not connected (phase: \(connectionPhase))")
            return
        }

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            statusMessage = "Notification failed: empty message"
            print("❌ sendLGTVToastNotification failed — message was empty")
            return
        }

        // LG `createToast` payload — `iconData` reserved for future base64 artwork injection.
        let toastPayload: [String: Any] = [
            "message": trimmedMessage,
            "iconData": ""
        ]

        do {
            _ = try await ssapRequest(
                uri: "system.notifications/createToast",
                payload: toastPayload,
                on: mainWebSocket
            )
            print("LG TV Notification Successfully Pushed: \(trimmedMessage)")
            statusMessage = "Connected — toast sent to TV"
        } catch {
            // Some firmware builds use the older notification service path.
            do {
                _ = try await ssapRequest(
                    uri: "com.webos.notification/createToast",
                    payload: toastPayload,
                    on: mainWebSocket
                )
                print("LG TV Notification Successfully Pushed (fallback URI): \(trimmedMessage)")
                statusMessage = "Connected — toast sent to TV"
            } catch {
                let errorText = error.localizedDescription
                statusMessage = "Connected, but TV toast failed: \(errorText)"
                print("❌ sendLGTVToastNotification network error: \(errorText)")
            }
        }
    }

    /// Sends a short test banner to the TV so you can confirm pairing + notifications work.
    func sendTestTVNotification() async {
        await sendLGTVToastNotification(message: "ZapRemote test — if you see this, TV alerts work.")
    }

    /// Legacy alias — forwards to `sendLGTVToastNotification(message:)`.
    func sendTVToastNotification(message: String) async {
        await sendLGTVToastNotification(message: message)
    }

    // MARK: Pointer Input Commands

    /// Simulates the magic-remote OK click — focuses the video without arrow keys.
    private func sendPointerClick() {
        guard let pointerWebSocket else { return }
        let frame = "type:click\n\n\n"
        pointerWebSocket.send(.string(frame)) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.statusMessage = error.localizedDescription
                }
            }
        }
    }

    /// Sends a single button press down the pointer-input WebSocket.
    func sendPointerButton(_ keyName: String) {
        guard let pointerWebSocket else {
            statusMessage = "Pointer socket not ready."
            return
        }

        // LG requires plain text — NOT JSON. Two trailing newlines are mandatory.
        let frame = "type:button\nname:\(keyName)\n\n"
        pointerWebSocket.send(.string(frame)) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.statusMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Teardown

    func disconnect() async {
        macroSequenceTask?.cancel()
        foregroundPollTask?.cancel()
        receiveLoopTask?.cancel()
        pointerReceiveLoopTask?.cancel()
        pairingTimeoutTask?.cancel()

        lanDiscovery?.stopDiscovery()
        lanDiscovery = nil

        for (_, continuation) in pendingSSAPRequests {
            continuation.resume(throwing: CancellationError())
        }
        pendingSSAPRequests.removeAll()

        pointerWebSocket?.cancel(with: .goingAway, reason: nil)
        mainWebSocket?.cancel(with: .goingAway, reason: nil)
        pointerWebSocket = nil
        mainWebSocket = nil

        registerHandshakeSent = false
        activeIPAddress = nil
        currentAppID = ""
        connectionPhase = .disconnected
        statusMessage = "Disconnected"
    }

    /// Clears saved pairing credentials and tears down sockets — use when connection is stuck.
    func resetTVConnection() async {
        await disconnect()

        savedClientKey = nil
        UserDefaults.standard.removeObject(forKey: Self.clientKeyStorageKey)

        selectedLGTV = nil
        discoveredLGTVs = []
        statusMessage = "TV connection reset — choose your TV again"
        print("🔄 TVController: pairing reset — client-key cleared")
    }

    // MARK: - SSAP Transport (Private)

    private func sendHello() {
        sendSSAP(envelope: [
            "type": "hello",
            "id": "hello_0",
            "payload": [String: Any]()
        ], on: mainWebSocket)
    }

    private func sendSSAP(envelope: [String: Any], on socket: URLSessionWebSocketTask?) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else { return }

        socket.send(.string(json)) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.statusMessage = error.localizedDescription
                    self?.connectionPhase = .disconnected
                }
            }
        }
    }

    /// Sends a request frame and suspends until the matching `id` response arrives.
    private func ssapRequest(
        uri: String,
        payload: [String: Any] = [:],
        on socket: URLSessionWebSocketTask?
    ) async throws -> [String: Any] {
        guard let socket else { throw TVControllerError.notConnected }

        ssapRequestCounter += 1
        let requestID = "ssap_req_\(ssapRequestCounter)"

        return try await withCheckedThrowingContinuation { continuation in
            pendingSSAPRequests[requestID] = continuation

            let envelope: [String: Any] = [
                "type": "request",
                "id": requestID,
                "uri": "ssap://\(uri)",
                "payload": payload
            ]
            sendSSAP(envelope: envelope, on: socket)
        }
    }

    /// Continuous receive loop — drives pairing state machine and SSAP request completions.
    private func startReceiveLoop(on socket: URLSessionWebSocketTask) {
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop(on: socket)
        }
    }

    private func receiveLoop(on socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard let data = message.data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                handleIncomingSSAP(json)
            } catch {
                if !Task.isCancelled {
                    statusMessage = "Socket closed: \(error.localizedDescription)"
                    connectionPhase = .disconnected
                }
                break
            }
        }
    }

    private func handleIncomingSSAP(_ json: [String: Any]) {
        // Complete pending request/response pairs.
        if let id = json["id"] as? String,
           let continuation = pendingSSAPRequests.removeValue(forKey: id) {
            if let type = json["type"] as? String, type == "error" {
                let message = (json["error"] as? String) ?? "SSAP error"
                continuation.resume(throwing: NSError(
                    domain: "ZapRemote.SSAP",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            } else if let payload = json["payload"] as? [String: Any] {
                continuation.resume(returning: payload)
            }
            return
        }

        if let type = json["type"] as? String, type == "hello" {
            Task { await requestPairingKey() }
            return
        }

        if let type = json["type"] as? String, type == "registered",
           let payload = json["payload"] as? [String: Any],
           let clientKey = payload["client-key"] as? String {
            savedClientKey = clientKey
            UserDefaults.standard.set(clientKey, forKey: Self.clientKeyStorageKey)
            Task { await openPointerInputSocket() }
            return
        }

        if let payload = json["payload"] as? [String: Any],
           payload["pairingType"] as? String == "PROMPT" {
            statusMessage = "Approve ZapRemote on your LG TV…"
            return
        }

        if let type = json["type"] as? String, type == "error" {
            let message = (json["error"] as? String) ?? "LG pairing failed."
            print("❌ TVController SSAP error: \(message)")

            if savedClientKey != nil {
                savedClientKey = nil
                UserDefaults.standard.removeObject(forKey: Self.clientKeyStorageKey)
                registerHandshakeSent = false
                statusMessage = "Old pairing expired — approve the new prompt on your TV…"
                Task { await requestPairingKey() }
                return
            }

            statusMessage = message
            connectionPhase = .disconnected
        }
    }

    // MARK: - Helpers

    private static func sanitizedHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://", "ws://", "wss://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        return host
    }

    private static func pointerSocketURL(_ socketPath: String, host: String) -> URL? {
        if socketPath.hasPrefix("ws://") || socketPath.hasPrefix("wss://") {
            return URL(string: socketPath)
        }
        if socketPath.hasPrefix("/") {
            return URL(string: "ws://\(host):\(webOSPort)\(socketPath)")
        }
        return URL(string: socketPath)
    }

    private static let registrationSignature =
        "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pb" +
        "ctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR" +
        "+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRy" +
        "aMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4" +
        "RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n" +
        "50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM" +
        "2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQoj" +
        "oa7NQnAtw=="

    private static let registrationPayload: [String: Any] = [
        "forcePairing": false,
        "pairingType": "PROMPT",
        "manifest": [
            "appVersion": "1.1",
            "manifestVersion": 1,
            "permissions": [
                "LAUNCH", "LAUNCH_WEBAPP", "CONTROL_AUDIO", "CONTROL_DISPLAY",
                "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_TV", "CONTROL_POWER",
                "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_INPUT_TEXT",
                "READ_APP_STATUS", "READ_RUNNING_APPS", "READ_CURRENT_CHANNEL",
                "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_SETTINGS",
                "WRITE_NOTIFICATION_TOAST"
            ],
            "signatures": [["signature": registrationSignature, "signatureVersion": 1]],
            "signed": [
                "appId": "com.lge.test",
                "created": "20140509",
                "localizedAppNames": ["": "ZapRemote"],
                "localizedVendorNames": ["": "LG Electronics"],
                "permissions": [
                    "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_INPUT_TEXT",
                    "READ_RUNNING_APPS", "READ_LGE_TV_INPUT_EVENTS",
                    "WRITE_NOTIFICATION_ALERT"
                ],
                "serial": "2f930e2d2cfe083771f68e4fe7bb07",
                "vendorId": "com.lge"
            ]
        ]
    ]
}

// MARK: - URLSessionWebSocketTask.Message helpers

private extension URLSessionWebSocketTask.Message {
    var data: Data? {
        switch self {
        case .string(let text): text.data(using: .utf8)
        case .data(let data): data
        @unknown default: nil
        }
    }
}

// MARK: - ContentView Compatibility

/// Bridges the new webOS foundation to the existing SwiftUI remote UI.
extension TVController {

    var isConnected: Bool { connectionPhase == .ready }
    var isConnecting: Bool {
        connectionPhase == .pairing || connectionPhase == .openingInputSocket
    }
    var isPresenceListening: Bool { connectionPhase == .discovering }

    /// Plain-language connection state for the Home screen.
    var connectionStatusHeadline: String {
        switch connectionPhase {
        case .disconnected: "Not connected to TV"
        case .discovering: "Searching for TVs…"
        case .pairing: "Waiting for TV approval"
        case .openingInputSocket: "Finishing connection…"
        case .ready: "Connected to TV"
        }
    }

    var connectionStatusDetail: String {
        switch connectionPhase {
        case .disconnected:
            return statusMessage
        case .discovering:
            return "Scanning your Wi‑Fi network"
        case .pairing:
            return "Check your TV screen for a ZapRemote pairing popup — then tap Yes."
        case .openingInputSocket:
            return "Setting up the remote control channel…"
        case .ready:
            let host = selectedLGTV?.ipAddress ?? "your TV"
            return "Remote ready at \(host). Controls and automation are live."
        }
    }

    var connectedTVIPAddress: String? {
        guard connectionPhase == .ready else { return selectedLGTV?.ipAddress }
        return selectedLGTV?.ipAddress
    }

    var lastErrorMessage: String? {
        guard connectionPhase == .disconnected || connectionPhase == .pairing else { return nil }
        if statusMessage.contains("failed")
            || statusMessage.contains("disabled")
            || statusMessage.contains("invalid")
            || statusMessage.contains("unavailable") {
            return statusMessage
        }
        return nil
    }
    var activeDeviceName: String? { selectedLGTV?.name }

    /// Picker-compatible discovery list for SwiftUI.
    var discoveredTVs: [DiscoveredTV] {
        discoveredLGTVs.map {
            DiscoveredTV(
                id: $0.id,
                name: $0.name,
                address: $0.ipAddress,
                modelName: nil,
                protocols: [.ssdp],
                lgProtocolType: .webOS
            )
        }
    }

    /// Currently selected device in the legacy picker shape.
    var selectedTV: DiscoveredTV? {
        guard let selectedLGTV else { return nil }
        return DiscoveredTV(
            id: selectedLGTV.id,
            name: selectedLGTV.name,
            address: selectedLGTV.ipAddress,
            modelName: nil,
            protocols: [.ssdp],
            lgProtocolType: .webOS
        )
    }

    func bootstrapConnection() {
        Task { await discoverLGTVs() }
    }

    func startPresenceListening() {
        Task { await discoverLGTVs() }
    }

    func selectTV(_ device: DiscoveredTV) {
        let match = DiscoveredLGTV(
            id: device.id,
            name: device.listRowTitle,
            ipAddress: device.ipAddress
        )
        selectedLGTV = match
        Task { await connectToTV(ipAddress: match.ipAddress) }
    }

    func connectToTV(manualIPAddress: String) async {
        let host = Self.sanitizedHost(manualIPAddress)
        guard !host.isEmpty else { return }

        let device = DiscoveredLGTV(id: host, name: "LG webOS TV", ipAddress: host)
        if !discoveredLGTVs.contains(where: { $0.ipAddress == host }) {
            discoveredLGTVs.append(device)
        }
        selectedLGTV = device
        await connectToTV(ipAddress: host)
    }

    @discardableResult
    func sendRemoteKey(_ key: RemoteKey) -> Bool {
        guard isConnected else {
            statusMessage = "Not connected."
            return false
        }
        sendPointerButton(key.lgSSAPKeyName)
        return true
    }
}

// MARK: - Legacy UI Types (ContentView picker)

enum TVProtocolType: String, Sendable, Hashable {
    case netcast
    case webOS
}

struct DiscoveredTV: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let address: String
    var modelName: String?
    var protocols: Set<TVDiscoveryProtocol>
    var lgProtocolType: TVProtocolType?

    var ipAddress: String { sanitizedAddress }
    var sanitizedAddress: String { Self.stripInterfaceScope(from: address) }

    static func stripInterfaceScope(from host: String) -> String {
        var cleaned = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let scope = cleaned.firstIndex(of: "%") {
            cleaned = String(cleaned[..<scope])
        }
        return cleaned
    }
}

extension DiscoveredTV {
    var listRowTitle: String { name.isEmpty ? "LG webOS TV" : name }
    var listRowSubtitle: String { ipAddress }
    var controlBackend: TVControlBackend { .lgWebOS }
    var usesUniversalControl: Bool { false }
    var isLGDevice: Bool { true }
}

enum TVControlBackend: Sendable {
    case lgWebOS
    case lgNetCast
    case universalHTTP
    case samsung
}
