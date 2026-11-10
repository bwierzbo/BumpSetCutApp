//
//  CourtCalibrationView.swift
//  RallyLab
//
//  Player Lab's court-calibration mode (research P2): the frame with a margin around it
//  (so a corner below or beside the picture can still be placed), the court drawn over
//  it — dashed orange as proposed, cyan once moved, green when confirmed; the near half
//  tinted blue and the far half orange; filled dots on things seen, hollow on estimates —
//  and every player's ground point in the colour of its zone. Drag a dot to move a
//  point, drag the middle of a line to move the line, drag anywhere else to pan; zoom
//  with the slider or a pinch. Nothing here knows about homographies: the person moves
//  dots until the lines sit on the court, and presses Confirm.
//

import AppKit
import SwiftUI

struct CourtCalibrationEditor: View {
    @Bindable var model: PlayerLabModel
    @Bindable var court: CourtCalibrationModel
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var drag: DragTarget?

    private enum DragTarget {
        case point(CourtLayout.Role)
        case edge([CourtLayout.Role], start: CourtLayout, from: CGPoint)
        case pan
    }

    /// The frame and a quarter of it on every side.
    private let margin: CGFloat = 0.25

    private struct Mapping {
        let size: CGSize
        let fw: CGFloat, fh: CGFloat
        let scale: CGFloat
        let center: CGPoint
        func view(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + (CGFloat(x) - 0.5) * fw * scale, y: center.y - (CGFloat(y) - 0.5) * fh * scale)
        }
        func frame(_ p: CGPoint) -> (Double, Double) {
            (Double((p.x - center.x) / (fw * scale) + 0.5), Double(-(p.y - center.y) / (fh * scale) + 0.5))
        }
        var imageRect: CGRect {
            let tl = view(0, 1)
            return CGRect(x: tl.x, y: tl.y, width: fw * scale, height: fh * scale)
        }
    }

    private func mapping(_ size: CGSize) -> Mapping {
        let fw = CGFloat(court.binding.frameWidth), fh = CGFloat(court.binding.frameHeight)
        let base = min(size.width / (fw * (1 + 2 * margin)), size.height / (fh * (1 + 2 * margin)))
        return Mapping(size: size, fw: fw, fh: fh, scale: base * zoom * pinch,
                       center: CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height))
    }

    private static let edges: [[CourtLayout.Role]] = [[.nearLeft, .nearRight], [.netLeft, .netRight], [.farLeft, .farRight],
                                                        [.nearLeft, .netLeft], [.netLeft, .farLeft], [.nearRight, .netRight], [.netRight, .farRight]]

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let m = mapping(geo.size)
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
                    if let image = model.composed {
                        ctx.draw(Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))), in: m.imageRect)
                    }
                    ctx.stroke(Path(m.imageRect), with: .color(.white.opacity(0.4)), lineWidth: 1)
                    draw(&ctx, m)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(m))
                .simultaneousGesture(MagnifyGesture().onChanged { pinch = $0.magnification }.onEnded { zoom = min(12, max(0.5, zoom * $0.magnification)); pinch = 1 })
            }
            .frame(minHeight: 420)
            HStack {
                Text("Zoom").font(.caption)
                Slider(value: $zoom, in: 0.5...12).frame(width: 200)
                Button("Fit") { zoom = 1; pan = .zero }
                Spacer()
                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            swatch(Color(cgColor: PlayerLabModel.courtColor(.proposal)), "proposed")
            swatch(Color(cgColor: PlayerLabModel.courtColor(.adjusted)), "moved by you")
            swatch(Color(cgColor: PlayerLabModel.courtColor(.confirmed)), "confirmed")
            Text("● seen  ○ estimated").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func swatch(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 3) { Rectangle().fill(c).frame(width: 14, height: 4); Text(s).font(.caption2) }
    }

    private func draw(_ ctx: inout GraphicsContext, _ m: Mapping) {
        guard let shown = court.shown else { return }
        let g = shown.geometry
        let color = Color(cgColor: PlayerLabModel.courtColor(shown.style))
        func path(_ pts: [(Double, Double)]) -> Path {
            var p = Path()
            guard let f = pts.first else { return p }
            p.move(to: m.view(f.0, f.1))
            for q in pts.dropFirst() { p.addLine(to: m.view(q.0, q.1)) }
            p.closeSubpath()
            return p
        }
        let near = g.outline([(0, 0), (1, 0), (1, 0.5), (0, 0.5)]), far = g.outline([(0, 0.5), (1, 0.5), (1, 1), (0, 1)])
        ctx.fill(path(near), with: .color(Color(cgColor: PlayerOverlay.zoneColor(.nearCourt, alpha: 0.18))))
        ctx.fill(path(far), with: .color(Color(cgColor: PlayerOverlay.zoneColor(.farCourt, alpha: 0.18))))
        let style = StrokeStyle(lineWidth: 2, dash: shown.style == .proposal ? [8, 5] : [])
        ctx.stroke(path(near), with: .color(color), style: style)
        ctx.stroke(path(far), with: .color(color), style: style)
        let d = CourtZoneClassifier.Settings().serveDepthM / court.spec.lengthM, sm = CourtZoneClassifier.Settings().serveSideMargin
        let serve = StrokeStyle(lineWidth: 1, dash: [3, 4])
        if g.map(near: true) != nil { ctx.stroke(path(g.outline([(-sm, -d), (1 + sm, -d), (1 + sm, 0), (-sm, 0)])), with: .color(color.opacity(0.7)), style: serve) }
        if g.map(near: false) != nil { ctx.stroke(path(g.outline([(-sm, 1), (1 + sm, 1), (1 + sm, 1 + d), (-sm, 1 + d)])), with: .color(color.opacity(0.7)), style: serve) }
        // The net label (read only) for reference.
        if let n = court.net, n.corners.count == 4 {
            var p = Path()
            p.move(to: m.view(n.corners[0][0], n.corners[0][1]))
            for c in n.corners.dropFirst() + [n.corners[0]] { p.addLine(to: m.view(c[0], c[1])) }
            ctx.stroke(p, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
        guard court.draft != nil else { return }
        for e in Self.edges where e.allSatisfy({ g[$0].status != .unknown }) {
            let a = m.view(g[e[0]].x, g[e[0]].y), b = m.view(g[e[1]].x, g[e[1]].y)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            ctx.fill(Path(CGRect(x: mid.x - 4, y: mid.y - 4, width: 8, height: 8)), with: .color(color.opacity(0.8)))
        }
        for r in CourtLayout.Role.allCases where g[r].status != .unknown {
            let p = m.view(g[r].x, g[r].y)
            let rect = CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)
            if g[r].status == .seen { ctx.fill(Path(ellipseIn: rect), with: .color(color)) }
            ctx.stroke(Path(ellipseIn: rect), with: .color(court.selected == r ? .white : color), lineWidth: court.selected == r ? 3 : 2)
            ctx.draw(Text(r.label).font(.caption2.bold()).foregroundColor(.white), at: CGPoint(x: p.x, y: p.y - 16))
        }
    }

    private func hit(_ p: CGPoint, _ m: Mapping) -> DragTarget? {
        guard let g = court.draft else { return nil }
        if let r = CourtLayout.Role.allCases.filter({ g[$0].status != .unknown })
            .min(by: { hypot(m.view(g[$0].x, g[$0].y).x - p.x, m.view(g[$0].x, g[$0].y).y - p.y) < hypot(m.view(g[$1].x, g[$1].y).x - p.x, m.view(g[$1].x, g[$1].y).y - p.y) }),
           hypot(m.view(g[r].x, g[r].y).x - p.x, m.view(g[r].x, g[r].y).y - p.y) < 14 {
            return .point(r)
        }
        for e in Self.edges where e.allSatisfy({ g[$0].status != .unknown }) {
            let a = m.view(g[e[0]].x, g[e[0]].y), b = m.view(g[e[1]].x, g[e[1]].y)
            if hypot((a.x + b.x) / 2 - p.x, (a.y + b.y) / 2 - p.y) < 12 { return .edge(e, start: g, from: p) }
        }
        return nil
    }

    private func dragGesture(_ m: Mapping) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    drag = hit(v.startLocation, m) ?? .pan
                    if case .point(let r) = drag { court.selected = r }
                    panStart = pan
                }
                switch drag {
                case .point(let r):
                    let f = m.frame(v.location)
                    court.move(r, to: f.0, f.1)
                case .edge(let roles, let start, let from):
                    let a = m.frame(from), b = m.frame(v.location)
                    court.shift(roles, from: start, dx: b.0 - a.0, dy: b.1 - a.1)
                case .pan:
                    pan = CGSize(width: panStart.width + v.translation.width, height: panStart.height + v.translation.height)
                case nil: break
                }
            }
            .onEnded { _ in
                if case .pan = drag {} else if drag != nil { court.commit() }
                drag = nil
            }
    }
}

