//
//  UniversalTVBrowser.swift
//  ZapRemote
//
//  Multi-protocol LAN discovery for universal TV remotes.
//
//  Protocol routing overview:
//  - AirPlay (_airplay._tcp): Apple TV + AirPlay-compatible smart TVs — media mirror / control.
//  - Media Remote TV (_mediaremotetv._tcp): Apple TV Siri Remote pairing channel.
//  - Google Cast (_googlecast._tcp): Chromecast built-in TVs — Cast control plane.
//  - DLNA (_dlna._tcp): Samsung, LG, Sony UPnP/DLNA renderers — HTTP SOAP control.
//  - SSDP (UDP 239.255.255.250:1900): LG webOS, Roku, and legacy UPnP TVs.
//

import Foundation
import Network
import Observation

// MARK: - Discovery Protocol

/// Identifies which discovery plane located a television.
enum TVDiscoveryProtocol: String, Sendable, CaseIterable, Hashable {
    case airPlay = "AirPlay"
    case mediaRemoteTV = "Media Remote TV"
    case googleCast = "Google Cast"
    case dlna = "DLNA"
    case ssdp = "SSDP"

    /// Bonjour service type registered in Info.plist (SSDP also uses raw UDP).
    var bonjourType: String? {
        switch self {
        case .airPlay: "_airplay._tcp"
        case .mediaRemoteTV: "_mediaremotetv._tcp"
        case .googleCast: "_googlecast._tcp"
        case .dlna: "_dlna._tcp"
        case .ssdp: "_ssdp._tcp"
        }
    }

    /// How commands are typically routed after discovery.
    var routingDescription: String {
        switch self {
        case .airPlay:
            "Routes via AirPlay HTTP / RTSP control on the LAN."
        case .mediaRemoteTV:
            "Routes via Apple's Media Remote TV pairing protocol."
        case .googleCast:
            "Routes via the Cast v2 protobuf channel (port 8009)."
        case .dlna:
            "Routes via UPnP SOAP actions on the device's HTTP server."
        case .ssdp:
            "Routes via UPnP LOCATION descriptors and LG webOS second-screen services."
        }
    }
}

// MARK: - Universal TV Device

/// A deduplicated television discovered across one or more protocols.
struct UniversalTVDevice: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let address: String
    var modelName: String?
    var protocols: Set<TVDiscoveryProtocol>
    /// LG stack hint from SSDP — webOS vs legacy NetCast.
    var lgProtocolType: TVProtocolType?
}

// MARK: - Thread-Safe Helpers (nonisolated — safe to call from Network callbacks)

/// Dispatch queues used by Network.framework callbacks. Kept nonisolated so handlers
/// never read MainActor state just to obtain a queue reference.
private enum DiscoveryDispatch {
    nonisolated static let bonjour = DispatchQueue(
        label: "com.zapremote.universal-browser.bonjour",
        qos: .userInitiated
    )
    nonisolated static let ssdp = DispatchQueue(
        label: "com.zapremote.universal-browser.ssdp",
        qos: .utility
    )
    nonisolated static let resolver = DispatchQueue(
        label: "com.zapremote.endpoint-resolver"
    )
}

private enum DiscoveryFormatting {
    nonisolated static func sanitizeHost(_ host: String) -> String {
        var cleaned = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let scope = cleaned.firstIndex(of: "%") {
            cleaned = String(cleaned[..<scope])
        }
        return cleaned
    }

    /// TXT keys that carry a human-readable device label across Cast, AirPlay, and DLNA.
    nonisolated private static let friendlyTXTKeys = [
        "fn", "name", "cn", "friendlyName", "deviceName"
    ]

    nonisolated static func txtRecord(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        switch metadata {
        case .bonjour(let record):
            return record.dictionary
        default:
            return [:]
        }
    }

    nonisolated static func serviceInstanceName(from endpoint: NWEndpoint) -> String {
        guard case .service(let name, _, _, _) = endpoint else {
            return ""
        }
        return decodeBonjourEscaped(name)
    }

