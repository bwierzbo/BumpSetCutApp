//
//  BSCStraightenControl.swift
//  BumpSetCut
//
//  The straighten (rotation) row shared by the pre-processing trim screen and
//  the rally trim overlay: −/+ steppers, a snapping slider, a signed degree
//  readout and a reset button. Drawn on media, so it uses the on-media tokens.
//

import SwiftUI

struct BSCStraightenControl: View {
    @Binding var degrees: Double
    var maxDegrees: Double = 10.0
    var step: Double = 0.5

    /// Readout width — grows with Dynamic Type so "+10.0°" never clips.
    @ScaledMetric(relativeTo: .body) private var readoutWidth: CGFloat = 56
    @State private var haptic = UISelectionFeedbackGenerator()

    private var isAtZero: Bool { abs(degrees) < 0.01 }

    var body: some View {
        HStack(spacing: BSCSpacing.md) {
            stepButton(systemImage: "minus", label: "Decrease angle") { set(degrees - step) }

            Slider(value: Binding(get: { degrees }, set: { set($0) }), in: -maxDegrees...maxDegrees, step: step)
                .tint(.bscPrimary)
                .accessibilityLabel("Rotation angle")
                .accessibilityValue(Self.format(degrees))

            stepButton(systemImage: "plus", label: "Increase angle") { set(degrees + step) }

            Text(Self.format(degrees))
                .bscFont(size: 13, weight: .medium, design: .monospaced)
                .foregroundColor(.bscPrimary)
                .frame(width: readoutWidth, alignment: .trailing)
                // The slider already speaks this value.
                .accessibilityHidden(true)

            Button { set(0) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .bscFont(size: 12, weight: .semibold)
                    .foregroundColor(Color.bscOnMedia.opacity(isAtZero ? 0.3 : 0.9))
                    .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .disabled(isAtZero)
            .accessibilityLabel("Reset angle")
        }
        .onAppear { haptic.prepare() }
    }

    private func stepButton(systemImage: String, label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .bscFont(size: 13, weight: .bold)
                .foregroundColor(.bscOnMedia)
                .frame(width: 28, height: 28)
                .background(Color.bscOnMedia.opacity(0.15))
                .clipShape(Circle())
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(label))
    }

    /// Clamp to ±maxDegrees, snap to the step, and tick when it lands on a new step.
    private func set(_ value: Double) {
        let clamped = min(maxDegrees, max(-maxDegrees, value))
        let snapped = step > 0 ? (clamped / step).rounded() * step : clamped
        guard snapped != degrees else { return }
        haptic.selectionChanged()
        haptic.prepare()
        degrees = snapped
    }

    private static func format(_ degrees: Double) -> String {
        degrees.formattedSignedDegrees()
    }
}

#Preview {
    @Previewable @State var degrees = 2.5
    BSCStraightenControl(degrees: $degrees)
        .padding()
        .background(Color.bscMediaBackground)
}
