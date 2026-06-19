//
//  TVController.swift
//  ZapRemote
//
//  Samsung Smart TV integration — Apple Remote-style instant pairing.
//
//  Discovery is delegated to UniversalTVBrowser (NWBrowser + SSDP).
//  Samsung pairing and commands travel over WebSocket (`ws://`) — never HTTP `dataTask`.
//

import Foundation
import Observation

// MARK: - Types

enum ZapTarget: String, CaseIterable, Sendable {
    case primary = "PRIMARY"
    case secondary = "SECONDARY"

    var displayName: String {
        switch self {
        case .primary: "Primary Game (HDMI 1)"
        case .secondary: "Secondary Game (HDMI 2)"
        }
    }

    var remoteKey: String {
        switch self {
        case .primary: "KEY_HDMI1"
        case .secondary: "KEY_HDMI2"
        }
    }
}

/// Samsung / universal remote directional keys.
enum RemoteKey: String, Sendable {
    case up = "KEY_UP"
    case down = "KEY_DOWN"
    case left = "KEY_LEFT"
    case right = "KEY_RIGHT"
    case select = "KEY_ENTER"
    case menu = "KEY_RETURN"

    init?(samsungPayloadKey: String) {
        switch samsungPayloadKey {
        case Self.up.rawValue: self = .up
        case Self.down.rawValue: self = .down
        case Self.left.rawValue: self = .left
        case Self.right.rawValue: self = .right
        case Self.select.rawValue: self = .select
        case Self.menu.rawValue: self = .menu
        default: return nil
        }
    }

    /// LG ROAP key codes for NetCast `HandleKeyInput`.
    var lgROAPKeyCode: Int? {
        switch self {
        case .up: 12
        case .down: 13
        case .left: 14
        case .right: 15
        case .select: 20
        case .menu: nil
        }
    }

    /// LG webOS SSAP key names for pointer-input socket.
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

/// LG television control stack — NetCast ROAP (HTTP :8080) vs modern webOS (WebSocket :3000).
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
    /// Discovery hint for LG sets — drives ROAP vs webOS routing.
    var lgProtocolType: TVProtocolType?
}

// MARK: - Nearby TVs List Formatting (native Remote sheet style)

extension DiscoveredTV {
    /// Primary row title — brand-specific labels override ugly model / IP fallback strings.
    var listRowTitle: String {
        switch inferredBrand {
        case .lg:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || Self.looksLikeOpaqueModel(trimmed) {
                return "LG webOS TV"
            }
            let lower = trimmed.lowercased()
            if lower.contains("lg") || lower.contains("webos") {
                return trimmed
            }
            return "\(trimmed) LG TV"
        case .samsung:
            return "Samsung Smart TV"
        case .roku:
            return "Roku TV"
        case nil:
            return name
        }
    }

    /// Subtitle beneath the title: `"Google Cast • 192.168.86.167"`.
    var listRowSubtitle: String {
        let ip = sanitizedAddress
        guard let protocolLabel = primaryProtocolLabel else { return ip }
        return "\(protocolLabel) • \(ip)"
    }

    var sanitizedAddress: String {
        Self.stripInterfaceScope(from: address)
    }

    /// IP address used for LAN control requests.
    var ipAddress: String { sanitizedAddress }

    /// Resolved LG control protocol for the active TV row.
    var protocolType: TVProtocolType {
        if let lgProtocolType { return lgProtocolType }
        let corpus = [name, modelName ?? "", listRowTitle]
            .joined(separator: " ")
            .lowercased()
        if corpus.contains("netcast") { return .netcast }
        if corpus.contains("webos") { return .webOS }
        // Modern LG sets discovered without an explicit hint default to webOS.
        if isLGDevice { return .webOS }
        return .webOS
    }

    static func stripInterfaceScope(from host: String) -> String {
        var cleaned = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let scope = cleaned.firstIndex(of: "%") {
            cleaned = String(cleaned[..<scope])
        }
        return cleaned
    }

    private var primaryProtocolLabel: String? {
        let priority: [TVDiscoveryProtocol] = [
            .googleCast, .airPlay, .mediaRemoteTV, .dlna, .ssdp
        ]
        for protocolKind in priority where protocols.contains(protocolKind) {
            return protocolKind.rawValue
        }
        return nil
    }

    private var inferredBrand: InferredTVBrand? {
        let corpus = [name, modelName ?? ""]
            .joined(separator: " ")
            .lowercased()

        if corpus.contains("roku") {
            return .roku
        }
        if corpus.contains("samsung") || corpus.contains("tizen") {
            return .samsung
        }
        if corpus.contains("lg") || corpus.contains("webos") || corpus.contains("lge") {
            return .lg
        }
        return nil
    }

    /// Samsung / Tizen TVs use the WebSocket remote-control API.
    var usesSamsungWebSocket: Bool {
        inferredBrand == .samsung
    }

    /// LG NetCast TVs use ROAP HTTP on port 8080.
    var usesLGNetCastControl: Bool {
        inferredBrand == .lg && protocolType == .netcast
    }

    /// LG webOS TVs use SSAP WebSockets on port 3000.
    var usesLGWebOSControl: Bool {
        inferredBrand == .lg && protocolType == .webOS
    }

    /// Non-Samsung / non-LG TVs that fall back to the universal HTTP keypress endpoint.
    var usesUniversalControl: Bool {
        controlBackend == .universalHTTP
    }

    var controlBackend: TVControlBackend {
        if usesSamsungWebSocket { return .samsung }
        if usesLGNetCastControl { return .lgNetCast }
        if usesLGWebOSControl { return .lgWebOS }
        return .universalHTTP
    }

    /// True for LG TVs, including cache-restored records with empty protocols.
    var isLGDevice: Bool {
        if controlBackend == .lgNetCast || controlBackend == .lgWebOS { return true }
        let corpus = [name, listRowTitle].joined(separator: " ").lowercased()
        return corpus.contains("lg") || corpus.contains("webos") || corpus.contains("lge")
    }

