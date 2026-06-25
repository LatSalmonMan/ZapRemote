//
//  RemoteView.swift
//  ZapRemote
//
//  Home — glanceable automation status, TV connection, and manual overrides.
//

import SwiftUI
import UIKit

// MARK: - Home Session State

private enum HomeSessionState: Equatable {
    case needsTV
    case pairingTV
    case needsGame
    case waitingForKickoff
    case needsLagSync
    case watchingLive
    case commercialBreak
    case attention(String)

    var heroTitle: String {
        switch self {
        case .needsTV: "Connect your TV"
        case .pairingTV: "Approve on your TV"
        case .needsGame: "Choose tonight's game"
        case .waitingForKickoff: "Waiting for kickoff"
        case .needsLagSync: "Set TV delay"
        case .watchingLive: "Hands-free armed"
        case .commercialBreak: "Skipping to highlights"
        case .attention(let message): message
        }
    }

    var heroSubtitle: String {
        switch self {
        case .needsTV:
            "Tap your LG TV below — same Wi‑Fi as your phone."
        case .pairingTV:
            "Accept the pairing prompt on the TV screen."
        case .needsGame:
            "Search ESPN for the game you're watching on TV."
        case .waitingForKickoff:
            "Clock starts at 00:00 when the ball is in play on your TV."
        case .needsLagSync:
            "Tap + or − until your TV clock matches."
        case .watchingLive:
            "Tap Ad on my TV when commercials start."
        case .commercialBreak:
            "Watching highlight — Go Live in ~45s."
        case .attention:
            "Check connection and try again."
        }
    }

    var badgeLabel: String? {
        switch self {
        case .watchingLive: "LIVE"
        case .commercialBreak: "BREAK"
        default: nil
        }
    }
}

struct RemoteView: View {

    @ObservedObject var tvController: TVController
    @ObservedObject var sportsAPIService: SportsAPIService
    @ObservedObject var adEventService: AdEventService
    var onChooseTV: () -> Void
    var onResetTV: (() -> Void)? = nil

    @AppStorage(SettingsStorageKey.defaultStreamingService)
    private var defaultStreamingServiceRaw = StreamingServicePreference.youtubeTV.rawValue

    @State private var isExplainerPresented = false
    @State private var isGameSearchPresented = false
    @State private var isClockSyncPresented = false

    private let theme = AppTheme.premium

    private var streamingService: StreamingServicePreference {
        StreamingServicePreference.from(appStorageRawValue: defaultStreamingServiceRaw)
    }

    private var deviceName: String? {
        tvController.selectedTV?.listRowTitle ?? tvController.activeDeviceName
    }

    private var sessionState: HomeSessionState {
        if let error = tvController.lastErrorMessage {
            return .attention(error)
        }
        if sportsAPIService.monitoringStatus == .error {
            return .attention("ESPN feed interrupted")
        }
        if tvController.isConnecting {
            return .pairingTV
        }
        if !tvController.isConnected {
            return .needsTV
        }
        if !sportsAPIService.hasMonitoredGame {
            return .needsGame
        }
        if sportsAPIService.isReplayOffsetMode, !sportsAPIService.hasSyncedStreamLag {
            return .needsLagSync
        }
        if sportsAPIService.isTrackedGameLive, !sportsAPIService.isMatchPhysicallyActive {
            return .waitingForKickoff
        }
        if !sportsAPIService.hasSyncedStreamLag {
            return .needsLagSync
        }
        if sportsAPIService.isBreakActive {
            return .commercialBreak
        }
        return .watchingLive
    }

    private var heroSubtitleText: String {
        switch sessionState {
        case .watchingLive where sportsAPIService.isHandsFreeAutomationEnabled:
            return "Hands-free ON — halftime & TV timeouts auto-skip to ESPN highlights."
        case .needsLagSync where sportsAPIService.isReplayOffsetMode:
            return "Set how many seconds your replay is behind ESPN (+1 min, +10s, etc.)."
        case .needsLagSync:
            return "ESPN ticks from 00:00 — add seconds until the TV line matches your screen."
        case .waitingForKickoff:
            return sessionState.heroSubtitle
        default:
            return sessionState.heroSubtitle
        }
    }

    private var statusFootnote: String? {
        if tvController.isMacroRunning || tvController.isExecutingMacro {
            return "Skipping on TV… keep \(streamingService.rawValue) in the foreground (~10s lock)."
        }
        if let summary = meaningfulStatusSummary {
            return summary
        }
        if !tvController.statusMessage.isEmpty,
           tvController.statusMessage != "Disconnected",
           !tvController.statusMessage.hasPrefix("Remote ready") {
            return tvController.statusMessage
        }
        return nil
    }

