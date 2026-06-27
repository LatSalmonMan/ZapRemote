//
//  GameNightSessionManager.swift
//  ZapRemote
//
//  Keeps TV control + automation alive while the phone is locked during a live game.
//  Uses silent audio (UIBackgroundModes audio) so WebSockets and timers keep running.
//

import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class GameNightSessionManager: ObservableObject {

    @Published private(set) var isActive = false

    private weak var tvController: TVController?
    private weak var sportsAPIService: SportsAPIService?
    private weak var adEventService: AdEventService?

    private let silentAudio = SilentAudioKeepAlive()
    private var healthCheckTimer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func configure(
        tvController: TVController,
        sportsAPIService: SportsAPIService,
        adEventService: AdEventService
    ) {
        self.tvController = tvController
        self.sportsAPIService = sportsAPIService
        self.adEventService = adEventService
        reevaluateSession()
    }

    /// Call when game selection changes.
    func reevaluateSession() {
        let shouldBeActive = sportsAPIService?.hasMonitoredGame == true

        if shouldBeActive, !isActive {
            startSession()
        } else if !shouldBeActive, isActive {
            stopSession()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            performHealthCheck()
        case .inactive, .background:
            if isActive {
                beginBackgroundTask()
            }
        @unknown default:
            break
        }
    }

    private func startSession() {
        isActive = true
        tvController?.setAutoReconnectEnabled(true)
        silentAudio.start()
        startHealthCheckTimer()

        if adEventService?.isCloudURLConfigured == true {
            adEventService?.startListening()
        }

        Task {
            await tvController?.ensureReadyConnection()
        }

        print("🌙 GameNightSession: active — keeping TV + automation alive in background")
    }

    private func stopSession() {
        isActive = false
        tvController?.setAutoReconnectEnabled(false)
        silentAudio.stop()
        stopHealthCheckTimer()
        endBackgroundTask()
        print("🌙 GameNightSession: stopped")
    }

    private func startHealthCheckTimer() {
        stopHealthCheckTimer()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performHealthCheck()
            }
        }
        if let healthCheckTimer {
            RunLoop.main.add(healthCheckTimer, forMode: .common)
        }
        performHealthCheck()
    }

    private func stopHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func performHealthCheck() {
        guard isActive else { return }

        sportsAPIService?.ensureGamePollingActive()

        if adEventService?.isCloudURLConfigured == true {
            adEventService?.ensureConnectionHealth()
        }

        Task {
            await tvController?.ensureReadyConnection()
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ZapRemoteGameNight") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

// MARK: - Silent Audio Keep-Alive

/// Plays inaudible audio so iOS keeps the app process running while the screen is off.
private final class SilentAudioKeepAlive {
    private let engine = AVAudioEngine()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let sourceNode = AVAudioSourceNode(format: format) { _, _, _, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in buffers {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return noErr
            }

            engine.attach(sourceNode)
            engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()
            isRunning = true
        } catch {
            print("⚠️ SilentAudioKeepAlive failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
