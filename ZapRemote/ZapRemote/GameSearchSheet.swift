//
//  GameSearchSheet.swift
//  ZapRemote
//

import SwiftUI

struct GameSearchSheet: View {
    @ObservedObject var sportsAPIService: SportsAPIService
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    private let theme = AppTheme.premium

    var body: some View {
        NavigationStack {
            ZStack {
                CouchModeScreenBackground(theme: theme, streamingAccent: theme.accentSecondary)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        searchHeader

                        if sportsAPIService.isSearchingGames {
                            loadingRow
                        } else if !sportsAPIService.gameSearchStatus.isEmpty {
                            statusBanner
                        }

                        if !liveResults.isEmpty {
                            liveNowSection
                        }

                        resultsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Find Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(theme.accentPrimary)
                }
            }
            .task {
                await sportsAPIService.showLiveGames()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var liveResults: [ESPNGameSearchResult] {
        sportsAPIService.gameSearchResults.filter(\.isLive)
    }

    private var otherResults: [ESPNGameSearchResult] {
        sportsAPIService.gameSearchResults.filter { !$0.isLive }
    }

    // MARK: - Search

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What are you watching?")
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.headerGradient)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.35))

                TextField("Team or league…", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                    .onChange(of: query) { _, newValue in
                        scheduleSearch(for: newValue)
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        Task { await sportsAPIService.showLiveGames() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(theme.accentPrimary.opacity(0.18), lineWidth: 1)
                    )
            )

            if !sportsAPIService.monitoredGameLabel.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accentPrimary)
                    Text("Tracking: \(sportsAPIService.monitoredGameLabel)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Leave") {
                        sportsAPIService.clearMonitoredGame(reason: "Left game")
                        dismiss()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.accentPrimary)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(theme.accentPrimary)
            Text("Searching ESPN…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBanner: some View {
        Text(sportsAPIService.gameSearchStatus)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.50))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    // MARK: - Live

    private var liveNowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Live Now", icon: "dot.radiowaves.left.and.right")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(liveResults) { result in
                        GameResultCard(result: result, theme: theme, style: .compact) {
                            select(result)
                        }
                        .frame(width: 260)
                    }
                }
            }
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                query.isEmpty ? "All Games" : "Results",
                icon: "list.bullet"
            )

            if sportsAPIService.gameSearchResults.isEmpty && !sportsAPIService.isSearchingGames {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(displayResults) { result in
                        GameResultCard(result: result, theme: theme, style: .full) {
                            select(result)
                        }
                    }
                }
            }
        }
    }

    private var displayResults: [ESPNGameSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return otherResults
        }
        return deduped(sportsAPIService.gameSearchResults)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sportscourt")
                .font(.title2)
                .foregroundStyle(theme.accentSecondary.opacity(0.6))
            Text("Search a team or league")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("Try Liverpool, MLS, Champions League, Argentina…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .premiumCardStyle(theme: theme, cornerRadius: 16, isActive: false)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.6)
        }
        .foregroundStyle(.white.opacity(0.42))
    }

    private func select(_ result: ESPNGameSearchResult) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        sportsAPIService.selectMonitoredGame(result)
        dismiss()
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await sportsAPIService.searchGames(query: trimmed) }
    }

    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            if trimmed.isEmpty {
                Task { await sportsAPIService.showLiveGames() }
            }
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await sportsAPIService.searchGames(query: trimmed)
        }
    }

    private func deduped(_ results: [ESPNGameSearchResult]) -> [ESPNGameSearchResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Game Card

private struct GameResultCard: View {
    let result: ESPNGameSearchResult
    let theme: AppTheme
    let style: Style
    let onTap: () -> Void

    enum Style { case compact, full }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: SportProfile.resolve(sportPath: result.sportPath).systemImageName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accentSecondary.opacity(0.9))

                    Text(result.leagueLabel.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(theme.accentSecondary.opacity(0.85))
                        .lineLimit(1)

                    Spacer()

                    if result.isLive {
                        Text("LIVE")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.accentPrimary))
                    }
                }

                Text(result.title)
                    .font(style == .compact ? .subheadline.weight(.bold) : .body.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .lineLimit(style == .compact ? 2 : 3)

                Text(result.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                result.isLive ? theme.accentPrimary.opacity(0.35) : Color.white.opacity(0.06),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    GameSearchSheet(sportsAPIService: SportsAPIService())
}
