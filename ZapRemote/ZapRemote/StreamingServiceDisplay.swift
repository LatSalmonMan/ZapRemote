//
//  StreamingServiceDisplay.swift
//  ZapRemote
//
//  Shared streaming-service visuals for Remote, Sports, and Settings tabs.
//

import SwiftUI

enum SettingsStorageKey {
    static let defaultStreamingService = "settings.defaultStreamingService"
}

extension StreamingServicePreference {
    var webOSAppID: String {
        switch self {
        case .youtubeTV: "youtube.leanback.ytv.v1"
        case .primeVideo: "amazon"
        case .netflix: "netflix"
        case .appleTVPlus: "com.apple.appletv"
        case .huluLive: "hulu"
        case .disneyPlus: "com.disney.disneyplus-prod"
        case .peacock: "com.peacocktv.peacock"
        case .foxOne: "com.fox.foxone"
        case .espnPlus: "com.espn.score_center"
        }
    }

    static func from(appStorageRawValue raw: String) -> StreamingServicePreference {
        StreamingServicePreference(rawValue: raw) ?? .youtubeTV
    }
}

// MARK: - Connection Banner

struct CouchModeConnectionBanner: View {
    let service: StreamingServicePreference
    let theme: AppTheme
    let statusMessage: String
    let isConnected: Bool
    var deviceName: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 14) {
                serviceIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.rawValue)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(theme.headerGradient)

                    Text(subtitleLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    PremiumAccountBadge(theme: theme, isConnected: isConnected)

                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                if onTap != nil {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .premiumCardStyle(theme: theme, cornerRadius: 20, isActive: isConnected)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private var serviceIcon: some View {
        ZStack {
            Circle()
                .fill(theme.accentPrimary.opacity(isConnected ? 0.28 : 0.10))
                .frame(width: 44, height: 44)
                .blur(radius: isConnected ? 8 : 0)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [theme.accentPrimary.opacity(0.45), theme.accentSecondary.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)

            Image(systemName: service.iconName)
                .font(.body.weight(.bold))
                .foregroundStyle(theme.headerGradient)
        }
    }

    private var subtitleLine: String {
        if let deviceName, !deviceName.isEmpty { return deviceName }
        if isConnected { return "Smart Remote active on home Wi‑Fi" }
        if statusMessage.localizedCaseInsensitiveContains("approve") {
            return "Waiting for TV pairing approval"
        }
        return "Tap to choose a TV on your network"
    }
}

// MARK: - Background

struct CouchModeScreenBackground: View {
    let theme: AppTheme
    let streamingAccent: Color

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.09)
                .ignoresSafeArea()

            RadialGradient(
                colors: [theme.backgroundTint, Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 340
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [theme.glowColor.opacity(0.10), Color.clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 280
            )
            .ignoresSafeArea()
        }
    }
}

extension View {
    func syncStreamingServicePreference(
        tvController: TVController,
        storageRawValue: String
    ) -> some View {
        let service = StreamingServicePreference.from(appStorageRawValue: storageRawValue)
        return self
            .onAppear {
                tvController.preferredStreamingAppID = service.webOSAppID
            }
            .onChange(of: storageRawValue) { _, newValue in
                let updated = StreamingServicePreference.from(appStorageRawValue: newValue)
                tvController.preferredStreamingAppID = updated.webOSAppID
            }
    }
}