    /// Avoid flashing ESPN poll noise ("In progress — …") on every 4s tick.
    private var meaningfulStatusSummary: String? {
        let summary = sportsAPIService.lastStatusSummary
        guard !summary.isEmpty, summary != "ESPN polling stopped" else { return nil }
        if summary.hasPrefix("In progress —") { return nil }
        if summary.hasPrefix("Polling ESPN game") { return nil }
        if summary == "Awaiting ESPN polling start" { return nil }
        return summary
    }

    private var statusFootnoteIsWarning: Bool {
        let text = statusFootnote?.lowercased() ?? ""
        return text.contains("failed")
            || text.contains("blocked")
            || text.contains("connect")
            || text.contains("open youtube")
            || text.contains("hasn't started")
            || text.contains("test skip")
    }

    private var rewindStickerPhase: RewindStickerPhase? {
        if tvController.isReturningToLive {
            return .returningToLive
        }
        if tvController.isMacroRunning || tvController.isExecutingMacro {
            return .rewinding
        }
        if sportsAPIService.pendingAutoGoLive || sportsAPIService.isCommercialBreakLoopActive {
            let current = sportsAPIService.commercialBreakHighlightIndex
            let total = sportsAPIService.commercialBreakPlaylist.count
            if total > 1, current > 0 {
                return .watchingHighlight(current: current, total: total)
            }
            return .watchingHighlight(current: nil, total: nil)
        }
        if sportsAPIService.isBreakActive, !sportsAPIService.isCommercialBreakLoopActive {
            return .rewinding
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            CouchModeScreenBackground(theme: theme, streamingAccent: streamingService.accent)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    HomeConnectionCard(
                        theme: theme,
                        streamingService: streamingService,
                        deviceName: deviceName,
                        isConnected: tvController.isConnected,
                        isConnecting: tvController.isConnecting,
                        connectionDetail: tvController.connectionStatusHeadline,
                        cloudLabel: adEventService.bridgeStatus.displayLabel,
                        onChooseTV: onChooseTV,
                        onResetTV: onResetTV
                    )

                    TimelineView(.periodic(from: sportsAPIService.matchClockTickAnchor ?? Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), by: 1)) { timeline in
                        let now = timeline.date
                        HomeHeroCard(
                            theme: theme,
                            state: sessionState,
                            subtitle: heroSubtitleText,
                            streamingService: streamingService,
                            streamDelayLabel: sportsAPIService.streamDelayOffsetLabel,
                            trackedGameLabel: sportsAPIService.monitoredGameLabel,
                            highlightRank: sportsAPIService.selectedHighlightRank,
                            plannedRewindSeconds: sportsAPIService.lastPlannedRewindSeconds,
                            espnLiveClockLabel: sportsAPIService.espnLiveClockDisplay(at: now)
                                ?? sportsAPIService.liveGameClockLabel,
                            syncedGameClockLabel: sportsAPIService.uiGameClockDisplay(at: now),
                            isReplayMode: sportsAPIService.isReplayOffsetMode,
                            onChangeGame: { isGameSearchPresented = true }
                        )
                    }

                        HomeControlDeck(
                        theme: theme,
                        isTVConnected: tvController.isConnected,
                        isMacroRunning: tvController.isMacroRunning,
                        showSyncLag: sportsAPIService.hasMonitoredGame,
                        syncLagTitle: sportsAPIService.isReplayOffsetMode ? "TV Delay" : "Match Clock",
                        syncLagIcon: sportsAPIService.isReplayOffsetMode ? "timer" : "clock.badge.checkmark",
                        showChooseGame: sessionState == .needsGame,
                        onChooseGame: { isGameSearchPresented = true },
                        onSyncLag: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            isClockSyncPresented = true
                        },
                        onGoLive: handleGoLive,
                        onBack: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            _ = tvController.sendRemoteKey(.menu)
                        },
                        onAdOnTV: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            Task { await sportsAPIService.skipAdToHighlights() }
                        }
                    )

                    if let statusFootnote {
                        Text(statusFootnote)
                            .font(.caption)
                            .foregroundStyle(statusFootnoteIsWarning ? .orange.opacity(0.9) : .white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .animation(nil, value: statusFootnote)
                    }

                    Button {
                        isExplainerPresented = true
                    } label: {
                        Label("How it works", systemImage: "info.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }

            if let phase = rewindStickerPhase {
                RewindFlowSticker(phase: phase, theme: theme)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: rewindStickerPhase)
        .sheet(isPresented: $isGameSearchPresented) {
            GameSearchSheet(sportsAPIService: sportsAPIService)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isClockSyncPresented) {
            NavigationStack {
                ZStack {
                    CouchModeScreenBackground(theme: theme, streamingAccent: streamingService.accent)
                    ScrollView {
                        TimelineSyncView(
                            apiService: sportsAPIService,
                            theme: theme,
                            showsResyncButton: true
                        )
                        .padding(20)
                    }
                }
                .navigationTitle(sportsAPIService.isReplayOffsetMode ? "TV Delay" : "Match Clock")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isClockSyncPresented = false }
                            .foregroundStyle(theme.accentPrimary)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isExplainerPresented) {
            NavigationStack {
                AutomaticRewindExplainerView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isExplainerPresented = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .syncStreamingServicePreference(
            tvController: tvController,
            storageRawValue: defaultStreamingServiceRaw
        )
    }

    private func handleGoLive() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard tvController.isConnected else { return }

        if tvController.isMacroRunning || tvController.isExecutingMacro {
            tvController.cancelActiveMacro()
            tvController.statusMessage = "Stopped skip — returning to live…"
        }

        sportsAPIService.clearBreakForManualGoLive()
        Task { await tvController.executeGoLiveMacro() }
    }
}

// MARK: - Rewind Sticker

private enum RewindStickerPhase: Equatable {
    case rewinding
    case watchingHighlight(current: Int?, total: Int?)
    case returningToLive

    var icon: String {
        switch self {
        case .rewinding: "backward.fill"
        case .watchingHighlight: "play.fill"
        case .returningToLive: "forward.end.fill"
        }
    }

    var label: String {
        switch self {
        case .rewinding:
            return "Rewinding"
        case .watchingHighlight(let current, let total):
            if let current, let total, total > 1 {
                return "Highlight \(current)/\(total)"
            }
            return "Highlight"
        case .returningToLive:
            return "Back to live"
        }
    }
}

private struct RewindFlowSticker: View {
    let phase: RewindStickerPhase
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: phase.icon)
                .font(.caption.weight(.black))
            Text(phase.label)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.black.opacity(0.86))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(theme.accentPrimary)
                .shadow(color: theme.accentPrimary.opacity(0.5), radius: 10, y: 4)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Connection Card

private struct HomeConnectionCard: View {
    let theme: AppTheme
    let streamingService: StreamingServicePreference
    let deviceName: String?
    let isConnected: Bool
    var isConnecting: Bool = false
    let connectionDetail: String
    let cloudLabel: String
    let onChooseTV: () -> Void
    var onResetTV: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onChooseTV) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(isConnected ? theme.accentPrimary : Color.white.opacity(0.25))
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(deviceName ?? "Choose TV")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))

                            Text(connectionDetail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.30))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let onResetTV, !isConnected || isConnecting {
                    Button(action: onResetTV) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset TV connection")
                }
            }

            HStack(spacing: 8) {
                statusChip(
                    label: isConnected ? "TV online" : (isConnecting ? "Pairing" : "TV offline"),
                    color: isConnected ? theme.accentPrimary : (isConnecting ? .orange : .white.opacity(0.35))
                )
                statusChip(label: streamingService.rawValue, color: streamingService.accent.opacity(0.85))
                statusChip(label: cloudLabel, color: .white.opacity(0.40))
            }
        }
        .padding(14)
        .premiumCardStyle(theme: theme, cornerRadius: 16, isActive: isConnected)
    }

    private func statusChip(label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.80))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.22)))
    }
}