    nonisolated static func displayName(
        txtRecord: [String: String],
        serviceInstanceName: String,
        address: String
    ) -> String {
        if let txtName = friendlyNameFromTXT(txtRecord) {
            return txtName
        }

        let instanceName = decodeBonjourInstanceName(serviceInstanceName)
        if !instanceName.isEmpty, !looksLikeHardwareID(instanceName) {
            return instanceName
        }

        return "Smart TV (\(address))"
    }

    // MARK: Audio-only filtering

    /// Google Cast TXT `ve` value for Chromecast Audio (audio-only, no video out).
    nonisolated private static let castAudioOnlyVersion = "05"

    /// Known Cast `md` model strings that never expose a video display.
    nonisolated private static let castAudioOnlyModels: Set<String> = [
        "chromecast audio",
        "google home",
        "google home mini",
        "google home max", // speaker — no display
        "google nest mini",
        "google nest audio",
        "nest mini",
        "nest audio",
    ]

    /// Returns `false` for Cast targets that are speakers/audio-only (Chromecast Audio, Nest Audio, etc.).
    nonisolated static func isVideoCapableCastTarget(
        txtRecord: [String: String],
        serviceInstanceName: String
    ) -> Bool {
        let model = txtValue(txtRecord, key: "md").lowercased()
        let version = txtValue(txtRecord, key: "ve")
        let friendlyName = (
            friendlyNameFromTXT(txtRecord)
                ?? decodeBonjourInstanceName(serviceInstanceName)
        ).lowercased()

        // ve=05 is the Chromecast Audio protocol revision (no video output).
        if version == castAudioOnlyVersion {
            return false
        }

        if castAudioOnlyModels.contains(model) {
            return false
        }

        if model.contains("chromecast audio") {
            return false
        }

        // Nest Hub / Hub Max have displays — allow even if name contains "nest".
        if model.contains("nest hub") || model.contains("hub max") {
            return true
        }

        if isAudioOnlyModelName(model) || isAudioOnlyFriendlyName(friendlyName) {
            return false
        }

        // Regular Chromecast and TV-embedded Cast report md=Chromecast or TV vendor strings.
        if model == "chromecast" || model.hasPrefix("chromecast ") {
            return !model.contains("audio")
        }

        // Unknown Cast model without audio signals — keep (likely a TV with built-in Cast).
        return true
    }

    /// Broad name/model heuristic applied across Bonjour protocols (AirPlay HomePods, DLNA speakers, etc.).
    nonisolated static func isLikelyAudioOnlyDevice(
        txtRecord: [String: String],
        serviceInstanceName: String,
        protocolKind: TVDiscoveryProtocol
    ) -> Bool {
        if protocolKind == .googleCast {
            return !isVideoCapableCastTarget(
                txtRecord: txtRecord,
                serviceInstanceName: serviceInstanceName
            )
        }

        let model = txtValue(txtRecord, key: "md").lowercased()
        if !model.isEmpty, isAudioOnlyModelName(model) {
            return true
        }

        let friendlyName = (
            friendlyNameFromTXT(txtRecord)
                ?? decodeBonjourInstanceName(serviceInstanceName)
        ).lowercased()

        return isAudioOnlyFriendlyName(friendlyName)
    }

    nonisolated static func txtValue(_ record: [String: String], key: String) -> String {
        if let value = record[key] {
            return value
        }
        return record.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? ""
    }

    nonisolated private static func isAudioOnlyModelName(_ model: String) -> Bool {
        let normalized = model.lowercased()
        if castAudioOnlyModels.contains(normalized) { return true }

        let blockedFragments = [
            "chromecast audio",
            "speaker",
            "soundbar",
            "sound bar",
            "homepod",
            "home pod",
            "home mini",
            "nest mini",
            "nest audio",
            "srs-",
            "srs "
        ]
        return blockedFragments.contains { normalized.contains($0) }
    }

    nonisolated private static func isAudioOnlyFriendlyName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if normalized.isEmpty { return false }

        // Devices with displays should survive even if the name mentions a room.
        if normalized.contains("tv") || normalized.contains("television") {
            return false
        }

