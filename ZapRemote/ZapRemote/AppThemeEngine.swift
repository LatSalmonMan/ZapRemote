//
//  AppThemeEngine.swift
//  ZapRemote
//
//  Luxury premium visual system — gold, indigo, and pulsing glow accents.
//

import SwiftUI

// MARK: - App Theme

struct AppTheme: Equatable {
    let accentPrimary: Color
    let accentSecondary: Color
    let glowColor: Color
    let accountBadgeText: String
    let backgroundTint: Color

    static let premium = AppTheme(
        accentPrimary: Color(red: 0.98, green: 0.78, blue: 0.32),
        accentSecondary: Color(red: 0.48, green: 0.32, blue: 0.88),
        glowColor: Color(red: 0.62, green: 0.38, blue: 0.98),
        accountBadgeText: "Premium Automation Active",
        backgroundTint: Color(red: 0.12, green: 0.08, blue: 0.22)
    )

    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentPrimary, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var headerGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.78, blue: 0.32),
                Color(red: 0.55, green: 0.38, blue: 0.92),
                Color(red: 0.38, green: 0.22, blue: 0.72)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Glow Engine

struct PremiumGlowEngine: ViewModifier {
    let theme: AppTheme
    let isActive: Bool

    @State private var glowPulse = false

    func body(content: Content) -> some View {
        content
            .shadow(
                color: theme.glowColor.opacity(isActive && glowPulse ? 0.55 : 0.22),
                radius: 10,
                y: 4
            )
            .onAppear { startGlow() }
    }

    private func startGlow() {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
    }
}

// MARK: - Premium Card Chrome

struct PremiumCardChrome: ViewModifier {
    let theme: AppTheme
    let cornerRadius: CGFloat
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentPrimary.opacity(0.12),
                                theme.accentSecondary.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                theme.accentPrimary.opacity(isActive ? 0.65 : 0.35),
                                lineWidth: 1.5
                            )
                    )
            )
            .modifier(PremiumGlowEngine(theme: theme, isActive: isActive))
    }
}

// MARK: - Brand Mark

struct ZapRemoteLogoMark: View {
    var height: CGFloat = 56

    var body: some View {
        Image("ZapRemoteLogo")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .shadow(color: Color.orange.opacity(0.40), radius: 14, y: 4)
            .shadow(color: Color.cyan.opacity(0.30), radius: 10, y: 2)
    }
}

// MARK: - Account Badge

struct PremiumAccountBadge: View {
    let theme: AppTheme
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? theme.accentPrimary : Color.white.opacity(0.35))
                .frame(width: 8, height: 8)
                .shadow(color: theme.accentPrimary.opacity(isConnected ? 0.9 : 0.2), radius: 6)

            Text(theme.accountBadgeText)
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.headerGradient)
        }
    }
}

// MARK: - Premium Quick Controls

struct PremiumUtilityControls: View {
    let theme: AppTheme
    let isEnabled: Bool
    let onGoLive: () -> Void
    let onMenu: () -> Void
    let onRewindHighlight: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Controls")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)

            HStack(spacing: 10) {
                PremiumUtilityButton(
                    title: "Go to Live",
                    subtitle: "Jump to live stream",
                    systemImage: "dot.radiowaves.left.and.right",
                    theme: theme,
                    isEnabled: isEnabled,
                    isPrimary: true,
                    action: onGoLive
                )

                PremiumUtilityButton(
                    title: "Menu",
                    subtitle: "TV navigation",
                    systemImage: "line.3.horizontal",
                    theme: theme,
                    isEnabled: isEnabled,
                    isPrimary: false,
                    action: onMenu
                )
            }

            PremiumUtilityButton(
                title: "Rewind Highlight",
                subtitle: "Manual 120s + lag override",
                systemImage: "gobackward",
                theme: theme,
                isEnabled: isEnabled,
                isPrimary: false,
                isWide: true,
                action: onRewindHighlight
            )
        }
        .padding(16)
        .premiumCardStyle(theme: theme, cornerRadius: 20, isActive: isEnabled)
    }
}

private struct PremiumUtilityButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let theme: AppTheme
    let isEnabled: Bool
    let isPrimary: Bool
    var isWide: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWide {
                    HStack(spacing: 14) {
                        buttonIcon
                        buttonText
                        Spacer()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        buttonIcon
                        buttonText
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(buttonBackground)
        }
        .buttonStyle(PremiumPressStyle())
        .disabled(!isEnabled)
    }

    private var buttonIcon: some View {
        Image(systemName: systemImage)
            .font(isWide ? .title3.weight(.bold) : .headline.weight(.bold))
            .foregroundStyle(isEnabled ? (isPrimary ? theme.accentPrimary : .white) : .white.opacity(0.25))
    }

    private var buttonText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(isWide ? .headline.weight(.bold) : .subheadline.weight(.bold))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.30))

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(isEnabled ? .white.opacity(0.50) : .white.opacity(0.20))
        }
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isPrimary
                        ? [theme.accentPrimary.opacity(isEnabled ? 0.45 : 0.12), theme.accentSecondary.opacity(isEnabled ? 0.28 : 0.06)]
                        : [Color.white.opacity(isEnabled ? 0.10 : 0.04), Color.white.opacity(isEnabled ? 0.05 : 0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isPrimary ? theme.accentPrimary.opacity(isEnabled ? 0.45 : 0.15) : Color.white.opacity(isEnabled ? 0.14 : 0.06),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - View Extensions

extension View {
    func premiumCardStyle(theme: AppTheme, cornerRadius: CGFloat = 20, isActive: Bool = true) -> some View {
        modifier(PremiumCardChrome(theme: theme, cornerRadius: cornerRadius, isActive: isActive))
    }

    func premiumGlow(theme: AppTheme, isActive: Bool = true) -> some View {
        modifier(PremiumGlowEngine(theme: theme, isActive: isActive))
    }
}

private struct PremiumPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
