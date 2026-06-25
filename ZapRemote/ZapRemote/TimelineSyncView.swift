//
//  TimelineSyncView.swift
//  ZapRemote
//
//  Simple match clock: ESPN ticks from game time. +/- adjusts TV line only.
//

import SwiftUI

struct TimelineSyncView: View {

    @ObservedObject var apiService: SportsAPIService
    let theme: AppTheme
    var showsResyncButton: Bool = false

    private var isWaitingForKickoff: Bool {
        apiService.isTrackedGameLive && !apiService.isMatchPhysicallyActive
    }

    private var isReplayMode: Bool {
        apiService.isReplayOffsetMode
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
            let espnClock = apiService.espnAPIClockDisplay(at: now)
            let tvClock = apiService.calibratedTVTimelineDisplay(at: now)

            VStack(alignment: .leading, spacing: 20) {
                if !hasChosenGame {
                    chooseGamePanel
                } else if isReplayMode {
                    replayOffsetPanel(now: now)
                } else if isWaitingForKickoff {
                    kickoffWaitingPanel
                } else {
                    liveSyncPanel(espnClock: espnClock, tvClock: tvClock, now: now)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: isWaitingForKickoff)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: isReplayMode)
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
            Text("Find Game picks live or replay — replay uses TV delay only (+seconds).")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(waitingCardBackground)
    }

    // MARK: - Pre-kickoff

    private var kickoffWaitingPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "hourglass")
                .font(.title)
                .foregroundStyle(theme.accentSecondary)

            Text(SportsAPIService.kickoffWaitBanner)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(theme.headerGradient)

            Text(SportsAPIService.kickoffWaitClockDisplay)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.30))
                .monospacedDigit()

            Text("Clock starts at 00:00 when the match really kicks off on TV.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(waitingCardBackground)
    }

    // MARK: - Live

    private func liveSyncPanel(espnClock: String, tvClock: String, now: Date) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("ESPN (no delay)")
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

            Text("Match your TV scoreboard — +/− moves TV only")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))

            tvClockHero(tvClock: tvClock, now: now)

            tvFineTuneRow(step: 1, now: now)
            tvFineTuneRow(step: 60, minuteLabel: true, now: now)

            lagSlider

            Text(apiService.streamingLagOffsetReadout)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.headerGradient)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(activeCardBackground)
    }

    private func tvClockHero(tvClock: String, now: Date) -> some View {
        HStack(spacing: 16) {
            nudgeCircle(
                systemName: "minus",
                enabled: apiService.canNudgeTVClockDisplay(by: -1, at: now)
            ) {
                nudgeTVClock(by: -1, at: now)
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
                enabled: apiService.canNudgeTVClockDisplay(by: 1, at: now)
            ) {
                nudgeTVClock(by: 1, at: now)
            }
        }
    }

    // MARK: - Replay / VOD

    private func replayOffsetPanel(now: Date) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "play.circle.fill")
                .font(.title)
                .foregroundStyle(theme.accentSecondary)

            Text("Replay / VOD")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white.opacity(0.88))

            Text("No live clock — set offset: + if TV is behind ESPN, − if TV is ahead.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)

            Text(SportsAPIService.formatStreamDelayOffset(apiService.streamDelaySeconds))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accentPrimary)
                .monospacedDigit()

            offsetFineTuneRow(step: 1)
            offsetFineTuneRow(step: 60, minuteLabel: true)

            lagSlider

            Text(apiService.streamingLagOffsetReadout)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.headerGradient)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(activeCardBackground)
    }

    // MARK: - Controls

    private func tvFineTuneRow(step: Int, minuteLabel: Bool = false, now: Date) -> some View {
        let label = minuteLabel ? "\(step / 60) min" : "\(step)s"
        return HStack(spacing: 10) {
            stepChip(label: "−\(label)", enabled: apiService.canNudgeTVClockDisplay(by: -step, at: now)) {
                nudgeTVClock(by: -step, at: now)
            }
            Spacer()
            Text(minuteLabel ? "Coarse" : "Fine tune")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.30))
            Spacer()
            stepChip(label: "+\(label)", enabled: apiService.canNudgeTVClockDisplay(by: step, at: now)) {
                nudgeTVClock(by: step, at: now)
            }
        }
    }

    private func offsetFineTuneRow(step: Int, minuteLabel: Bool = false) -> some View {
        let label = minuteLabel ? "\(step / 60) min" : "\(step)s"
        return HStack(spacing: 10) {
            stepChip(label: "−\(label)", enabled: apiService.canNudgeStreamDelay(by: -step)) {
                nudgeOffset(by: -step)
            }
            Spacer()
            Text(minuteLabel ? "Coarse" : "Fine tune")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.30))
            Spacer()
            stepChip(label: "+\(label)", enabled: apiService.canNudgeStreamDelay(by: step)) {
                nudgeOffset(by: step)
            }
        }
    }

    private var lagSlider: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TV offset (seconds)")
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

    private func nudgeTVClock(by seconds: Int, at now: Date) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        apiService.nudgeTVClockDisplay(by: seconds, at: now)
    }

    private func nudgeOffset(by seconds: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        apiService.nudgeStreamDelay(by: seconds)
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
