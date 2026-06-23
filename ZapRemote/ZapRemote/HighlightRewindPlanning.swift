//
//  HighlightRewindPlanning.swift
//  ZapRemote
//
//  ESPN play-by-play → rewind depth for landing on real highlights.
//

import Foundation

/// Computes how far back the TV should skip to reach a recent highlight play.
@MainActor
protocol HighlightRewindPlanning: AnyObject {
    func plannedHighlightRewindSeconds() async -> Int?
    func lastHighlightPlayDescription() -> String?
    var rankedHighlights: [SportHighlight] { get }
    var selectedHighlightRank: Int { get }
    var lastPlannedRewindSeconds: Int { get }
}
