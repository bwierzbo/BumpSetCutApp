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
                    if sampler.contextPlayer == nil {
                        drawGuides(in: &ctx, view: view)
                        drawBoxes(in: &ctx, view: view)
                    }
                    if let point = sampler.snapping {
                        let c = CGPoint(x: view.minX + point.x * view.width, y: view.minY + point.y * view.height)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)),
                                   with: .color(ReviewStyle.yours), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                    if case .draw = drag, let live = liveRect {
                        ctx.fill(Path(roundedRect: live, cornerRadius: 2), with: .color(ReviewStyle.yours.opacity(0.12)))
                        ctx.stroke(Path(roundedRect: live, cornerRadius: 2), with: .color(ReviewStyle.yours),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    }
                    if !sample.keep {
                        ctx.fill(Path(view), with: .color(.black.opacity(0.55)))
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)

                if !sample.keep {
                    Label("Discarded — press K to keep it", systemImage: "eye.slash")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                // The context loop sits exactly over the frame, at the same zoom.
                if let player = sampler.contextPlayer {
                    LabPlayerView(player: player, showsControls: false)
                        .frame(width: view.width, height: view.height)
                        .offset(x: view.minX, y: view.minY)
                        .allowsHitTesting(false)
                    Label("Playing ±0.75 s at half speed", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .top)
                }

                if sampler.zoom > 1.01 {
                    Button {
                        sampler.resetZoom()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.magnifyingglass")
                            Text(String(format: "%.1f×", sampler.zoom)).monospacedDigit()
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Back to fit (0)")
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(dragGesture(view: view))
            .simultaneousGesture(SpatialTapGesture().onEnded { tap($0.location, view: view) })
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

    /// Yours: solid green. The detector's guesses: dashed amber with their
    /// confidence on a tag. A ball is often a few pixels at fit, so small
    /// boxes also get a ring to find them by; the selected box gets a halo
    /// and handles.
    private func drawBoxes(in ctx: inout GraphicsContext, view: CGRect) {
        let confirmed = sample.reviewed && sample.keep
        for box in sample.boxes {
            let isSelected = box.id == sampler.selectedBoxId
            let boxRect = OverlayGeometry.rect(box.rect, turns: 0, in: view)
            let screen = (isSelected && drag != nil) ? (liveRect ?? boxRect) : boxRect
            let yours = confirmed || (box.confidence == nil && !box.held)
            let color = ReviewStyle.color(box, confirmed: confirmed)
            let outline = Path(roundedRect: screen, cornerRadius: min(3, screen.width / 4))

            if max(screen.width, screen.height) < 18 {
                let r = max(screen.width, screen.height) / 2 + 10
                let ring = CGRect(x: screen.midX - r, y: screen.midY - r, width: 2 * r, height: 2 * r)
                ctx.stroke(Path(ellipseIn: ring), with: .color(color.opacity(isSelected ? 0.95 : 0.7)), lineWidth: 1.5)
            }
            if isSelected {
                ctx.stroke(outline, with: .color(.white.opacity(0.85)), lineWidth: 5)
            }
            ctx.stroke(outline, with: .color(color),
                       style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.75, dash: yours ? [] : box.held ? [6, 3] : [4, 3]))
            if isSelected {
                for corner in corners(of: screen) {
                    let dot = CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)
                    ctx.fill(Path(ellipseIn: dot), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: dot), with: .color(color), lineWidth: 2)
                }
            }
            if !confirmed, box.held || box.confidence != nil {
                let label = ctx.resolve(Text(box.held ? "held" : String(format: "%.2f", box.confidence ?? 0))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.85)))
                let size = label.measure(in: CGSize(width: 80, height: 20))
                let ringPad: CGFloat = max(screen.width, screen.height) < 18 ? 12 : 4
                var tag = CGRect(x: screen.midX - size.width / 2 - 5, y: screen.minY - ringPad - size.height - 4,
                                 width: size.width + 10, height: size.height + 4)
                if tag.minY < view.minY { tag.origin.y = screen.maxY + ringPad }
                ctx.fill(Path(roundedRect: tag, cornerRadius: tag.height / 2), with: .color(color))
                ctx.draw(label, at: CGPoint(x: tag.midX, y: tag.midY))
            }
        }
    }

    /// Faint crosshair lines through the pointer over empty image, to line
    /// a new box up with the ball.
    private func drawGuides(in ctx: inout GraphicsContext, view: CGRect) {
        guard drag == nil, let p = hoverPoint, view.contains(p),
              !sample.boxes.contains(where: { OverlayGeometry.rect($0.rect, turns: 0, in: view).insetBy(dx: -4, dy: -4).contains(p) })
        else { return }
        var lines = Path()
        lines.move(to: CGPoint(x: view.minX, y: p.y)); lines.addLine(to: CGPoint(x: view.maxX, y: p.y))
        lines.move(to: CGPoint(x: p.x, y: view.minY)); lines.addLine(to: CGPoint(x: p.x, y: view.maxY))
        ctx.stroke(lines, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
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

    /// A click on a box selects it; on the image anywhere else, it's a ball
    /// to box.
    private func tap(_ p: CGPoint, view: CGRect) {
        guard sampler.contextPlayer == nil, view.contains(p) else { return }
        if let box = boxHit(at: p, view: view) {
            sampler.selectedBoxId = box.id
        } else {
            sampler.selectedBoxId = nil
            sampler.snapBox(at: imagePoint(p, in: view))
        }
    }

    /// The smallest box under the point, so a ball inside a bigger mistaken
    /// box is still reachable.
    private func boxHit(at p: CGPoint, view: CGRect) -> SampleBox? {
        sample.boxes
            .map { ($0, OverlayGeometry.rect($0.rect, turns: 0, in: view)) }
            .filter { $0.1.insetBy(dx: -4, dy: -4).contains(p) }
            .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
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
        if let box = boxHit(at: p, view: view) {
            sampler.selectedBoxId = box.id
            return .move(boxId: box.id, original: OverlayGeometry.rect(box.rect, turns: 0, in: view), start: p)
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
