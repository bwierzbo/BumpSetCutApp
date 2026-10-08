//
//  TrackReviewView.swift
//  RallyLab (iPhone)
//
//  Track a rally's ball by checking only the frames worth a look. Each one
//  is shown zoomed on the ball (or where it was last), its path through the
//  nearby frames drawn faintly. ✓ = right, tap the picture = the ball is
//  there (drag the box to move it, its corner handle to size it), Hidden =
//  can't be seen. Pinch to zoom,
//  drag the picture to look around. Every fix re-solves the rest of the rally,
//  so one tap often clears several frames. When nothing's left, watch it
//  once and mark it done. The strip along the top jumps anywhere.
//

import SwiftUI

struct TrackReviewView: View {
    @State private var session: TrackSession
    @State private var zoom: CGFloat = 3
    @State private var watching = false
    @Environment(\.dismiss) private var dismiss

    init(model: LabelerModel, video: LabelVideo, span: LabelRally? = nil, found: [Double]? = nil, track: LabelTrack? = nil) {
        _session = State(initialValue: TrackSession(model: model, video: video, span: span, found: found, track: track))
    }

    var body: some View {
        Group {
            switch session.phase {
            case .preparing(let what, let fraction):
                VStack(spacing: 14) {
                    ProgressView(value: fraction)
                    Text(what).font(.callout).foregroundStyle(.secondary)
                }
                .padding(40)
            case .failed(let why):
                ContentUnavailableView("Couldn't track this rally", systemImage: "exclamationmark.triangle", description: Text(why))
            case .reviewing:
                review
            }
        }
        .navigationTitle("\(RallyTimesView.clock(session.bounds.start)) · \(session.video.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.phase == .reviewing {
                ToolbarItem(placement: .topBarTrailing) { rallyMenu }
            }
        }
        .task { if session.frames.isEmpty { await session.prepare() } }
    }

    /// The rally's own start and end, more frames, or not a rally at all.
    private var rallyMenu: some View {
        Menu {
            Section("The rally (serve to dead ball): \(RallyTimesView.clock(session.bounds.start)) – \(RallyTimesView.clock(session.bounds.end))") {
                Button { session.setBound(start: true) } label: { Label("Rally starts on this frame", systemImage: "arrow.right.to.line") }
                Button { session.setBound(start: false) } label: { Label("Rally ends on this frame", systemImage: "arrow.left.to.line") }
            }
            Section("Frames") {
                Button { Task { await session.extend(before: 2) } } label: { Label("2 s more before", systemImage: "backward") }
                Button { Task { await session.extend(after: 2) } } label: { Label("2 s more after", systemImage: "forward") }
            }
            Button(role: .destructive) {
                session.discard()
                dismiss()
            } label: { Label("Not a rally", systemImage: "xmark.circle") }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private var review: some View {
        let left = session.toCheck.count
        return VStack(spacing: 10) {
            FrameStrip(session: session).frame(height: 26).padding(.horizontal)
            HStack {
                Text(left == 0 ? "Nothing left to check" : "\(left) to check")
                    .font(.headline).foregroundStyle(left == 0 ? .green : .primary)
                if session.isLookingAgain { ProgressView().controlSize(.mini).help("Looking again near your fix") }
                Spacer()
                let t = session.point?.time ?? 0
                Text(t < session.bounds.start ? "before the serve" : t > session.bounds.end ? "after the rally" : "in the rally")
                    .font(.caption).foregroundStyle(.secondary)
                Text("frame \(session.index + 1)/\(session.rally.points.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ZoomedFrame(session: session, zoom: $zoom, watching: watching)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 8)

            stateLine.padding(.horizontal)
            controls.padding(.horizontal).padding(.bottom, 8)
        }
        .sensoryFeedback(.selection, trigger: session.index)
    }

    private var stateLine: some View {
        let p = session.point
        let text: String = {
            guard let p else { return "" }
            switch (p.origin, p.state) {
            case (.user, .visible): return "Yours: the ball is here"
            case (.user, .hidden): return "Yours: hidden"
            case (_, .unknown): return "No ball found — tap it, or mark it hidden"
            case (.filled, _): return "Guessed between frames — is it right?"
            case (.auto, .visible): return String(format: "Found (%.0f%% sure)", (p.box?.confidence ?? 0) * 100)
            case (_, .hidden): return "Thought hidden"
            }
        }()
        return HStack {
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Picker("Zoom", selection: $zoom) {
                Text("1×").tag(CGFloat(1)); Text("3×").tag(CGFloat(3)); Text("6×").tag(CGFloat(6))
            }
            .pickerStyle(.segmented).frame(width: 140)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(maxWidth: .infinity) }
                    .disabled(!session.canUndo)
                Button { step(-1) } label: { Image(systemName: "backward.frame").frame(maxWidth: .infinity) }
                Button { step(1) } label: { Image(systemName: "forward.frame").frame(maxWidth: .infinity) }
                Button { session.nextToCheck() } label: { Image(systemName: "arrow.right.to.line").frame(maxWidth: .infinity) }
                    .disabled(session.toCheck.isEmpty)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 10) {
                Button {
                    session.markHidden()
                    session.nextToCheck()
                } label: { Label("Hidden", systemImage: "eye.slash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.gray)
                Button {
                    session.confirm()
                    session.nextToCheck()
                } label: { Label("Right", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(session.point?.state == .unknown)
            }
            .controlSize(.large)

            if session.toCheck.isEmpty {
                HStack(spacing: 10) {
                    Button { watch() } label: { Label(watching ? "Watching…" : "Watch it", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).disabled(watching)
                    Button {
                        session.setDone(true)
                        dismiss()
                    } label: { Label("Done", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        }
        .sensoryFeedback(.success, trigger: session.rally.done)
    }

    private func step(_ by: Int) {
        session.index = min(max(0, session.index + by), session.rally.points.count - 1)
    }

    /// Play the rally at half speed with the ball drawn.
    private func watch() {
        watching = true
        let start = max(0, session.index)
        Task {
            for i in start..<session.rally.points.count {
                guard watching else { break }
                session.index = i
                try? await Task.sleep(nanoseconds: 66_000_000)
            }
            watching = false
        }
    }
}

/// One cell per frame: green sure, yellow worth a look, grey hidden, red
/// nothing found. Drag along it to jump.
private struct FrameStrip: View {
    let session: TrackSession

    var body: some View {
        GeometryReader { geo in
            let n = max(session.rally.points.count, 1)
            let w = geo.size.width / CGFloat(n)
            Canvas { ctx, size in
                for (i, p) in session.rally.points.enumerated() {
                    let color: Color = p.state == .unknown ? .red : p.isUncertain ? .yellow
                        : p.state == .hidden ? .gray : (p.origin == .user ? .blue : .green)
                    ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: 0, width: max(w - 0.5, 0.5), height: size.height)), with: .color(color.opacity(0.75)))
                }
                // The rally's own start and end.
                for t in [session.bounds.start, session.bounds.end] {
                    if let k = session.rally.points.firstIndex(where: { $0.time >= t - 0.001 }) {
                        ctx.fill(Path(CGRect(x: CGFloat(k) * w - 1, y: -2, width: 2, height: size.height + 4)), with: .color(.white))
                    }
                }
                ctx.stroke(Path(CGRect(x: CGFloat(session.index) * w - 1, y: 0, width: max(w, 2) + 2, height: size.height)),
                           with: .color(.primary), lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                session.index = min(max(0, Int(v.location.x / w)), n - 1)
            })
        }
    }
}

/// The frame, zoomed on the ball, with its path and the current pick.
/// Tap to place the ball, drag the box to move it or its corner handle to
/// size it, drag elsewhere to look
/// around, pinch to zoom. The view stays put frame to frame (see `centre`).
private struct ZoomedFrame: View {
    let session: TrackSession
    @Binding var zoom: CGFloat
    let watching: Bool
    /// Where the view is centred (top-down fraction of the frame): where
    /// you last placed the ball or dragged to, kept frame to frame at your
    /// zoom — the ball moves a little a frame, so it stays in view. Nil
    /// (at first) centres on the ball. Moves to the ball when it's left the view.
    @State private var centre: CGPoint?
    @State private var panBase: CGPoint?
    @State private var viewSize: CGSize = .zero
    @State private var pinchBase: CGFloat?
    /// Where the box is being dragged to (view points).
    @State private var moving: CGPoint?
    /// The box's half-side while its corner handle is dragged (view points).
    @State private var resizing: CGFloat?

    var body: some View {
        GeometryReader { geo in
            if let image = session.image(session.index) {
                let size = geo.size
                let imgSize = image.size
                // Fit the frame, then zoom about the ball.
                let fit = min(size.width / imgSize.width, size.height / imgSize.height) * zoom
                let shown = CGSize(width: imgSize.width * fit, height: imgSize.height * fit)
                let c = centre ?? ballCentre ?? CGPoint(x: 0.5, y: 0.5)
                let origin = CGPoint(x: Self.clamp(size.width / 2 - c.x * shown.width, size.width, shown.width),
                                     y: Self.clamp(size.height / 2 - c.y * shown.height, size.height, shown.height))
                // The box on screen, at its real size.
                let box: CGRect? = {
                    guard let cur = session.point, let b = cur.box, cur.state == .visible else { return nil }
                    return CGRect(x: origin.x + b.x * shown.width, y: origin.y + (1 - b.y - b.h) * shown.height,
                                  width: b.w * shown.width, height: b.h * shown.height)
                }()
                let handle = box.map(Self.handle(for:))
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(uiImage: image).resizable().frame(width: shown.width, height: shown.height).offset(x: origin.x, y: origin.y)
                    Canvas { ctx, _ in
                        func pt(_ b: TrackCandidate) -> CGPoint {
                            CGPoint(x: origin.x + (b.x + b.w / 2) * shown.width, y: origin.y + (1 - b.y - b.h / 2) * shown.height)
                        }
                        // The path through nearby frames.
                        let near = max(0, session.index - 12)...min(session.rally.points.count - 1, session.index + 12)
                        for k in near where k != session.index {
                            guard let b = session.rally.points[k].box, session.rally.points[k].state == .visible else { continue }
                            let p = pt(b)
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                     with: .color(.cyan.opacity(k < session.index ? 0.45 : 0.25)))
                        }
                        if let moving, let box {
                            let r = CGRect(x: moving.x - box.width / 2, y: moving.y - box.height / 2, width: box.width, height: box.height)
                            ctx.stroke(Path(r.insetBy(dx: -1, dy: -1)), with: .color(.blue), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        } else if let half = resizing, let box {
                            let r = CGRect(x: box.midX - half, y: box.midY - half, width: 2 * half, height: 2 * half)
                            ctx.stroke(Path(r.insetBy(dx: -1, dy: -1)), with: .color(.blue), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            let h = Self.handle(for: r)
                            ctx.fill(Path(ellipseIn: CGRect(x: h.x - 8, y: h.y - 8, width: 16, height: 16)), with: .color(.white))
                        } else if let cur = session.point, let box, let handle {
                            let colour: Color = cur.origin == .user ? .blue : cur.isUncertain ? .yellow : .green
                            // Just outside the box, so the ball's edge shows.
                            ctx.stroke(Path(box.insetBy(dx: -1.5, dy: -1.5)), with: .color(colour), lineWidth: 2)
                            if !watching {
                                ctx.fill(Path(ellipseIn: CGRect(x: handle.x - 8, y: handle.y - 8, width: 16, height: 16)), with: .color(.white))
                                ctx.stroke(Path(ellipseIn: CGRect(x: handle.x - 8, y: handle.y - 8, width: 16, height: 16)),
                                           with: .color(colour), lineWidth: 2)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard !watching else { return }
                    place(at: location, origin: origin, shown: shown)
                }
                .gesture(DragGesture(minimumDistance: 6)
                    .onChanged { drag in
                        if moving == nil && resizing == nil && panBase == nil {
                            // The corner handle resizes, the box moves; anywhere else looks around.
                            if !watching, let handle, let box, hypot(drag.startLocation.x - handle.x, drag.startLocation.y - handle.y) < 22 {
                                resizing = max(box.width, box.height) / 2
                            } else if !watching, let box, box.insetBy(dx: -22, dy: -22).contains(drag.startLocation) {
                                moving = drag.location
                                return
                            } else {
                                // From where the view really is (past an edge it stops).
                                panBase = CGPoint(x: (size.width / 2 - origin.x) / shown.width, y: (size.height / 2 - origin.y) / shown.height)
                            }
                        }
                        if moving != nil {
                            moving = drag.location
                        } else if resizing != nil, let box {
                            // Square on screen (a ball is round), about the box's centre.
                            resizing = max(2, max(abs(drag.location.x - box.midX), abs(drag.location.y - box.midY)) - Self.handleGap * 0.7)
                        } else if let base = panBase {
                            centre = CGPoint(x: base.x - drag.translation.width / shown.width, y: base.y - drag.translation.height / shown.height)
                        }
                    }
                    .onEnded { _ in
                        if let moving { place(at: moving, origin: origin, shown: shown) }
                        if let half = resizing, let box {
                            session.setBall(at: CGPoint(x: (box.midX - origin.x) / shown.width, y: 1 - (box.midY - origin.y) / shown.height),
                                            size: CGSize(width: 2 * half / shown.width, height: 2 * half / shown.height))
                        }
                        resizing = nil
                        if panBase != nil, let c = centre {
                            // Forget dragging past the edge, so dragging back moves at once.
                            let o = CGPoint(x: Self.clamp(size.width / 2 - c.x * shown.width, size.width, shown.width),
                                            y: Self.clamp(size.height / 2 - c.y * shown.height, size.height, shown.height))
                            centre = CGPoint(x: (size.width / 2 - o.x) / shown.width, y: (size.height / 2 - o.y) / shown.height)
                        }
                        moving = nil
                        panBase = nil
                    })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? zoom
                        if pinchBase == nil { pinchBase = base }
                        zoom = min(max(1, base * value.magnification), 8)
                    }
                    .onEnded { _ in pinchBase = nil })
            } else {
                Color.black
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .onChange(of: session.index) { followIfLost() }
    }

    /// The ball on this frame (or where it was last), top-down fraction.
    private var ballCentre: CGPoint? {
        session.focus(around: session.index).map { CGPoint(x: $0.x, y: 1 - $0.y) }
    }

    /// The new frame's ball is out of view (or near its edge): centre on it.
    private func followIfLost() {
        guard let c = centre, let ball = session.point.flatMap({ $0.state == .visible ? $0.box : nil }),
              let image = session.image(session.index), viewSize.width > 0 else { return }
        let fit = min(viewSize.width / image.size.width, viewSize.height / image.size.height) * zoom
        let shown = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let origin = CGPoint(x: Self.clamp(viewSize.width / 2 - c.x * shown.width, viewSize.width, shown.width),
                             y: Self.clamp(viewSize.height / 2 - c.y * shown.height, viewSize.height, shown.height))
        let p = CGPoint(x: origin.x + (ball.x + ball.w / 2) * shown.width, y: origin.y + (1 - ball.y - ball.h / 2) * shown.height)
        let inner = CGRect(origin: .zero, size: viewSize).insetBy(dx: viewSize.width * 0.12, dy: viewSize.height * 0.12)
        if !inner.contains(p) { centre = CGPoint(x: ball.x + ball.w / 2, y: 1 - ball.y - ball.h / 2) }
    }

    /// The resize handle sits this far out from the box's corner, so even
    /// a tiny box has room to grab it apart from the box itself.
    static let handleGap: CGFloat = 14

    private static func handle(for box: CGRect) -> CGPoint {
        CGPoint(x: box.maxX + handleGap * 0.7, y: box.maxY + handleGap * 0.7)
    }

    /// Keep the picture covering the view (centred when smaller).
    private static func clamp(_ v: CGFloat, _ view: CGFloat, _ content: CGFloat) -> CGFloat {
        content <= view ? (view - content) / 2 : min(0, max(view - content, v))
    }

    /// The ball goes here, and the view centres on it (at your zoom) for
    /// this frame and the ones after.
    private func place(at location: CGPoint, origin: CGPoint, shown: CGSize) {
        let x = (location.x - origin.x) / shown.width
        let y = (location.y - origin.y) / shown.height
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        session.setBall(at: CGPoint(x: x, y: 1 - y))
        withAnimation(.easeOut(duration: 0.2)) { centre = CGPoint(x: x, y: y) }
    }
}