    private static func looksLikeOpaqueModel(_ value: String) -> Bool {
        value.range(of: #"^[0-9A-Fa-f-]{20,}$"#, options: .regularExpression) != nil
    }
}

private enum InferredTVBrand {
    case lg
    case samsung
    case roku
}

enum TVControlBackend: Sendable {
    case samsung
    case lgNetCast
    case lgWebOS
    case universalHTTP
}

enum TVControllerError: LocalizedError {
    case connectionDropped
    case invalidTarget(String)
    case notConnected
    case encodingFailed
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionDropped:
            "TV connection dropped — the TV is no longer reachable."
        case .invalidTarget(let target):
            "Invalid zap target '\(target)'. Expected PRIMARY or SECONDARY."
        case .notConnected:
            "No TV selected. Choose a device to connect."
        case .encodingFailed:
            "Failed to encode the Samsung remote-control payload."
        case .sendFailed(let reason):
            "Failed to send command: \(reason)"
        }
    }
}

// MARK: - TVController

@MainActor
@Observable
final class TVController {

    // MARK: Published State

    private(set) var activeDeviceName: String?
    var tvIPAddress: String = ""

    /// Last-known TV IP — persisted for instant reconnect on next launch.
    var cachedTVIP: String = "" {
        didSet { persistCachedTVIP() }
    }

    var hasCachedDevice: Bool { !cachedTVIP.isEmpty }

    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false

    /// TVs discovered across AirPlay, Cast, DLNA, Media Remote, and SSDP.
    private(set) var discoveredTVs: [DiscoveredTV] = []

    /// User's actively chosen control target for the MVP workflow.
    var selectedTV: DiscoveredTV?

    /// Whether universal LAN discovery is active.
    private(set) var isPresenceListening: Bool = false

    var savedToken: String = "" {
        didSet { persistToken() }
    }

    var lgClientKey: String = "" {
        didSet { persistLGClientKey() }
    }

    private(set) var lastErrorMessage: String?

    /// Shared multi-protocol browser — also usable directly from SwiftUI.
    let universalBrowser = UniversalTVBrowser()

    // MARK: Private

    private static let appName = "ZAPRemote"
    /// Samsung remote-control WebSocket (primary port 8001, fallback 8002 on newer sets).
    private static let samsungWebSocketPort = 8001
    private static let samsungWebSocketFallbackPort = 8002
    /// LG NetCast ROAP HTTP command endpoint.
    private static let lgROAPPort = 8080
    /// LG webOS SSAP WebSocket (pairing / fallback).
    private static let lgWebSocketPort = 3000
    /// Temporary universal keypress endpoint (Roku-style ECP) for unknown TVs.
    private static let universalHTTPPort = 8060
    private static let tokenStorageKey = "com.zapremote.samsung.token"
    private static let lgClientKeyStorageKey = "com.zapremote.lg.clientKey"
    private static let lgManifestVersionKey = "com.zapremote.lg.manifestVersion"
    private static let lgManifestVersion = 2
    private static let lgProtocolTypeKeyPrefix = "com.zapremote.lg.protocol."
    private static let cachedTVIPKey = "com.zapremote.samsung.cachedTVIP"
    private static let cachedDeviceNameKey = "com.zapremote.samsung.cachedDeviceName"
    private static let connectionTimeout: TimeInterval = 15

    private let session: URLSession
    /// Long-lived session dedicated to LG webOS WebSocket control (port 3000).
    private let lgWebSocketSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    /// Secondary LG pointer-input socket for `type:button` commands.
    private var lgInputWebSocketTask: URLSessionWebSocketTask?
    private var lgCommandCounter = 0
    private var lgPendingRequests: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var lgForceRePairAttempted = false
    private var lgActivePersistCache = true
    private var lgRegisterSent = false
    private var pairingTimeoutTask: Task<Void, Never>?
    private var activePairingAddress: String?
    private var activePairingPort: Int?
    private var didAttemptPortFallback = false
    private var activeWebSocketBackend: TVControlBackend = .samsung

    // MARK: Init

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.connectionTimeout
        configuration.timeoutIntervalForResource = Self.connectionTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let lgWSConfiguration = URLSessionConfiguration.default
        lgWSConfiguration.timeoutIntervalForRequest = 300
        lgWSConfiguration.timeoutIntervalForResource = 300
        lgWSConfiguration.waitsForConnectivity = true
        lgWebSocketSession = URLSession(configuration: lgWSConfiguration)

