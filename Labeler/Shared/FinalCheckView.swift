//
//  FinalCheckView.swift
//  RallyLab (macOS and iPhone)
//
//  Final check (leads only): each complete rally's whole ball path drawn on
//  one frame, cut into stretches wherever it jumps further than a ball can
//  go (AnnotationReview.stretches) — two courts' balls labeled in turn show
//  as stretches in different places. Each stretch has its colour on the
//  path and a crop of its middle frame. Tap the stretches on the wrong ball:
//  their boxes are cleared and they go to Find the ball, in order, where
//  each starts from a guess along the right ball's path (the frames either
//  side, then each one you place). Otherwise sign the rally off. A signed-off
//  rally comes back if any of its frames is labeled again. On the Mac:
//  1–9 pick a stretch, ↩/Space done, S skip, ⌫ back.
//

import SwiftUI

struct FinalCheckView: View {
    let store: any ReviewStore
    /// The rallies to check, fixed when the pass opens.
    @State private var rallies: [AnnotationReview.RallyCheck]?
    @State private var at = 0
    /// The rally shown and its stretches, set together (a sync can change
    /// the rally underneath; what's shown stays as it was cut).
    @State private var rally: TrackedRally?
    @State private var stretches: [ClosedRange<Int>] = []
    @State private var frame: CGImage?
    @State private var crops: [ClosedRange<Int>: CropPatch] = [:]
    @State private var wrong: Set<ClosedRange<Int>> = []
    @State private var failure: String?
    /// Decisions in this pass, for going back: the rally, and its frames as
    /// they were before (empty when it was signed off).
    @State private var done: [(check: AnnotationReview.RallyCheck, before: [Int: TrackPoint])] = []
    @State private var signedOff = 0
    @State private var readers: [String: ReviewFrames] = [:]

    private static let colours: [Color] = [.green, .yellow, .cyan, .pink, .orange, .purple, .mint, .red, .blue]

    private var check: AnnotationReview.RallyCheck? { rallies.flatMap { $0.indices.contains(at) ? $0[at] : nil } }

