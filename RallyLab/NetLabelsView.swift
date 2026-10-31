//
//  NetLabelsView.swift
//  RallyLab
//
//  The Net labels tab: the project's recordings on the left, the chosen frame
//  on the right with the net's four corners to place: drag a corner, drag the
//  whole net, or draw a new box outside it. Return confirms and moves to the
//  next recording to label. A vision model's proposal (sparkles in the list)
//  is placed as the corners to check; Reject turns it down.
//

import SwiftUI

struct NetLabelsView: View {
    @Bindable var model: NetLabelsModel
    let isActive: Bool
    @State private var hideSkipped = true
    @FocusState private var focused: Bool

    var body: some View {
        HSplitView {
            list.frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            VStack(spacing: 10) {
                picture.frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
            }
            .padding(12)
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: isActive) { _, active in if active { model.reload() } }
    }

    // MARK: - Recordings

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    .help("Read project.json and net-labels.json again")
            }
            .padding(.horizontal, 10).padding(.top, 8)
            Toggle("Hide skipped", isOn: $hideSkipped).toggleStyle(.checkbox).font(.caption).padding(.horizontal, 10)
            List(selection: Binding(get: { model.selected }, set: { if let v = $0 { model.select(v) } })) {
                ForEach(model.items.filter { !hideSkipped || $0.skip == nil }) { item in
                    let ai = model.offeredAI(item)
                    HStack(spacing: 6) {
                        Image(systemName: item.labeled ? "checkmark.circle.fill" : item.stale ? "exclamationmark.triangle" : item.boxOnly ? "square.dashed" : ai != nil ? "sparkles" : item.skip == nil ? "circle" : "minus.circle")
                            .foregroundStyle(item.labeled ? .green : item.stale ? .red : item.boxOnly ? .yellow : ai != nil ? .purple : item.skip == nil ? .secondary : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.video).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Text(item.skip.map { "skipped: \($0.rawValue)" } ?? (item.stale ? "label on file is another recording's" : item.boxOnly ? "box only — mark the corners"
                                 : ai.map { $0.outcome == .proposed ? "\($0.model) proposal (\($0.confidence?.rawValue ?? "unrated")) to review" : "\($0.model): needs manual review" } ?? item.camera))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(item.video)
                    .opacity(item.skip == nil ? 1 : 0.6)
                }
            }
        }
    }

    // MARK: - Frame and box

    private var picture: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let frame = model.frame {
                    let fit = OverlayGeometry.fittedRect(content: CGSize(width: frame.width, height: frame.height), in: geo.size)
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                    NetQuadEditor(fit: fit, quad: model.quad, proposal: model.proposal, drawn: { model.setBox($0) }, moved: { model.setQuad($0) })
                } else if model.loading {
                    ProgressView()
                } else if model.blocked != nil {
                    ContentUnavailableView("Nothing can be labeled", systemImage: "lock.fill", description: Text(model.blocked ?? ""))
                } else if let item = model.selectedItem, let skip = item.skip {
                    ContentUnavailableView("Skipped: \(skip.rawValue)", systemImage: "minus.circle",
                                           description: Text(skip == .withheld ? "A withheld recording is never opened here." : skip == .handheld ? "Handheld: the net doesn't hold still." : "No file identity for this recording."))
                } else if model.selected == nil {
                    ContentUnavailableView("Pick a recording", systemImage: "rectangle.split.3x1",
                                           description: Text("\(model.toLabelCount) to label. Drag the four corners onto the net's corners; Return confirms and goes to the next one."))
                } else {
                    ContentUnavailableView("No frame", systemImage: "film", description: Text(model.status))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .focusable()
        .focused($focused)
        .onKeyPress(.return) { model.confirm() ? .handled : .ignored }
        .onKeyPress(.leftArrow) { model.step(seconds: -1); return .handled }
        .onKeyPress(.rightArrow) { model.step(seconds: 1); return .handled }
        .onAppear { focused = true }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { model.step(seconds: -1) } label: { Image(systemName: "gobackward") }.help("A second earlier (←)")
            Text(NetLabelsModel.clock(model.time)).font(.system(.caption, design: .monospaced)).frame(width: 60)
            Button { model.step(seconds: 1) } label: { Image(systemName: "goforward") }.help("A second later (→)")
            if model.loading { ProgressView().controlSize(.small) }
            if let ahead = model.prefetching {
                // While this recording loads, the read-ahead finishes the file it is on and then waits.
                Text(model.loading ? "read-ahead waits after \(ahead) · \(model.prefetched.count) ready"
                                   : "reading ahead: \(ahead) · \(model.prefetched.count) ready")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if !model.prefetched.isEmpty {
                Text("\(model.prefetched.count) ready").font(.caption2).foregroundStyle(.secondary)
            }
            Divider().frame(height: 18)
            Button("Use proposal") { model.useProposal() }.disabled(!model.canUseProposal)
            if model.shownAI != nil {
                Button("Reject proposal") { model.rejectAIProposal() }
                    .help("Turn the vision model's proposal down; it is not offered again and the old model's box is proposed instead")
            }
            Button("Clear") { model.clearBox() }.disabled(model.quad == nil)
            Spacer()
            if let item = model.selectedItem, let skip = item.skip {
                Text("Skipped: \(skip.rawValue)").font(.caption).foregroundStyle(.orange)
            } else {
                boxReadout
            }
            Button("Remove label", role: .destructive) { model.removeLabel() }.disabled(model.selectedItem.map { $0.labeled || $0.stale || $0.boxOnly } != true)
            Button("Next to label") { model.nextToLabel() }.disabled(model.toLabelCount == 0)
            Button("Confirm ⏎") { model.confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
        }
        .disabled(model.blocked != nil)
    }

    private var boxReadout: some View {
        Group {
            if let q = model.quad {
                Text(String(format: "tape y L %.3f R %.3f · x %.3f–%.3f", q.topLeft.y, q.topRight.y, q.bounds.minX, q.bounds.maxX)
                     + (model.proposed && !model.adjusted ? (model.shownAI.map { " · \($0.model) proposal" } ?? " · proposal") : model.adjusted ? " · adjusted" : ""))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The net's corners over the fitted frame: drag a corner to place it, drag
/// inside the net to move all four, drag outside to draw a new box (its corners
/// are then dragged into place). Points are Vision-normalised; `fit` maps them.
private struct NetQuadEditor: View {
    let fit: CGRect
    let quad: NetQuad?
    let proposal: CGRect?
    /// A new box drawn outside the net.
    let drawn: (CGRect) -> Void
    /// A corner or the whole net dragged.
    let moved: (NetQuad) -> Void

    private enum Grip: Equatable { case move, corner(Int), draw }
    @State private var grip: Grip?
    @State private var startQuad: NetQuad?
    @State private var startPoint: CGPoint = .zero
    @State private var liveQuad: NetQuad?
    @State private var liveBox: CGRect?

    private static let handle: CGFloat = 14
    private static let cornerNames = ["top-left", "top-right", "bottom-right", "bottom-left"]

    var body: some View {
        Canvas { ctx, _ in
            if let p = proposal, quad.map({ NetQuad(rect: p) != $0 }) ?? true {
                ctx.stroke(Path(OverlayGeometry.rect(p, turns: 0, in: fit)), with: .color(.cyan.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let b = liveBox {
                ctx.stroke(Path(OverlayGeometry.rect(b, turns: 0, in: fit)), with: .color(.cyan), lineWidth: 2)
            } else if let q = liveQuad ?? quad {
                let c = screenCorners(of: q)
                var outline = Path(); outline.move(to: c[0]); for p in c.dropFirst() { outline.addLine(to: p) }; outline.closeSubpath()
                ctx.stroke(outline, with: .color(.cyan), lineWidth: 2)
                var tape = Path(); tape.move(to: c[0]); tape.addLine(to: c[1])
                ctx.stroke(tape, with: .color(.yellow), lineWidth: 3)
                for (i, p) in c.enumerated() {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(i < 2 ? .yellow : .cyan))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged(dragChanged).onEnded(dragEnded))
        .help("Drag a corner onto the net's corner (yellow: the tape ends); drag inside to move the net; drag outside to draw a new box.")
    }

    private func screenCorners(of q: NetQuad) -> [CGPoint] {
        q.points.map { OverlayGeometry.point($0, turns: 0, in: fit) }
    }

    /// A view point as a Vision-normalised point in the frame (clamped to it).
    private func vision(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - fit.minX) / fit.width)), y: min(1, max(0, 1 - (p.y - fit.minY) / fit.height)))
    }

    private func dragChanged(_ drag: DragGesture.Value) {
        if grip == nil {
            startPoint = drag.startLocation
            if let q = quad {
                let c = screenCorners(of: q)
                var inside = Path(); inside.move(to: c[0]); for p in c.dropFirst() { inside.addLine(to: p) }; inside.closeSubpath()
                if let i = c.firstIndex(where: { hypot($0.x - drag.startLocation.x, $0.y - drag.startLocation.y) <= Self.handle }) {
                    grip = .corner(i); startQuad = q
                } else if inside.contains(drag.startLocation) {
                    grip = .move; startQuad = q
                } else { grip = .draw }
            } else { grip = .draw }
        }
        let a = vision(startPoint), p = vision(drag.location)
        switch grip {
        case .move:
            guard let s = startQuad else { return }
            liveQuad = s.offset(dx: p.x - a.x, dy: p.y - a.y)
        case .corner(let i):
            guard let s = startQuad else { return }
            liveQuad = s.moving(corner: i, to: p)
        case .draw:
            liveBox = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
        case nil:
            break
        }
    }

    private func dragEnded(_ drag: DragGesture.Value) {
        dragChanged(drag)
        if let liveBox, liveBox.width > 0.005, liveBox.height > 0.005 { drawn(liveBox) }
        else if let liveQuad, liveQuad.isUsable { moved(liveQuad) }
        grip = nil; startQuad = nil; liveQuad = nil; liveBox = nil
    }
}