        let patterns = [
            #"\bchromecast audio\b"#,
            #"\b(audio|speaker|soundbar|sound bar|homepod|home pod)\b"#,
            #"\b(google home|nest mini|nest audio|home mini)\b"#,
            #"\bsrs[\s-]"#
        ]
        return patterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    nonisolated static func isBetterDisplayName(_ candidate: String, than current: String) -> Bool {
        let candidatePretty = !looksLikeHardwareID(candidate)
        let currentPretty = !looksLikeHardwareID(current)

        if candidatePretty, !currentPretty { return true }
        if !candidatePretty, currentPretty { return false }

        return candidate.count > current.count
    }

    nonisolated private static func friendlyNameFromTXT(_ txtRecord: [String: String]) -> String? {
        for key in friendlyTXTKeys {
            if let value = txtRecord[key], let pretty = prettifyName(value) {
                return pretty
            }
            if let match = txtRecord.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
               let pretty = prettifyName(match.value) {
                return pretty
            }
        }
        return nil
    }

    nonisolated private static func prettifyName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeHardwareID(trimmed) else { return nil }
        return trimmed
    }

    nonisolated private static func decodeBonjourEscaped(_ name: String) -> String {
        name.replacingOccurrences(of: "\\032", with: " ")
    }

    nonisolated private static func decodeBonjourInstanceName(_ raw: String) -> String {
        decodeBonjourEscaped(raw)
            .components(separatedBy: "._").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    nonisolated static func looksLikeHardwareID(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if trimmed.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if trimmed.range(of: #"^[0-9A-Fa-f]{16,}$"#, options: .regularExpression) != nil {
            return true
        }

        if trimmed.count > 18,
           !trimmed.contains(" "),
           trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return true
        }

        return false
    }

    nonisolated static func parseSSDPResponse(_ text: String) -> SSDPParsedDevice? {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        guard let location = headers["LOCATION"],
              let url = URL(string: location),
              let host = url.host else {
            return nil
        }

        let address = sanitizeHost(host)
        let server = headers["SERVER"]
        let searchTarget = headers["ST"]
        let usn = headers["USN"]

        guard isRelevantSSDPDevice(server: server, searchTarget: searchTarget, usn: usn) else {
            return nil
        }

        let isLGWebOS = isLGWebOSDevice(server: server, searchTarget: searchTarget, usn: usn)
        let interimName = lgDisplayName(
            friendlyName: nil,
            server: server,
            usn: usn,
            address: address,
            isLGWebOS: isLGWebOS
        )

        return SSDPParsedDevice(
            name: interimName,
            address: address,
            locationURL: location,
            modelName: server,
            server: server,
            searchTarget: searchTarget,
            usn: usn,
            isLGWebOS: isLGWebOS
        )
    }

    /// Filters SSDP replies to TVs and known streamers — skips printers and unrelated UPnP gear.
    nonisolated static func isRelevantSSDPDevice(
        server: String?,
        searchTarget: String?,
        usn: String?
    ) -> Bool {
        let corpus = [server, searchTarget, usn]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if corpus.contains("webos") || corpus.contains("lge") || corpus.contains(" lg") {
            return true
        }
        if corpus.contains("roku") || corpus.contains("samsung") || corpus.contains("tizen") {
            return true
        }
        if corpus.contains("mediarenderer") || corpus.contains("mediaserver") {
            return true
        }
        if let searchTarget {
            let st = searchTarget.lowercased()
            if st == "ssdp:all" || st == "upnp:rootdevice" {
                return true
            }
        }
        return false
    }

    nonisolated static func isLGWebOSDevice(
        server: String?,
        searchTarget: String?,
        usn: String?
    ) -> Bool {
        let corpus = [server, searchTarget, usn]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        return corpus.contains("webos")
            || corpus.contains("lge-com")
            || corpus.contains("lge")
    }

    /// Builds a human-friendly LG label such as "Living Room LG TV" once UPnP friendlyName is known.
    nonisolated static func lgDisplayName(
        friendlyName: String?,
        server: String?,
        usn: String?,
        address: String,
        isLGWebOS: Bool
    ) -> String {
        if let friendlyName = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !friendlyName.isEmpty,
           !looksLikeHardwareID(friendlyName) {
            let lower = friendlyName.lowercased()
            if lower.contains("lg") || lower.contains("webos") {
                return friendlyName
            }
            return "\(friendlyName) LG TV"
        }

        if isLGWebOS {
            return "LG webOS TV"
        }

        let rawName = server ?? usn ?? address
        return displayName(txtRecord: [:], serviceInstanceName: rawName, address: address)
    }
}

