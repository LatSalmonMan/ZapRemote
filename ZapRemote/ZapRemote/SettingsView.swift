//
//  SettingsView.swift
//  ZapRemote
//
//  Account and configuration — premium-only $10/mo model.
//

import SwiftUI

enum StreamingServicePreference: String, CaseIterable, Identifiable {
    case youtubeTV = "YouTube TV"
    case huluLive = "Hulu Live"
    case peacock = "Peacock"
    case espnPlus = "ESPN+"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .youtubeTV: "play.tv.fill"
        case .huluLive: "tv.fill"
        case .peacock: "play.rectangle.fill"
        case .espnPlus: "sportscourt.fill"
        }
    }

    var accent: Color {
        switch self {
        case .youtubeTV: Color(red: 0.95, green: 0.18, blue: 0.16)
        case .huluLive: Color(red: 0.22, green: 0.86, blue: 0.44)
        case .peacock: Color(red: 0.35, green: 0.55, blue: 0.98)
        case .espnPlus: Color(red: 0.98, green: 0.72, blue: 0.18)
        }
    }

    var macroBehaviorNote: String {
        switch self {
        case .youtubeTV: "15s skip steps"
        case .huluLive, .peacock: "10s skip steps"
        case .espnPlus: "Skip timing not mapped yet"
        }
    }
}

struct SettingsView: View {

    @ObservedObject var tvController: TVController
    @ObservedObject var sportsAPIService: SportsAPIService
    @ObservedObject var adEventService: AdEventService

    @AppStorage(SettingsStorageKey.defaultStreamingService)
    private var defaultStreamingServiceRaw = StreamingServicePreference.youtubeTV.rawValue

    @State private var isCheckoutSheetPresented = false
    @State private var isGameSearchPresented = false
    @State private var isCloudExpanded = false

    #if DEBUG
    @State private var isDebugExpanded = false
    #endif

    @Environment(\.openURL) private var openURL

    private let theme = AppTheme.premium

