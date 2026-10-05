//
//  CameraSetupPickerView.swift
//  BumpSetCut
//
//  Before processing: where was the video filmed from? A top-down court with
//  a camera pin to drag anywhere around it, the recommended spot marked, and
//  what to expect from the chosen angle. The pick sets the angle-dependent
//  rules (see ProcessorConfig.applyCamera) and is kept with the video.
//

import SwiftUI

struct CameraSetupPickerView: View {
    let onContinue: (CameraSetup) -> Void
    let onCancel: () -> Void

    @State private var setup: CameraSetup

    init(initial: CameraSetup?, onContinue: @escaping (CameraSetup) -> Void, onCancel: @escaping () -> Void) {
        self.onContinue = onContinue
        self.onCancel = onCancel
        _setup = State(initialValue: initial ?? .recommended)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BSCSpacing.lg) {
                    Text("Drag the camera to where you filmed from.")
                        .bscFont(size: 15)
                        .foregroundColor(.bscTextSecondary)

                    CourtDiagram(setup: $setup)
                        .frame(maxWidth: .infinity)
                        .frame(height: 380)

                    zoneSummary

                    presetRow

                    heightPicker
                }
                .padding(BSCSpacing.lg)
            }
            .background(Color.bscBackground.ignoresSafeArea())
            .navigationTitle("Where did you film from?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: BSCSpacing.sm) {
                    BSCButton(title: "Continue", style: .primary, size: .large, isFullWidth: true) {
                        onContinue(setup)
                    }
                    .accessibilityIdentifier(AccessibilityID.Process.cameraSetupContinue)
                    if setup != .recommended {
                        BSCButton(title: "Use recommended setup", style: .secondary, size: .medium, isFullWidth: true) {
                            withAnimation(.bscSnappy) { setup = .recommended }
                        }
                    }
                }
                .padding(BSCSpacing.lg)
                .background(Color.bscBackground)
            }
        }
    }

    // MARK: - Zone summary

    private var zoneSummary: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            HStack(spacing: BSCSpacing.xs) {
                Image(systemName: setup.zone.icon)
                    .foregroundColor(.bscPrimaryText)
                    .accessibilityHidden(true)
                Text(setup.zone.title)
                    .bscFont(size: 17, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                Text("· \(Int(setup.viewingAngleDegrees.rounded()))°")
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
                    .accessibilityLabel(Text("\(Int(setup.viewingAngleDegrees.rounded())) degrees off the court's long axis"))
                if setup == .recommended {
                    Text("Recommended")
                        .bscFont(size: 12, weight: .semibold)
                        .foregroundColor(.bscSuccessText)
                        .padding(.horizontal, BSCSpacing.sm)
                        .padding(.vertical, BSCSpacing.xxs)
                        .background(Capsule().fill(Color.bscSuccessText.opacity(0.12)))
                }
            }
            .accessibilityElement(children: .combine)
            Text(tip)
                .bscFont(size: 14)
                .foregroundColor(.bscTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BSCSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous).fill(Color.bscSurfaceGlass))
    }

    /// What to expect from this spot, and how it compares to the recommended one.
    private var tip: String {
        switch (setup.zone, setup.height) {
        case (.endline, .raised):
            return String(localized: "Best results: the whole court in frame and the net running across it. Landscape, on a tripod or in the stands.")
        case (.endline, .ground):
            return String(localized: "Good. Raising the phone 2 m or more — stands, a tripod or a fence — stops players blocking the ball.")
        case (.corner, _):
            return String(localized: "Works, but filtering out rallies on a neighbouring court is off from a corner, so some may be included. Behind an end line gives the best results.")
        case (.sideline, _):
            return String(localized: "Works, but filtering out rallies on a neighbouring court is off from the side, so some may be included. Behind an end line gives the best results.")
        }
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: BSCSpacing.sm) {
            ForEach(CameraZone.allCases, id: \.self) { zone in
                Button {
                    withAnimation(.bscSnappy) {
                        setup = CameraSetup(position: zone.presetPosition, height: setup.height)
                    }
                } label: {
                    VStack(spacing: BSCSpacing.xxs) {
                        Image(systemName: zone.icon)
                            .bscFont(size: 16)
                        Text(zone.title)
                            .bscFont(size: 13, weight: .medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: BSCTouchTarget.standard)
                    .padding(.vertical, BSCSpacing.xs)
                    .foregroundColor(setup.zone == zone ? .bscOnPrimary : .bscTextPrimary)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                            .fill(setup.zone == zone ? Color.bscPrimaryFill : Color.bscSurfaceGlass)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(setup.zone == zone ? .isSelected : [])
            }
        }
    }

    // MARK: - Height

    private var heightPicker: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            Text("Camera height")
                .bscFont(size: 13, weight: .semibold)
                .foregroundColor(.bscTextSecondary)
            Picker("Camera height", selection: $setup.height) {
                Text("Raised (2 m+)").tag(CameraHeight.raised)
                Text("Ground level").tag(CameraHeight.ground)
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Court diagram

/// Top-down court, long axis vertical, with the camera pin and its sight cone.
private struct CourtDiagram: View {
    @Binding var setup: CameraSetup

    /// Court units → points: x in half-widths, y in half-lengths (twice as long).
    private func layout(in size: CGSize) -> (scale: CGFloat, center: CGPoint) {
        let worldWidth = CameraSetup.maxReach.width * 2
        let worldHeight = CameraSetup.maxReach.height * 2 * CameraSetup.courtLengthToWidth
        let scale = min(size.width / worldWidth, size.height / worldHeight)
        return (scale, CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private func point(_ court: CGPoint, _ scale: CGFloat, _ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + court.x * scale,
                y: center.y - court.y * CameraSetup.courtLengthToWidth * scale)
    }

    private func court(_ point: CGPoint, _ scale: CGFloat, _ center: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - center.x) / scale,
                y: -(point.y - center.y) / (CameraSetup.courtLengthToWidth * scale))
    }

    var body: some View {
        GeometryReader { geo in
            let (scale, center) = layout(in: geo.size)
            let pin = point(setup.position, scale, center)
            let recommended = point(CameraSetup.recommended.position, scale, center)

            ZStack {
                Canvas { context, _ in
                    let half = CGSize(width: scale, height: scale * CameraSetup.courtLengthToWidth)
                    let courtRect = CGRect(x: center.x - half.width, y: center.y - half.height,
                                           width: half.width * 2, height: half.height * 2)

                    // Sight cone: from the camera toward the court centre.
                    let toward = CGPoint(x: center.x - pin.x, y: center.y - pin.y)
                    let length = hypot(toward.x, toward.y)
                    if length > 1 {
                        let direction = atan2(toward.y, toward.x)
                        let spread: CGFloat = .pi / 6
                        let reach = length * 1.6
                        var cone = Path()
                        cone.move(to: pin)
                        cone.addLine(to: CGPoint(x: pin.x + cos(direction - spread) * reach,
                                                 y: pin.y + sin(direction - spread) * reach))
                        cone.addLine(to: CGPoint(x: pin.x + cos(direction + spread) * reach,
                                                 y: pin.y + sin(direction + spread) * reach))
                        cone.closeSubpath()
                        context.fill(cone, with: .color(Color.bscPrimary.opacity(0.14)))
                    }

                    context.fill(Path(courtRect), with: .color(Color.bscPrimary.opacity(0.08)))
                    context.stroke(Path(courtRect), with: .color(Color.bscTextSecondary), lineWidth: 2)

                    // Attack lines, 3 m from the net (a third of each half).
                    for side in [-1.0, 1.0] {
                        let y = center.y - CGFloat(side) * half.height / 3
                        var line = Path()
                        line.move(to: CGPoint(x: courtRect.minX, y: y))
                        line.addLine(to: CGPoint(x: courtRect.maxX, y: y))
                        context.stroke(line, with: .color(Color.bscTextSecondary.opacity(0.6)), lineWidth: 1)
                    }

                    // Net, overhanging the sidelines to the posts.
                    var net = Path()
                    net.move(to: CGPoint(x: courtRect.minX - 6, y: center.y))
                    net.addLine(to: CGPoint(x: courtRect.maxX + 6, y: center.y))
                    context.stroke(net, with: .color(Color.bscTextPrimary), lineWidth: 4)
                }
                .accessibilityHidden(true)

                Text("NET")
                    .bscFont(size: 10, weight: .bold)
                    .foregroundColor(.bscTextSecondary)
                    .position(x: center.x, y: center.y - 12)
                    .accessibilityHidden(true)

                // Recommended spot.
                Circle()
                    .strokeBorder(Color.bscSuccessText, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: 44, height: 44)
                    .position(recommended)
                    .accessibilityHidden(true)

                // Camera pin.
                Image(systemName: "video.fill")
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscOnPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.bscPrimaryFill))
                    .shadow(color: Color.bscMediaScrimBase.opacity(0.3), radius: 3, y: 1)
                    .position(pin)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        setup = CameraSetup(position: court(value.location, scale, center), height: setup.height)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Court diagram"))
            .accessibilityValue(Text("Camera at \(setup.zone.title), \(Int(setup.viewingAngleDegrees.rounded())) degrees"))
            .accessibilityHint(Text("Swipe up or down to move the camera between end line, corner and sideline."))
            .accessibilityAdjustableAction { direction in
                let zones = CameraZone.allCases
                guard let index = zones.firstIndex(of: setup.zone) else { return }
                let next = direction == .increment ? min(index + 1, zones.count - 1) : max(index - 1, 0)
                setup = CameraSetup(position: zones[next].presetPosition, height: setup.height)
            }
        }
    }
}

// MARK: - Zone icon

extension CameraZone {
    var icon: String {
        switch self {
        case .endline: return "arrow.up.to.line"
        case .corner: return "arrow.up.right"
        case .sideline: return "arrow.right.to.line"
        }
    }
}

#Preview {
    CameraSetupPickerView(initial: nil, onContinue: { _ in }, onCancel: {})
}