// MARK: - Hero

private struct HomeHeroCard: View {
    let theme: AppTheme
    let state: HomeSessionState
    let subtitle: String
    let streamingService: StreamingServicePreference
    let streamDelayLabel: String
    var trackedGameLabel: String = ""
    var highlightRank: Int = 0
    var plannedRewindSeconds: Int = 0
    var espnLiveClockLabel: String = "—"
    var syncedGameClockLabel: String = "—"
    var isReplayMode: Bool = false
    var onChangeGame: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            if let badge = state.badgeLabel {
                Text(badge)
                    .font(.caption.weight(.black))
                    .foregroundStyle(state == .commercialBreak ? .black : .white.opacity(0.90))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(state == .commercialBreak ? theme.accentPrimary : Color.white.opacity(0.14))
                    )
            } else {
                heroIcon
            }

            VStack(spacing: 6) {
                Text(state.heroTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(theme.accentPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.50))
                    .multilineTextAlignment(.center)
            }

            Button {
                onChangeGame?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sportscourt")
                        .font(.caption.weight(.semibold))
                    Text(trackedGameLabel.isEmpty ? "Choose game" : trackedGameLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white.opacity(0.60))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if state == .watchingLive || state == .commercialBreak || state == .needsLagSync || state == .waitingForKickoff {
                HStack(spacing: 20) {
                    if state == .waitingForKickoff {
                        heroFact(label: "Match clock", value: syncedGameClockLabel)
                    }
                    if state == .needsLagSync {
                        if isReplayMode {
                            heroFact(label: "TV offset", value: streamDelayLabel)
                        } else {
                            if espnLiveClockLabel != "—", espnLiveClockLabel != "Replay" {
                                heroFact(label: "ESPN", value: espnLiveClockLabel)
                            }
                            heroFact(label: "Your TV", value: syncedGameClockLabel)
                            heroFact(label: "Offset", value: streamDelayLabel)
                        }
                    }
                    if state == .watchingLive || state == .commercialBreak {
                        if isReplayMode {
                            heroFact(label: "TV offset", value: streamDelayLabel)
                        } else {
                            heroFact(label: "TV clock", value: syncedGameClockLabel)
                            heroFact(label: "Offset", value: streamDelayLabel)
                        }
                    }
                    if highlightRank > 0, state != .needsLagSync {
                        heroFact(label: "Rank", value: rankDisplay(highlightRank))
                    }
                    if plannedRewindSeconds > 0, state != .needsLagSync {
                        heroFact(label: "Skip", value: "\(plannedRewindSeconds)s")
                    }
                }
                .animation(nil, value: plannedRewindSeconds)
                .animation(nil, value: highlightRank)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .premiumCardStyle(
            theme: theme,
            cornerRadius: 20,
            isActive: state == .commercialBreak || state == .watchingLive
        )
    }

    @ViewBuilder
    private var heroIcon: some View {
        switch state {
        case .needsTV:
            Image(systemName: "tv")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(theme.accentSecondary)
        case .needsLagSync:
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(theme.accentPrimary)
        case .waitingForKickoff:
            Image(systemName: "hourglass.circle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(theme.accentSecondary)
        case .needsGame:
            Image(systemName: "sportscourt")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(theme.accentSecondary)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.orange)
        default:
            Image(systemName: "play.tv.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.accentPrimary.opacity(0.85))
        }
    }

    private func heroFact(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private func rankDisplay(_ rank: Int) -> String {
        switch rank {
        case 3: "Max"
        case 2: "Med"
        default: "Low"
        }
    }
}

// MARK: - Controls

private struct HomeControlDeck: View {
    let theme: AppTheme
    let isTVConnected: Bool
    let isMacroRunning: Bool
    let showSyncLag: Bool
    let syncLagTitle: String
    let syncLagIcon: String
    let showChooseGame: Bool
    let onChooseGame: () -> Void
    let onSyncLag: () -> Void
    let onGoLive: () -> Void
    let onBack: () -> Void
    let onAdOnTV: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if showChooseGame {
                HomeControlButton(
                    title: "Choose Game",
                    systemImage: "sportscourt.fill",
                    theme: theme,
                    isPrimary: true,
                    isEnabled: true,
                    isWide: true,
                    action: onChooseGame
                )
            }

            if showSyncLag {
                HomeControlButton(
                    title: syncLagTitle,
                    systemImage: syncLagIcon,
                    theme: theme,
                    isPrimary: true,
                    isEnabled: isTVConnected,
                    isWide: true,
                    action: onSyncLag
                )
            }

            HomeControlButton(
                title: "Ad on my TV",
                systemImage: "tv.and.hifispeaker.fill",
                theme: theme,
                isPrimary: !showSyncLag && !showChooseGame,
                isEnabled: isTVConnected,
                isWide: true,
                action: onAdOnTV
            )

            HStack(spacing: 12) {
                HomeControlButton(
                    title: isMacroRunning ? "Stop" : "Go Live",
                    systemImage: isMacroRunning ? "stop.fill" : "dot.radiowaves.left.and.right",
                    theme: theme,
                    isPrimary: false,
                    isEnabled: isTVConnected,
                    action: onGoLive
                )

                HomeControlButton(
                    title: "Back",
                    systemImage: "arrow.uturn.backward",
                    theme: theme,
                    isPrimary: false,
                    isEnabled: isTVConnected,
                    action: onBack
                )
            }
        }
    }
}

private struct HomeControlButton: View {
    let title: String
    let systemImage: String
    let theme: AppTheme
    let isPrimary: Bool
    let isEnabled: Bool
    var isWide: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWide {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage)
                            .font(.headline.weight(.bold))
                        Text(title)
                            .font(.subheadline.weight(.bold))
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.bold))
                        Text(title)
                            .font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.35))
            .padding(isWide ? 16 : 16)
            .frame(maxWidth: .infinity, minHeight: isWide ? 52 : 72)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isPrimary
                            ? theme.accentPrimary.opacity(isEnabled ? 0.38 : 0.12)
                            : Color.white.opacity(isEnabled ? 0.10 : 0.05)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

#Preview {
    RemoteView(
        tvController: TVController(),
        sportsAPIService: SportsAPIService(),
        adEventService: AdEventService(),
        onChooseTV: {}
    )
}
