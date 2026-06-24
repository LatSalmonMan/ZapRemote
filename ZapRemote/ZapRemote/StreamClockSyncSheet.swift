//
//  StreamClockSyncSheet.swift
//  ZapRemote
//
//  Hue-style sync: ESPN live clock (no delay) vs your TV clock (match with −/+).
//

import SwiftUI

struct StreamClockSyncSheet: View {

    @ObservedObject var sportsAPIService: SportsAPIService
    @Environment(\.dismiss) private var dismiss

    @State private var delaySeconds: Int = 30
    @State private var isPlaySyncing = false

    private let theme = AppTheme.premium

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = timeline.date
                let espnLive = sportsAPIService.espnLiveClockDisplay(at: now)
                let tvClock = sportsAPIService.broadcastGameClockDisplay(delaySeconds: delaySeconds, at: now)

                ScrollView {
                    VStack(spacing: 20) {
                        introText

                        espnLiveCard(display: espnLive)

                        tvMatchCard(tvClock: tvClock)

                        playSyncSection

                        confirmButton
                    }
                    .padding(20)
                }
            }
            .background(CouchModeScreenBackground(theme: theme, streamingAccent: .blue))
            .navigationTitle("Match Clock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: seedFromService)
        }
        .preferredColorScheme(.dark)
    }

    private var introText: some View {
        Text(
            "ESPN LIVE is the real game clock. Match YOUR TV below — "
            + "that becomes your timeline. ESPN at 14:23 = your 14:31 when you're 8s behind."
        )
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.55))
        .multilineTextAlignment(.center)
    }

    private func espnLiveCard(display: String?) -> some View {
        VStack(spacing: 8) {
            Text("ESPN LIVE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.38))

            Text("No delay — real game clock")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.30))

            Text(display ?? "Waiting for kickoff…")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accentPrimary)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    private func tvMatchCard(tvClock: String?) -> some View {
        VStack(spacing: 16) {
            Text("YOUR TV — MATCH THIS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.35))

            Text("Look at your TV and match this clock")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.30))

            HStack(spacing: 20) {
                adjustButton(systemName: "minus", enabled: delaySeconds < GameClockSyncEngine.maxBroadcastDelaySeconds) {
                    delaySeconds += 1
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                Text(tvClock ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                adjustButton(systemName: "plus", enabled: delaySeconds > 0) {
                    delaySeconds -= 1
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            HStack(spacing: 12) {
                stepButton(label: "−5s", enabled: delaySeconds + 5 <= GameClockSyncEngine.maxBroadcastDelaySeconds) {
                    delaySeconds = min(delaySeconds + 5, GameClockSyncEngine.maxBroadcastDelaySeconds)
                }
                stepButton(label: "+5s", enabled: delaySeconds >= 5) {
                    delaySeconds = max(delaySeconds - 5, 0)
                }
            }

            Text("− TV further behind live · + TV closer to live")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))

            if delaySeconds > 0 {
                Text("Your timeline — \(delaySeconds)s behind ESPN live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accentPrimary.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    private var playSyncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or sync on a play")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.45))

            Text("When this ESPN play is on your TV screen right now, tap:")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.40))

            if !sportsAPIService.latestESPNPlayLabel.isEmpty {
                Text("“\(sportsAPIService.latestESPNPlayLabel)”")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(3)
            }

            Button {
                isPlaySyncing = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task {
                    let ok = await sportsAPIService.syncStreamDelayFromLatestPlay()
                    isPlaySyncing = false
                    if ok {
                        delaySeconds = Int(sportsAPIService.streamDelaySeconds.rounded())
                    }
                }
            } label: {
                HStack {
                    if isPlaySyncing {
                        ProgressView().tint(.white)
                    }
                    Text(isPlaySyncing ? "Syncing…" : "This play is on my TV now")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.90))
            .disabled(isPlaySyncing || sportsAPIService.latestESPNPlayLabel.isEmpty)
        }
        .padding(14)
        .background(cardBackground)
    }

    private func adjustButton(
        systemName: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title.weight(.bold))
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(theme.accentPrimary.opacity(enabled ? 0.35 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.30))
        .disabled(!enabled)
    }

    private func stepButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(enabled ? 0.12 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.30))
        .disabled(!enabled)
    }

    private var confirmButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            sportsAPIService.confirmStreamDelay(delaySeconds)
            dismiss()
        } label: {
            Label("Save — clocks matched", systemImage: "checkmark.circle.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.accentPrimary.opacity(0.42))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(delaySeconds <= 0)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.08))
    }

    private func seedFromService() {
        let existing = Int(sportsAPIService.streamDelaySeconds.rounded())
        if existing > 0 {
            delaySeconds = min(existing, GameClockSyncEngine.maxBroadcastDelaySeconds)
        }
    }
}
