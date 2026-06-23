//
//  AutomaticRewindExplainerView.swift
//  ZapRemote
//
//  Product explainer — how ad skip + ESPN highlight targeting works.
//

import SwiftUI

struct AutomaticRewindExplainerView: View {

    private let theme = AppTheme.premium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How Automatic Rewind Works")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.headerGradient)

                    Text(
                        "ZapRemote can't see your TV screen. You tell it when an ad is on — or a cloud detector does — "
                        + "and ESPN's play-by-play tells it *which* highlight to jump to."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                }

                ExplainerStepCard(
                    theme: theme,
                    step: 1,
                    title: "Match the game clock",
                    systemImage: "clock.badge.checkmark",
                    detail: "A live clock ticks on your phone (93:44, 93:45…). Tap − or + until it matches your TV — that's your delay. Then highlight rewinds land on the right play."
                )

                ExplainerStepCard(
                    theme: theme,
                    step: 2,
                    title: "Hands-free (default ON)",
                    systemImage: "bolt.fill",
                    detail: "With Hands-free ad skip enabled in Settings, ESPN game stoppages trigger the same skip macro automatically. You can still tap Ad on my TV anytime."
                )

                ExplainerStepCard(
                    theme: theme,
                    step: 3,
                    title: "Find the highlight",
                    systemImage: "sportscourt.fill",
                    detail: "ESPN's live play feed lists touchdowns, big passes, turnovers, and more. ZapRemote picks the best recent play and calculates how far back to rewind."
                )

                ExplainerStepCard(
                    theme: theme,
                    step: 4,
                    title: "Watch on the big screen",
                    systemImage: "gobackward",
                    detail: "Your LG TV skips in 15-second steps on YouTube TV (LEFT + OK). When ESPN shows play resumed, ZapRemote taps Go Live automatically."
                )

                ExplainerStepCard(
                    theme: theme,
                    step: 5,
                    title: "Cloud detector (optional)",
                    systemImage: "waveform.badge.magnifyingglass",
                    detail: "Run the detector on your Mac for real broadcast ad cues (SCTE-35). It uses the same skip macro over WebSocket."
                )

                Text(
                    "ESPN tells us which highlight to target. Hands-free mode fires on game stoppages; cloud detector adds real ad detection when configured."
                )
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(ExplainerBackground())
        .navigationTitle("Automatic Rewind")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Step Card

private struct ExplainerStepCard: View {
    let theme: AppTheme
    let step: Int
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(theme.accentPrimary.opacity(0.20))
                    .frame(width: 36, height: 36)

                Text("\(step)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.accentPrimary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.88))

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .premiumCardStyle(theme: theme, cornerRadius: 16, isActive: false)
    }
}

// MARK: - Background

private struct ExplainerBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            RadialGradient(
                colors: [Color(red: 0.18, green: 0.10, blue: 0.32).opacity(0.55), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }
}

#Preview {
    NavigationStack {
        AutomaticRewindExplainerView()
    }
    .preferredColorScheme(.dark)
}