    private var selectedStreamingService: StreamingServicePreference {
        get { StreamingServicePreference(rawValue: defaultStreamingServiceRaw) ?? .youtubeTV }
        nonmutating set { defaultStreamingServiceRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CouchModeScreenBackground(theme: theme, streamingAccent: selectedStreamingService.accent)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        gameNightSection
                        timelineSyncSection
                        tvSection
                        automationSection
                        cloudSection
                        premiumSection
                        supportSection
                        #if DEBUG
                        debugSection
                        #endif
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isCheckoutSheetPresented) {
                PremiumCheckoutSheet()
            }
            .sheet(isPresented: $isGameSearchPresented) {
                GameSearchSheet(sportsAPIService: sportsAPIService)
                    .preferredColorScheme(.dark)
            }
            .syncStreamingServicePreference(
                tvController: tvController,
                storageRawValue: defaultStreamingServiceRaw
            )
        }
    }

    // MARK: - Sections

    private var gameNightSection: some View {
        SettingsCard(theme: theme, title: "Game Night", icon: "sportscourt") {
            VStack(spacing: 14) {
                streamingPicker

                Button {
                    isGameSearchPresented = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedStreamingService.accent.opacity(0.18))
                                .frame(width: 40, height: 40)
                            Image(systemName: "sportscourt.fill")
                                .foregroundStyle(selectedStreamingService.accent)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(sportsAPIService.monitoredGameLabel.isEmpty ? "Find tonight's game" : sportsAPIService.monitoredGameLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .multilineTextAlignment(.leading)
                            Text(sportsAPIService.monitoringStatus.displayLabel)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.42))
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var streamingPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Streaming on TV")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StreamingServicePreference.allCases) { service in
                        Button {
                            selectedStreamingService = service
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: service.iconName)
                                    .font(.caption.weight(.semibold))
                                Text(service.rawValue)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(
                                selectedStreamingService == service
                                    ? .white
                                    : .white.opacity(0.55)
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(
                                        selectedStreamingService == service
                                            ? service.accent.opacity(0.55)
                                            : Color.white.opacity(0.07)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(selectedStreamingService.macroBehaviorNote)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.32))
        }
    }

    private var timelineSyncSection: some View {
        SettingsCard(
            theme: theme,
            title: sportsAPIService.isReplayOffsetMode ? "TV Delay" : "Match Clock",
            icon: sportsAPIService.isReplayOffsetMode ? "timer" : "clock.badge.checkmark"
        ) {
            TimelineSyncView(
                apiService: sportsAPIService,
                theme: theme,
                showsResyncButton: true
            )
        }
    }

    private var tvSection: some View {
        SettingsCard(theme: theme, title: "TV", icon: "tv.fill") {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(tvController.isConnected ? theme.accentPrimary : Color.white.opacity(0.22))
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(tvController.isConnected ? "Connected" : "Not connected")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.90))
                        Text(tvController.connectionStatusHeadline)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.42))
                    }

                    Spacer()

                    if tvController.isConnected {
                        Button("Test alert") {
                            Task { await tvController.sendTestTVNotification() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accentPrimary)
                    }
                }

                Button(role: .destructive) {
                    Task { await tvController.resetTVConnection() }
                } label: {
                    Label("Reset TV connection", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var automationSection: some View {
        SettingsCard(theme: theme, title: "Automation", icon: "bolt.fill") {
            VStack(spacing: 16) {
                SettingsToggleRow(
                    title: "Hands-free ad skip",
                    subtitle: "ESPN stoppage or cloud detector → highlights → Go Live",
                    isOn: $sportsAPIService.isHandsFreeAutomationEnabled
                )

                Divider().overlay(Color.white.opacity(0.08))

                SettingsToggleRow(
                    title: "Auto Go Live",
                    subtitle: "Return to live ~45s after each highlight",
                    isOn: $sportsAPIService.autoReturnToLiveAfterHighlight
                )
            }
        }
    }

    private var cloudSection: some View {
        SettingsCard(theme: theme, title: "Cloud Detector", icon: "waveform", isCollapsible: true, isExpanded: $isCloudExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Optional Mac bridge for broadcast ad cues")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.40))

                TextField("ws://192.168.x.x:8787", text: $adEventService.cloudWebSocketURLString)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                HStack {
                    Text(adEventService.bridgeStatus.displayLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    if adEventService.hasConfiguredDetectorURL {
                        Button(adEventService.bridgeStatus == .connected ? "Reconnect" : "Connect") {
                            adEventService.stopListening()
                            adEventService.startListening()
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.accentPrimary)
                    }
                }
            }
        }
    }

    private var premiumSection: some View {
        PremiumSubscriptionCard(
            theme: theme,
            onActivate: { isCheckoutSheetPresented = true },
            onManage: openStripeBillingPortal
        )
    }

    private var supportSection: some View {
        SettingsCard(theme: theme, title: "Help", icon: "questionmark.circle") {
            NavigationLink {
                AutomaticRewindExplainerView()
            } label: {
                Label("How automatic rewind works", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        SettingsCard(theme: theme, title: "Developer", icon: "hammer.fill", isCollapsible: true, isExpanded: $isDebugExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("ESPN game ID", text: $sportsAPIService.monitoredGameID)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Restart ESPN polling") {
                    sportsAPIService.stopGamePolling()
                    sportsAPIService.startGamePolling()
                }
                .font(.caption.weight(.semibold))

                Button("Simulate cloud ad") { adEventService.simulateAdStart() }
                Button("Simulate game live") { adEventService.simulateGameLive() }
                Button("Simulate ad skip") {
                    Task { await sportsAPIService.skipAdToHighlights() }
                }
                .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.65))
        }
    }
    #endif

    private func openStripeBillingPortal() {
        guard let url = URL(string: "https://billing.stripe.com/p/login/test") else { return }
        openURL(url)
    }
}

// MARK: - Settings Card Chrome

private struct SettingsCard<Content: View>: View {
    let theme: AppTheme
    let title: String
    let icon: String
    var isCollapsible: Bool = false
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(
        theme: AppTheme,
        title: String,
        icon: String,
        isCollapsible: Bool = false,
        isExpanded: Binding<Bool> = .constant(true),
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.theme = theme
        self.title = title
        self.icon = icon
        self.isCollapsible = isCollapsible
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isCollapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack {
                        headerLabel
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .buttonStyle(.plain)
            } else {
                headerLabel
            }

            if !isCollapsible || isExpanded {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCardStyle(theme: theme, cornerRadius: 18, isActive: false)
    }

    private var headerLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.accentPrimary)
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.6)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.40))
            }
        }
        .tint(AppTheme.premium.accentPrimary)
    }
}

// MARK: - Premium Subscription Card

private struct PremiumSubscriptionCard: View {
    let theme: AppTheme
    let onActivate: () -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PREMIUM")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.40))
                        .tracking(0.6)

                    Text("$10 / month")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.headerGradient)

                    Text("Hands-free commercial rewinds")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.48))
                }

                Spacer()

                Image(systemName: "crown.fill")
                    .font(.title3)
                    .foregroundStyle(theme.headerGradient)
            }

            Button(action: onActivate) {
                Text("Activate Premium")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.accentSecondary, theme.accentPrimary.opacity(0.80)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            }
            .buttonStyle(.plain)

            Button(action: onManage) {
                Label("Manage subscription", systemImage: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.50))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .premiumCardStyle(theme: theme, cornerRadius: 18, isActive: true)
    }
}

#Preview {
    SettingsView(tvController: TVController(), sportsAPIService: SportsAPIService(), adEventService: AdEventService())
        .preferredColorScheme(.dark)
}