/// Parsed SSDP M-SEARCH reply — IP from LOCATION, identity from SERVER/ST/USN.
struct SSDPParsedDevice: Sendable {
    var name: String
    let address: String
    let locationURL: String
    let modelName: String?
    let server: String?
    let searchTarget: String?
    let usn: String?
    let isLGWebOS: Bool
}

/// NWEndpoint is not Sendable; this wrapper lets us cross into MainActor tasks safely
/// after extracting data on the browser callback queue.
private struct SendableEndpoint: @unchecked Sendable {
    let endpoint: NWEndpoint
}

/// Sendable snapshot of a Bonjour browse delta — built on the browser queue, consumed on MainActor.
private struct BonjourBrowseEvent: Sendable {
    enum Kind: Sendable {
        case added
        case changed
        case removed
    }

    let kind: Kind
    let endpoint: SendableEndpoint
    let txtRecord: [String: String]
    let serviceInstanceName: String
}

private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var resumed = false
    private let continuation: CheckedContinuation<T, Never>

    nonisolated init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    nonisolated func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

// MARK: - UniversalTVBrowser

/// Runs parallel Bonjour browsers plus SSDP multicast discovery.
///
/// All mutable UI state is confined to the main actor. Network callbacks only parse
/// raw packets on background queues, then hop back via `Task { @MainActor in … }`.
@MainActor
@Observable
final class UniversalTVBrowser {

    // MARK: Published State

    private(set) var discoveredDevices: [UniversalTVDevice] = []
    private(set) var isScanning = false
    private(set) var lastError: String?

    /// Optional callback for hosts that prefer delegation over Observation.
    var onDevicesUpdated: (@MainActor ([UniversalTVDevice]) -> Void)?

    // MARK: Private

    private let registry = DiscoveryRegistry()
    private let resolver = EndpointResolver()

    private var browsers: [NWBrowser] = []
    private var ssdpListener: NWListener?
    private var ssdpTask: Task<Void, Never>?
    private var streamContinuations: [UUID: AsyncStream<[UniversalTVDevice]>.Continuation] = [:]

    /// Serializes browse/SSDP ingest so registry snapshots publish in order.
    private var discoveryPipeline: Task<Void, Never>?

    /// Weak back-reference for SSDP receive loops that cannot capture `self` on background queues.
    nonisolated(unsafe) private static weak var ssdpDeliveryTarget: UniversalTVBrowser?

    private static let bonjourProtocols: [TVDiscoveryProtocol] = [
        .airPlay, .mediaRemoteTV, .googleCast, .dlna, .ssdp
    ]

    private static let ssdpMulticastHost = "239.255.255.250"
    private static let ssdpPort: UInt16 = 1900
    private static let ssdpProbeInterval: TimeInterval = 3

    /// M-SEARCH `ST` headers — includes LG webOS second-screen and UPnP media targets.
    private static let ssdpSearchTargets = [
        "ssdp:all",
        "upnp:rootdevice",
        "urn:schemas-upnp-org:device:MediaServer:1",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:lge-com:service:webos-second-screen:1"
    ]

    private let ssdpLocationResolver = SSDPLocationResolver()

    // MARK: Public API

    /// Starts all Bonjour browsers and the SSDP multicast probe simultaneously.
    func startDiscovery() {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        Self.ssdpDeliveryTarget = self

        startBonjourBrowsers()
        startSSDPDiscovery()
    }

    /// Stops every active browser and SSDP listener.
    func stopDiscovery() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()

        ssdpTask?.cancel()
        ssdpTask = nil
        discoveryPipeline?.cancel()
        discoveryPipeline = nil

        ssdpListener?.cancel()
        ssdpListener = nil

        if Self.ssdpDeliveryTarget === self {
            Self.ssdpDeliveryTarget = nil
        }

