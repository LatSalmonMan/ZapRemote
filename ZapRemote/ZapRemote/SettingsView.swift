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
    @State private var isClockSyncPresented = false
    @State private var isAdvancedExpanded = false
    @State private var isDeveloperToolsExpanded = false

    @Environment(\.openURL) private var openURL

    private let theme = AppTheme.premium

    private var selectedStreamingService: StreamingServicePreference {
        get { StreamingServicePreference(rawValue: defaultStreamingServiceRaw) ?? .youtubeTV }
        nonmutating set { defaultStreamingServiceRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SettingsBackground()

                List {
                    tonightSection
                    tvConnectionAndDelaySection
                    cloudSection
                    premiumSection
                    moreSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
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
            .sheet(isPresented: $isClockSyncPresented) {
                StreamClockSyncSheet(sportsAPIService: sportsAPIService)
            }
            .syncStreamingServicePreference(
                tvController: tvController,
                storageRawValue: defaultStreamingServiceRaw
            )
        }
    }

    // MARK: - Sections

    private var tonightSection: some View {
        Section {
            Picker(selection: Binding(
                get: { selectedStreamingService },
                set: { selectedStreamingService = $0 }
            )) {
                ForEach(StreamingServicePreference.allCases) { service in
                    Label { Text(service.rawValue) } icon: {
                        Image(systemName: service.iconName).foregroundStyle(service.accent)
                    }
                    .tag(service)
                }
            } label: {
                Label("Streaming app on TV", systemImage: "play.tv")
            }
            .listRowBackground(SettingsRowBackground())

            Button {
                isGameSearchPresented = true
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sportsAPIService.monitoredGameLabel.isEmpty ? "Choose game" : sportsAPIService.monitoredGameLabel)
                                .foregroundStyle(.white.opacity(0.90))
                            Text(sportsAPIService.monitoringStatus.displayLabel)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.40))
                        }
                    } icon: {
                        Image(systemName: "sportscourt")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(SettingsRowBackground())

            Button {
                isClockSyncPresented = true
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Match clock (full screen)")
                                .foregroundStyle(.white.opacity(0.90))
                            Text("Larger ± clock UI for fine-tuning beyond 60s")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.40))
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.2.circlepath")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(SettingsRowBackground())

            Toggle(isOn: $sportsAPIService.isHandsFreeAutomationEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hands-free ad skip")
                    Text("ESPN stoppage or cloud ad_start → up to 3 highlights → Go Live")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .listRowBackground(SettingsRowBackground())

            Toggle(isOn: $sportsAPIService.autoReturnToLiveAfterHighlight) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto Go Live after highlight")
                    Text("Waits ~45–60s on the highlight, then jumps back to live")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .listRowBackground(SettingsRowBackground())

            Text(selectedStreamingService.macroBehaviorNote)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.40))
                .listRowBackground(SettingsRowBackground())
        } header: {
            SettingsSectionHeader(title: "Tonight", icon: "sportscourt")
        } footer: {
            Text("Open YouTube TV, Hulu, or Peacock on your TV before using skip macros.")
        }
    }

    private var tvConnectionAndDelaySection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(tvController.isConnected ? theme.accentPrimary : Color.white.opacity(0.25))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tvController.isConnected ? "TV connected" : "TV not connected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text(tvController.connectionStatusHeadline)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
            }
            .listRowBackground(SettingsRowBackground())

            StreamDelayHueSyncPanel(apiService: sportsAPIService, theme: theme)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(SettingsRowBackground())
        } header: {
            SettingsSectionHeader(title: "TV Connection & Delay", icon: "tv.and.hifispeaker.fill")
        } footer: {
            Text("Drag the slider until the app clock matches your TV. The offset feeds highlight skip timing instantly.")
        }
    }

    private var cloudSection: some View {
        Section {
            TextField("ws://192.168.x.x:8787", text: $adEventService.cloudWebSocketURLString)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(SettingsRowBackground())

            HStack {
                Text(adEventService.bridgeStatus.displayLabel)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                if adEventService.hasConfiguredDetectorURL {
                    Button(adEventService.bridgeStatus == .connected ? "Reconnect" : "Connect") {
                        adEventService.stopListening()
                        adEventService.startListening()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .listRowBackground(SettingsRowBackground())
        } header: {
            SettingsSectionHeader(title: "Cloud detector", icon: "waveform")
        } footer: {
            Text("Optional. Run detector on your Mac — point phone at ws://YOUR-MAC-IP:8787")
        }
    }

    private var premiumSection: some View {
        Section {
            PremiumSubscriptionCard(
                theme: theme,
                onActivate: { isCheckoutSheetPresented = true },
                onManage: openStripeBillingPortal
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var moreSection: some View {
        Section {
            NavigationLink {
                AutomaticRewindExplainerView()
            } label: {
                Label("How automatic rewind works", systemImage: "info.circle")
            }
            .listRowBackground(SettingsRowBackground())

            Button(role: .destructive) {
                Task { await tvController.resetTVConnection() }
            } label: {
                Label("Reset TV connection", systemImage: "arrow.counterclockwise")
            }
            .listRowBackground(SettingsRowBackground())

            if tvController.isConnected {
                Button {
                    Task { await tvController.sendTestTVNotification() }
                } label: {
                    Label("Send test alert to TV", systemImage: "bell.badge")
                }
                .listRowBackground(SettingsRowBackground())
            }

            DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
                TextField("ESPN game ID", text: $sportsAPIService.monitoredGameID)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(SettingsRowBackground())

                Button("Restart ESPN polling") {
                    sportsAPIService.stopGamePolling()
                    sportsAPIService.startGamePolling()
                }
                .listRowBackground(SettingsRowBackground())

                Text(sportsAPIService.lastStatusSummary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .listRowBackground(SettingsRowBackground())
            }
            .listRowBackground(SettingsRowBackground())

            DisclosureGroup("Developer", isExpanded: $isDeveloperToolsExpanded) {
                Button("Simulate cloud ad") { adEventService.simulateAdStart() }
                    .listRowBackground(SettingsRowBackground())
                Button("Simulate game live") { adEventService.simulateGameLive() }
                    .listRowBackground(SettingsRowBackground())
                Button("Simulate manual ad skip") {
                    Task { await sportsAPIService.skipAdToHighlights() }
                }
                .listRowBackground(SettingsRowBackground())
                Button("Simulate play resumed") { sportsAPIService.simulatePlayResumed() }
                    .listRowBackground(SettingsRowBackground())
            }
            .listRowBackground(SettingsRowBackground())
        } header: {
            SettingsSectionHeader(title: "More", icon: "ellipsis.circle")
        } footer: {
            Text(tvController.statusMessage)
        }
    }

    private func openStripeBillingPortal() {
        guard let url = URL(string: "https://billing.stripe.com/p/login/test") else { return }
        openURL(url)
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
                    Text("Premium")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .textCase(.uppercase)

                    Text("$10 / month")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(theme.headerGradient)

                    Text("Hands-free commercial rewinds")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.50))
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
            .buttonStyle(.borderless)

            Button(action: onManage) {
                Label("Manage subscription", systemImage: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .premiumCardStyle(theme: theme, cornerRadius: 18, isActive: true)
        .padding(.horizontal, 16)
    }
}

private struct SettingsBackground: View {
    var body: some View {
        Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea()
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            Text(title)
        }
        .foregroundStyle(.white.opacity(0.45))
        .textCase(.uppercase)
    }
}

private struct SettingsRowBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.05))
    }
}

