//
//  BSCExportProgressRing.swift
//  BumpSetCut
//
//  Determinate circular progress with a centered percentage — iOS renders
//  ProgressView(value:) with a circular style as an indeterminate spinner,
//  which reads as "stuck" on long exports. This shows real progress.
//

import SwiftUI

struct BSCExportProgressRing: View {
    let progress: Double
    var size: CGFloat = 104
    var lineWidth: CGFloat = 9
    var tint: Color = .bscPrimary

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.bscStandard, value: progress)

            Text("\(Int(min(progress, 1) * 100))%")
                .bscFont(size: size * 0.22, weight: .bold, design: .monospaced)
                .foregroundColor(.bscTextPrimary)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress \(Int(min(progress, 1) * 100)) percent")
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: BSCSpacing.xl) {
        BSCExportProgressRing(progress: 0.06)
        BSCExportProgressRing(progress: 0.62, tint: .bscTealText)
    }
    .padding()
    .background(Color.bscBackground)
}
