//
//  SamplerReviewCanvas.swift
//  RallyLab
//

import SwiftUI

/// The selected frame with editable boxes. All hit-testing happens in the
/// fitted image rect; boxes stay Vision-normalized in the model.
struct ReviewCanvas: View {
    @Bindable var sampler: SamplerModel
    let sample: FrameSample

    private enum Drag {
        case draw(origin: CGPoint)
        case move(boxId: UUID, original: CGRect, start: CGPoint)
        case resize(boxId: UUID, original: CGRect, anchor: CGPoint)
    }
    @State private var drag: Drag?
    @State private var liveRect: CGRect?
    private let handleRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let image = sampler.preview ?? sample.thumbnail
            let imgSize = CGSize(width: image.width, height: image.height)
            let fit = OverlayGeometry.fittedRect(content: imgSize, in: geo.size)

            Canvas { ctx, _ in
                ctx.draw(Image(decorative: image, scale: 1, orientation: .up), in: fit)
                for box in sample.boxes {
                    let isSelected = box.id == sampler.selectedBoxId
                    let boxRect = OverlayGeometry.rect(box.rect, turns: 0, in: fit)
                    let screen = (isSelected && drag != nil) ? (liveRect ?? boxRect) : boxRect
                    let color: Color = box.confidence == nil ? .green : .yellow
                    ctx.stroke(Path(screen), with: .color(color), lineWidth: isSelected ? 3 : 2)
                    if isSelected {
                        for corner in corners(of: screen) {
                            ctx.fill(Path(ellipseIn: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)), with: .color(color))
                        }
                    }
                    if let c = box.confidence {
                        ctx.draw(Text(String(format: "%.2f", c)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.black),
                                 at: CGPoint(x: screen.minX + 14, y: screen.minY - 7))
                    }
                }
                if case .draw = drag, let live = liveRect {
                    ctx.stroke(Path(live), with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                if !sample.keep {
                    ctx.fill(Path(fit), with: .color(.black.opacity(0.5)))
                    ctx.draw(Text("DISCARDED — K to keep").font(.headline).foregroundStyle(.white), at: CGPoint(x: fit.midX, y: fit.midY))
                }
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .gesture(dragGesture(fit: fit))
        }
    }

    private func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func dragGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil { drag = beginDrag(at: value.startLocation, fit: fit) }
                guard let drag else { return }
                switch drag {
                case .draw(let origin):
                    liveRect = CGRect(x: min(origin.x, value.location.x), y: min(origin.y, value.location.y),
                                      width: abs(value.location.x - origin.x), height: abs(value.location.y - origin.y))
                case .move(_, let original, let start):
                    liveRect = original.offsetBy(dx: value.location.x - start.x, dy: value.location.y - start.y)
                case .resize(_, _, let anchor):
                    liveRect = CGRect(x: min(anchor.x, value.location.x), y: min(anchor.y, value.location.y),
                                      width: abs(value.location.x - anchor.x), height: abs(value.location.y - anchor.y))
                }
            }
            .onEnded { _ in
                defer { drag = nil; liveRect = nil }
                guard let drag, let live = liveRect else { return }
                let normalized = normalize(live, in: fit)
                switch drag {
                case .draw:
                    if live.width > 4, live.height > 4 { sampler.addBox(normalized) }
                case .move(let boxId, _, _), .resize(let boxId, _, _):
                    sampler.updateBox(boxId, rect: normalized)
                }
            }
    }

    /// Corner handle of the selected box → resize; inside any box → move
    /// (and select it); empty space → draw.
    private func beginDrag(at p: CGPoint, fit: CGRect) -> Drag {
        if let selectedId = sampler.selectedBoxId,
           let box = sample.boxes.first(where: { $0.id == selectedId }) {
            let screen = OverlayGeometry.rect(box.rect, turns: 0, in: fit)
            for corner in corners(of: screen) where hypot(corner.x - p.x, corner.y - p.y) <= handleRadius {
                let anchor = CGPoint(x: corner.x == screen.minX ? screen.maxX : screen.minX,
                                     y: corner.y == screen.minY ? screen.maxY : screen.minY)
                return .resize(boxId: box.id, original: screen, anchor: anchor)
            }
        }
        // Smallest box under the cursor wins, so a ball inside a bigger
        // mistaken box is still reachable.
        let hit = sample.boxes
            .map { ($0, OverlayGeometry.rect($0.rect, turns: 0, in: fit)) }
            .filter { $0.1.insetBy(dx: -4, dy: -4).contains(p) }
            .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        if let (box, screen) = hit {
            sampler.selectedBoxId = box.id
            return .move(boxId: box.id, original: screen, start: p)
        }
        sampler.selectedBoxId = nil
        return .draw(origin: p)
    }

    /// Screen rect inside `fit` → Vision-normalized (origin bottom-left).
    private func normalize(_ r: CGRect, in fit: CGRect) -> CGRect {
        let x = (r.minX - fit.minX) / fit.width
        let w = r.width / fit.width
        let yTop = (r.minY - fit.minY) / fit.height
        let h = r.height / fit.height
        return CGRect(x: x, y: 1 - yTop - h, width: w, height: h)
    }
}