    var body: some View {
        VStack(spacing: 12) {
            header
            Group {
                if let rally, let frame {
                    ScrollView {
                        VStack(spacing: 10) {
                            path(rally, on: frame)
                            Text(stretches.count > 1
                                 ? "The path breaks into \(stretches.count) stretches · tap any on the wrong ball (they go to Find the ball)"
                                 : "One unbroken path · sign it off if it's all the same ball")
                                .font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                                ForEach(Array(stretches.enumerated()), id: \.element) { n, s in stretchCell(n, s, rally) }
                            }
                        }
                    }
                } else if let failure {
                    ContentUnavailableView("Can't show this rally", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if rallies != nil && check == nil {
                    ContentUnavailableView("Every finished rally checked", systemImage: "checkmark.seal.fill",
                                           description: Text("\(signedOff) signed off this time."))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle("Final check")
        .inlineTitle()
        .reviewKeys { press in
            switch press.key {
            case .return, .space: finish()
            case .delete, .deleteForward: back()
            default:
                let c = press.characters.lowercased()
                if c == "s" { next() } else if let n = Int(c), (1...stretches.count).contains(n) { toggle(stretches[n - 1]) } else { return false }
            }
            return true
        }
        .task {
            let signed = (try? await LabelingClient.shared.rallyFinals()) ?? []
            rallies = store.finishedRallies().filter { !signed.contains($0.track) }
            await show()
        }
    }

    private var header: some View {
        HStack {
            Text("\(max(0, (rallies?.count ?? 0) - at).formatted()) left").font(.headline.monospacedDigit())
            Spacer()
            if let check {
                Text("\(store.videoName(video: check.video)) · \(clockText(check.start))–\(clockText(check.end))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { back() } label: { Label("Back", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).disabled(done.isEmpty)
            Button { next() } label: { Label("Skip", systemImage: "forward").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).disabled(check == nil)
            Button { finish() } label: {
                Label(wrong.isEmpty ? "Sign off" : "\(wrongFrames.count) frames to Find the ball", systemImage: wrong.isEmpty ? "checkmark.seal" : "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(wrong.isEmpty ? .green : .orange).disabled(frame == nil)
        }
        .controlSize(.large)
    }

    /// The whole path on one frame: each stretch in its colour, a dot per
    /// boxed frame, the breaks between stretches dashed red.
    private func path(_ rally: TrackedRally, on frame: CGImage) -> some View {
        let aspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
        return Canvas { ctx, size in
            ctx.draw(Image(decorative: frame, scale: 1), in: CGRect(origin: .zero, size: size))
            func at(_ i: Int) -> CGPoint? {
                rally.points[i].box.map { CGPoint(x: $0.rect.midX * size.width, y: (1 - $0.rect.midY) * size.height) }
            }
            for (n, s) in stretches.enumerated() {
                let colour = Self.colours[n % Self.colours.count]
                let shown = wrong.contains(s) ? Color.red : colour
                let dots = s.compactMap { rally.points[$0].state == .visible ? at($0) : nil }
                var line = Path()
                line.addLines(dots)
                ctx.stroke(line, with: .color(shown.opacity(0.9)), lineWidth: 2)
                for d in dots { ctx.fill(Path(ellipseIn: CGRect(x: d.x - 2, y: d.y - 2, width: 4, height: 4)), with: .color(shown)) }
                if let first = dots.first {
                    ctx.draw(Text("\(n + 1)").font(.caption.bold()).foregroundStyle(.white), at: CGPoint(x: first.x, y: first.y - 10))
                }
                if n > 0, let a = at(stretches[n - 1].upperBound), let b = dots.first {
                    var jump = Path()
                    jump.move(to: a)
                    jump.addLine(to: b)
                    ctx.stroke(jump, with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stretchCell(_ n: Int, _ s: ClosedRange<Int>, _ rally: TrackedRally) -> some View {
        let isWrong = wrong.contains(s)
        let colour = Self.colours[n % Self.colours.count]
        let mid = middle(s, rally)
        return VStack(spacing: 4) {
            Group {
                if let patch = crops[s], let box = rally.points[mid].box?.rect {
                    CropCanvas(patch: patch, box: box, offset: .zero, scale: 1, tint: isWrong ? .red : colour)
                } else {
                    Color.black
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isWrong ? Color.red : colour, lineWidth: 3))
            .overlay(alignment: .topTrailing) {
                if isWrong { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white, .red).padding(4) }
            }
            Text("\(n + 1) · \(clockText(rally.points[s.lowerBound].time))–\(clockText(rally.points[s.upperBound].time)) · \(boxed(s, rally).count)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(s) }
    }

    private func toggle(_ s: ClosedRange<Int>) {
        if wrong.contains(s) { wrong.remove(s) } else { wrong.insert(s) }
    }

    private func item(_ check: AnnotationReview.RallyCheck, _ index: Int) -> AnnotationReview.Item {
        AnnotationReview.Item(video: check.video, track: check.track, index: index)
    }

    private func boxed(_ s: ClosedRange<Int>, _ rally: TrackedRally) -> [Int] {
        s.filter { rally.points[$0].state == .visible && rally.points[$0].box != nil }
    }

    private func middle(_ s: ClosedRange<Int>, _ rally: TrackedRally) -> Int {
        let b = boxed(s, rally)
        return b.isEmpty ? s.lowerBound : b[b.count / 2]
    }

    /// The frames of the stretches picked out: their balls.
    private var wrongFrames: [Int] {
        guard let rally else { return [] }
        return wrong.flatMap { boxed($0, rally) }.sorted()
    }

    /// The rally at `at` with its stretches (at once), then the frame in
    /// the middle of the rally and a crop per stretch.
    private func show() async {
        frame = nil
        crops = [:]
        wrong = []
        failure = nil
        rally = check.flatMap { store.rally(of: item($0, 0)) }
        stretches = rally.map { AnnotationReview.stretches($0) } ?? []
        guard let check, let rally, !rally.points.isEmpty else { return }
        let stretches = stretches
        do {
            let file = try await store.videoFile(video: check.video)
            if readers[check.video]?.video != file { readers[check.video] = ReviewFrames(video: file) }
            guard let reader = readers[check.video] else { return }
            let mids = stretches.map { middle($0, rally) }
            reader.prefetch(mids.map { rally.points[$0].time })
            let shown = check
            guard let picture = await reader.image(at: rally.points[mids.first ?? rally.points.count / 2].time), shown == self.check else { return }
            frame = picture
            for (s, i) in zip(stretches, mids) {
                guard let box = rally.points[i].box?.rect, let image = await reader.image(at: rally.points[i].time), shown == self.check else { continue }
                crops[s] = CropPatch(frame: image, box: box)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The picked-out stretches' boxes cleared, to Find the ball; with none, sign the rally off.
    private func finish() {
        guard let check, frame != nil else { return }
        var before: [Int: TrackPoint] = [:]
        for i in wrongFrames {
            if let was = store.review(item(check, i), AnnotationReview.findAgain) { before[i] = was }
        }
        if before.isEmpty {
            signedOff += 1
            Task { try? await LabelingClient.shared.rallyFinal(check.track, ok: true) }
        }
        done.append((check, before))
        next()
    }

    private func next() {
        at += 1
        Task { await show() }
    }

    /// The last rally again, as it was.
    private func back() {
        guard let last = done.popLast() else { return }
        if last.before.isEmpty {
            signedOff -= 1
            Task { try? await LabelingClient.shared.rallyFinal(last.check.track, ok: false) }
        } else {
            for (i, was) in last.before { store.review(item(last.check, i)) { $0 = was } }
        }
        at = rallies?.firstIndex(of: last.check) ?? max(0, at - 1)
        Task { await show() }
    }
}
