//
//  ZapRemoteApp.swift
//  ZapRemote
//
//  Premium automation TV remote — flat $10/mo model.
//

import SwiftUI

@main
struct ZapRemoteApp: App {
    @StateObject private var tvController = TVController()
    @StateObject private var sportsAPIService = SportsAPIService()
    @StateObject private var adEventService = AdEventService()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(
                    tvController: tvController,
                    sportsAPIService: sportsAPIService,
                    adEventService: adEventService
                )
                .tabItem {
                    Label("Home", systemImage: "tv.and.mediabox")
                }

                SettingsView(
                    tvController: tvController,
                    sportsAPIService: sportsAPIService,
                    adEventService: adEventService
                )
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .preferredColorScheme(.dark)
            .background(Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea())
            .onAppear {
                sportsAPIService.configure(tvController: tvController)
                adEventService.configure(tvController: tvController)
                adEventService.sportsAPIService = sportsAPIService
                adEventService.subscribedGameID = sportsAPIService.monitoredGameID
                adEventService.streamDelayOffsetSeconds = Int(
                    sportsAPIService.streamDelaySeconds.rounded()
                )
                if adEventService.isCloudURLConfigured {
                    adEventService.startListening()
                }

                if sportsAPIService.hasMonitoredGame {
                    sportsAPIService.startGamePolling()
                }
            }
            .onChange(of: sportsAPIService.isHandsFreeAutomationEnabled) { _, enabled in
                if enabled, adEventService.isCloudURLConfigured {
                    adEventService.startListening()
                }
            }
            .onChange(of: sportsAPIService.streamDelaySeconds) { _, delay in
                adEventService.streamDelayOffsetSeconds = Int(delay.rounded())
            }
            .onChange(of: sportsAPIService.monitoredGameID) { _, newGameID in
                adEventService.subscribedGameID = newGameID
                let trimmed = newGameID.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    sportsAPIService.stopGamePolling()
                } else {
                    sportsAPIService.startLiveGameMonitoring(gameID: trimmed)
                }
            }
        }
    }
}