        isScanning = false
    }

    /// Async stream that emits whenever the unified device list changes.
    func deviceUpdates() -> AsyncStream<[UniversalTVDevice]> {
        AsyncStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let token = UUID()
                streamContinuations[token] = continuation
                continuation.yield(discoveredDevices)
                continuation.onTermination = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.streamContinuations.removeValue(forKey: token)
                    }
                }
            }
        }
    }

    // MARK: Bonjour (NWBrowser)

    private func startBonjourBrowsers() {
        for protocolKind in Self.bonjourProtocols {
            guard let serviceType = protocolKind.bonjourType else { continue }

            // Each browser needs its own parameters instance.
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: parameters)

            browser.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor [weak self] in
                        self?.lastError = error.localizedDescription
                    }
                }
            }

            browser.browseResultsChangedHandler = { [weak self] _, changes in
                let events = Self.snapshotBrowseEvents(changes)
                guard !events.isEmpty else { return }

                Task { @MainActor [weak self] in
                    await self?.enqueueBrowseEvents(events, protocolKind: protocolKind)
                }
            }

            browsers.append(browser)
            browser.start(queue: DiscoveryDispatch.bonjour)
        }
    }

    /// Extract Sendable snapshots on the browser queue before any MainActor hop.
    nonisolated private static func snapshotBrowseEvents(
        _ changes: Set<NWBrowser.Result.Change>
    ) -> [BonjourBrowseEvent] {
        changes.compactMap { change in
            switch change {
            case .added(let result):
                BonjourBrowseEvent(
                    kind: .added,
                    endpoint: SendableEndpoint(endpoint: result.endpoint),
                    txtRecord: DiscoveryFormatting.txtRecord(from: result.metadata),
                    serviceInstanceName: DiscoveryFormatting.serviceInstanceName(from: result.endpoint)
                )
            case .changed(_, let result, _):
                BonjourBrowseEvent(
                    kind: .changed,
                    endpoint: SendableEndpoint(endpoint: result.endpoint),
                    txtRecord: DiscoveryFormatting.txtRecord(from: result.metadata),
                    serviceInstanceName: DiscoveryFormatting.serviceInstanceName(from: result.endpoint)
                )
            case .removed(let result):
                BonjourBrowseEvent(
                    kind: .removed,
                    endpoint: SendableEndpoint(endpoint: result.endpoint),
                    txtRecord: DiscoveryFormatting.txtRecord(from: result.metadata),
                    serviceInstanceName: DiscoveryFormatting.serviceInstanceName(from: result.endpoint)
                )
            case .identical:
                nil
            @unknown default:
                nil
            }
        }
    }

    private func enqueueBrowseEvents(
        _ events: [BonjourBrowseEvent],
        protocolKind: TVDiscoveryProtocol
    ) async {
        let previous = discoveryPipeline
        discoveryPipeline = Task { @MainActor in
            await previous?.value
            for event in events {
                switch event.kind {
                case .added, .changed:
                    await ingestBonjourEndpoint(
                        event.endpoint.endpoint,
                        txtRecord: event.txtRecord,
                        serviceInstanceName: event.serviceInstanceName,
                        protocolKind: protocolKind
                    )
                case .removed:
                    // Skip TCP resolution on removal — it spams NW cancel / NECP warnings.
                    break
                }
            }
        }
    }

    private func ingestBonjourEndpoint(
        _ endpoint: NWEndpoint,
        txtRecord: [String: String],
        serviceInstanceName: String,
        protocolKind: TVDiscoveryProtocol
    ) async {
        guard !DiscoveryFormatting.isLikelyAudioOnlyDevice(
            txtRecord: txtRecord,
            serviceInstanceName: serviceInstanceName,
            protocolKind: protocolKind
        ) else {
            return
        }

        guard let address = await resolveAddress(from: endpoint) else { return }

        let displayName = DiscoveryFormatting.displayName(
            txtRecord: txtRecord,
            serviceInstanceName: serviceInstanceName,
            address: address
        )
        let modelName = DiscoveryFormatting.txtValue(txtRecord, key: "md")
        let lowerName = displayName.lowercased()
        let lgProtocolType: TVProtocolType? = {
            guard lowerName.contains("lg") || lowerName.contains("webos") else { return nil }
            return lowerName.contains("webos") ? .webOS : nil
        }()

        let devices = await registry.upsert(
            name: displayName,
            address: address,
            modelName: modelName.isEmpty ? nil : modelName,
            protocol: protocolKind,
            lgProtocolType: lgProtocolType
        )
        publish(devices)
    }

    private func resolveAddress(from endpoint: NWEndpoint) async -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            return DiscoveryFormatting.sanitizeHost("\(host)")
        case .service:
            return await resolver.resolve(endpoint: endpoint)
        default:
            return nil
        }
    }

    // MARK: SSDP (UDP Multicast)

    private func startSSDPDiscovery() {
        ssdpTask?.cancel()
        ssdpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSSDPMulticastProbe()
        }
    }

    private func runSSDPMulticastProbe() async {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        guard let listener = try? NWListener(using: parameters, on: .any) else {
            lastError = "SSDP listener could not bind."
            return
        }

        ssdpListener = listener

        listener.newConnectionHandler = { connection in
            connection.start(queue: DiscoveryDispatch.ssdp)
            Self.beginSSDPReceiveLoop(on: connection)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce = OnceContinuation(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor [weak self] in
                        self?.sendSSDPMSearchBurst()
                    }
                    resumeOnce.resume(returning: ())
                case .failed:
                    resumeOnce.resume(returning: ())
                default:
                    break
                }
            }
            listener.start(queue: DiscoveryDispatch.ssdp)
        }

        // Keep shouting on the multicast address while the app session is scanning.
        while !Task.isCancelled, isScanning {
            try? await Task.sleep(for: .seconds(Self.ssdpProbeInterval))
            guard !Task.isCancelled, isScanning else { break }
            sendSSDPMSearchBurst()
        }
    }

    /// Broadcasts M-SEARCH to 239.255.255.250:1900 for each LG / UPnP search target.
    private func sendSSDPMSearchBurst() {
        for target in Self.ssdpSearchTargets {
            sendSSDPMSearch(searchTarget: target)
        }
    }

    private func sendSSDPMSearch(searchTarget: String) {
        let payload = """
        M-SEARCH * HTTP/1.1\r
        HOST: \(Self.ssdpMulticastHost):\(Self.ssdpPort)\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: \(searchTarget)\r
        USER-AGENT: ZAPRemote/1.0 UPnP/1.1\r
        \r
        """

        guard let data = payload.data(using: .utf8),
              let port = NWEndpoint.Port(rawValue: Self.ssdpPort) else { return }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(Self.ssdpMulticastHost), port: port)
        let connection = NWConnection(to: endpoint, using: .udp)

        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        connection.start(queue: DiscoveryDispatch.ssdp)
    }

    /// Receive loop runs entirely on `DiscoveryDispatch.ssdp` — no MainActor state touched.
    nonisolated private static func beginSSDPReceiveLoop(on connection: NWConnection) {
        connection.receiveMessage { content, _, _, error in
            if let content,
               let text = String(data: content, encoding: .utf8),
               let parsed = DiscoveryFormatting.parseSSDPResponse(text) {
                Task { @MainActor in
                    await Self.ssdpDeliveryTarget?.enqueueSSDPResult(parsed)
                }
            }

            if error == nil {
                beginSSDPReceiveLoop(on: connection)
            }
        }
    }

    private func enqueueSSDPResult(_ device: SSDPParsedDevice) async {
        var resolved = device

        if device.isLGWebOS,
           let friendlyName = await ssdpLocationResolver.fetchFriendlyName(locationURL: device.locationURL) {
            resolved.name = DiscoveryFormatting.lgDisplayName(
                friendlyName: friendlyName,
                server: device.server,
                usn: device.usn,
                address: device.address,
                isLGWebOS: true
            )
        }

        let previous = discoveryPipeline
        discoveryPipeline = Task { @MainActor in
            await previous?.value
            let corpus = [resolved.server, resolved.searchTarget, resolved.usn]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            let isLG = corpus.contains("webos") || corpus.contains("lge") || corpus.contains(" lg")
            let lgProtocolType: TVProtocolType? = isLG
                ? (resolved.isLGWebOS ? .webOS : .netcast)
                : nil
            let devices = await registry.upsert(
                name: resolved.name,
                address: resolved.address,
                modelName: resolved.modelName,
                protocol: .ssdp,
                lgProtocolType: lgProtocolType
            )
            publish(devices)
        }
    }

    // MARK: Publish

    /// Updates the observable device list. Must run on the main actor.
    private func publish(_ devices: [UniversalTVDevice]) {
        discoveredDevices = devices
        onDevicesUpdated?(devices)
        streamContinuations.values.forEach { $0.yield(devices) }
    }
}

