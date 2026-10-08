//
//  TrackReviewView.swift
//  RallyLab (iPhone)
//
//  Track a rally's ball by checking only the frames worth a look. Each one
//  is shown zoomed on the ball (or where it was last), its path through the
//  nearby frames drawn faintly. ✓ = right, tap the picture = the ball is
//  there (or drag the ring onto it), Hidden = can't be seen. Pinch to zoom,
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
/// Tap to place the ball, drag the ring to move it, drag elsewhere to look
/// around, pinch to zoom. A new frame centres on the ball again.
private struct ZoomedFrame: View {
    let session: TrackSession
    @Binding var zoom: CGFloat
    let watching: Bool
    /// How far you've dragged the picture from centred on the ball.
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize?
    @State private var pinchBase: CGFloat?
    /// Where the ring is being dragged to (view points).
    @State private var moving: CGPoint?

    var body: some View {
        GeometryReader { geo in
            if let image = session.image(session.index) {
                let size = geo.size
                let imgSize = image.size
                // Fit the frame, then zoom about the ball.
                let fit = min(size.width / imgSize.width, size.height / imgSize.height) * zoom
                let shown = CGSize(width: imgSize.width * fit, height: imgSize.height * fit)
                let focus = session.focus(around: session.index) ?? CGPoint(x: 0.5, y: 0.5)
                // Vision (bottom-up) → top-down image fraction.
                let fx = focus.x, fy = 1 - focus.y
                let raw = CGPoint(x: size.width / 2 - fx * shown.width, y: size.height / 2 - fy * shown.height)
                let origin = CGPoint(x: Self.clamp(raw.x + pan.width, size.width, shown.width),
                                     y: Self.clamp(raw.y + pan.height, size.height, shown.height))
                let ball: (CGPoint, CGFloat)? = {
                    guard let cur = session.point, let b = cur.box, cur.state == .visible else { return nil }
                    return (CGPoint(x: origin.x + (b.x + b.w / 2) * shown.width, y: origin.y + (1 - b.y - b.h / 2) * shown.height),
                            max(12, b.w * shown.width * 0.9))
                }()
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
                        if let moving {
                            let r = ball?.1 ?? 14
                            ctx.stroke(Path(ellipseIn: CGRect(x: moving.x - r, y: moving.y - r, width: 2 * r, height: 2 * r)),
                                       with: .color(.blue), style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                        } else if let cur = session.point, let (p, r) = ball {
                            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                                       with: .color(cur.origin == .user ? .blue : cur.isUncertain ? .yellow : .green), lineWidth: 3)
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
                        if moving == nil && panBase == nil {
                            // Starting on the ring moves it; anywhere else looks around.
                            if !watching, let (p, r) = ball, hypot(drag.startLocation.x - p.x, drag.startLocation.y - p.y) < r + 22 {
                                moving = drag.location
                                return
                            }
                            panBase = CGSize(width: origin.x - raw.x, height: origin.y - raw.y)
                        }
                        if moving != nil {
                            moving = drag.location
                        } else if let base = panBase {
                            pan = CGSize(width: base.width + drag.translation.width, height: base.height + drag.translation.height)
                        }
                    }
                    .onEnded { _ in
                        if let moving { place(at: moving, origin: origin, shown: shown) }
                        // Forget dragging past the edge, so dragging back moves at once.
                        if panBase != nil { pan = CGSize(width: origin.x - raw.x, height: origin.y - raw.y) }
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
        .onChange(of: session.index) { pan = .zero }
        .onChange(of: zoom) { if pinchBase == nil { pan = .zero } }
    }

    /// Keep the picture covering the view (centred when smaller).
    private static func clamp(_ v: CGFloat, _ view: CGFloat, _ content: CGFloat) -> CGFloat {
        content <= view ? (view - content) / 2 : min(0, max(view - content, v))
    }

    private func place(at location: CGPoint, origin: CGPoint, shown: CGSize) {
        let x = (location.x - origin.x) / shown.width
        let y = (location.y - origin.y) / shown.height
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        session.setBall(at: CGPoint(x: x, y: 1 - y))
    }
}
