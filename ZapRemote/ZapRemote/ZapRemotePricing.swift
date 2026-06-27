//
//  ZapRemotePricing.swift
//  ZapRemote
//

import Foundation

enum ZapRemotePricing {
    static let monthlyUSD = 5

    static var perMonthLabel: String { "$\(monthlyUSD) / month" }
    static var perMonthShort: String { "$\(monthlyUSD)/mo" }
}