// MARK: - Discovery Registry (Actor)

/// Thread-safe deduplication keyed by normalized IP / hostname.
actor DiscoveryRegistry {

    private var devices: [String: UniversalTVDevice] = [:]

    func upsert(
        name: String,
        address: String,
        modelName: String?,
        protocol protocolKind: TVDiscoveryProtocol,
        lgProtocolType: TVProtocolType? = nil
    ) -> [UniversalTVDevice] {
        let key = Self.normalizedKey(address)
        guard !key.isEmpty else { return sortedSnapshot() }

        if var existing = devices[key] {
            existing.protocols.insert(protocolKind)
            if DiscoveryFormatting.isBetterDisplayName(name, than: existing.name) {
                existing.name = name
            }
            if let modelName, !modelName.isEmpty {
                existing.modelName = existing.modelName ?? modelName
            }
            if let lgProtocolType {
                if lgProtocolType == .webOS || existing.lgProtocolType == nil {
                    existing.lgProtocolType = lgProtocolType
                }
            }
            devices[key] = existing
        } else {
            devices[key] = UniversalTVDevice(
                id: key,
                name: name,
                address: address,
                modelName: modelName,
                protocols: [protocolKind],
                lgProtocolType: lgProtocolType
            )
        }

        return sortedSnapshot()
    }

    func remove(key: String) -> [UniversalTVDevice] {
        devices.removeValue(forKey: key)
        return sortedSnapshot()
    }

    static func normalizedKey(_ address: String) -> String {
        address
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    private func sortedSnapshot() -> [UniversalTVDevice] {
        devices.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Endpoint Resolver (Actor)

/// Resolves Bonjour service endpoints to a host string — only reads path data in `.ready`.
actor EndpointResolver {

    func resolve(endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let resumeOnce = OnceContinuation(continuation)
            let lifecycle = ResolverConnectionLifecycle()

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let connection = NWConnection(to: endpoint, using: parameters)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let resolved: String?
                    if let remote = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = remote {
                        resolved = DiscoveryFormatting.sanitizeHost("\(host)")
                    } else {
                        resolved = nil
                    }
                    lifecycle.finish(connection: connection) {
                        resumeOnce.resume(returning: resolved)
                    }

                case .failed, .cancelled:
                    lifecycle.finish(connection: connection) {
                        resumeOnce.resume(returning: nil)
                    }

                default:
                    break
                }
            }

            connection.start(queue: DiscoveryDispatch.resolver)
        }
    }
}