/// The calibration controls beside the picture.
struct CourtCalibrationPanel: View {
    @Bindable var model: PlayerLabModel
    @Bindable var court: CourtCalibrationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stale = court.stale {
                Text("Not usable: \(stale)").font(.caption).foregroundStyle(.red)
                Button("Start over for this file") { court.startOver() }
            }
            setupQuestions
            Divider()
            segments
            Divider()
            HStack {
                Button(court.proposing ? "Looking…" : "Propose automatically") { Task { await court.propose() } }
                    .disabled(court.proposing || court.stale != nil || court.needsAnswers)
                    .help(court.needsAnswers ? "Answer what marks the court first" : "")
                Button("Place by hand") { court.placeManually() }.disabled(court.stale != nil)
                if court.segment?.confirmation != nil, court.draft == nil { Button("Edit confirmed") { court.editConfirmed() } }
                if court.draft != nil { Button("Discard draft") { court.discardDraft() } }
            }
            if let seg = court.segment, !seg.latestProposals.isEmpty {
                HStack(spacing: 6) {
                    Text("Reset to:").font(.caption)
                    ForEach(seg.latestProposals, id: \.method) { p in
                        Button("\(p.method.label) \(String(format: "%.2f", p.confidence))") { court.use(p.method) }
                            .font(.caption)
                    }
                }
            }
            pointList
            HStack {
                Button("Confirm court") { court.confirm() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!court.canConfirm)
                Button("Reject proposals") { court.reject() }.disabled(court.stale != nil)
                Button("Camera changed here") { if let t = model.time { court.split(at: t) } }.disabled(court.stale != nil)
                Button("Not one court view") { court.markUnknownView() }.disabled(court.stale != nil)
            }
            if !court.problems.isEmpty { Text(court.problems.joined(separator: "; ")).font(.caption).foregroundStyle(.orange) }
            zoneCounts
            ForEach(court.notes, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(.secondary) }
            Text(court.message).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Asked once per recording: they pick the method and the court's size (metadata, never proof of the court).
    private var setupQuestions: some View {
        let s = court.setup
        return VStack(alignment: .leading, spacing: 4) {
            Text("About this court").font(.caption.bold())
            HStack {
                Picker("Surface", selection: Binding(get: { s.surface }, set: { court.answer(surface: .some($0)) })) {
                    Text("—").tag(CourtSetup.Surface?.none)
                    ForEach(CourtSetup.Surface.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                .frame(width: 170)
                Picker("Format", selection: Binding(get: { s.format }, set: { court.answer(format: .some($0)) })) {
                    Text("—").tag(CourtSetup.Format?.none)
                    ForEach(CourtSetup.Format.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                .frame(width: 150)
                Picker("Court marked by", selection: Binding(get: { s.markings }, set: { court.answer(markings: .some($0)) })) {
                    Text("— choose —").tag(CourtSetup.Markings?.none)
                    ForEach(CourtSetup.Markings.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .frame(width: 280)
            }
            .font(.caption)
            Text("Court size used: \(court.spec.source)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var segments: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("View segments (one per stable camera view)").font(.caption.bold())
            ForEach(court.file?.segments ?? []) { s in
                Button { court.selectSegment(s.id) } label: {
                    Text(String(format: "#%d  %.1f–%.1f s  %@%@", s.id, s.validFromSec, s.validToSec, s.status.rawValue,
                                s.confirmation.map { " by \($0.confirmedBy)" } ?? ""))
                        .font(.caption.monospaced()).fontWeight(s.id == court.segmentId ? .bold : .regular)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pointList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let g = court.draft {
                ForEach(CourtLayout.Role.allCases, id: \.self) { r in
                    HStack {
                        Text(r.label).font(.caption).frame(width: 70, alignment: .leading).fontWeight(court.selected == r ? .bold : .regular)
                        Picker("", selection: Binding(get: { g[r].status }, set: { court.setStatus(r, $0) })) {
                            Text("seen").tag(CourtPoint.Status.seen)
                            Text("estimated").tag(CourtPoint.Status.estimated)
                            Text("unknown").tag(CourtPoint.Status.unknown)
                        }
                        .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                        if g[r].status == .unknown {
                            Button("Place") {
                                // At the court's middle line height, beside the net: then drag it into place.
                                let n = g.netLeft, q = g.netRight
                                let x = [.nearLeft, .netLeft, .farLeft].contains(r) ? n.x : q.x
                                let y = (n.y + q.y) / 2 + ([.farLeft, .farRight].contains(r) ? 0.1 : (r.rawValue.hasPrefix("near") ? -0.2 : 0))
                                court.place(r, at: x, y)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var zoneCounts: some View {
        let c = model.zoneCounts
        return Text(c.isEmpty ? "No court covers this frame." :
            CourtZone.allCases.filter { c[$0] != nil }.map { "\(PlayerOverlay.short($0)) \(c[$0]!)" }.joined(separator: " · ") + "  (confirmed tracks, this frame)")
            .font(.caption)
    }
}
