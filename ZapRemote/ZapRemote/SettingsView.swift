//
//  SettingsView.swift
//  ZapRemote
//
//  Account and configuration — premium-only $5/mo model.
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
        case .youtubeTV: "10s skip steps (1 click/sec)"
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

    @AppStorage(SportsAPIStorageKey.highlightWatchSeconds)
    private var highlightWatchSeconds: Double = 0

    @State private var isCheckoutSheetPresented = false
    @State private var isAdvancedExpanded = false

    #if DEBUG
    @State private var isDebugExpanded = false
    #endif

    @Environment(\.openURL) private var openURL

    private let theme = AppTheme.premium

    private var selectedStreamingService: StreamingServicePreference {
        get { StreamingServicePreference(rawValue: defaultStreamingServiceRaw) ?? .youtubeTV }
        nonmutating set { defaultStreamingServiceRaw = newValue.rawValue }
    }

    private var highlightWatchLabel: String {
        if highlightWatchSeconds <= 0 {
            return "Auto — goals ~22s, big plays ~18s, other ~14s (TV icon stays for whole reel)"
        }
        return "Each highlight stays on TV for \(Int(highlightWatchSeconds))s (icon stays for whole reel)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CouchModeScreenBackground(theme: theme, streamingAccent: selectedStreamingService.accent)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        premiumSection
                        automationSection
                        advancedSection
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
            .syncStreamingServicePreference(
                tvController: tvController,
                storageRawValue: defaultStreamingServiceRaw
            )
        }
    }

    // MARK: - Sections

    private var automationSection: some View {
        SettingsCard(theme: theme, title: "TV", icon: "tv.fill") {
            VStack(spacing: 12) {
                streamingPicker

                Text("Game, clock, and controls are on Home.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
    }

    private var advancedSection: some View {
        SettingsCard(
            theme: theme,
            title: "Advanced",
            icon: "slider.horizontal.3",
            isCollapsible: true,
            isExpanded: $isAdvancedExpanded
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mac ad detector (optional)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))

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

                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Highlight watch time (testing)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))

                    HStack(spacing: 10) {
                        Text("10s")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                        Slider(value: $highlightWatchSeconds, in: 0...90, step: 5)
                            .tint(theme.accentPrimary)
                        Text("90s")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }

                    Text(highlightWatchLabel)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.40))
                }

                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { sportsAPIService.isNonLiveTestModeEnabled },
                        set: { sportsAPIService.setNonLiveTestModeEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Non-live test mode")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text("Test rewinds and match clock anytime — finished games, replays, or off-air.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.40))
                        }
                    }
                    .tint(theme.accentPrimary)

                    if sportsAPIService.isNonLiveTestModeEnabled {
                        Text("Pick any game from Find Game. Clock starts at 00:00 — nudge ESPN and TV to any time. Ad on TV and test rewind work without a live match.")
                            .font(.caption2)
                            .foregroundStyle(theme.accentSecondary.opacity(0.85))

                        if tvController.isConnected {
                            Button {
                                sportsAPIService.triggerTestRewind(seconds: 120)
                            } label: {
                                Label("Test 2 min rewind on TV", systemImage: "backward.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("TV troubleshooting")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))

                    if tvController.isConnected {
                        Button {
                            Task { await tvController.sendTestTVNotification() }
                        } label: {
                            Label("Test highlight chip on TV (5s)", systemImage: "bell.badge")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.85))
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

                Divider().overlay(Color.white.opacity(0.08))

                NavigationLink {
                    AutomaticRewindExplainerView()
                } label: {
                    Label("How automatic rewind works", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
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

    private var premiumSection: some View {
        PremiumSubscriptionCard(
            theme: theme,
            onActivate: { isCheckoutSheetPresented = true },
            onManage: openStripeBillingPortal
        )
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

                    Text(ZapRemotePricing.perMonthLabel)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.headerGradient)

                    Text("Live sports on autopilot")
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
