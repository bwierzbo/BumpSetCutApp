//
//  GameScoreOverlay.swift
//  BumpSetCut
//
//  Score overlay for Game Review mode with blue/red team boxes.
//

import SwiftUI

struct GameScoreOverlay: View {
    let score: GameScore
    let currentServer: CourtSide
    let nearMappedTo: CourtSide
    let currentRallyIndex: Int
    let totalRallies: Int

    /// Whether sides have been swapped from their starting positions.
    private var isSwitched: Bool { nearMappedTo != .near }

    /// Colors follow the team, not the court position.
    /// Near team starts blue, far team starts red — colors swap with them.
    private var nearColor: Color { isSwitched ? .bscError : .bscPrimary }
    private var farColor: Color { isSwitched ? .bscPrimary : .bscError }

    var body: some View {
        HStack(spacing: BSCSpacing.md) {
            // Near court side — color follows whichever team is here
            sideBox(
                side: .near,
                label: nearLabel,
                color: nearColor,
                isServing: currentServer == .near
            )

            // Center — rally counter + switch indicator
            VStack(spacing: 2) {
                Text("Rally \(currentRallyIndex + 1)/\(totalRallies)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                if isSwitched {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.bscOrange)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("VS")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isSwitched)

            // Far court side — color follows whichever team is here
            sideBox(
                side: .far,
                label: farLabel,
                color: farColor,
                isServing: currentServer == .far
            )
        }
        .padding(.horizontal, BSCSpacing.lg)
        .animation(.easeInOut(duration: 0.35), value: isSwitched)
    }

    private var nearLabel: String {
        nearMappedTo == .near ? "Near" : "Far"
    }

    private var farLabel: String {
        nearMappedTo == .near ? "Far" : "Near"
    }

    private func sideBox(side: CourtSide, label: String, color: Color, isServing: Bool) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if isServing {
                    Image(systemName: "sportscourt.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.bscOrange)
                }
            }

            Text("\(score.score(for: side))")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BSCSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .fill(color.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                        .stroke(color, lineWidth: 2)
                )
        )
        .animation(.easeInOut(duration: 0.35), value: color)
        .animation(.easeInOut(duration: 0.25), value: score.score(for: side))
    }
}
