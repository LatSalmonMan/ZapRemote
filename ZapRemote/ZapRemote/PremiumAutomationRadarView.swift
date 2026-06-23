//
//  PremiumAutomationRadarView.swift
//  ZapRemote
//
//  Central automation radar — pulsing AI tracking display.
//

import SwiftUI
import Combine

struct PremiumAutomationRadarView: View {
    let theme: AppTheme

    @State private var radarPulse = false
    @State private var sweepRotation: Double = 0
    @State private var adCountdown = 28

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(
                            theme.glowColor.opacity(radarPulse ? 0.06 : 0.22 - Double(ring) * 0.05),
                            lineWidth: 1.5
                        )
                        .frame(width: 120 + CGFloat(ring) * 44, height: 120 + CGFloat(ring) * 44)
                        .scaleEffect(radarPulse ? 1.08 : 1.0)
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                theme.accentPrimary.opacity(0.35),
                                theme.accentSecondary.opacity(0.12),
                                .clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 90
                        )
                    )
                    .frame(width: 160, height: 160)

                RadarSweepWedge()
                    .fill(
                        AngularGradient(
                            colors: [theme.glowColor.opacity(0.0), theme.glowColor.opacity(0.50)],
                            center: .center
                        )
                    )
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(sweepRotation))

                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.accentPrimary)

                    Text("Auto-Rewinding...")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(height: 210)
            .premiumGlow(theme: theme, isActive: true)

            VStack(spacing: 8) {
                Text("AI Hands-Free Automation Active")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(theme.headerGradient)
                    .multilineTextAlignment(.center)

                Text("Smart engine monitoring audio signature for commercial breaks")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 14) {
                Label("Ad Tracking", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))

                Spacer()

                Text("\(adCountdown)s")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(theme.accentPrimary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.glowColor.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .padding(20)
        .premiumCardStyle(theme: theme, cornerRadius: 24, isActive: true)
        .allowsHitTesting(false)
        .onAppear { startAnimations() }
        .onReceive(timer) { _ in
            if adCountdown > 0 { adCountdown -= 1 }
            else { adCountdown = Int.random(in: 22...35) }
        }
    }

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            radarPulse = true
        }
        withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
            sweepRotation = 360
        }
    }
}

private struct RadarSweepWedge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-40), clockwise: false)
        path.closeSubpath()
        return path
    }
}

#Preview {
    PremiumAutomationRadarView(theme: .premium)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}
