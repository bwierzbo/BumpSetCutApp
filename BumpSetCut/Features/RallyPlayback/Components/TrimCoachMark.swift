//
//  TrimCoachMark.swift
//  BumpSetCut
//
//  Pulsing "Hold to trim" hint shown in the rally player until the user
//  enters trim mode for the first time.
//

import SwiftUI

struct TrimCoachMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "hand.tap.fill")
                .bscFont(size: 15, weight: .semibold)
                .foregroundStyle(Color.bscPrimary)
            Text("Hold anywhere to trim this rally")
                .bscFont(size: 14, weight: .semibold)
                .foregroundColor(.bscOnMedia)
        }
        .padding(.horizontal, BSCSpacing.lg)
        .padding(.vertical, BSCSpacing.md)
        .background(Color.bscMediaScrimBase.opacity(0.75))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(Color.bscPrimary.opacity(0.5), lineWidth: 1)
        )
        .scaleEffect(pulsing ? 1.05 : 1.0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.bscFloat) { pulsing = true }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ZStack {
        Color.black
        TrimCoachMark()
    }
}
