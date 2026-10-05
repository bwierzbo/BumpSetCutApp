//
//  DisplayFormatting.swift
//  BumpSetCut
//
//  The one place durations, counts and percentages are turned into display
//  text. Everything goes through Foundation's locale-aware format styles, so
//  digits, separators and unit words follow the user's locale — never build
//  these with String(format:) or string math. (design-system.md → Localization)
//  Byte sizes: StorageChecker.formatBytes.
//

import Foundation

extension TimeInterval {
    /// Clock-style minutes and seconds for clip lengths and timestamps:
    /// "0:05", "1:05", "62:05" (minutes keep counting past an hour). Partial
    /// seconds are dropped, like a player's elapsed-time readout.
    func formattedClock(locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(wholeSeconds)
            .formatted(.time(pattern: .minuteSecond).locale(locale))
    }

    /// The same duration spelled out for VoiceOver: "1 minute, 5 seconds".
    func formattedSpokenDuration(locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(wholeSeconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale))
    }

    /// Seconds to one decimal with the short unit: "12.3s".
    func formattedSeconds(locale: Locale = .autoupdatingCurrent) -> String {
        tenthsDuration
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)).locale(locale))
    }

    /// Seconds to one decimal, spelled out for VoiceOver: "12.3 seconds".
    func formattedSpokenSeconds(locale: Locale = .autoupdatingCurrent) -> String {
        tenthsDuration
            .formatted(.units(allowed: [.seconds], width: .wide, fractionalPart: .show(length: 1)).locale(locale))
    }

    private var wholeSeconds: Int64 {
        guard isFinite, self > 0 else { return 0 }
        return Int64(self)
    }

    private var tenthsDuration: Duration {
        guard isFinite, self > 0 else { return .zero }
        return .milliseconds(Int64((self * 1000).rounded()))
    }
}

extension BinaryInteger {
    /// Social counts in compact form: "999", "1.2K", "3.4M" (locale-aware).
    func formattedCompact(locale: Locale = .autoupdatingCurrent) -> String {
        Int(self).formatted(.number.notation(.compactName).locale(locale))
    }
}

extension Double {
    /// A 0…1 fraction as a whole percentage, rounded down so a running task
    /// never reads 100% before it finishes: 0.428 → "42%".
    func formattedPercent(locale: Locale = .autoupdatingCurrent) -> String {
        let clamped = isFinite ? Swift.min(Swift.max(self, 0), 1) : 0
        return clamped.formatted(
            .percent.precision(.fractionLength(0)).rounded(rule: .down).locale(locale)
        )
    }

    /// A zoom/speed factor to one decimal: "1.5×".
    func formattedMultiplier(locale: Locale = .autoupdatingCurrent) -> String {
        formatted(.number.precision(.fractionLength(1)).locale(locale)) + "×"
    }

    /// A signed angle in degrees to one decimal: "+2.5°", "-1.0°".
    func formattedSignedDegrees(locale: Locale = .autoupdatingCurrent) -> String {
        Measurement(value: self, unit: UnitAngle.degrees).formatted(
            .measurement(
                width: .narrow,
                numberFormatStyle: .number.precision(.fractionLength(1)).sign(strategy: .always())
            ).locale(locale)
        )
    }
}
