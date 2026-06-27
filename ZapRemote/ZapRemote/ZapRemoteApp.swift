//
//  ZapRemoteApp.swift
//  ZapRemote
//
//  Premium automation TV remote — flat $5/mo model.
//

import SwiftUI

@main
struct ZapRemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var tvController = TVController()
    @StateObject private var sportsAPIService = SportsAPIService()
    @StateObject private var adEventService = AdEventService()
    @StateObject private var gameNightSession = GameNightSessionManager()

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
                gameNightSession.configure(
                    tvController: tvController,
                    sportsAPIService: sportsAPIService,
                    adEventService: adEventService
                )
                adEventService.subscribedGameID = sportsAPIService.monitoredGameID
                if adEventService.isCloudURLConfigured {
                    adEventService.startListening()
                }

                if sportsAPIService.hasMonitoredGame {
                    sportsAPIService.startGamePolling()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                gameNightSession.handleScenePhase(phase)
            }
            .onChange(of: sportsAPIService.monitoredGameID) { _, newGameID in
                adEventService.subscribedGameID = newGameID
                adEventService.syncDetectorConfiguration()
                let trimmed = newGameID.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    sportsAPIService.stopGamePolling()
                } else {
                    sportsAPIService.startLiveGameMonitoring(gameID: trimmed)
                }
                gameNightSession.reevaluateSession()
            }
            .onChange(of: sportsAPIService.monitoredSportPath) { _, _ in
                adEventService.syncDetectorConfiguration()
            }
        }
    }
}
