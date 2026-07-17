//
//  HighlightReturnMath.swift
//  ZapRemote
//
//  After a highlight, the TV already played forward while you watched.
//  Only scrub the remaining gap — never more (avoids overshooting live).
//
//      remaining = (rewindClicks × skipSize) − watchedSeconds
//      forwardClicks = max(1, floor(remaining / skipSize))
//

import Foundation

enum HighlightReturnMath {

    static func forwardClicks(
        rewindClicks: Int,
        watchedSeconds: Double,
        secondsPerClick: Int
    ) -> Int {
        let spc = max(1, secondsPerClick)
        let rewindSeconds = Double(max(0, rewindClicks) * spc)
        let remaining = rewindSeconds - max(0, watchedSeconds)
        guard remaining > 0 else { return 1 }
        return max(1, Int(floor(remaining / Double(spc))))
    }
}