// MARK: - Hue-Style Stream Delay Sync

private struct StreamDelayHueSyncPanel: View {
    @ObservedObject var apiService: SportsAPIService
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            timeSyncReadoutPanel

            VStack(alignment: .leading, spacing: 10) {
                Slider(
                    value: $apiService.streamDelaySeconds,
                    in: SportsAPIService.settingsSliderDelayRange,
                    step: SportsAPIService.settingsSliderStep
                )
                .tint(theme.accentPrimary)

                HStack {
                    Text("0s")
                    Spacer()
                    Text("60s")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.32))
            }

            streamOffsetReadoutCard
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.22), value: apiService.streamDelaySeconds)
    }

    private var timeSyncReadoutPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Instructions: Compare the clock below with your television screen. "
                + "Move the slider until the app timeline matches your TV feed exactly."
            )
            .font(.caption)
            .foregroundStyle(.white.opacity(0.48))
            .fixedSize(horizontal: false, vertical: true)

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let clock = apiService.syncedTimelineClockDisplay(at: timeline.date)

                VStack(alignment: .leading, spacing: 6) {
                    Text("APP TIMELINE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.35))

                    Text(clock)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accentPrimary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.22), value: apiService.streamDelaySeconds)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var streamOffsetReadoutCard: some View {
        Text(apiService.streamOffsetReadout)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.headerGradient)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentPrimary.opacity(0.22),
                                theme.accentSecondary.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.accentPrimary.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentTransition(.numericText())
    }
}

#Preview {
    SettingsView(tvController: TVController(), sportsAPIService: SportsAPIService(), adEventService: AdEventService())
        .preferredColorScheme(.dark)
}
