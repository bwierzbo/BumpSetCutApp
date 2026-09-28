//
//  SamplerReviewCanvas.swift
//  RallyLab
//

import AppKit
import SwiftUI

/// The selected frame with editable boxes. The image is drawn into a view
/// rect that is the fitted rect scaled by the review zoom around
/// `zoomCenter`; all drawing and hit-testing go through it, and boxes stay
/// Vision-normalized in the model.
///
/// Pinch or ⌘-scroll zooms around the pointer, two-finger scroll pans when
/// zoomed in; the tab's keys do the rest (= - 0 Z).
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
    @State private var pinchBase: CGFloat?
    @State private var hoverPoint: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var monitor: Any?
    private let handleRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let image = sampler.preview ?? sample.thumbnail
            let imgSize = CGSize(width: image.width, height: image.height)
            let view = viewRect(image: imgSize, canvas: geo.size)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    ctx.draw(Image(decorative: image, scale: 1, orientation: .up), in: view)
                    if sampler.contextPlayer == nil { drawBoxes(in: &ctx, view: view) }
                    if case .draw = drag, let live = liveRect {
                        ctx.stroke(Path(live), with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                    if !sample.keep {
                        ctx.fill(Path(view), with: .color(.black.opacity(0.5)))
                        ctx.draw(Text("DISCARDED — K to keep").font(.headline).foregroundStyle(.white),
                                 at: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
                    }
                }

                // The context loop sits exactly over the frame, at the same zoom.
                if let player = sampler.contextPlayer {
                    LabPlayerView(player: player, showsControls: false)
                        .frame(width: view.width, height: view.height)
                        .offset(x: view.minX, y: view.minY)
                        .allowsHitTesting(false)
                    Text("Playing ±0.75 s at half speed — P to stop")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                }

                if sampler.zoom > 1.01 {
                    Text(String(format: "%.1f×", sampler.zoom))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(dragGesture(view: view))
            .simultaneousGesture(pinch(view: view))
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverPoint = p } else { hoverPoint = nil }
            }
            .onAppear { canvasSize = geo.size; installScrollMonitor(imageSize: imgSize) }
            .onChange(of: geo.size) { _, size in canvasSize = size }
            .onDisappear(perform: removeScrollMonitor)
        }
    }

    // MARK: - Geometry

    /// The fitted rect scaled by the zoom, positioned so `zoomCenter` (a
    /// top-left normalized image point) sits at the middle of the canvas.
    private func viewRect(image: CGSize, canvas: CGSize) -> CGRect {
        let fit = OverlayGeometry.fittedRect(content: image, in: canvas)
        let w = fit.width * sampler.zoom, h = fit.height * sampler.zoom
        return CGRect(x: canvas.width / 2 - sampler.zoomCenter.x * w,
                      y: canvas.height / 2 - sampler.zoomCenter.y * h,
                      width: w, height: h)
    }

    /// Canvas point → top-left normalized image point.
    private func imagePoint(_ p: CGPoint, in view: CGRect) -> CGPoint {
        CGPoint(x: (p.x - view.minX) / view.width, y: (p.y - view.minY) / view.height)
    }

    /// Zoom by `factor`, keeping the image point under `anchor` fixed.
    private func zoom(by factor: CGFloat, anchor: CGPoint?, view: CGRect) {
        let old = sampler.zoom
        let new = min(max(old * factor, 1), SamplerModel.maxZoom)
        guard new != old else { return }
        guard let anchor else { sampler.setZoom(new); return }
        let target = imagePoint(anchor, in: view)
        let offsetX = (anchor.x - canvasSize.width / 2) / (view.width / old * new)
        let offsetY = (anchor.y - canvasSize.height / 2) / (view.height / old * new)
        sampler.setZoom(new, around: CGPoint(x: target.x - offsetX, y: target.y - offsetY))
    }

    private func pinch(view: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? sampler.zoom
                if pinchBase == nil { pinchBase = base }
                zoom(by: (base * value.magnification) / sampler.zoom, anchor: value.startLocation, view: view)
            }
            .onEnded { _ in pinchBase = nil }
    }

    /// Scroll: pan when zoomed in; ⌘-scroll (a mouse wheel) zooms around the
    /// pointer. Only while the pointer is over the canvas.
    private func installScrollMonitor(imageSize: CGSize) {
        removeScrollMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let hover = hoverPoint else { return event }
            let view = viewRect(image: imageSize, canvas: canvasSize)
            if event.modifierFlags.contains(.command) {
                zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)),
                     anchor: hover, view: view)
                return nil
            }
            guard sampler.zoom > 1.01 else { return event }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            sampler.pan(dx: -event.scrollingDeltaX * scale / view.width,
                        dy: -event.scrollingDeltaY * scale / view.height)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: - Boxes

    private func drawBoxes(in ctx: inout GraphicsContext, view: CGRect) {
        for box in sample.boxes {
            let isSelected = box.id == sampler.selectedBoxId
            let boxRect = OverlayGeometry.rect(box.rect, turns: 0, in: view)
            let screen = (isSelected && drag != nil) ? (liveRect ?? boxRect) : boxRect
            let color: Color = box.confidence == nil ? .green : .yellow
            ctx.stroke(Path(screen), with: .color(color), lineWidth: isSelected ? 2.5 : 1.5)
            if isSelected {
                for corner in corners(of: screen) {
                    ctx.fill(Path(ellipseIn: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)), with: .color(color))
                }
            }
            if let c = box.confidence {
                ctx.draw(Text(String(format: "%.2f", c)).font(.system(size: 10, design: .monospaced)).foregroundStyle(color),
                         at: CGPoint(x: screen.minX + 14, y: screen.minY - 8))
            }
        }
    }

    private func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func dragGesture(view: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil { drag = beginDrag(at: value.startLocation, view: view) }
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
                let normalized = normalize(live, in: view)
                switch drag {
                case .draw:
                    if live.width > 3, live.height > 3 { sampler.addBox(normalized) }
                case .move(let boxId, _, _), .resize(let boxId, _, _):
                    sampler.updateBox(boxId, rect: normalized)
                }
            }
    }

    /// Corner handle of the selected box → resize; inside any box → move
    /// (and select it); empty space → draw.
    private func beginDrag(at p: CGPoint, view: CGRect) -> Drag {
        if let selectedId = sampler.selectedBoxId,
           let box = sample.boxes.first(where: { $0.id == selectedId }) {
            let screen = OverlayGeometry.rect(box.rect, turns: 0, in: view)
            for corner in corners(of: screen) where hypot(corner.x - p.x, corner.y - p.y) <= handleRadius {
                let anchor = CGPoint(x: corner.x == screen.minX ? screen.maxX : screen.minX,
                                     y: corner.y == screen.minY ? screen.maxY : screen.minY)
                return .resize(boxId: box.id, original: screen, anchor: anchor)
            }
        }
        // Smallest box under the cursor wins, so a ball inside a bigger
        // mistaken box is still reachable.
        let hit = sample.boxes
            .map { ($0, OverlayGeometry.rect($0.rect, turns: 0, in: view)) }
            .filter { $0.1.insetBy(dx: -4, dy: -4).contains(p) }
            .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        if let (box, screen) = hit {
            sampler.selectedBoxId = box.id
            return .move(boxId: box.id, original: screen, start: p)
        }
        sampler.selectedBoxId = nil
        return .draw(origin: p)
    }

    /// Screen rect inside `view` → Vision-normalized (origin bottom-left).
    private func normalize(_ r: CGRect, in view: CGRect) -> CGRect {
        let x = (r.minX - view.minX) / view.width
        let w = r.width / view.width
        let yTop = (r.minY - view.minY) / view.height
        let h = r.height / view.height
        return CGRect(x: x, y: 1 - yTop - h, width: w, height: h)
    }
}
