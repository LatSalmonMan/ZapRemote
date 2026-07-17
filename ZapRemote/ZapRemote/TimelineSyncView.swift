//
//  TimelineSyncView.swift
//  ZapRemote
//
//  Live: sync TV delay to ESPN match clock.
//  Replay: set the match minute on your TV — clock ticks from there like live.
//

import SwiftUI

struct TimelineSyncView: View {

    @ObservedObject var apiService: SportsAPIService
    let theme: AppTheme

    private var isReplayMode: Bool {
        apiService.isReplayOffsetMode && !apiService.isNonLiveTestModeEnabled
    }

    private var calibrationUnlocked: Bool {
        apiService.allowsStreamOffsetCalibration
    }

    private var hasChosenGame: Bool {
        apiService.hasMonitoredGame
    }

    private var streamDelayBinding: Binding<Double> {
        Binding(
            get: { apiService.streamDelaySeconds },
            set: { newValue in
                guard apiService.allowsStreamOffsetCalibration else { return }
                apiService.streamDelaySeconds = newValue
                apiService.acknowledgeStreamDelayCalibration()
            }
        )
    }

    private var tickAnchor: Date {
        apiService.matchClockTickAnchor ?? Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }

    var body: some View {
        TimelineView(.periodic(from: tickAnchor, by: 1)) { timeline in
            let now = timeline.date

            VStack(alignment: .leading, spacing: 20) {
                if !hasChosenGame {
                    chooseGamePanel
                } else if isReplayMode {
                    replayMinutePanel(now: now)
                } else {
                    liveSyncPanel(now: now)
                }
            }
        }
    }

    // MARK: - No game

    private var chooseGamePanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "sportscourt")
                .font(.title)
                .foregroundStyle(theme.accentSecondary)
            Text("Choose a game first")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Live games sync delay to ESPN. Replays: set the clock on your TV, then it ticks with the game.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(waitingCardBackground)
    }

    // MARK: - Live match clock

    private func liveSyncPanel(now: Date) -> some View {
        let espnClock = apiService.espnAPIClockDisplay(at: now)
        let tvClock = apiService.calibratedTVTimelineDisplay(at: now)

        return VStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("ESPN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.40))
                Text(espnClock)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.accentSecondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            Text("Match your TV scoreboard — +/− adjusts TV delay only")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))

            tvClockHero(tvClock: tvClock, now: now, usesDelayNudge: true)

            tvFineTuneRow(step: 5, now: now, usesDelayNudge: true)
            tvFineTuneRow(step: 60, minuteLabel: true, now: now, usesDelayNudge: true)

            lagSlider

            Text(apiService.streamingLagOffsetReadout)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.headerGradient)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(activeCardBackground)
    }

    // MARK: - Replay — set minute, then tick

    private func replayMinutePanel(now: Date) -> some View {
        let tvClock = apiService.calibratedTVTimelineDisplay(at: now)
        let hasSeeded = apiService.matchClockTickAnchor != nil

        return VStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(hasSeeded ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(hasSeeded ? "Replay clock running" : "Where is your TV?")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.40))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            Text("Set the match minute on your screen — clock runs from there like live")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)

            tvClockHero(tvClock: tvClock, now: now, usesDelayNudge: false)

            tvFineTuneRow(step: 5, now: now, usesDelayNudge: false)
            tvFineTuneRow(step: 60, minuteLabel: true, now: now, usesDelayNudge: false)
            tvFineTuneRow(step: 300, minuteLabel: true, now: now, usesDelayNudge: false)

            Text(apiService.streamingLagOffsetReadout)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.headerGradient)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(activeCardBackground)
    }

    private func tvClockHero(tvClock: String, now: Date, usesDelayNudge: Bool) -> some View {
        HStack(spacing: 16) {
            nudgeCircle(
                systemName: "minus",
                enabled: canNudgeClock(by: -1, at: now, usesDelayNudge: usesDelayNudge)
            ) {
                nudgeClock(by: -1, at: now, usesDelayNudge: usesDelayNudge)
            }

            VStack(spacing: 4) {
                Text("YOUR TV CLOCK")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.32))

                Text(tvClock)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accentPrimary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)

            nudgeCircle(
                systemName: "plus",
                enabled: canNudgeClock(by: 1, at: now, usesDelayNudge: usesDelayNudge)
            ) {
                nudgeClock(by: 1, at: now, usesDelayNudge: usesDelayNudge)
            }
        }
    }

    // MARK: - Controls

    private func tvFineTuneRow(step: Int, minuteLabel: Bool = false, now: Date, usesDelayNudge: Bool) -> some View {
        let label: String
        if minuteLabel {
            label = step >= 60 ? "\(step / 60) min" : "\(step)s"
        } else {
            label = "\(step)s"
        }
        let centerLabel = minuteLabel ? (step >= 300 ? "Jump" : "Coarse") : "\(step) sec"
        return HStack(spacing: 10) {
            stepChip(label: "−\(label)", enabled: canNudgeClock(by: -step, at: now, usesDelayNudge: usesDelayNudge)) {
                nudgeClock(by: -step, at: now, usesDelayNudge: usesDelayNudge)
            }
            Spacer()
            Text(centerLabel)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.30))
            Spacer()
            stepChip(label: "+\(label)", enabled: canNudgeClock(by: step, at: now, usesDelayNudge: usesDelayNudge)) {
                nudgeClock(by: step, at: now, usesDelayNudge: usesDelayNudge)
            }
        }
    }

    private var lagSlider: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TV delay (seconds)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))

            Slider(
                value: streamDelayBinding,
                in: SportsAPIService.settingsSliderDelayRange,
                step: SportsAPIService.settingsSliderStep
            )
            .tint(theme.accentPrimary)
            .disabled(!calibrationUnlocked)

            HStack {
                Text("TV ahead")
                Spacer()
                Text("0")
                Spacer()
                Text("TV behind")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.28))
        }
    }

    private var waitingCardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.accentSecondary.opacity(0.25), lineWidth: 1)
            )
    }

    private var activeCardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.accentPrimary.opacity(0.22), lineWidth: 1)
            )
    }

    private func canNudgeClock(by seconds: Int, at now: Date, usesDelayNudge: Bool) -> Bool {
        if usesDelayNudge {
            return apiService.canNudgeTVClockDisplay(by: seconds, at: now)
        }
        return apiService.canNudgeESPNMatchClock(by: seconds, at: now)
    }

    private func nudgeClock(by seconds: Int, at now: Date, usesDelayNudge: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if usesDelayNudge {
            apiService.nudgeTVClockDisplay(by: seconds, at: now)
        } else {
            apiService.nudgeESPNMatchClock(by: seconds, at: now)
        }
    }

    private func nudgeCircle(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.25))
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(theme.accentPrimary.opacity(enabled ? 0.35 : 0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func stepChip(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(enabled ? 0.88 : 0.28))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(enabled ? 0.12 : 0.05)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        TimelineSyncView(apiService: SportsAPIService(), theme: .premium)
            .padding()
    }
    .preferredColorScheme(.dark)
}
