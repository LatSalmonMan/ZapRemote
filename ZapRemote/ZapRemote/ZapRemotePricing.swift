//
//  ZapRemotePricing.swift
//  ZapRemote
//

import Foundation

enum ZapRemotePricing {
    /// Flat soccer subscription — no Pro tier.
    static let monthlyUSD = 1.99

    static var perMonthLabel: String { "$1.99 / month" }
    static var perMonthShort: String { "$1.99/mo" }
}
