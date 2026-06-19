//
//  ContentView.swift
//  ZapRemote
//
//  iOS Remote-style TV controller — pick a TV, then use the arrow pad.
//

import SwiftUI
import UIKit

// MARK: - ContentView

struct ContentView: View {

    @State private var tvController = TVController()
    @State private var isDevicePickerPresented = false
    @State private var showRemoteControls = false

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                deviceHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                if let banner = statusBannerMessage {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                Spacer()

                if showRemoteControls {
                    VStack(spacing: 0) {
                        RemoteDPad(
                            tvController: tvController,
                            isEnabled: tvController.isConnected
                        )
                        .padding(.horizontal, 24)

                        Spacer()

                        bottomActions
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer()
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showRemoteControls)
        .onAppear {
            tvController.bootstrapConnection()
            if tvController.selectedTV == nil {
                isDevicePickerPresented = true
            }
        }
        .onChange(of: tvController.isConnected) { _, connected in
            if connected {
                isDevicePickerPresented = false
                withAnimation(.easeInOut(duration: 0.3)) {
                    showRemoteControls = true
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

    // MARK: Device Header

    private var deviceHeader: some View {
        Button {
            isDevicePickerPresented = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "tv")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(deviceTitle)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text(connectionSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private var deviceTitle: String {
        tvController.selectedTV?.listRowTitle
            ?? tvController.activeDeviceName
            ?? "Choose a TV"
    }

    private var connectionSubtitle: String {
        if tvController.isConnecting {
            if tvController.selectedTV?.controlBackend == .lgWebOS {
                return "Approve on LG TV…"
            }
            return "Connecting…"
        }
        if tvController.isConnected { return "Connected" }
        if tvController.isPresenceListening, tvController.discoveredTVs.isEmpty {
            return "Searching nearby…"
        }
        return "Not connected"
    }

    private var statusBannerMessage: String? {
        if let error = tvController.lastErrorMessage {
            return error
        }
        if tvController.isConnecting,
           tvController.selectedTV?.controlBackend == .lgWebOS {
            return "Approve ZapRemote on your LG TV"
        }
        if tvController.isConnected,
           tvController.selectedTV?.controlBackend == .lgNetCast {
            return "Connected via LG NetCast (ROAP)"
        }
        if tvController.isConnected,
           tvController.selectedTV?.controlBackend == .lgWebOS {
            return "Connected to LG webOS"
        }
        if tvController.isConnected,
           tvController.selectedTV?.usesUniversalControl == true {
            return "Connected via Universal Mode"
        }
        return nil
    }

    // MARK: Bottom Actions

    private var bottomActions: some View {
        RemoteActionButton(
            title: "Menu",
            systemImage: "line.3.horizontal",
            isEnabled: tvController.isConnected
        ) {
            tvController.sendRemoteKey(.menu)
        }
        .frame(maxWidth: 200)
    }
}

// MARK: - Remote D-Pad (Apple Remote style)

private struct RemoteDPad: View {
    var tvController: TVController
    let isEnabled: Bool

    @State private var activeDirection: RemoteKey?
    @State private var isCenterPressed = false
    @State private var repeatTask: Task<Void, Never>?

    private let padSize: CGFloat = 300
    private let centerButtonSize: CGFloat = 76
    private let tapThreshold: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, padSize)

            ZStack {
                padBackground(size: size)
                directionHighlights(size: size)
                directionChevrons(size: size)
                centerSelectButton(size: size)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            .gesture(padGesture(in: size))
            .onDisappear { stopRepeating() }
        }
        .frame(height: padSize)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .allowsHitTesting(isEnabled)
    }

    // MARK: Visual layers

    private func padBackground(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.22),
                            Color(white: 0.16)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.5
                    )
                )

            Circle()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)

            Circle()
                .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                .padding(2)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    private func directionHighlights(size: CGFloat) -> some View {
        ZStack {
            ForEach(CardinalDirection.allCases, id: \.self) { direction in
                if activeDirection == direction.remoteKey {
                    RemoteDirectionWedge(direction: direction)
                        .fill(Color.white.opacity(0.14))
                        .frame(width: size, height: size)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: activeDirection)
    }

    private func directionChevrons(size: CGFloat) -> some View {
        let offset = size * 0.30

        return ZStack {
            chevron("chevron.up", key: .up)
                .offset(y: -offset)
            chevron("chevron.right", key: .right)
                .offset(x: offset)
            chevron("chevron.down", key: .down)
                .offset(y: offset)
            chevron("chevron.left", key: .left)
                .offset(x: -offset)
        }
        .allowsHitTesting(false)
    }

    private func chevron(_ name: String, key: RemoteKey) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white.opacity(activeDirection == key ? 0.95 : 0.28))
            .animation(.easeOut(duration: 0.12), value: activeDirection)
    }

    private func centerSelectButton(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(isCenterPressed ? 0.22 : 0.12))
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )

            Circle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 10, height: 10)
        }
        .frame(width: centerButtonSize, height: centerButtonSize)
        .scaleEffect(isCenterPressed ? 0.94 : 1)
        .animation(.easeOut(duration: 0.12), value: isCenterPressed)
        .allowsHitTesting(false)
        .accessibilityLabel("Select")
    }

    // MARK: Gesture

    private func padGesture(in size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let center = CGPoint(x: size / 2, y: size / 2)
                let point = value.location
                let dx = point.x - center.x
                let dy = point.y - center.y
                let distance = hypot(dx, dy)
                let centerRadius = centerButtonSize / 2 + 8

                guard distance > centerRadius else {
                    if activeDirection != nil {
                        stopRepeating()
                    }
                    isCenterPressed = true
                    return
                }

                isCenterPressed = false

                guard let key = directionKey(dx: dx, dy: dy) else { return }

                if activeDirection != key {
                    activeDirection = key
                    startRepeating(key)
                }
            }
            .onEnded { value in
                let center = CGPoint(x: size / 2, y: size / 2)
                let point = value.location
                let dx = point.x - center.x
                let dy = point.y - center.y
                let distance = hypot(dx, dy)
                let movement = hypot(value.translation.width, value.translation.height)
                let centerRadius = centerButtonSize / 2 + 8
                let wasRepeating = activeDirection != nil

                if movement < tapThreshold, !wasRepeating {
                    if distance <= centerRadius {
                        fireKey(.select)
                    } else if let key = directionKey(dx: dx, dy: dy) {
                        fireKey(key)
                    }
                }

                stopRepeating()
            }
    }

    // MARK: Input helpers

    private func directionKey(dx: CGFloat, dy: CGFloat) -> RemoteKey? {
        guard abs(dx) > 4 || abs(dy) > 4 else { return nil }

        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .down : .up
    }

    private func fireKey(_ key: RemoteKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tvController.sendRemoteKey(key)
    }

    private func startRepeating(_ key: RemoteKey) {
        repeatTask?.cancel()
        fireKey(key)

        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                fireKey(key)
                try? await Task.sleep(for: .milliseconds(130))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        activeDirection = nil
        isCenterPressed = false
    }
}

