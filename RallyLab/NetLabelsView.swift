//
//  NetLabelsView.swift
//  RallyLab
//
//  The Net labels tab: the project's recordings on the left, the chosen frame
//  on the right with the net box to confirm, move, resize or draw. Return
//  confirms and moves to the next recording to label.
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
                    HStack(spacing: 6) {
                        Image(systemName: item.labeled ? "checkmark.circle.fill" : item.stale ? "exclamationmark.triangle" : item.skip == nil ? "circle" : "minus.circle")
                            .foregroundStyle(item.labeled ? .green : item.stale ? .red : item.skip == nil ? .secondary : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.video).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Text(item.skip.map { "skipped: \($0.rawValue)" } ?? (item.stale ? "label on file is another recording's" : item.camera))
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
                    NetBoxEditor(fit: fit, box: model.box, proposal: model.proposal) { model.setBox($0) }
                } else if model.loading {
                    ProgressView()
                } else if model.blocked != nil {
                    ContentUnavailableView("Nothing can be labeled", systemImage: "lock.fill", description: Text(model.blocked ?? ""))
                } else if let item = model.selectedItem, let skip = item.skip {
                    ContentUnavailableView("Skipped: \(skip.rawValue)", systemImage: "minus.circle",
                                           description: Text(skip == .withheld ? "A withheld recording is never opened here." : skip == .handheld ? "Handheld: the net doesn't hold still." : "No file identity for this recording."))
                } else if model.selected == nil {
                    ContentUnavailableView("Pick a recording", systemImage: "rectangle.split.3x1",
                                           description: Text("\(model.toLabelCount) to label. Return confirms the box and goes to the next one."))
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
            Divider().frame(height: 18)
            Button("Use proposal") { model.useProposal() }.disabled(model.proposal == nil)
            Button("Clear") { model.clearBox() }.disabled(model.box == nil)
            Spacer()
            if let item = model.selectedItem, let skip = item.skip {
                Text("Skipped: \(skip.rawValue)").font(.caption).foregroundStyle(.orange)
            } else {
                boxReadout
            }
            Button("Remove label", role: .destructive) { model.removeLabel() }.disabled(model.selectedItem.map { $0.labeled || $0.stale } != true)
            Button("Next to label") { model.nextToLabel() }.disabled(model.toLabelCount == 0)
            Button("Confirm ⏎") { model.confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
        }
        .disabled(model.blocked != nil)
    }

    private var boxReadout: some View {
        Group {
            if let b = model.box {
                Text(String(format: "net top y %.3f · x %.3f–%.3f", b.maxY, b.minX, b.maxX) + (model.proposed && !model.adjusted ? " · proposal" : model.adjusted ? " · adjusted" : ""))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The box over the fitted frame: drag inside to move, a corner to resize,
/// outside to draw a new one. Boxes are Vision-normalised; `fit` maps them.
private struct NetBoxEditor: View {
    let fit: CGRect
    let box: CGRect?
    let proposal: CGRect?
    let changed: (CGRect) -> Void

    private enum Grip: Equatable { case move, corner(Int), draw }
    @State private var grip: Grip?
    @State private var startBox: CGRect?
    @State private var startPoint: CGPoint = .zero
    @State private var live: CGRect?

    private static let handle: CGFloat = 14

    var body: some View {
        Canvas { ctx, _ in
            if let p = proposal, p != (live ?? box) {
                ctx.stroke(Path(OverlayGeometry.rect(p, turns: 0, in: fit)), with: .color(.cyan.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let b = live ?? box {
                let r = OverlayGeometry.rect(b, turns: 0, in: fit)
                ctx.stroke(Path(r), with: .color(.cyan), lineWidth: 2)
                var tape = Path(); tape.move(to: CGPoint(x: r.minX, y: r.minY)); tape.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                ctx.stroke(tape, with: .color(.yellow), lineWidth: 3)
                for c in Self.corners(of: r) {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.cyan))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged(dragChanged).onEnded(dragEnded))
    }

    private static func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// A view point as a Vision-normalised point in the frame (clamped to it).
    private func vision(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - fit.minX) / fit.width)), y: min(1, max(0, 1 - (p.y - fit.minY) / fit.height)))
    }

    private func dragChanged(_ drag: DragGesture.Value) {
        if grip == nil {
            startPoint = drag.startLocation
            if let b = box {
                let r = OverlayGeometry.rect(b, turns: 0, in: fit)
                if let i = Self.corners(of: r).firstIndex(where: { hypot($0.x - drag.startLocation.x, $0.y - drag.startLocation.y) <= Self.handle }) {
                    grip = .corner(i); startBox = b
                } else if r.contains(drag.startLocation) {
                    grip = .move; startBox = b
                } else { grip = .draw }
            } else { grip = .draw }
        }
        let a = vision(startPoint), p = vision(drag.location)
        switch grip {
        case .move:
            guard let s = startBox else { return }
            var moved = s.offsetBy(dx: p.x - a.x, dy: p.y - a.y)
            moved.origin.x = min(max(0, moved.origin.x), 1 - s.width)
            moved.origin.y = min(max(0, moved.origin.y), 1 - s.height)
            live = moved
        case .corner(let i):
            guard let s = startBox else { return }
            // The corner opposite the one dragged stays put.
            let anchor: CGPoint = [CGPoint(x: s.maxX, y: s.minY), CGPoint(x: s.minX, y: s.minY),
                                   CGPoint(x: s.minX, y: s.maxY), CGPoint(x: s.maxX, y: s.maxY)][i]
            live = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(anchor.x - p.x), height: abs(anchor.y - p.y))
        case .draw:
            live = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
        case nil:
            break
        }
    }

    private func dragEnded(_ drag: DragGesture.Value) {
        dragChanged(drag)
        if let live, live.width > 0.005, live.height > 0.005 { changed(live) }
        grip = nil; startBox = nil; live = nil
    }
}
