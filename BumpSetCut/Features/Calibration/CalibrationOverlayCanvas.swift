//
//  CalibrationOverlayCanvas.swift
//  BumpSetCut
//
//  The video frame with the court and the net drawn over it, through a viewport: the
//  editor's picture, and the same picture magnified in its loupe. The court's lines join
//  the points as placed — each half is its own four-sided region in perspective, never a
//  rectangle on screen — with the centre line of each mapped half drawn through that
//  half's perspective map as a check on the placement.
//

import SwiftUI

struct CalibrationOverlayCanvas: View {
    let image: CGImage?
    let viewport: CalibrationViewport
    let shapes: CalibrationWorkingShapes
    let showCourt: Bool
    let showNet: Bool
    /// The shape being edited: its points are drawn as handles.
    let target: CalibrationTarget?
    let selected: CalibrationHandle?

    static let courtColor = Color.bscOrange
    static let netColor = Color.bscTeal

    var body: some View {
        Canvas { context, _ in
            let rect = viewport.frameRect
            if let image {
                context.draw(Image(decorative: image, scale: 1), in: rect)
            } else {
                context.fill(Path(rect), with: .color(.white.opacity(0.08)))
            }
            // The frame's edge, so room outside it reads as outside the picture.
            context.stroke(Path(rect), with: .color(.white.opacity(0.4)), lineWidth: 1)
            if showCourt { drawCourt(&context) }
            if showNet { drawNet(&context) }
        }
    }

    private func point(_ handle: CalibrationHandle) -> CGPoint? {
        shapes.position(handle).map { viewport.point(x: $0.x, y: $0.y) }
    }

    private func strokeLine(_ context: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, color: Color, width: CGFloat, dash: [CGFloat] = []) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        context.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: width + 2, lineCap: .round, dash: dash))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    private func drawCourt(_ context: inout GraphicsContext) {
        let editing = target == .court
        let color = Self.courtColor.opacity(editing ? 1 : 0.6)
        for (a, b) in CalibrationWorkingShapes.edges(of: .court) {
            guard let p = point(a), let q = point(b) else { continue }
            strokeLine(&context, p, q, color: color, width: 2.5)
        }
        for (from, to) in [(0.0, 0.5), (0.5, 1.0)] {
            guard shapes.court.map(near: from == 0) != nil, let a = shapes.court.image(u: 0.5, v: from), let b = shapes.court.image(u: 0.5, v: to) else { continue }
            strokeLine(&context, viewport.point(x: a.x, y: a.y), viewport.point(x: b.x, y: b.y), color: color.opacity(0.7), width: 1, dash: [5, 5])
        }
        guard editing else { return }
        for handle in CalibrationWorkingShapes.handles(of: .court) {
            guard case .court(let role) = handle, let p = point(handle) else { continue }
            drawHandle(&context, at: p, color: Self.courtColor, label: handle.shortName, estimated: shapes.court[role].status == .estimated, isSelected: selected == handle)
        }
    }

    private func drawNet(_ context: inout GraphicsContext) {
        let editing = target == .net
        let color = Self.netColor.opacity(editing ? 1 : 0.6)
        let corners = (0..<4).map { point(.net($0)) }
        if corners.allSatisfy({ $0 != nil }) {
            var fill = Path()
            fill.addLines(corners.compactMap { $0 })
            fill.closeSubpath()
            context.fill(fill, with: .color(Self.netColor.opacity(0.15)))
        }
        for (a, b) in CalibrationWorkingShapes.edges(of: .net) {
            guard let p = point(a), let q = point(b) else { continue }
            strokeLine(&context, p, q, color: color, width: 2.5)
        }
        guard editing else { return }
        for handle in CalibrationWorkingShapes.handles(of: .net) {
            guard let p = point(handle) else { continue }
            drawHandle(&context, at: p, color: Self.netColor, label: handle.shortName, estimated: false, isSelected: selected == handle)
        }
    }

    private func drawHandle(_ context: inout GraphicsContext, at p: CGPoint, color: Color, label: String, estimated: Bool, isSelected: Bool) {
        let radius: CGFloat = isSelected ? 11 : 8
        let circle = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        // The centre is left open so the corner under the point stays visible.
        context.stroke(circle, with: .color(.black.opacity(0.6)), lineWidth: 5)
        context.stroke(circle, with: .color(color), style: StrokeStyle(lineWidth: 3, dash: estimated ? [4, 3] : []))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(.white))
        if isSelected {
            let ring = Path(ellipseIn: CGRect(x: p.x - radius - 5, y: p.y - radius - 5, width: (radius + 5) * 2, height: (radius + 5) * 2))
            context.stroke(ring, with: .color(.white), lineWidth: 1.5)
        }
        let text = context.resolve(Text(label).font(.caption2.weight(.bold)).foregroundColor(.white))
        let size = text.measure(in: CGSize(width: 120, height: 40))
        let centre = CGPoint(x: p.x, y: p.y - radius - 12)
        let plate = CGRect(x: centre.x - size.width / 2 - 4, y: centre.y - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
        context.fill(Path(roundedRect: plate, cornerRadius: 4), with: .color(.black.opacity(0.6)))
        context.draw(text, at: centre)
    }
}

extension CalibrationHandle {
    /// A few letters, drawn beside the point.
    var shortName: String {
        switch self {
        case .court(.nearLeft): return String(localized: "Near L")
        case .court(.nearRight): return String(localized: "Near R")
        case .court(.netLeft): return String(localized: "Net L")
        case .court(.netRight): return String(localized: "Net R")
        case .court(.farLeft): return String(localized: "Far L")
        case .court(.farRight): return String(localized: "Far R")
        case .net(0): return String(localized: "Top L")
        case .net(1): return String(localized: "Top R")
        case .net(2): return String(localized: "Bottom R")
        case .net: return String(localized: "Bottom L")
        }
    }

    /// What the person is asked to tap.
    var prompt: String {
        switch self {
        case .court(.nearLeft): return String(localized: "Tap the court's near-left corner.")
        case .court(.nearRight): return String(localized: "Tap the court's near-right corner.")
        case .court(.netLeft): return String(localized: "Tap where the left sideline passes under the net.")
        case .court(.netRight): return String(localized: "Tap where the right sideline passes under the net.")
        case .court(.farLeft): return String(localized: "Tap the court's far-left corner.")
        case .court(.farRight): return String(localized: "Tap the court's far-right corner.")
        case .net(0): return String(localized: "Tap the net's top-left corner.")
        case .net(1): return String(localized: "Tap the net's top-right corner.")
        case .net(2): return String(localized: "Tap the net's bottom-right corner.")
        case .net: return String(localized: "Tap the net's bottom-left corner.")
        }
    }
}
