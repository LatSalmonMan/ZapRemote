//
//  PremiumCheckoutView.swift
//  ZapRemote
//
//  Single-tier Stripe checkout — $1.99/mo soccer automation.
//

import SwiftUI

struct PremiumCheckoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let theme = AppTheme.premium

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08)
                .ignoresSafeArea()

            RadialGradient(
                colors: [theme.glowColor.opacity(0.18), Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 400
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "crown.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.headerGradient)
                    .premiumGlow(theme: theme)

                VStack(spacing: 12) {
                    Text("Activate Lifetime Automation Support")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(ZapRemotePricing.perMonthShort)
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.headerGradient)

                    Text("Soccer highlights on your LG TV — rewind, watch, return. Built for YouTube TV game nights.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                Button(action: beginCheckout) {
                    Text("Activate Lifetime Automation Support — \(ZapRemotePricing.perMonthShort)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.accentSecondary, theme.accentPrimary.opacity(0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .premiumGlow(theme: theme)
                }
                .buttonStyle(PremiumPressStyle())

                Text("💳 Secured by Stripe. Cancel anytime in one click.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(20)
        }
    }

    private func beginCheckout() {
        guard let url = URL(string: "https://checkout.stripe.com/test?plan=premium") else { return }
        openURL(url)
    }
}

struct PremiumCheckoutSheet: View {
    var body: some View {
        PremiumCheckoutView()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}

private struct PremiumPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    PremiumCheckoutView()
        .preferredColorScheme(.dark)
}
