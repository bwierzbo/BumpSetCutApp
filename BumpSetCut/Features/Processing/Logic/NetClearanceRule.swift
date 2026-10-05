//
//  NetClearanceRule.swift
//  BumpSetCut
//
//  The above-net (multi-contact) rule for keeping a rally segment.
//  Compiled into RallyLab too (membershipExceptions).
//

import CoreGraphics

enum NetClearanceRule {
    /// A rally with multiple ball contacts must clear the net top at least once; a
    /// single trajectory is exempt. `ySamples` are the ball's Vision-y positions
    /// over the segment, in time order. `netTopY` should already include any
    /// leniency margin. Returns true to KEEP the segment.
    static func rallyClearsNetTop(ySamples: [CGFloat], netTopY: CGFloat,
                                  arcProminence: CGFloat) -> Bool {
        guard countArcs(ySamples, prominence: arcProminence) >= 2 else {
            return true        // single trajectory (or too few samples) → exempt
        }
        return ySamples.contains { $0 > netTopY }
    }

    /// Counts distinct arcs (apexes) in a vertical-position series: each up-then-down
    /// of at least `prominence` is one arc/contact. A simple hysteresis walk, robust
    /// to per-sample jitter below the prominence.
    private static func countArcs(_ ys: [CGFloat], prominence: CGFloat) -> Int {
        guard ys.count >= 3 else { return ys.isEmpty ? 0 : 1 }
        var arcs = 0
        var rising = true
        var extreme = ys[0]            // running peak while rising, valley while falling
        for y in ys.dropFirst() {
            if rising {
                if y > extreme { extreme = y }
                else if y < extreme - prominence { arcs += 1; rising = false; extreme = y }
            } else {
                if y < extreme { extreme = y }
                else if y > extreme + prominence { rising = true; extreme = y }
            }
        }
        return arcs
    }
}
