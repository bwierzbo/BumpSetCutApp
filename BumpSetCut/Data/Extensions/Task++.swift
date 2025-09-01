//
//  Task++.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//


import Foundation

// MARK: Sleep
extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: CGFloat) async {
        try! await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
