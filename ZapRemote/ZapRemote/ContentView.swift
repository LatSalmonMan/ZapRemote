//
//  ContentView.swift
//  ZapRemote
//
//  Remote tab shell — device picker + tactile RemoteView control layer.
//

import SwiftUI

// MARK: - ContentView

struct ContentView: View {

    @ObservedObject var tvController: TVController
    @ObservedObject var sportsAPIService: SportsAPIService
    @ObservedObject var adEventService: AdEventService
    @State private var isDevicePickerPresented = false

    init(
        tvController: TVController,
        sportsAPIService: SportsAPIService,
        adEventService: AdEventService
    ) {
        _tvController = ObservedObject(wrappedValue: tvController)
        _sportsAPIService = ObservedObject(wrappedValue: sportsAPIService)
        _adEventService = ObservedObject(wrappedValue: adEventService)
    }

    var body: some View {
        RemoteView(
            tvController: tvController,
            sportsAPIService: sportsAPIService,
            adEventService: adEventService,
            onChooseTV: {
                isDevicePickerPresented = true
            },
            onResetTV: {
                Task { await tvController.resetTVConnection() }
            }
        )
        .onAppear {
            Task {
                if !tvController.isConnected {
                    await tvController.reconnectToSavedTVIfPossible()
                }
                if !tvController.isConnected {
                    await tvController.discoverLGTVs()
                }
            }
        }
        .sheet(isPresented: $isDevicePickerPresented) {
            DeviceDiscoverySheet(tvController: tvController)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .presentationBackground(.ultraThinMaterial)
        }
    }
}

// MARK: - Device Discovery Sheet

private struct DeviceDiscoverySheet: View {
    @ObservedObject var tvController: TVController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if tvController.isPresenceListening {
                    HStack {
                        ProgressView()
                        Text("Scanning your Wi‑Fi…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if tvController.discoveredTVs.isEmpty {
                    Text("No LG TVs found. Make sure your phone and TV are on the same Wi‑Fi.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tvController.discoveredTVs) { device in
                        DeviceRow(
                            device: device,
                            isSelected: tvController.selectedTV?.id == device.id
                        ) {
                            tvController.selectTV(device)
                            dismiss()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Connect to TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan") {
                        Task { await tvController.startPresenceListening() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            Task { await tvController.startPresenceListening() }
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: DiscoveredTV
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: "tv.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.listRowTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(device.listRowSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Storage

enum TVControllerStorageKey {
    static let lastTVIP = "com.zapremote.lg.lastTVIP"
}

// MARK: - Preview

#Preview {
    ContentView(
        tvController: TVController(),
        sportsAPIService: SportsAPIService(),
        adEventService: AdEventService()
    )
}
