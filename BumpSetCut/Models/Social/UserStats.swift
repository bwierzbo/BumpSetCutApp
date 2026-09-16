//
//  UserStats.swift
//  BumpSetCut
//
//  Lifetime processing totals stored on the account (`user_stats` row).
//

import Foundation

struct UserStats: Codable, Equatable {
    // `.convertFromSnakeCase` maps user_id / rallies_found / time_cut_seconds.
    let userId: String
    let ralliesFound: Int
    let timeCutSeconds: Double

    static func empty(userId: String) -> UserStats {
        UserStats(userId: userId, ralliesFound: 0, timeCutSeconds: 0)
    }
}