/// Ensures each resolver connection is cancelled at most once.
private final class ResolverConnectionLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(connection: NWConnection, completion: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        completion()
        connection.cancel()
    }
}

// MARK: - SSDP Location Resolver (Actor)

/// Fetches the UPnP device description at the SSDP LOCATION URL to read `<friendlyName>`.
actor SSDPLocationResolver {

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        session = URLSession(configuration: configuration)
    }

    func fetchFriendlyName(locationURL: String) async -> String? {
        guard let baseURL = URL(string: locationURL) else { return nil }

        if let name = await fetchFriendlyName(from: baseURL) {
            return name
        }

        // Some LG TVs expose description.xml beside the LOCATION root.
        if let descriptionURL = URL(string: "description.xml", relativeTo: baseURL) {
            return await fetchFriendlyName(from: descriptionURL)
        }

        return nil
    }

    private func fetchFriendlyName(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8) else {
            return nil
        }

        return Self.parseFriendlyName(fromXML: xml)
    }

    private static func parseFriendlyName(fromXML xml: String) -> String? {
        let patterns = [
            "<friendlyName>(.*?)</friendlyName>",
            "<FriendlyName>(.*?)</FriendlyName>"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(match.range(at: 1), in: xml) else {
                continue
            }

            let value = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }
}
