//
//  StreamClockSyncSheet.swift
//  ZapRemote
//
//  Match your TV: ticking clock +/− until it lines up with the screen.
//

import SwiftUI

struct StreamClockSyncSheet: View {

    @ObservedObject var sportsAPIService: SportsAPIService
    @Environment(\.dismiss) private var dismiss

    @State private var delaySeconds: Int = 30

    private let theme = AppTheme.premium

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = timeline.date
                let espnDisplay = sportsAPIService.espnClockDisplay(at: now)
                let tvDisplay = sportsAPIService.tvClockDisplay(delaySeconds: delaySeconds, at: now)

                ScrollView {
                    VStack(spacing: 24) {
                        Text("Look at the game clock on your TV. Use − and + until this matches it.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)

                        tvClockCard(tvDisplay: tvDisplay)

                        if let espnDisplay {
                            Text("ESPN live: \(espnDisplay)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.45))
                        } else {
                            Text("No live clock yet — set your delay anyway, or wait for kickoff")
                                .font(.caption)
                                .foregroundStyle(.orange.opacity(0.85))
                                .multilineTextAlignment(.center)
                        }

                        Text("Delay: \(delaySeconds)s")
                            .font(.caption)
                            .foregroundStyle(theme.accentPrimary.opacity(0.85))

                        confirmButton
                    }
                    .padding(20)
                }
            }
            .background(CouchModeScreenBackground(theme: theme, streamingAccent: .blue))
            .navigationTitle("Match TV Clock")
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

    private func tvClockCard(tvDisplay: String?) -> some View {
        VStack(spacing: 16) {
            Text("YOUR TV")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.35))

            HStack(spacing: 20) {
                adjustButton(systemName: "minus", enabled: delaySeconds < GameClockSyncEngine.maxBroadcastDelaySeconds) {
                    delaySeconds += 1
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                Text(tvDisplay ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                adjustButton(systemName: "plus", enabled: delaySeconds > 0) {
                    delaySeconds -= 1
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            Text("− if your TV is behind · + if your TV is ahead")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
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

    private var confirmButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            sportsAPIService.confirmStreamDelay(delaySeconds)
            dismiss()
        } label: {
            Label("Synced", systemImage: "checkmark.circle.fill")
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
    }

    private func seedFromService() {
        let existing = Int(sportsAPIService.streamDelaySeconds.rounded())
        if existing > 0 {
            delaySeconds = min(existing, GameClockSyncEngine.maxBroadcastDelaySeconds)
        }
    }
}