        loadPersistedState()
        wireUniversalBrowser()
    }

    // MARK: Bootstrap

    /// Launches universal discovery and connects instantly when a target is known.
    func bootstrapConnection() {
        startPresenceListening()

        guard !isConnected, !isConnecting else { return }

        if hasCachedDevice {
            if activeDeviceName == nil {
                activeDeviceName = loadCachedDeviceName()
            }
            restoreSelectedTVFromCacheIfNeeded()

            // LG TVs must come from discovery — never auto-connect to a stale cached IP.
            if let target = selectedTV, target.isLGDevice {
                if discoveredTVs.isEmpty { return }
                if let match = findDiscoveredMatch(for: target) {
                    selectTV(match)
                }
                return
            }

            syncSelectedTVWithDiscovery()

            let target = selectedTV
            let address = target?.sanitizedAddress ?? cachedTVIP
            guard !address.isEmpty else { return }

            tvIPAddress = address
            connectToDevice(
                to: address,
                displayName: activeDeviceName ?? target?.listRowTitle,
                device: target
            )
            return
        }

        if let device = preferredDiscoveredDevice() {
            selectTV(device)
        }
    }

    // MARK: Universal Discovery

    /// Starts parallel Bonjour browsers and SSDP multicast probing.
    func startPresenceListening() {
        guard !isPresenceListening else { return }
        isPresenceListening = true
        universalBrowser.startDiscovery()
    }

    func stopPresenceListening() {
        universalBrowser.stopDiscovery()
        isPresenceListening = false
    }

    // MARK: Connection

    /// Assigns the active control target and begins connecting.
    func selectTV(_ device: DiscoveredTV) {
        let liveDevice = discoveredTVs.first(where: { $0.id == device.id }) ?? device
        var merged = liveDevice
        if merged.lgProtocolType == nil {
            merged.lgProtocolType = device.lgProtocolType
                ?? loadPersistedLGProtocolType(for: merged.id)
        }
        selectedTV = merged
        tvIPAddress = merged.sanitizedAddress
        cachedTVIP = merged.sanitizedAddress
        connectToDevice(
            to: merged.sanitizedAddress,
            displayName: merged.listRowTitle,
            device: merged
        )
    }

    func connectToDevice(_ device: DiscoveredTV) {
        selectTV(device)
    }

    func connectToDevice(
        to address: String,
        displayName: String? = nil,
        device: DiscoveredTV? = nil
    ) {
        guard !address.isEmpty else { return }

        if let device {
            selectedTV = discoveredTVs.first(where: { $0.id == device.id }) ?? device
        }

        let target = selectedTV

        switch target?.controlBackend {
        case .samsung:
            beginWebSocketPairing(
                to: address,
                displayName: displayName,
                persistCache: true
            )
        case .lgNetCast:
            establishLGNetCastConnection(
                to: address,
                displayName: displayName,
                persistCache: true
            )
        case .lgWebOS:
            beginLGWebSocketConnection(
                to: address,
                displayName: displayName,
                persistCache: true
            )
        case .universalHTTP, nil:
            establishUniversalHTTPConnection(
                to: address,
                displayName: displayName,
                persistCache: true
            )
        }
    }

    func connectToDevice(at address: String, displayName: String? = nil) {
        connectToDevice(to: address, displayName: displayName, device: selectedTV)
    }

    func reconnect() {
        let address = tvIPAddress.isEmpty ? cachedTVIP : tvIPAddress
        guard !address.isEmpty else { return }
        connectToDevice(at: address, displayName: activeDeviceName)
    }

    func disconnect() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        lgPendingRequests.removeAll()
        lgInputWebSocketTask?.cancel(with: .goingAway, reason: nil)
        lgInputWebSocketTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        activePairingAddress = nil
        activePairingPort = nil
        isConnecting = false
        isConnected = false
        activeWebSocketBackend = .samsung
    }

    // MARK: Private — Browser Wiring

    private func wireUniversalBrowser() {
        universalBrowser.onDevicesUpdated = { [weak self] devices in
            DispatchQueue.main.async {
                self?.applyDiscoveredDevices(devices)
            }
        }
    }

    private func applyDiscoveredDevices(_ devices: [UniversalTVDevice]) {
        discoveredTVs = devices.map {
            DiscoveredTV(
                id: $0.id,
                name: $0.name,
                address: $0.address,
                modelName: $0.modelName,
                protocols: $0.protocols,
                lgProtocolType: resolvedLGProtocolType(
                    discovered: $0.lgProtocolType,
                    deviceID: $0.id
                )
            )
        }

        syncSelectedTVWithDiscovery()

        // TV got a new DHCP address — reconnect to the discovered record.
        if let selectedTV,
           let match = findDiscoveredMatch(for: selectedTV),
           match.sanitizedAddress != selectedTV.sanitizedAddress {
            selectTV(match)
            return
        }

        let cachedName = loadCachedDeviceName()
        if let cachedName,
           let match = discoveredTVs.first(where: {
               $0.name == cachedName || $0.listRowTitle == cachedName
           }) {
            if cachedTVIP != match.sanitizedAddress {
                cachedTVIP = match.sanitizedAddress
            }
            if selectedTV == nil {
                selectedTV = match
                tvIPAddress = match.sanitizedAddress
            }
            if !isConnected, !isConnecting {
                activeDeviceName = match.listRowTitle
                connectToDevice(
                    to: match.sanitizedAddress,
                    displayName: match.listRowTitle,
                    device: match
                )
            }
        } else if let selectedTV,
                  selectedTV.isLGDevice,
                  !isConnected,
                  !isConnecting,
                  let lgTV = discoveredTVs.first(where: {
                      $0.controlBackend == .lgWebOS || $0.controlBackend == .lgNetCast
                  }) {
            selectTV(lgTV)
        }
    }

    private func resolvedLGProtocolType(
        discovered: TVProtocolType?,
        deviceID: String
    ) -> TVProtocolType? {
        if let discovered { return discovered }
        return loadPersistedLGProtocolType(for: deviceID)
    }

    private func persistLGProtocolType(_ type: TVProtocolType, for deviceID: String) {
        UserDefaults.standard.set(type.rawValue, forKey: Self.lgProtocolTypeKeyPrefix + deviceID)
    }

    private func loadPersistedLGProtocolType(for deviceID: String) -> TVProtocolType? {
        guard let raw = UserDefaults.standard.string(forKey: Self.lgProtocolTypeKeyPrefix + deviceID) else {
            return nil
        }
        return TVProtocolType(rawValue: raw)
    }

    /// Finds the freshest discovery record for a TV (handles DHCP / name drift).
    private func findDiscoveredMatch(for tv: DiscoveredTV) -> DiscoveredTV? {
        let normalizedID = tv.id.lowercased()
        let normalizedIP = tv.sanitizedAddress.lowercased()

        if let match = discoveredTVs.first(where: {
            $0.id.lowercased() == normalizedID || $0.sanitizedAddress.lowercased() == normalizedIP
        }) {
            return match
        }

        if !tv.name.isEmpty,
           let match = discoveredTVs.first(where: {
               $0.name == tv.name || $0.listRowTitle == tv.name
           }) {
            return match
        }

        if let match = discoveredTVs.first(where: { $0.listRowTitle == tv.listRowTitle }) {
            return match
        }

        if let cachedName = loadCachedDeviceName(), !cachedName.isEmpty,
           let match = discoveredTVs.first(where: {
               $0.name == cachedName || $0.listRowTitle == cachedName
           }) {
            return match
        }

        if tv.controlBackend == .lgWebOS || tv.controlBackend == .lgNetCast,
           let match = discoveredTVs.first(where: {
               $0.controlBackend == .lgWebOS || $0.controlBackend == .lgNetCast
           }) {
            return match
        }

        return nil
    }

    /// Reconciles `selectedTV` with the latest discovery snapshot so IP changes are picked up.
    private func syncSelectedTVWithDiscovery() {
        guard !discoveredTVs.isEmpty else { return }

        if let selectedTV, let match = findDiscoveredMatch(for: selectedTV) {
            var merged = match
            if merged.lgProtocolType == nil {
                merged.lgProtocolType = selectedTV.lgProtocolType
                    ?? loadPersistedLGProtocolType(for: merged.id)
            }
            self.selectedTV = merged
            applyLiveControlIP(merged.sanitizedAddress)
        } else if let cachedName = loadCachedDeviceName(),
                  let match = discoveredTVs.first(where: {
                      $0.name == cachedName || $0.listRowTitle == cachedName
                  }) {
            selectedTV = match
            applyLiveControlIP(match.sanitizedAddress)
        }
    }

    private func applyLiveControlIP(_ ip: String) {
        tvIPAddress = ip
        if cachedTVIP != ip {
            cachedTVIP = ip
        }
    }

    /// Live IP for outbound control requests — only verified discovery addresses.
    private var liveControlIPAddress: String? {
        if let selectedTV {
            if let match = findDiscoveredMatch(for: selectedTV) {
                self.selectedTV = match
                applyLiveControlIP(match.sanitizedAddress)
                if match.sanitizedAddress != selectedTV.sanitizedAddress {
                    print("✅ Resolved live IP: \(match.sanitizedAddress) (was \(selectedTV.sanitizedAddress))")
                }
                return match.sanitizedAddress
            }

            if !discoveredTVs.isEmpty {
                let known = discoveredTVs.map(\.sanitizedAddress).joined(separator: ", ")
                print("❌ Stale IP \(selectedTV.sanitizedAddress) — discovery has: [\(known)]")
                lastErrorMessage = "TV address changed — open Nearby TVs and re-select your TV."
                return nil
            }

            // Discovery still running — refuse cache-only synthetic records.
            guard !selectedTV.protocols.isEmpty else {
                print("❌ Waiting for discovery — refusing cache IP \(selectedTV.sanitizedAddress)")
                return nil
            }

            return selectedTV.sanitizedAddress
        }

        if let cachedName = loadCachedDeviceName(),
           let match = discoveredTVs.first(where: {
               $0.name == cachedName || $0.listRowTitle == cachedName
           }) {
            selectedTV = match
            applyLiveControlIP(match.sanitizedAddress)
            return match.sanitizedAddress
        }

        return nil
    }

    private func restoreSelectedTVFromCacheIfNeeded() {
        guard selectedTV == nil, hasCachedDevice else { return }
        let cachedName = loadCachedDeviceName() ?? cachedTVIP
        selectedTV = DiscoveredTV(
            id: cachedTVIP.lowercased(),
            name: cachedName,
            address: cachedTVIP,
            modelName: nil,
            protocols: [],
            lgProtocolType: loadPersistedLGProtocolType(for: cachedTVIP.lowercased())
        )
    }

    // MARK: Private — Samsung WebSocket Pairing

    /// Opens `ws://<ip>:8001/api/v2/channels/samsung.remote.control` and waits for TV approval.
    private func beginWebSocketPairing(
        to address: String,
        displayName: String?,
        persistCache: Bool
    ) {
        let host = sanitizedSamsungHost(address)
        guard !host.isEmpty else {
            lastErrorMessage = "Invalid device address."
            return
        }

        if isConnecting,
           activePairingAddress == host,
           webSocketTask != nil {
            return
        }

        pairingTimeoutTask?.cancel()
        lgPendingRequests.removeAll()
        lgInputWebSocketTask?.cancel(with: .goingAway, reason: nil)
        lgInputWebSocketTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        tvIPAddress = host
        activePairingAddress = host
        activePairingPort = Self.samsungWebSocketPort
        didAttemptPortFallback = false
        if let displayName {
            activeDeviceName = displayName
        }

        lastErrorMessage = nil
        isConnected = false
        isConnecting = true

        activeWebSocketBackend = .samsung
        openWebSocket(to: host, port: Self.samsungWebSocketPort, persistCache: persistCache)
    }

    private func openWebSocket(to host: String, port: Int, persistCache: Bool) {
        guard let url = webSocketURL(for: host, port: port) else {
            isConnecting = false
            lastErrorMessage = "Invalid device address."
            return
        }

        // URLSession logs WebSocket URLs as http:// in NSError — the scheme here is ws.
        precondition(url.scheme?.lowercased() == "ws", "Samsung pairing must use ws://, not http://")

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        listenForWebSocketMessages(persistCache: persistCache, address: host, port: port)
        startPairingTimeout(host: host, port: port, persistCache: persistCache)
    }

    private func tryFallbackPort(host: String, persistCache: Bool) {
        guard !didAttemptPortFallback else { return }
        didAttemptPortFallback = true
        pairingTimeoutTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        activePairingPort = Self.samsungWebSocketFallbackPort
        openWebSocket(to: host, port: Self.samsungWebSocketFallbackPort, persistCache: persistCache)
    }

    private func startPairingTimeout(host: String, port: Int, persistCache: Bool) {
        pairingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectionTimeout))
            guard let self, !Task.isCancelled, self.isConnecting, !self.isConnected else { return }

            if port == Self.samsungWebSocketPort {
                self.tryFallbackPort(host: host, persistCache: persistCache)
                return
            }

            self.applyConnectionFailure("Pairing timed out — approve the connection on your Samsung TV.")
        }
    }

    private func listenForWebSocketMessages(persistCache: Bool, address: String, port: Int) {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.handleWebSocketMessage(
                        message,
                        persistCache: persistCache,
                        address: address,
                        port: port
                    )
                    if self.webSocketTask != nil {
                        self.listenForWebSocketMessages(
                            persistCache: persistCache,
                            address: address,
                            port: port
                        )
                    }
                }

            case .failure(let error):
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled { return }

                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.isConnecting || self.isConnected else { return }

                    if self.activeWebSocketBackend == .samsung,
                       self.isConnecting,
                       port == Self.samsungWebSocketPort,
                       (nsError.code == NSURLErrorCannotConnectToHost
                        || nsError.code == NSURLErrorNetworkConnectionLost) {
                        self.tryFallbackPort(host: address, persistCache: persistCache)
                        return
                    }

                    self.applyConnectionFailure(error.localizedDescription)
                }
            }
        }
    }

    private func handleWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        persistCache: Bool,
        address: String,
        port: Int
    ) {
        let payload: Data?
        switch message {
        case .string(let text):
            payload = text.data(using: .utf8)
        case .data(let data):
            payload = data
        @unknown default:
            payload = nil
        }

        guard let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }

        switch activeWebSocketBackend {
        case .samsung:
            handleSamsungWebSocketMessage(json, persistCache: persistCache, address: address)
        case .lgWebOS:
            handleLGWebSocketMessage(json, persistCache: persistCache, address: address)
        case .lgNetCast, .universalHTTP:
            break
        }
    }

    private func handleSamsungWebSocketMessage(
        _ json: [String: Any],
        persistCache: Bool,
        address: String
    ) {
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            parseSamsungCommandResponse(data)
        }

        guard let event = json["event"] as? String else { return }

        if event == "ms.channel.connect" {
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            isConnected = true
            isConnecting = false
            lastErrorMessage = nil

            if persistCache {
                cachedTVIP = address
                if let name = activeDeviceName {
                    persistCachedDeviceName(name)
                }
            }
        }
    }

    private func handleLGWebSocketMessage(
        _ json: [String: Any],
        persistCache: Bool,
        address: String
    ) {
        if let id = json["id"] as? String,
           let handler = lgPendingRequests.removeValue(forKey: id) {
            if let type = json["type"] as? String, type == "error" {
                let message = (json["error"] as? String) ?? "LG request failed."
                if isLGPermissionError(message) {
                    handleLGPermissionDenied(host: address)
                    return
                }
                handler(.failure(NSError(
                    domain: "ZapRemote.LG",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )))
            } else if let payload = json["payload"] as? [String: Any] {
                if let returnValue = payload["returnValue"] as? Bool, !returnValue {
                    let message = (payload["errorText"] as? String) ?? "LG request failed."
                    if isLGPermissionError(message) {
                        handleLGPermissionDenied(host: address)
                        return
                    }
                    handler(.failure(NSError(
                        domain: "ZapRemote.LG",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )))
                } else {
                    handler(.success(payload))
                }
            }
            return
        }

        if let type = json["type"] as? String, type == "hello" {
            print("LG webOS hello received — registering…")
            sendLGRegisterHandshake()
            return
        }

        if let type = json["type"] as? String, type == "registered",
           let payload = json["payload"] as? [String: Any],
           let clientKey = payload["client-key"] as? String {
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            lgClientKey = clientKey
            lastErrorMessage = nil
            print("✅ LG webOS paired at \(address) — opening input socket…")

            if persistCache {
                cachedTVIP = address
                if let name = activeDeviceName {
                    persistCachedDeviceName(name)
                }
            }

            requestLGPointerInputSocket(host: address, persistCache: lgActivePersistCache)
            return
        }

        if let payload = json["payload"] as? [String: Any],
           payload["pairingType"] as? String == "PROMPT" {
            lastErrorMessage = nil
            print("📺 Approve ZapRemote on your LG TV")
            return
        }

        if let type = json["type"] as? String, type == "error" {
            let message = (json["error"] as? String) ?? "LG webOS pairing failed."
            print("❌ LG SSAP error: \(message)")
            if isLGPermissionError(message) {
                handleLGPermissionDenied(host: address)
                return
            }
            applyConnectionFailure(message)
        }
    }

    private func preferredDiscoveredDevice() -> DiscoveredTV? {
        if let cachedName = loadCachedDeviceName(),
           let match = discoveredTVs.first(where: {
               $0.name == cachedName || $0.listRowTitle == cachedName
           }) {
            return match
        }
        return discoveredTVs.first
    }

    // MARK: Private — LG NetCast ROAP

    /// NetCast TVs accept ROAP over HTTP :8080 — no WebSocket pairing required.
    private func establishLGNetCastConnection(
        to address: String,
        displayName: String?,
        persistCache: Bool
    ) {
        let host = sanitizedSamsungHost(address)
        guard !host.isEmpty else {
            lastErrorMessage = "Invalid device address."
            return
        }

        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        lgPendingRequests.removeAll()
        lgInputWebSocketTask?.cancel(with: .goingAway, reason: nil)
        lgInputWebSocketTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        activePairingAddress = nil
        activePairingPort = nil

        tvIPAddress = host
        activeWebSocketBackend = .lgNetCast
        if let displayName {
            activeDeviceName = displayName
        }

        if let match = discoveredTVs.first(where: { $0.sanitizedAddress == host }) {
            selectedTV = match
        }

        lastErrorMessage = nil
        isConnecting = false
        isConnected = true

        if var tv = selectedTV {
            tv.lgProtocolType = .netcast
            selectedTV = tv
            persistLGProtocolType(.netcast, for: tv.id)
        }

        print("✅ LG NetCast ready at \(host) — ROAP :8080")

        if persistCache {
            cachedTVIP = host
            if let name = activeDeviceName {
                persistCachedDeviceName(name)
            }
        }
    }

    // MARK: Private — LG webOS WebSocket

    private func beginLGWebSocketConnection(
        to address: String,
        displayName: String?,
        persistCache: Bool
    ) {
        let host = sanitizedSamsungHost(address)
        guard !host.isEmpty else {
            lastErrorMessage = "Invalid device address."
            return
        }

        if isConnecting,
           activePairingAddress == host,
           activeWebSocketBackend == .lgWebOS,
           webSocketTask != nil {
            return
        }

        if isConnected,
           activePairingAddress == host,
           activeWebSocketBackend == .lgWebOS,
           lgInputWebSocketTask != nil {
            return
        }

        pairingTimeoutTask?.cancel()
        lgPendingRequests.removeAll()
        lgForceRePairAttempted = false
        lgRegisterSent = false
        lgActivePersistCache = persistCache
        lgInputWebSocketTask?.cancel(with: .goingAway, reason: nil)
        lgInputWebSocketTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        tvIPAddress = host
        activePairingAddress = host
        activePairingPort = Self.lgWebSocketPort
        didAttemptPortFallback = false
        activeWebSocketBackend = .lgWebOS
        if let displayName {
            activeDeviceName = displayName
        }

        if let match = discoveredTVs.first(where: { $0.sanitizedAddress == host }) {
            selectedTV = match
        }

        lastErrorMessage = nil
        isConnected = false
        isConnecting = true

        openLGWebSocket(to: host, persistCache: persistCache)
    }

    private func openLGWebSocket(to host: String, persistCache: Bool) {
        guard let url = lgWebSocketURL(for: host) else {
            isConnecting = false
            lastErrorMessage = "Invalid device address."
            return
        }

        print("Connecting LG webOS WebSocket at \(url.absoluteString)")

        let task = lgWebSocketSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        sendLGHello()
        scheduleLGRegisterFallback()
        listenForWebSocketMessages(
            persistCache: persistCache,
            address: host,
            port: Self.lgWebSocketPort
        )
        startLGPairingTimeout(host: host, persistCache: persistCache)
    }

    private func startLGPairingTimeout(host: String, persistCache: Bool) {
        pairingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectionTimeout))
            guard let self, !Task.isCancelled, self.isConnecting, !self.isConnected else { return }
            self.applyConnectionFailure("Pairing timed out — approve the connection on your LG TV.")
        }
    }

    private func scheduleLGRegisterFallback() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self,
                  self.isConnecting,
                  !self.isConnected,
                  !self.lgRegisterSent,
                  self.webSocketTask != nil else { return }
            print("LG hello timeout — registering directly")
            self.sendLGRegisterHandshake()
        }
    }

    private func sendLGHello() {
        let envelope: [String: Any] = [
            "type": "hello",
            "id": "hello_0",
            "payload": [String: Any]()
        ]
        sendLGWebSocketJSON(envelope)
    }

    private func sendLGRegisterHandshake(forcePairing: Bool = false) {
        lgRegisterSent = true
        var payload = Self.lgRegistrationPayload
        if forcePairing {
            payload["forcePairing"] = true
            payload.removeValue(forKey: "client-key")
        } else if !lgClientKey.isEmpty {
            payload["client-key"] = lgClientKey
        }

        let envelope: [String: Any] = [
            "type": "register",
            "id": "register_0",
            "payload": payload
        ]
        sendLGWebSocketJSON(envelope)
    }

    private func isLGPermissionError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("401")
            || normalized.contains("insufficient permission")
            || normalized.contains("not allowed")
    }

    private func handleLGPermissionDenied(host: String) {
        if lgForceRePairAttempted {
            applyConnectionFailure(
                "LG TV denied remote control. Check Settings → General → Mobile App Connection."
            )
            return
        }

        lgForceRePairAttempted = true
        lgClientKey = ""
        UserDefaults.standard.removeObject(forKey: Self.lgClientKeyStorageKey)
        lgInputWebSocketTask?.cancel(with: .goingAway, reason: nil)
        lgInputWebSocketTask = nil
        isConnected = false
        isConnecting = true
        lastErrorMessage = "Approve ZapRemote on your LG TV to allow remote control."
        print("⚠️ LG 401 — clearing saved key and forcing re-pair")

        sendLGRegisterHandshake(forcePairing: true)
    }

    private func sendLGWebSocketJSON(_ envelope: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else {
            lastErrorMessage = TVControllerError.encodingFailed.localizedDescription
            return
        }

        task.send(.string(json)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.applyConnectionFailure(error.localizedDescription)
                }
            }
        }
    }

    private func requestLGService(
        uri: String,
        payload: [String: Any] = [:],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        lgCommandCounter += 1
        let requestID = "lg_req_\(lgCommandCounter)"
        lgPendingRequests[requestID] = completion

        let envelope: [String: Any] = [
            "type": "request",
            "id": requestID,
            "uri": "ssap://\(uri)",
            "payload": payload
        ]
        sendLGWebSocketJSON(envelope)
    }

    private func requestLGPointerInputSocket(host: String, persistCache: Bool) {
        requestLGService(uri: "com.webos.service.networkinput/getPointerInputSocket") { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let payload):
                    guard let socketPath = payload["socketPath"] as? String,
                          let url = self.lgInputSocketURL(socketPath, fallbackHost: host) else {
                        self.applyConnectionFailure("LG input socket unavailable.")
                        return
                    }
                    self.openLGInputWebSocket(url: url, host: host)

                case .failure(let error):
                    let message = error.localizedDescription
                    print("❌ LG input socket request failed: \(message)")
                    if self.isLGPermissionError(message) {
                        self.handleLGPermissionDenied(host: host)
                    } else {
                        self.applyConnectionFailure(message)
                    }
                }
            }
        }
    }

    private func openLGInputWebSocket(url: URL, host: String) {
        lgInputWebSocketTask?.cancel(with: .goingAway, reason: nil)

        print("Opening LG input socket at \(url.absoluteString)")

        let task = lgWebSocketSession.webSocketTask(with: url)
        lgInputWebSocketTask = task
        task.resume()

        if var tv = selectedTV {
            tv.lgProtocolType = .webOS
            selectedTV = tv
            persistLGProtocolType(.webOS, for: tv.id)
        }

        isConnected = true
        isConnecting = false
        lgForceRePairAttempted = false
        lastErrorMessage = nil
        print("✅ LG remote ready at \(host)")
    }

    private func lgInputSocketURL(_ socketPath: String, fallbackHost: String) -> URL? {
        if socketPath.hasPrefix("ws://") || socketPath.hasPrefix("wss://") {
            return URL(string: socketPath)
        }
        if socketPath.hasPrefix("/") {
            return URL(string: "ws://\(fallbackHost):\(Self.lgWebSocketPort)\(socketPath)")
        }
        return URL(string: socketPath)
    }

    private func lgWebSocketURL(for host: String) -> URL? {
        URL(string: "ws://\(host):\(Self.lgWebSocketPort)/")
    }

    // MARK: Commands

    @discardableResult
    func sendRemoteKey(_ key: RemoteKey) -> Bool {
        guard isConnected else {
            lastErrorMessage = TVControllerError.notConnected.localizedDescription
            return false
        }

        syncSelectedTVWithDiscovery()

        switch selectedTV?.controlBackend {
        case .samsung:
            return sendSamsungRemoteKey(key.rawValue)
        case .lgNetCast, .lgWebOS:
            return sendCommand(key)
        case .universalHTTP, nil:
            return sendUniversalHTTPKey(key)
        }
    }

    @discardableResult
    func sendRemoteKey(_ key: String) -> Bool {
        guard isConnected else {
            lastErrorMessage = TVControllerError.notConnected.localizedDescription
            return false
        }

        syncSelectedTVWithDiscovery()

        switch selectedTV?.controlBackend {
        case .samsung:
            return sendSamsungRemoteKey(key)
        case .lgNetCast, .lgWebOS, .universalHTTP, nil:
            guard let remoteKey = RemoteKey(samsungPayloadKey: key) else {
                lastErrorMessage = TVControllerError.encodingFailed.localizedDescription
                return false
            }
            if selectedTV?.controlBackend == .lgNetCast || selectedTV?.controlBackend == .lgWebOS {
                return sendCommand(remoteKey)
            }
            return sendUniversalHTTPKey(remoteKey)
        }
    }

    @discardableResult
    func sendZapCommand(toTarget: String) -> Bool {
        guard let target = ZapTarget(rawValue: toTarget.uppercased()) else {
            lastErrorMessage = TVControllerError.invalidTarget(toTarget).localizedDescription
            return false
        }
        return sendZapCommand(to: target)
    }

    @discardableResult
    func sendZapCommand(to target: ZapTarget) -> Bool {
        sendRemoteKey(target.remoteKey)
    }

    // MARK: Private — Universal HTTP Connection

    /// Marks an unknown TV as connected for the HTTP keypress fallback.
    private func establishUniversalHTTPConnection(
        to address: String,
        displayName: String?,
        persistCache: Bool
    ) {
        let host = sanitizedSamsungHost(address)
        guard !host.isEmpty else {
            lastErrorMessage = "Invalid device address."
            return
        }

        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        activePairingAddress = nil
        activePairingPort = nil

        tvIPAddress = host
        if let displayName {
            activeDeviceName = displayName
        }

        if let match = discoveredTVs.first(where: { $0.sanitizedAddress == host }) {
            selectedTV = match
        } else if let current = selectedTV {
            selectedTV = DiscoveredTV(
                id: host.lowercased(),
                name: current.name,
                address: host,
                modelName: current.modelName,
                protocols: current.protocols
            )
        }

        lastErrorMessage = nil
        isConnecting = false
        isConnected = true

        if persistCache {
            cachedTVIP = host
            if let name = activeDeviceName {
                persistCachedDeviceName(name)
            }
        }
    }

    // MARK: Private — Command Backends

    @discardableResult
    private func sendSamsungRemoteKey(_ key: String) -> Bool {
        guard let task = webSocketTask else {
            lastErrorMessage = TVControllerError.notConnected.localizedDescription
            return false
        }

        guard let body = buildRemoteKeyPayload(key: key),
              let json = String(data: body, encoding: .utf8) else {
            lastErrorMessage = TVControllerError.encodingFailed.localizedDescription
            return false
        }

        task.send(.string(json)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.applyConnectionFailure(error.localizedDescription)
                }
            }
        }

        return true
    }

    // MARK: Private — LG Protocol Router

    /// Routes button presses to ROAP (NetCast :8080) or webOS pointer socket (:3000).
    @discardableResult
    private func sendCommand(_ key: RemoteKey) -> Bool {
        syncSelectedTVWithDiscovery()

        guard let selectedTV, !selectedTV.ipAddress.isEmpty else {
            lastErrorMessage = TVControllerError.notConnected.localizedDescription
            return false
        }

        switch selectedTV.protocolType {
        case .netcast:
            return sendRoapCommand(key, to: selectedTV.ipAddress)
        case .webOS:
            return sendWebOSButtonCommand(key)
        }
    }

    @discardableResult
    private func sendRoapCommand(_ key: RemoteKey, to ipAddress: String) -> Bool {
        guard let roapCode = key.lgROAPKeyCode else {
            return false
        }

        let roapURL = "http://\(ipAddress):\(Self.lgROAPPort)/roap/api/command"
        guard let url = URL(string: roapURL) else {
            lastErrorMessage = "Invalid LG ROAP URL."
            return false
        }

        let xmlBody =
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<command><name>HandleKeyInput</name><value>\(roapCode)</value></command>"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = xmlBody.data(using: .utf8)
        request.timeoutInterval = 5

        print("Sending ROAP key \(roapCode) to \(roapURL)")

        session.dataTask(with: request) { [weak self] _, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                    return
                }
                self.lastErrorMessage = nil
            }
        }.resume()

        return true
    }

    @discardableResult
    private func sendWebOSButtonCommand(_ key: RemoteKey) -> Bool {
        guard isConnected, let task = lgInputWebSocketTask else {
            lastErrorMessage = "LG webOS not ready — approve the connection on your TV."
            return false
        }

        let message = "type:button\nname:\(key.lgSSAPKeyName)\n\n"
        print("Sending webOS button \(key.lgSSAPKeyName) to \(tvIPAddress)")

        task.send(.string(message)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.lastErrorMessage = error.localizedDescription
                }
            }
        }

        lastErrorMessage = nil
        return true
    }

    @discardableResult
    private func sendUniversalHTTPKey(_ key: RemoteKey) -> Bool {
        guard let dynamicIP = liveControlIPAddress else {
            lastErrorMessage = TVControllerError.notConnected.localizedDescription
            return false
        }

        let path = universalKeyPath(for: key)
        guard let url = URL(string: "http://\(dynamicIP):\(Self.universalHTTPPort)/keypress/\(path)") else {
            lastErrorMessage = "Invalid universal keypress URL."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        session.dataTask(with: request) { [weak self] _, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.lastErrorMessage = "Could not connect to the server."
                    return
                }
                self.lastErrorMessage = nil
            }
        }.resume()

        return true
    }

    private func universalKeyPath(for key: RemoteKey) -> String {
        switch key {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "Select"
        case .menu: "Back"
        }
    }

    // MARK: Private — URLs & Payload

    /// Builds an explicit WebSocket URL — must start with `ws://`, never `http://`.
    ///
    /// `ws://192.168.86.167:8001/api/v2/channels/samsung.remote.control?name=ZAPRemote`
    private func webSocketURL(for address: String, port: Int) -> URL? {
        let host = sanitizedSamsungHost(address)
        guard !host.isEmpty else { return nil }

        let encodedName = Self.appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? Self.appName

        var urlString =
            "ws://\(host):\(port)/api/v2/channels/samsung.remote.control?name=\(encodedName)"

        if !savedToken.isEmpty {
            let encodedToken = savedToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? savedToken
            urlString += "&token=\(encodedToken)"
        }

        guard !urlString.lowercased().hasPrefix("http://"),
              !urlString.lowercased().hasPrefix("https://"),
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "ws" else {
            return nil
        }

        return url
    }

    private func sanitizedSamsungHost(_ address: String) -> String {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["http://", "https://", "ws://", "wss://"] {
            if host.lowercased().hasPrefix(prefix) {
                host = String(host.dropFirst(prefix.count))
                break
            }
        }

        if let pathStart = host.firstIndex(of: "/") {
            host = String(host[..<pathStart])
        }

        return DiscoveredTV.stripInterfaceScope(from: host)
    }

    private func buildRemoteKeyPayload(key: String) -> Data? {
        let envelope: [String: Any] = [
            "method": "ms.remote.control",
            "params": [
                "Cmd": "Click",
                "DataOfCmd": key,
                "Option": "false",
                "TypeOfRemote": "SendRemoteKey"
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: envelope)
    }

    private func parseSamsungCommandResponse(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event = json["event"] as? String
        else { return }

        if event == "ms.channel.connect",
           let payload = json["data"] as? [String: Any],
           let token = payload["token"] as? String {
            savedToken = token
        } else if event == "ms.error" {
            lastErrorMessage = (json["data"] as? String) ?? "Unknown Samsung API error"
        }
    }

    private func applyConnectionFailure(_ message: String) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        lgPendingRequests.removeAll()
        lastErrorMessage = message
        isConnecting = false
        isConnected = false
        lgInputWebSocketTask?.cancel(with: .goingAway, reason: nil)
        lgInputWebSocketTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        activePairingAddress = nil
        activePairingPort = nil
    }

    private static let lgRegistrationSignature =
        "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pb" +
        "ctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR" +
        "+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRy" +
        "aMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4" +
        "RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n" +
        "50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM" +
        "2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQoj" +
        "oa7NQnAtw=="

    private static let lgRegistrationPayload: [String: Any] = [
        "forcePairing": false,
        "pairingType": "PROMPT",
        "manifest": [
            "appVersion": "1.1",
            "manifestVersion": 1,
            "permissions": [
                "LAUNCH",
                "LAUNCH_WEBAPP",
                "APP_TO_APP",
                "CLOSE",
                "TEST_OPEN",
                "TEST_PROTECTED",
                "CONTROL_AUDIO",
                "CONTROL_DISPLAY",
                "CONTROL_INPUT_JOYSTICK",
                "CONTROL_INPUT_MEDIA_RECORDING",
                "CONTROL_INPUT_MEDIA_PLAYBACK",
                "CONTROL_INPUT_TV",
                "CONTROL_POWER",
                "CONTROL_TV_SCREEN",
                "READ_APP_STATUS",
                "READ_CURRENT_CHANNEL",
                "READ_INPUT_DEVICE_LIST",
                "READ_NETWORK_STATE",
                "READ_RUNNING_APPS",
                "READ_TV_CHANNEL_LIST",
                "WRITE_NOTIFICATION_TOAST",
                "READ_POWER_STATE",
                "READ_COUNTRY_INFO",
                "CONTROL_INPUT_TEXT",
                "CONTROL_MOUSE_AND_KEYBOARD",
                "READ_INSTALLED_APPS",
                "READ_SETTINGS"
            ],
            "signatures": [
                ["signature": lgRegistrationSignature, "signatureVersion": 1]
            ],
            "signed": [
                "appId": "com.lge.test",
                "created": "20140509",
                "localizedAppNames": [
                    "": "ZapRemote",
                    "ko-KR": "리모컨 앱",
                    "zxx-XX": "ЛГ Rэмotэ AПП"
                ],
                "localizedVendorNames": ["": "LG Electronics"],
                "permissions": [
                    "TEST_SECURE",
                    "CONTROL_INPUT_TEXT",
                    "CONTROL_MOUSE_AND_KEYBOARD",
                    "READ_INSTALLED_APPS",
                    "READ_LGE_SDX",
                    "READ_NOTIFICATIONS",
                    "SEARCH",
                    "WRITE_SETTINGS",
                    "WRITE_NOTIFICATION_ALERT",
                    "CONTROL_POWER",
                    "READ_CURRENT_CHANNEL",
                    "READ_RUNNING_APPS",
                    "READ_UPDATE_INFO",
                    "UPDATE_FROM_REMOTE_APP",
                    "READ_LGE_TV_INPUT_EVENTS",
                    "READ_TV_CURRENT_TIME"
                ],
                "serial": "2f930e2d2cfe083771f68e4fe7bb07",
                "vendorId": "com.lge"
            ]
        ]
    ]

    private func loadPersistedState() {
        savedToken = UserDefaults.standard.string(forKey: Self.tokenStorageKey) ?? ""
        if UserDefaults.standard.integer(forKey: Self.lgManifestVersionKey) < Self.lgManifestVersion {
            UserDefaults.standard.removeObject(forKey: Self.lgClientKeyStorageKey)
            UserDefaults.standard.set(Self.lgManifestVersion, forKey: Self.lgManifestVersionKey)
        }
        lgClientKey = UserDefaults.standard.string(forKey: Self.lgClientKeyStorageKey) ?? ""
        cachedTVIP = UserDefaults.standard.string(forKey: Self.cachedTVIPKey) ?? ""
        activeDeviceName = loadCachedDeviceName()
        if !cachedTVIP.isEmpty {
            tvIPAddress = cachedTVIP
        }
    }

    private func persistToken() {
        UserDefaults.standard.set(savedToken, forKey: Self.tokenStorageKey)
    }

    private func persistLGClientKey() {
        UserDefaults.standard.set(lgClientKey, forKey: Self.lgClientKeyStorageKey)
    }

    private func persistCachedTVIP() {
        UserDefaults.standard.set(cachedTVIP, forKey: Self.cachedTVIPKey)
    }

    private func loadCachedDeviceName() -> String? {
        UserDefaults.standard.string(forKey: Self.cachedDeviceNameKey)
    }

    private func persistCachedDeviceName(_ name: String) {
        UserDefaults.standard.set(name, forKey: Self.cachedDeviceNameKey)
    }
}