// MARK: - Direction Wedge

private enum CardinalDirection: CaseIterable {
    case up, right, down, left

    var remoteKey: RemoteKey {
        switch self {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }

    var startAngle: Angle {
        switch self {
        case .up: .degrees(-135)
        case .right: .degrees(-45)
        case .down: .degrees(45)
        case .left: .degrees(135)
        }
    }

    var endAngle: Angle {
        switch self {
        case .up: .degrees(-45)
        case .right: .degrees(45)
        case .down: .degrees(135)
        case .left: .degrees(225)
        }
    }
}

private struct RemoteDirectionWedge: Shape {
    let direction: CardinalDirection

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.46
        let innerRadius = radius * 0.34

        path.addArc(
            center: center,
            radius: radius,
            startAngle: direction.startAngle,
            endAngle: direction.endAngle,
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: direction.endAngle,
            endAngle: direction.startAngle,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Remote Action Button

private struct RemoteActionButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(RemotePressStyle())
        .disabled(!isEnabled)
    }
}

// MARK: - Press Style

private struct RemotePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Device Discovery Sheet

private struct DeviceDiscoverySheet: View {
    let tvController: TVController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if tvController.isPresenceListening && tvController.discoveredTVs.isEmpty {
                    discoveringState
                } else if tvController.discoveredTVs.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle("Nearby TVs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { tvController.startPresenceListening() }
    }

    private var discoveringState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Looking for TVs on your Wi‑Fi…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tv.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No TVs Found")
                .font(.headline)
            Text("Make sure your TV is on and on the same network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var deviceList: some View {
        List {
            Section {
                ForEach(tvController.discoveredTVs) { device in
                    DeviceRow(
                        device: device,
                        isSelected: tvController.selectedTV?.id == device.id
                    ) {
                        tvController.selectTV(device)
                        dismiss()
                    }
                }
            } header: {
                Text("Tap a TV to connect")
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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

// MARK: - Preview

#Preview {
    ContentView()
}
