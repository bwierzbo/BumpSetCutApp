//
//  CMTime+Helpers.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 8/8/25.
//

import CoreMedia

extension CMTimeRange {
    func containsTime(_ time: CMTime) -> Bool {
        return CMTimeRangeContainsTime(self, time: time)
    }
}

func timeDeltaSec(_ a: CMTime, _ b: CMTime) -> Double {
    CMTimeGetSeconds(CMTimeSubtract(a, b))
}

func gapSec(between a: CMTimeRange, and b: CMTimeRange) -> Double {
    let startB = b.start
    let endA = a.end
    return max(0.0, CMTimeGetSeconds(CMTimeSubtract(startB, endA)))
}
