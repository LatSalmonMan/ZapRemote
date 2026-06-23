//
//  GameSearchSheet.swift
//  ZapRemote
//

import SwiftUI

struct GameSearchSheet: View {
    @ObservedObject var sportsAPIService: SportsAPIService
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Argentina, Chiefs, Lakers…", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await sportsAPIService.searchGames(query: query) } }

                    Button {
                        Task { await sportsAPIService.searchGames(query: query) }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await sportsAPIService.showLiveGames() }
                    } label: {
                        Label("Show Live Games", systemImage: "dot.radiowaves.left.and.right")
                    }
                }

                if !sportsAPIService.gameSearchStatus.isEmpty {
                    Section {
                        Text(sportsAPIService.gameSearchStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if sportsAPIService.isSearchingGames {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Searching ESPN…")
                        }
                    }
                }

                Section("Results") {
                    if sportsAPIService.gameSearchResults.isEmpty {
                        Text("Search for a team or tap Show Live Games")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sportsAPIService.gameSearchResults) { result in
                            Button {
                                sportsAPIService.selectMonitoredGame(result)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title)
                                            .font(.body.weight(.semibold))
                                        Text(result.statusLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if result.isLive {
                                        Text("LIVE")
                                            .font(.caption2.weight(.black))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(.green))
                                    }
                                }
                            }
                        }
                    }
                }

                if !sportsAPIService.monitoredGameLabel.isEmpty {
                    Section("Currently tracking") {
                        Text(sportsAPIService.monitoredGameLabel)
                    }
                }
            }
            .navigationTitle("Find Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await sportsAPIService.showLiveGames()
            }
        }
    }
}
