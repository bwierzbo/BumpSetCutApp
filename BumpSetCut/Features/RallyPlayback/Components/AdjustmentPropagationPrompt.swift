//
//  AdjustmentPropagationPrompt.swift
//  BumpSetCut
//
//  Shown after confirming a rally trim whose rotation and/or zoom changed.
//  Dims the paused video behind it and asks whether the adjustment should
//  carry forward to the remaining rallies.
//

import SwiftUI

struct AdjustmentPropagationPrompt: View {
    /// Non-nil when rotation changed during this trim session.
    let rotation: Double?
    /// Non-nil when zoom/pan changed during this trim session.
    let zoom: Double?
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        ZStack {
            // Dim + gray out the paused video behind the prompt
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: BSCSpacing.lg) {
                Image(systemName: iconName)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.bscPrimary)

                VStack(spacing: BSCSpacing.sm) {
                    Text("Apply to Other Rallies?")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text("Apply \(changeDescription) to this rally and every rally after it?")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: BSCSpacing.md) {
                    Button(action: onNo) {
                        Text("Just This One")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, BSCSpacing.md)
                            .background(Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                    }

                    Button(action: onYes) {
                        Text("Apply to All")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, BSCSpacing.md)
                            .background(Color.bscPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
                    }
                }
            }
            .padding(BSCSpacing.xl)
            .background(Color.bscBackgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.xl))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.xl)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, BSCSpacing.xxl)
        }
    }

    private var iconName: String {
        if rotation != nil && zoom != nil { return "slider.horizontal.3" }
        if zoom != nil { return "plus.magnifyingglass" }
        return "rotate.right.fill"
    }

    /// Human description of what changed, e.g. "this +2.5° rotation and 1.4× zoom".
    private var changeDescription: String {
        var parts: [String] = []
        if let rotation { parts.append(String(format: "this %+.1f° rotation", rotation)) }
        if let zoom { parts.append(String(format: "%.1f× zoom", zoom)) }
        switch parts.count {
        case 0: return "this adjustment"
        case 1: return parts[0]
        default: return parts.joined(separator: " and ")
        }
    }
}

#Preview {
    ZStack {
        Color.gray
        AdjustmentPropagationPrompt(rotation: 2.5, zoom: 1.4, onYes: {}, onNo: {})
    }
}
