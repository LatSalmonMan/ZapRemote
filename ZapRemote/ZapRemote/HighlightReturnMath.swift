//
//  HighlightReturnMath.swift
//  ZapRemote
//
//  TV skip buttons move from the *current* playhead. While you watch a highlight,
// playback advances for you — so return only needs the remaining gap:
//
//      remaining = rewindSeconds − watchedSeconds − rewindSeekPlaythrough
//      forwardClicks = max(1, floor(remaining / secondsPerClick))
//
//  Use floor on remaining seconds (not rewindClicks − floor(watch/spc)), or the
//  leftover almost-skip launches you past live by up to ~14s.
//

import Foundation

enum HighlightReturnMath {

    /// Forward RIGHT clicks that close the remaining gap without crossing live.
    static func forwardClicks(
        rewindClicks: Int,
        highlightSeconds: Double,
        secondsPerClick: Int,
        rewindSeekPlaythroughSeconds: Double = 0
    ) -> Int {
        let spc = max(1, secondsPerClick)
        let rewind = max(0, rewindClicks)
        guard rewind > 0 else { return 1 }

        let rewindSeconds = Double(rewind * spc)
        let watched = max(0, highlightSeconds)
        let seekPlay = max(0, rewindSeekPlaythroughSeconds)
        let remainingSeconds = rewindSeconds - watched - seekPlay

        // Already at / past the original edge — one RIGHT to kick the scrubber.
        guard remainingSeconds > 0 else { return 1 }
        return max(1, Int(floor(remainingSeconds / Double(spc))))
    }

    /// Rough seconds the live timeline advances while LEFT skips are being sent.
    /// YTTV keeps playing during the macro, so true rewind depth is slightly less than clicks×spc.
    static func estimatedSeekPlaythroughSeconds(
        clicks: Int,
        spacingMs: Int,
        openMs: Int = 550,
        burstSize: Int = 6,
        burstBreatherMs: Int = 350,
        confirmMs: Int = 400
    ) -> Double {
        let clicks = max(0, clicks)
        guard clicks > 0 else { return 0 }
        let gaps = max(0, clicks - 1)
        let breathers = clicks / max(1, burstSize)
        let ms = openMs
            + gaps * max(1, spacingMs)
            + breathers * max(0, burstBreatherMs)
            + confirmMs
        return Double(ms) / 1000.0
    }
}
