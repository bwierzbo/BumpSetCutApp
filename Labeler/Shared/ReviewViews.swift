//
//  ReviewViews.swift
//  RallyLab (macOS and iPhone)
//
//  Annotation review, the same screens on the Mac and the phone (see
//  AnnotationReview). The Review tab shows how much is checked and opens:
//   · Rally or not — each rally the model pre-tracked plays (looping, 2× by
//     default): Rally sends its frames to review, Not a rally drops it from
//     review and training. Its frames wait until it's answered; Skip leaves
//     it for later. On the Mac: R rally, N not a rally, S skip, Space
//     play/pause, ⌫ back.
//   · Review — every ball's box in finished rallies, in order, as a crop:
//     the box fixed in the middle (drag the picture to put the ball's centre
//     under it, pinch to size it, tap to approve and go on). Hidden: the
//     ball can't be seen here — covered, or off screen (its place is worked
//     out from the frames either side, so don't guess a box). Hidden frames
//     aren't shown: they count as checked. Not sure (the box is on
//     something else, or you can't tell) sets a frame aside for Not sure.
//   Then, for frames the model lost the ball on —
//   · Over the top — where the model lost the ball with the ball high up
//     either side: the frames before and after, then the top of the
//     picture on each frame of the gap, one at a time. Where the ball
//     shows, tap it to box it; Done hides the frames without a box. Skip
//     leaves the gap for Find the ball. On the Mac: ← → frames, click the
//     ball, [ ] size, X remove the box, ↩/Space done, S skip, ⌫ back.
//   · Find the ball — the whole frame: tap the ball and approve, or hidden.
//   · Not sure — frames set aside, on the whole frame with their box.
//   Both whole-frame passes: Skip leaves a frame for later.
//   · Sure frames — the frames the model is sure of, a page of crops at a
//     time (3 × 3): tap any whose box isn't on the ball (they go to Not
//     sure), then approve the page. On the Mac: click to pick out, ↩/Space
//     approve, ⌫ back.
//   · RallyCoin — a joke: coins for labeling, a leaderboard, and a shop of
//     fake things to spend them on.
//   · Final check (leads only) — each complete rally's whole ball path, to
//     catch labels that jump between balls or courts (FinalCheckView).
//   · Labelers (leads only) — each other labeler's frames labeled and how
//     many were checked right or wrong; their labels to check, a page at a
//     time like Sure frames (hidden ones as the whole frame). Wrong ones go
//     to your Not sure.
//  Back shows the last decision again, to change it.
//
//  On the Mac: two fingers on the trackpad move the picture, pinch sizes the
//  box (as on the phone); ↩/Space approve and go on, arrows move the box a
//  pixel (⇧ five), [ ] size it, H hidden, U not sure, ⌫ back. On the
//  whole frame: click the ball, [ ] size the box, ↩/Space approve and go on, H hidden, = − zoom,
//  arrows pan.
//

import AVKit
import SwiftUI

struct ReviewHomeView: View {
    let store: any ReviewStore
    let progress: AnnotationReview.Progress
    /// Rallies with frames to review that someone else is on right now.
    @State private var held: Set<UUID> = []
    @State private var takingOver = false
    /// Other labelers' frames waiting to be checked (leads only; nil for everyone else).
    @State private var toCheck: Int?
    /// RallyCoin: the board, you included.
    @State private var coins: [LabelingClient.CoinHolder] = []
    /// Rallies signed off in the final check (leads only; nil for everyone else).
    @State private var finals: Set<UUID>?

    var body: some View {
        // Frames of rallies someone else is on are passed over when opened: not counted.
        let frames = count([.crop]), noBall = count([.noBall]), unsure = count([.unsure]), sure = count([.sure])
        let gaps = store.offTopGaps().filter { !held.contains($0.track) }
        let checks = store.rallyChecks().count
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(progress.reviewed.formatted()) of \(progress.total.formatted()) frames reviewed")
                        .font(.headline.monospacedDigit())
                    ProgressView(value: Double(progress.reviewed), total: Double(max(progress.total, 1)))
                    Text("\(progress.ralliesDone.formatted()) of \(progress.rallies.formatted()) rallies complete")
                        .font(.subheadline.weight(.semibold).monospacedDigit()).padding(.top, 4)
                    ProgressView(value: Double(progress.ralliesDone), total: Double(max(progress.rallies, 1))).tint(.green)
                    Text("Complete: every frame checked, the hard ones too. Only reviewed frames are used for training.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                if let mine = coins.firstIndex(where: \.me) {
                    NavigationLink { RallyCoinView() } label: { coinCard(coins[mine], rank: mine + 1) }
                        .buttonStyle(.plain)
                }
                if !held.isEmpty { heldCard }
                if let finals {
                    let finished = store.finishedRallies().filter { !finals.contains($0.track) }.count
                    NavigationLink { FinalCheckView(store: store) } label: {
                        card("Final check", "\(finished.formatted()) finished rallies to sign off · see the whole ball path, catch labels that jump to another ball or court",
                             "point.topleft.down.to.point.bottomright.curvepath", finished)
                    }
                    .buttonStyle(.plain).disabled(finished == 0)
                }
                if let toCheck {
                    NavigationLink { LabelersView(store: store) } label: {
                        card("Labelers", "\(toCheck.formatted()) frames others labeled to check · how each is doing, and their labels a page at a time",
                             "person.3", toCheck)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink { RallyCheckView(store: store) } label: {
                    card("Rally or not", "\(checks.formatted()) rallies the model picked · is each a real rally? Their frames come to review once it is",
                         "play.rectangle.on.rectangle", checks)
                }
                .buttonStyle(.plain).disabled(checks == 0)
                NavigationLink { QuickSortView(store: store) } label: {
                    card("Quick sort", "\(frames.formatted()) frames to check, 9 at a time · leave the ones on the ball, tap the rest: Hidden, Fix or Not sure",
                         "square.grid.3x3.square", frames)
                }
                .buttonStyle(.plain).disabled(frames == 0)
                NavigationLink { CropReviewView(store: store) } label: {
                    card("Review", "\(frames.formatted()) frames to check · drag to centre, pinch to size, tap to approve", "viewfinder", frames)
                }
                .buttonStyle(.plain).disabled(frames == 0)
                NavigationLink { OffTopReviewView(store: store) } label: {
                    card("Over the top", "\(gaps.count.formatted()) gaps (\(gaps.reduce(0) { $0 + $1.frames.count }.formatted()) frames) where the ball likely went above the picture · box it where it shows, hide the rest at once",
                         "arrow.up.to.line", gaps.count)
                }
                .buttonStyle(.plain).disabled(gaps.isEmpty)
                NavigationLink { WholeFrameReviewView(store: store, kind: .noBall) } label: {
                    card("Find the ball", "\(noBall.formatted()) where the ball was lost or the label was on another ball · find it on the whole frame, or call it hidden", "scope", noBall)
                }
                .buttonStyle(.plain).disabled(noBall == 0)
                NavigationLink { WholeFrameReviewView(store: store, kind: .unsure) } label: {
                    card("Not sure", "\(unsure.formatted()) set aside · a closer look when you have time", "questionmark.circle", unsure)
                }
                .buttonStyle(.plain).disabled(unsure == 0)
                NavigationLink { SureReviewView(store: store) } label: {
                    card("Sure frames", "\(sure.formatted()) the model is sure of · tap any that are wrong, approve the rest a page at a time",
                         "square.grid.3x3", sure)
                }
                .buttonStyle(.plain).disabled(sure == 0)
            }
            .padding()
        }
        .navigationTitle("Review")
        // Who's on what changes as others review: look again now and then.
        .task {
            while !Task.isCancelled {
                await refreshHeld()
                if let board = try? await LabelingClient.shared.coinBoard() { coins = board }
                finals = try? await LabelingClient.shared.rallyFinals()
                if let others = try? await LabelingClient.shared.labelerSummary() {
                    toCheck = others.isEmpty ? nil : others.reduce(0) { $0 + $1.waiting }
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Someone else is reviewing some rallies: their frames are skipped, or take them over.
    private var heldCard: some View {
        let frames = store.reviewItems([.crop, .noBall, .unsure, .sure]).filter { held.contains($0.track) }.count
            + store.offTopGaps().filter { held.contains($0.track) }.reduce(0) { $0 + $1.frames.count }
        return HStack(spacing: 12) {
            Image(systemName: "person.2.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Someone else is reviewing \(held.count) rall\(held.count == 1 ? "y" : "ies")").font(.headline)
                Text("\(frames.formatted()) frames you'll skip while they're on them; idle for 3 minutes, they come free.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                takingOver = true
                Task {
                    await store.takeOver(held)
                    await refreshHeld()
                    takingOver = false
                }
            } label: { takingOver ? AnyView(ProgressView()) : AnyView(Text("Take over")) }
                .buttonStyle(.borderedProminent).tint(.orange).disabled(takingOver)
        }
        .padding()
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func count(_ kinds: Set<AnnotationReview.Kind>) -> Int {
        store.reviewItems(kinds).count { !held.contains($0.track) }
    }

    /// Only rallies that still have frames for this person to review.
    private func refreshHeld() async {
        let mine = Set(store.reviewItems([.crop, .noBall, .unsure, .sure]).map(\.track) + store.offTopGaps().map(\.track))
        held = await store.heldByOthers().intersection(mine)
    }

    private func coinCard(_ me: LabelingClient.CoinHolder, rank: Int) -> some View {
        HStack(spacing: 14) {
            Text("🪙").font(.largeTitle)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(me.coins.formatted()) RallyCoin").font(.title3.bold().monospacedDigit())
                Text("#\(rank) of \(coins.count) · 1 a frame · spend it in the shop · no cash value")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func card(_ title: String, _ detail: String, _ icon: String, _ count: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title).foregroundStyle(count > 0 ? Color.accentColor : .secondary).frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: count > 0 ? "chevron.right" : "checkmark.circle.fill").foregroundStyle(count > 0 ? .tertiary : .secondary)
        }
        .padding(18)
        .background(Color.accentColor.opacity(count > 0 ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Review: one crop at a time, every frame in order.
struct CropReviewView: View {
    @State private var walk: ReviewWalk
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize?
    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat?
    /// This touch so far: how far it went, and whether it pinched.
    @State private var moved: CGFloat = 0
    @State private var pinched = false
    @State private var patch: CropPatch?
    @State private var approved = 0

    /// How much of a pinch / a two-finger scroll goes into the box: the
    /// Mac's trackpad gestures are damped for fine adjustments; a finger on
    /// the phone moves 1:1.
    #if os(macOS)
    private static let pinchSensitivity: CGFloat = 0.35
    private static let scrollSensitivity: CGFloat = 0.3
    #else
    private static let pinchSensitivity: CGFloat = 1
    private static let scrollSensitivity: CGFloat = 1
    #endif

    init(store: any ReviewStore) {
        _walk = State(initialValue: ReviewWalk(store: store, kinds: [.crop]))
    }

    /// The frame's ball box: your box on a frame gone back to, or the one it
    /// had if you called it hidden.
    private var ball: CGRect? {
        [walk.point, walk.originalPoint].lazy.compactMap { $0.flatMap { $0.state == .visible ? $0.box?.rect : nil } }.first
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Group {
                    if let image = walk.image, let box = ball, let patch {
                        let k = CropCanvas.geometry(frameSize: patch.frameSize, box: box, view: CGSize(width: side, height: side)).k
                        CropCanvas(patch: patch, box: box, offset: offset, scale: scale)
                            .contentShape(Rectangle())
                            // One gesture from the first touch: moving drags the picture
                            // at once; lifting without moving (and no pinch) approves.
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { d in
                                    let base = dragBase ?? offset
                                    if dragBase == nil { dragBase = base }
                                    moved = max(moved, hypot(d.translation.width, d.translation.height))
                                    // The picture follows the finger: the ball's centre moves the other way.
                                    offset = CGSize(width: base.width - d.translation.width / k, height: base.height - d.translation.height / k)
                                }
                                .onEnded { _ in
                                    let tap = moved < 6 && !pinched
                                    if tap, let base = dragBase { offset = base }
                                    dragBase = nil
                                    moved = 0
                                    pinched = false
                                    if tap { approve(box, image: image) }
                                })
                            .simultaneousGesture(MagnifyGesture()
                                .onChanged { m in
                                    pinched = true
                                    // Like zooming a photo: spreading the fingers brings the
                                    // picture closer, so the ball grows against the box — the
                                    // box shrinks to the ball.
                                    let base = pinchBase ?? scale
                                    if pinchBase == nil { pinchBase = base }
                                    scale = min(max(base / pow(m.magnification, Self.pinchSensitivity), 0.3), 4)
                                }
                                .onEnded { _ in pinchBase = nil })
                            .reviewScroll { dx, dy in
                                // Two fingers move the picture, as a drag does — slower,
                                // for fine centring.
                                offset = CGSize(width: offset.width - dx * Self.scrollSensitivity / k,
                                                height: offset.height - dy * Self.scrollSensitivity / k)
                            }
                    } else if let failure = walk.failure {
                        ContentUnavailableView("Can't show this frame", systemImage: "exclamationmark.triangle", description: Text(failure))
                    } else if walk.item == nil {
                        ContentUnavailableView("All frames checked", systemImage: "checkmark.seal.fill",
                                               description: Text("\(approved) approved this time."))
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            controls
            ReviewPassBar(walk: walk)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle("Review")
        .inlineTitle()
        .reviewKeys { press in cropKey(press) }
        .task { await walk.load() }
        // Cut out the part around the box once per frame.
        .onChange(of: walk.image.map(ObjectIdentifier.init), initial: true) {
            patch = walk.image.flatMap { image in ball.flatMap { CropPatch(frame: image, box: $0) } }
        }
        .sensoryFeedback(.success, trigger: approved)
    }

    private var header: some View {
        HStack {
            Text("\(walk.left.formatted()) left").font(.headline.monospacedDigit())
            Spacer()
            if let item = walk.item, let p = walk.point {
                Text("\(walk.store.videoName(video: item.video)) · \(clockText(p.time))").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Text("Drag to centre the ball · pinch to size · tap to approve · covered or off screen: Hidden · box on something else: Not sure")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Task { reset(); await walk.back() } } label: {
                    Label("Back", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(!walk.canGoBack)
                Button { decide(AnnotationReview.confirmHidden) } label: {
                    Label("Hidden", systemImage: "eye.slash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.indigo).disabled(walk.item == nil)
                Button { decide(AnnotationReview.markUnsure) } label: {
                    Label("Not sure", systemImage: "questionmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange).disabled(walk.item == nil)
            }
            .labelStyle(StackedLabel())
            .controlSize(.large)
        }
    }

    private func cropKey(_ press: KeyPress) -> Bool {
        let step: CGFloat = press.modifiers.contains(.shift) ? 5 : 1
        switch press.key {
        case .return, .space:
            guard let image = walk.image, let ball else { return false }
            approve(ball, image: image)
        case .leftArrow: offset.width -= step
        case .rightArrow: offset.width += step
        case .upArrow: offset.height -= step
        case .downArrow: offset.height += step
        case .delete, .deleteForward: Task { reset(); await walk.back() }
        default:
            switch press.characters.lowercased() {
            case "[", "-": scale = max(0.3, scale / 1.05)
            case "]", "=", "+": scale = min(4, scale * 1.05)
            case "h": decide(AnnotationReview.confirmHidden)
            case "?", "/", "u": decide(AnnotationReview.markUnsure)
            default: return false
            }
        }
        return true
    }

    /// The ball's box, as adjusted.
    private func approve(_ ball: CGRect, image: CGImage) {
        let size = CGSize(width: image.width, height: image.height)
        let new = AnnotationReview.adjusted(ball, offset: offset, scale: scale, in: size)
        approved += 1
        decide { AnnotationReview.approve(&$0, box: new) }
    }

    /// Decide this frame and go on.
    private func decide(_ change: @escaping (inout TrackPoint) -> Void) {
        reset()
        Task { await walk.decide(change) }
    }

    private func reset() {
        offset = .zero
        scale = 1
    }
}

/// Sure frames: a page of crops at a time, each box as the model put it.
/// Tap any that isn't on the ball (set aside as not sure, for a look on the
/// whole frame); approve approves the rest.
struct SureReviewView: View {
    @State private var walk: ReviewWalk
    /// Checking this labeler's frames instead of the model's sure frames.
    private let labeler: LabelingClient.LabelerSummary?
    /// This page's crops, cut out once when it loads.
    @State private var patches: [AnnotationReview.Item: CropPatch] = [:]
    /// Picked out as wrong on this page.
    @State private var wrong: Set<AnnotationReview.Item> = []
    @State private var approved = 0
    /// A labeler's pages checked, in order, for taking the checks back.
    @State private var checked: [[AnnotationReview.Item]] = []
    @State private var verdictFailure: String?

    /// 3 × 3, big enough to judge a far ball, and the whole grid fits the window.
    private static let columns = 3

    init(store: any ReviewStore) {
        labeler = nil
        _walk = State(initialValue: ReviewWalk(store: store, kinds: [.sure], pageSize: Self.columns * Self.columns))
    }

    /// A labeler's frames waiting to be checked.
    init(store: any ReviewStore, labeler: LabelingClient.LabelerSummary, items: [AnnotationReview.Item]) {
        self.labeler = labeler
        _walk = State(initialValue: ReviewWalk(store: store, items: items, pageSize: Self.columns * Self.columns))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(walk.left.formatted()) left").font(.headline.monospacedDigit())
                Spacer()
                if let first = walk.page.first, let p = walk.store.rally(of: first.item)?.points[safe: first.item.index] {
                    Text("\(walk.store.videoName(video: first.item.video)) · \(clockText(p.time))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            GeometryReader { geo in
                let side = max(1, (min(geo.size.width, geo.size.height) - 12) / CGFloat(Self.columns))
                Group {
                    if !walk.page.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 6), count: Self.columns), spacing: 6) {
                            ForEach(walk.page, id: \.item) { cell($0.item, image: $0.image).frame(width: side, height: side) }
                        }
                    } else if let failure = walk.failure {
                        ContentUnavailableView("Can't show these frames", systemImage: "exclamationmark.triangle", description: Text(failure))
                    } else if walk.item == nil {
                        ContentUnavailableView(labeler.map { "All of \($0.name)'s frames checked" } ?? "All sure frames checked",
                                               systemImage: "checkmark.seal.fill", description: Text("\(approved) approved this time."))
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            if let verdictFailure {
                Text(verdictFailure).font(.caption).foregroundStyle(.red)
            }
            Text(labeler == nil ? "Tap any box that isn't on the ball · it goes to Not sure"
                                : "Tap any label that's wrong · it goes to your Not sure")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { goBack() } label: {
                    Label("Back", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(!walk.canGoBack)
                Button { approvePage() } label: {
                    Label(wrong.isEmpty ? "Approve all" : "Approve \(walk.page.count - wrong.count) · \(wrong.count) wrong",
                          systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green).disabled(walk.page.isEmpty)
            }
            .controlSize(.large)
            ReviewPassBar(walk: walk)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle(labeler?.name ?? "Sure frames")
        .inlineTitle()
        .reviewKeys { press in
            switch press.key {
            case .return, .space: approvePage()
            case .delete, .deleteForward: goBack()
            default: return false
            }
            return true
        }
        .task { await walk.load() }
        // A new page: cut out its crops; frames gone back to show what was said of them.
        .onChange(of: walk.page.map(\.item), initial: true) {
            patches = Dictionary(uniqueKeysWithValues: walk.page.compactMap { f in
                box(f.item).flatMap { CropPatch(frame: f.image, box: $0) }.map { (f.item, $0) }
            })
            wrong = Set(walk.page.map(\.item).filter { walk.store.rally(of: $0)?.points[safe: $0.index]?.unsure == true })
        }
        .sensoryFeedback(.success, trigger: approved)
    }

    private func box(_ item: AnnotationReview.Item) -> CGRect? {
        walk.store.rally(of: item)?.points[safe: item.index].flatMap { $0.state == .visible ? $0.box?.rect : nil }
    }

    @ViewBuilder
    private func cell(_ item: AnnotationReview.Item, image: CGImage) -> some View {
        let isWrong = wrong.contains(item)
        Group {
            if let patch = patches[item], let box = box(item) {
                CropCanvas(patch: patch, box: box, offset: .zero, scale: 1, tint: isWrong ? .red : .green)
            } else {
                // Called hidden (no box): the whole frame, to judge that.
                Color.black.overlay {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                }
                .overlay(alignment: .bottomLeading) {
                    Text("Hidden").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange, in: Capsule()).foregroundStyle(.white).padding(4)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isWrong {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white, .red).padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isWrong ? Color.red : .clear, lineWidth: 3))
        .contentShape(Rectangle())
        .onTapGesture { if isWrong { wrong.remove(item) } else { wrong.insert(item) } }
    }

    /// Sure frames: the page's boxes approved as they are (squared like a
    /// crop approved untouched). A labeler's: their labels kept as they
    /// are, checked right. The ones picked out set aside as not sure.
    private func approvePage() {
        guard !walk.page.isEmpty else { return }
        let sizes = Dictionary(uniqueKeysWithValues: walk.page.map { ($0.item, CGSize(width: $0.image.width, height: $0.image.height)) })
        let wrong = wrong, items = walk.page.map(\.item)
        approved += items.count - wrong.count
        if let labeler {
            checked.append(items)
            send(items.map { LabelingClient.LabelVerdict(track: $0.track, i: $0.index, labeler: labeler.labeler, ok: !wrong.contains($0)) })
        }
        Task {
            await walk.decidePage { item, point in
                if wrong.contains(item) {
                    AnnotationReview.markUnsure(&point)
                } else if labeler == nil, point.state == .visible, let box = point.box?.rect, let size = sizes[item] {
                    AnnotationReview.approve(&point, box: AnnotationReview.adjusted(box, offset: .zero, scale: 1, in: size))
                }
            }
        }
    }

    /// The last page again; a labeler's checks of it taken back.
    private func goBack() {
        guard walk.canGoBack else { return }
        if let labeler, let last = checked.popLast() {
            send(last.map { LabelingClient.LabelVerdict(track: $0.track, i: $0.index, labeler: labeler.labeler, ok: nil) })
        }
        Task { await walk.back() }
    }

    private func send(_ verdicts: [LabelingClient.LabelVerdict]) {
        Task {
            do {
                try await LabelingClient.shared.labelVerdicts(verdicts)
                verdictFailure = nil
            } catch {
                verdictFailure = "Checks not saved: \(error.localizedDescription)"
            }
        }
    }
}

/// Review a page at a time: the frames to check as crops, 3 × 3. Leave the
/// ones on the ball; tap the others through what they are — Hidden first
/// (the usual case: the box is on something else and the ball is gone),
/// then Fix (the box is a little off: left for Review, one at a time), then
/// Not sure. Done approves the rest as they are; Back takes the page back.
/// When the box has latched onto another ball for a stretch, hold a frame:
/// Hide the stretch marks the whole run hidden at once, past this page too.
struct QuickSortView: View {
    enum Call {
        case fix, hidden, unsure

        var next: Call? {
            switch self {
            case .hidden: return .fix
            case .fix: return .unsure
            case .unsure: return nil
            }
        }
        var title: String {
            switch self {
            case .fix: return "Fix"
            case .hidden: return "Hidden"
            case .unsure: return "Not sure"
            }
        }
        var icon: String {
            switch self {
            case .fix: return "arrow.up.and.down.and.arrow.left.and.right"
            case .hidden: return "eye.slash.fill"
            case .unsure: return "questionmark"
            }
        }
        var tint: Color {
            switch self {
            case .fix: return .yellow
            case .hidden: return .indigo
            case .unsure: return .orange
            }
        }
    }

    @State private var walk: ReviewWalk
    /// This page's crops, cut out once when it loads.
    @State private var patches: [AnnotationReview.Item: CropPatch] = [:]
    /// What you tapped each frame to; untouched ones are approved.
    @State private var calls: [AnnotationReview.Item: Call] = [:]
    @State private var approved = 0

    private static let columns = 3

    init(store: any ReviewStore) {
        _walk = State(initialValue: ReviewWalk(store: store, kinds: [.crop], pageSize: Self.columns * Self.columns))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(walk.left.formatted()) left").font(.headline.monospacedDigit())
                Spacer()
                if let first = walk.page.first, let p = walk.store.rally(of: first.item)?.points[safe: first.item.index] {
                    Text("\(walk.store.videoName(video: first.item.video)) · \(clockText(p.time))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            GeometryReader { geo in
                let side = max(1, (min(geo.size.width, geo.size.height) - 12) / CGFloat(Self.columns))
                Group {
                    if !walk.page.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 6), count: Self.columns), spacing: 6) {
                            ForEach(walk.page, id: \.item) { cell($0.item).frame(width: side, height: side) }
                        }
                    } else if let failure = walk.failure {
                        ContentUnavailableView("Can't show these frames", systemImage: "exclamationmark.triangle", description: Text(failure))
                    } else if walk.item == nil {
                        ContentUnavailableView("All frames sorted", systemImage: "checkmark.seal.fill",
                                               description: Text("\(approved) approved this time. Ones marked Fix are in Review."))
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Text("Leave the ones on the ball · tap: Hidden → Fix → Not sure")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Task { await walk.back() } } label: {
                    Label("Back", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(!walk.canGoBack)
                Button { donePage() } label: {
                    Label(calls.isEmpty ? "Approve all" : "Approve \(walk.page.count - calls.count) · \(calls.count) sorted",
                          systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green).disabled(walk.page.isEmpty)
            }
            .controlSize(.large)
            ReviewPassBar(walk: walk)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle("Quick sort")
        .inlineTitle()
        .reviewKeys { press in
            switch press.key {
            case .return, .space: donePage()
            case .delete, .deleteForward: Task { await walk.back() }
            default: return false
            }
            return true
        }
        .task { await walk.load() }
        // A new page: cut out its crops; a page gone back to shows what was said of it.
        .onChange(of: walk.page.map(\.item), initial: true) {
            patches = Dictionary(uniqueKeysWithValues: walk.page.compactMap { f in
                box(f.item).flatMap { CropPatch(frame: f.image, box: $0) }.map { (f.item, $0) }
            })
            calls = Dictionary(uniqueKeysWithValues: walk.page.compactMap { f -> (AnnotationReview.Item, Call)? in
                guard let point = point(f.item) else { return nil }
                if point.unsure { return (f.item, .unsure) }
                if point.state == .hidden && point.reviewed { return (f.item, .hidden) }
                return nil
            })
        }
        .sensoryFeedback(.success, trigger: approved)
    }

    private func point(_ item: AnnotationReview.Item) -> TrackPoint? {
        walk.store.rally(of: item)?.points[safe: item.index]
    }

    private func box(_ item: AnnotationReview.Item) -> CGRect? {
        point(item).flatMap { $0.state == .visible ? $0.box?.rect : nil }
    }

    @ViewBuilder
    private func cell(_ item: AnnotationReview.Item) -> some View {
        let call = calls[item]
        let guess = point(item)?.origin == .filled
        Group {
            if let patch = patches[item], let box = box(item) {
                CropCanvas(patch: patch, box: box, offset: .zero, scale: 1, tint: call?.tint ?? .green)
            } else {
                Color.black
            }
        }
        .overlay(alignment: .topLeading) {
            // Drawn between sightings: the model never saw the ball here.
            if guess {
                Text("guess").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(4)
            }
        }
        .overlay(alignment: .bottom) {
            if let call {
                Label(call.title, systemImage: call.icon).font(.caption.bold())
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(call.tint, in: Capsule()).foregroundStyle(.black).padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(call?.tint ?? .clear, lineWidth: 3))
        .contentShape(Rectangle())
        .onTapGesture { calls[item] = call.map { $0.next } ?? .hidden }
        .contextMenu {
            let stretch = walk.stretch(from: item)
            if stretch.count > 1 {
                Button { hide(stretch) } label: {
                    Label("Hide this stretch · \(stretch.count) frames", systemImage: "eye.slash.fill")
                }
                Text("From here while the box follows the same thing")
            }
        }
    }

    /// The whole run hidden at once: the frames on this page show it; the
    /// ones past the page are decided now and passed over.
    private func hide(_ stretch: [AnnotationReview.Item]) {
        let onPage = Set(walk.page.map(\.item))
        for item in stretch where onPage.contains(item) { calls[item] = .hidden }
        walk.decideAhead(stretch.filter { !onPage.contains($0) }, AnnotationReview.confirmHidden)
    }

    /// The page decided: untouched boxes approved as they are (squared like a
    /// crop approved untouched), Hidden and Not sure set, Fix left for Review.
    private func donePage() {
        guard !walk.page.isEmpty else { return }
        let sizes = Dictionary(uniqueKeysWithValues: walk.page.map { ($0.item, CGSize(width: $0.image.width, height: $0.image.height)) })
        let calls = calls
        approved += walk.page.count - calls.count
        Task {
            await walk.decidePage { item, point in
                switch calls[item] {
                case .hidden: AnnotationReview.confirmHidden(&point)
                case .unsure: AnnotationReview.markUnsure(&point)
                case .fix: break
                case nil:
                    if point.state == .visible, let box = point.box?.rect, let size = sizes[item] {
                        AnnotationReview.approve(&point, box: AnnotationReview.adjusted(box, offset: .zero, scale: 1, in: size))
                    }
                }
            }
        }
    }
}

/// Other labelers (leads only): how many frames each has labeled, how many
/// of those were checked right or wrong, and their frames waiting to be
/// checked, a page at a time.
struct LabelersView: View {
    let store: any ReviewStore
    @State private var labelers: [LabelingClient.LabelerSummary] = []
    @State private var failure: String?

    var body: some View {
        List {
            if let failure { Text(failure).foregroundStyle(.red) }
            ForEach(labelers) { l in
                NavigationLink { LabelerCheckView(store: store, labeler: l) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(l.name).font(.headline)
                            Spacer()
                            if l.waiting > 0 {
                                Text("\(l.waiting.formatted()) to check").font(.subheadline.monospacedDigit()).foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(detail(l)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .disabled(l.waiting == 0)
            }
        }
        .navigationTitle("Labelers")
        .task { await load() }
        .refreshable { await load() }
    }

    private func detail(_ l: LabelingClient.LabelerSummary) -> String {
        var parts = ["\(l.labeled.formatted()) labeled"]
        let checked = l.approved + l.wrong
        if checked > 0 {
            parts.append("\(l.approved.formatted()) right · \(l.wrong.formatted()) wrong (\(Int((Double(l.approved) / Double(checked) * 100).rounded()))%)")
        }
        if let last = l.lastAt { parts.append("last \(last.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            labelers = try await LabelingClient.shared.labelerSummary()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// RallyCoin, a joke: the leaderboard and a shop of things nobody will
/// ever receive. 1 coin a frame labeled, +1 when it's checked right, −1
/// when it's checked wrong.
struct RallyCoinView: View {
    @State private var board: [LabelingClient.CoinHolder] = []
    @State private var items: [LabelingClient.ShopItem] = []
    @State private var bought: LabelingClient.ShopItem?
    @State private var failure: String?
    @State private var buying: String?

    private var mine: Int { board.first(where: \.me)?.coins ?? 0 }

    var body: some View {
        List {
            Section {
                ForEach(Array(board.enumerated()), id: \.element) { rank, holder in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rank < 3 ? ["🥇", "🥈", "🥉"][rank] : "\(rank + 1).").frame(width: 30, alignment: .leading)
                            Text(holder.name).fontWeight(holder.me ? .bold : .regular)
                            Spacer()
                            Text("\(holder.coins.formatted()) 🪙").font(.body.monospacedDigit())
                        }
                        if !holder.owns.isEmpty {
                            Text("Owns " + holder.owns.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
                        }
                    }
                }
            } header: {
                Text("Leaderboard")
            } footer: {
                Text("1 coin a frame labeled · +1 when Ben checks it right · −1 when it goes to his Not sure for being wrong. No cash value. Not financial advice.")
            }
            Section("Shop · you have \(mine.formatted()) 🪙") {
                if let failure { Text(failure).foregroundStyle(.red) }
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Text(item.emoji).font(.title)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline)
                            Text(item.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            buy(item)
                        } label: {
                            if buying == item.id { ProgressView() } else { Text("\(item.price.formatted()) 🪙").monospacedDigit() }
                        }
                        .buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                        .disabled(item.price > mine || buying != nil)
                    }
                }
            }
        }
        .navigationTitle("RallyCoin")
        .task { await load() }
        .refreshable { await load() }
        .alert("Purchased!", isPresented: Binding(get: { bought != nil }, set: { if !$0 { bought = nil } })) {
            Button("Can't wait") { bought = nil }
        } message: {
            Text("\(bought?.emoji ?? "") \(bought?.name ?? "") is on its way. Estimated delivery: never.")
        }
        .sensoryFeedback(.success, trigger: bought)
    }

    private func load() async {
        do {
            async let b = LabelingClient.shared.coinBoard()
            async let i = LabelingClient.shared.shopItems()
            (board, items) = try await (b, i)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func buy(_ item: LabelingClient.ShopItem) {
        buying = item.id
        Task {
            do {
                _ = try await LabelingClient.shared.buy(item.id)
                bought = item
                failure = nil
                await load()
            } catch {
                failure = error.localizedDescription
            }
            buying = nil
        }
    }
}

/// A labeler's frames waiting to be checked, loaded, then the grid.
private struct LabelerCheckView: View {
    let store: any ReviewStore
    let labeler: LabelingClient.LabelerSummary
    @State private var items: [AnnotationReview.Item]?
    @State private var failure: String?

    var body: some View {
        Group {
            if let items {
                SureReviewView(store: store, labeler: labeler, items: items)
            } else if let failure {
                ContentUnavailableView("Can't load \(labeler.name)'s frames", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                // Only frames still labeled here (a later change may have undone one).
                items = try await LabelingClient.shared.labelerFrames(labeler.labeler).compactMap { f in
                    store.reviewItem(track: f.track, index: f.index).flatMap { item in
                        store.rally(of: item)?.points[safe: item.index]?.reviewed == true ? item : nil
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The whole frame, to find the ball: pinch to zoom, drag to look around,
/// tap the ball to place it, then approve — or call it hidden. The ball's
/// boxes on the frames either side are drawn faintly (with their offsets),
/// and −2 −1 +1 +2 show those frames themselves for a moment. Starts at
/// `zoom` (2.5 = zoomed in where the ball was last seen; 1 = the whole
/// frame), with `box` if there is one; looking at `centre` if given (the
/// last frame's view, for the next frame of a rally), else at the box.
struct FindBallView: View {
    let image: CGImage
    let rally: TrackedRally
    let index: Int
    /// Frame `offset` away, for a look; nil to leave out the look-around strip.
    var neighbour: ((Int) async -> CGImage?)?
    let onBall: (CGRect) -> Void
    let onHidden: () -> Void
    /// The zoom as you change it, to keep for the next frame.
    let onZoom: (CGFloat) -> Void
    /// Where the view is centred as you move it, likewise.
    let onCentre: (CGPoint) -> Void
    @State private var zoom: CGFloat
    @State private var centre: CGPoint
    @State private var panBase: CGPoint?
    @State private var pinchBase: CGFloat?
    @State private var placed: CGRect?
    /// `placed` is a guess from the ball's path, not yet moved or sized.
    @State private var guessed: Bool
    /// `placed` has a size to keep when moved: yours, or sized here with − +.
    /// Otherwise a tap sizes it like your boxes nearby (placedBox).
    @State private var sized: Bool
    /// Showing a neighbouring frame instead (offset and picture).
    @State private var peek: (offset: Int, image: CGImage)?

    /// How many frames either side are drawn and can be looked at.
    static let around = 2

    init(image: CGImage, rally: TrackedRally, index: Int, box: CGRect?, boxIsYours: Bool = false, guess: CGRect? = nil, zoom: CGFloat = 2.5,
         centre: CGPoint? = nil, neighbour: ((Int) async -> CGImage?)? = nil,
         onBall: @escaping (CGRect) -> Void, onHidden: @escaping () -> Void,
         onZoom: @escaping (CGFloat) -> Void = { _ in }, onCentre: @escaping (CGPoint) -> Void = { _ in }) {
        self.image = image
        self.rally = rally
        self.index = index
        self.neighbour = neighbour
        self.onBall = onBall
        self.onHidden = onHidden
        self.onZoom = onZoom
        self.onCentre = onCentre
        _zoom = State(initialValue: zoom)
        let start = box ?? guess
        _centre = State(initialValue: zoom <= 1 ? CGPoint(x: 0.5, y: 0.5)
                        : centre ?? start.map { CGPoint(x: $0.midX, y: 1 - $0.midY) } ?? FrameCanvas.focus(rally, frame: index))
        _placed = State(initialValue: start)
        _guessed = State(initialValue: box == nil && guess != nil)
        _sized = State(initialValue: box != nil && boxIsYours)
    }

    /// The ball's box on the frames either side.
    private var neighbours: [(offset: Int, box: CGRect)] {
        (-Self.around...Self.around).filter { $0 != 0 }.compactMap { d in
            guard let p = rally.points[safe: index + d], p.state == .visible, let b = p.box else { return nil }
            return (d, b.rect)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                Group {
                    if let peek {
                        // A neighbouring frame, with its own ball.
                        FrameCanvas(image: peek.image, zoom: zoom, centre: centre,
                                    box: rally.points[safe: index + peek.offset].flatMap { $0.state == .visible ? $0.box?.rect : nil })
                            .overlay(alignment: .top) {
                                Text(peek.offset > 0 ? "\(peek.offset) frame\(peek.offset == 1 ? "" : "s") after" : "\(-peek.offset) frame\(peek.offset == -1 ? "" : "s") before")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule()).padding(8)
                            }
                    } else {
                        FrameCanvas(image: image, zoom: zoom, centre: centre, box: placed, boxColor: guessed ? .yellow : .blue, neighbours: neighbours)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard peek == nil,
                          let p = FrameCanvas.framePoint(location, image: image, zoom: zoom, centre: centre, view: geo.size) else { return }
                    // Moving a box you sized keeps its size; otherwise it takes
                    // the size of your boxes nearby (not a wrong guess's).
                    guessed = false
                    if let box = placed, sized {
                        placed = CGRect(x: p.x - box.width / 2, y: p.y - box.height / 2, width: box.width, height: box.height)
                    } else {
                        placed = AnnotationReview.placedBox(at: p, in: rally, frame: index)
                    }
                }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { d in
                        let base = panBase ?? centre
                        if panBase == nil { panBase = base }
                        let shown = FrameCanvas.shown(image: image, zoom: zoom, view: geo.size)
                        centre = CGPoint(x: base.x - d.translation.width / shown.width, y: base.y - d.translation.height / shown.height)
                    }
                    .onEnded { _ in
                        panBase = nil
                        centre = FrameCanvas.clampedCentre(centre, shown: FrameCanvas.shown(image: image, zoom: zoom, view: geo.size), view: geo.size)
                    })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { m in
                        let base = pinchBase ?? zoom
                        if pinchBase == nil { pinchBase = base }
                        zoom = max(base * m.magnification, 1)
                    }
                    .onEnded { _ in pinchBase = nil })
                .reviewScroll { dx, dy in
                    // Two fingers move the picture, as a drag does.
                    let shown = FrameCanvas.shown(image: image, zoom: zoom, view: geo.size)
                    centre = FrameCanvas.clampedCentre(CGPoint(x: centre.x - dx / shown.width, y: centre.y - dy / shown.height),
                                                       shown: shown, view: geo.size)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if neighbour != nil { lookAround }
            Text(peek != nil ? "Back to this frame to place the ball"
                 : placed == nil ? "Tap the ball to place it, or call it hidden · orange: the ball on the frames either side"
                 : guessed ? "Yellow: a guess from the ball's path · right: Ball here · wrong: tap the ball, or Hidden"
                 : "Tap again to move it · − + size the box")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: onHidden) { Label("Hidden", systemImage: "eye.slash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { size(by: 1 / 1.1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.bordered).disabled(placed == nil || peek != nil)
                    .accessibilityLabel("Smaller box")
                Button { size(by: 1.1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.bordered).disabled(placed == nil || peek != nil)
                    .accessibilityLabel("Bigger box")
                Button { if let placed { onBall(placed) } } label: { Label("Ball here", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(placed == nil || peek != nil)
            }
            .controlSize(.large)
        }
        .padding(8)
        .onChange(of: zoom) { onZoom(zoom) }
        .onChange(of: centre, initial: true) { onCentre(centre) }
        .reviewKeys { press in
            let pan = 0.05 / zoom
            switch press.key {
            case .return, .space:
                guard let placed, peek == nil else { return false }
                onBall(placed)
            case .leftArrow: centre.x -= pan
            case .rightArrow: centre.x += pan
            case .upArrow: centre.y -= pan
            case .downArrow: centre.y += pan
            default:
                switch press.characters.lowercased() {
                case "h": onHidden()
                case "[": size(by: 1 / 1.05)
                case "]": size(by: 1.05)
                case "=", "+": zoom *= 1.25
                case "-": zoom = max(1, zoom / 1.25)
                case ",": look(-1)
                case ".": look(1)
                default: return false
                }
            }
            return true
        }
    }

    /// −2 −1 · this frame · +1 +2.
    private var lookAround: some View {
        HStack(spacing: 6) {
            ForEach(-Self.around...Self.around, id: \.self) { d in
                Button {
                    look(d)
                } label: {
                    Text(d == 0 ? "This frame" : d > 0 ? "+\(d)" : "\(d)")
                        .font(.callout.monospacedDigit())
                        .frame(maxWidth: d == 0 ? .infinity : 44)
                }
                .buttonStyle(.bordered)
                .tint((peek?.offset ?? 0) == d ? .accentColor : .secondary)
                .disabled(d != 0 && rally.points[safe: index + d] == nil)
            }
        }
        .controlSize(.small)
    }

    /// The placed box `k` times as big, about its centre (a far ball is a
    /// few pixels; never under a thousandth of the frame).
    private func size(by k: CGFloat) {
        guard let box = placed, peek == nil else { return }
        guessed = false
        sized = true
        let w = max(box.width * k, 0.001), h = max(box.height * k, 0.001)
        placed = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// Show the frame `offset` away (0: back to this one).
    private func look(_ offset: Int) {
        guard offset != 0, let neighbour else { peek = nil; return }
        Task {
            if let picture = await neighbour(offset) { peek = (offset, picture) }
        }
    }
}

/// A pass on the whole frame: frames said to have no ball (find it, or
/// call it hidden), or frames set aside as not sure (with their box).
struct WholeFrameReviewView: View {
    @State private var walk: ReviewWalk
    let kind: AnnotationReview.Kind
    /// The zoom you left each rally at: its next frame opens at it.
    @State private var zoomByRally: [UUID: CGFloat] = [:]
    /// The frame last shown and where its view was centred: a frame just
    /// after it in the same rally opens looking at the same place (the ball
    /// has barely moved), not jumping to its box; a jump goes to the box.
    @State private var lastView: (item: AnnotationReview.Item, centre: CGPoint)?

    /// How far ahead the next frame may be and still count as following on.
    private static let followFrames = 3

    init(store: any ReviewStore, kind: AnnotationReview.Kind) {
        self.kind = kind
        _walk = State(initialValue: ReviewWalk(store: store, kinds: [kind]))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { Task { await walk.back() } } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                    .disabled(!walk.canGoBack)
                Button { Task { await walk.skip() } } label: { Label("Skip", systemImage: "forward") }
                    .disabled(walk.item == nil)
                Spacer()
                Text("\(walk.left.formatted()) left").font(.headline.monospacedDigit())
            }
            .padding(.horizontal, 8)
            Group {
                if let image = walk.image, let rally = walk.rally, let item = walk.item {
                    FindBallView(image: image, rally: rally, index: item.index,
                                 // A box someone else placed (the model, a guess) where it is, but
                                 // sized like your boxes nearby; yours as you made it.
                                 box: walk.point.flatMap { p in
                                     guard p.state == .visible, let b = p.box?.rect else { return nil }
                                     return p.origin == .user ? b : AnnotationReview.placedBox(at: CGPoint(x: b.midX, y: b.midY), in: rally, frame: item.index)
                                 },
                                 boxIsYours: walk.point?.origin == .user,
                                 // No box yet: start from where the ball's path says it is.
                                 guess: kind == .noBall ? AnnotationReview.guessedBox(in: rally, frame: item.index) : nil,
                                 // Not sure: the whole frame as it is, to see where the ball fits
                                 // in; then as you left this rally.
                                 zoom: zoomByRally[item.track] ?? (kind == .unsure ? 1 : 2.5),
                                 centre: lastView.flatMap { last in
                                     last.item.track == item.track && (1...Self.followFrames).contains(item.index - last.item.index) ? last.centre : nil
                                 },
                                 neighbour: { await walk.neighbourImage($0) },
                                 onBall: { box in Task { await walk.decide { AnnotationReview.approve(&$0, box: box) } } },
                                 onHidden: { Task { await walk.decide(AnnotationReview.confirmHidden) } },
                                 onZoom: { zoomByRally[item.track] = $0 },
                                 onCentre: { lastView = (item, $0) })
                        .id(item)
                } else if let failure = walk.failure {
                    ContentUnavailableView("Can't show this frame", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if walk.item == nil {
                    ContentUnavailableView(kind == .unsure ? "Nothing set aside" : "Every ball found", systemImage: "checkmark.seal.fill", description: Text(""))
                } else {
                    ProgressView()
                }
            }
            .frame(maxHeight: .infinity)
            ReviewPassBar(walk: walk)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle(kind == .unsure ? "Not sure" : "Find the ball")
        .inlineTitle()
        .task { await walk.load() }
    }
}

/// Over the top: one gap at a time — the frames either side with the ball,
/// then the top of the picture on each frame of the gap, stepped through one
/// by one (a strip shows them all). Where the ball shows, tap it to box it
/// there (− + size it); Done marks every frame without a box hidden.
struct OffTopReviewView: View {
    let store: any ReviewStore
    @State private var gaps: [AnnotationReview.Gap]
    @State private var at = 0
    /// Gaps done, with their frames as they were, for going back.
    @State private var done: [(gap: AnnotationReview.Gap, before: [Int: TrackPoint])] = []
    /// This gap: the frames either side, the top of the picture on each of
    /// its frames, and where that strip sits in the frame (Vision-normalised).
    @State private var shown: (gap: AnnotationReview.Gap, before: CGImage, after: CGImage, band: [CGImage], area: CGRect)?
    /// The frame of the gap showing (offset into it).
    @State private var frame = 0
    /// Balls boxed on this gap's frames, by offset (Vision-normalised).
    @State private var boxes: [Int: CGRect] = [:]
    @State private var failure: String?
    @State private var readers: [String: ReviewFrames] = [:]
    @State private var claimed: Set<UUID> = []
    @State private var refused: Set<UUID> = []

    init(store: any ReviewStore) {
        self.store = store
        _gaps = State(initialValue: store.offTopGaps())
    }

    private var gap: AnnotationReview.Gap? { gaps.indices.contains(at) ? gaps[at] : nil }
    private var ready: Bool { gap != nil && shown?.gap == gap }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { back() } label: { Label("Back", systemImage: "arrow.uturn.backward") }.disabled(done.isEmpty)
                Button { skip() } label: { Label("Skip", systemImage: "forward") }.disabled(gap == nil)
                Spacer()
                Text("\(max(0, gaps.count - at).formatted()) left").font(.headline.monospacedDigit())
            }
            .padding(.horizontal, 8)
            Group {
                if let shown, shown.gap == gap, let rally = store.rally(of: item(shown.gap, shown.gap.frames.lowerBound)) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            end("Before", shown.before, rally.points[safe: shown.gap.frames.lowerBound - 1])
                            end("After", shown.after, rally.points[safe: shown.gap.frames.upperBound + 1])
                        }
                        band(shown.band[frame], area: shown.area, rally: rally)
                        HStack(spacing: 12) {
                            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 28) }
                                .buttonStyle(.bordered).disabled(frame == 0)
                            Text("Frame \(frame + 1) of \(shown.band.count)").font(.callout.monospacedDigit())
                            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 28) }
                                .buttonStyle(.bordered).disabled(frame == shown.band.count - 1)
                            Spacer()
                            Button { size(by: 1 / 1.1) } label: { Image(systemName: "minus.magnifyingglass") }
                                .buttonStyle(.bordered).disabled(boxes[frame] == nil).accessibilityLabel("Smaller box")
                            Button { size(by: 1.1) } label: { Image(systemName: "plus.magnifyingglass") }
                                .buttonStyle(.bordered).disabled(boxes[frame] == nil).accessibilityLabel("Bigger box")
                            Button { boxes[frame] = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.bordered).disabled(boxes[frame] == nil).accessibilityLabel("No ball on this frame")
                        }
                        .padding(.horizontal, 8)
                        strip(shown.band)
                    }
                } else if let failure {
                    ContentUnavailableView("Can't show this gap", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if gap == nil {
                    ContentUnavailableView("Every gap checked", systemImage: "checkmark.seal.fill",
                                           description: Text("Skipped ones are still in Find the ball."))
                } else {
                    ProgressView()
                }
            }
            .frame(maxHeight: .infinity)
            Text("Step through; where the ball shows, tap it. Done: the frames without a box are hidden.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { finish() } label: {
                Label(doneTitle, systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).tint(.indigo).disabled(!ready)
            .padding(.horizontal, 8)
            ProgressView(value: Double(min(at, gaps.count)), total: Double(max(gaps.count, 1))).tint(.green).padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
        .navigationTitle("Over the top")
        .inlineTitle()
        .reviewKeys { press in
            switch press.key {
            case .leftArrow: step(-1)
            case .rightArrow: step(1)
            case .return, .space: finish()
            case .delete, .deleteForward: back()
            default:
                switch press.characters.lowercased() {
                case "[": size(by: 1 / 1.05)
                case "]": size(by: 1.05)
                case "x": boxes[frame] = nil
                case "s": skip()
                default: return false
                }
            }
            return true
        }
        .task(id: gap) {
            frame = 0
            boxes = [:]
            await load()
        }
    }

    private var doneTitle: String {
        let n = gap?.frames.count ?? 0
        return boxes.isEmpty ? "Done · all \(n) hidden" : "Done · \(boxes.count) ball\(boxes.count == 1 ? "" : "s"), \(n - boxes.count) hidden"
    }

    /// The top of the picture on this frame of the gap: tap the ball to box it.
    private func band(_ image: CGImage, area: CGRect, rally: TrackedRally) -> some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(image.width), geo.size.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
            Canvas { ctx, _ in
                ctx.draw(Image(decorative: image, scale: 1), in: CGRect(origin: origin, size: size))
                if let box = boxes[frame] {
                    // Vision (bottom-up, whole frame) → this strip, top-down.
                    let r = CGRect(x: origin.x + (box.minX - area.minX) / area.width * size.width,
                                   y: origin.y + (area.maxY - box.maxY) / area.height * size.height,
                                   width: box.width / area.width * size.width, height: box.height / area.height * size.height)
                    ctx.stroke(Path(r.insetBy(dx: -1.5, dy: -1.5)), with: .color(.green), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in
                let x = (p.x - origin.x) / size.width, y = (p.y - origin.y) / size.height
                guard (0...1).contains(x), (0...1).contains(y), let gap else { return }
                let centre = CGPoint(x: area.minX + x * area.width, y: area.maxY - y * area.height)
                if let box = boxes[frame] {
                    boxes[frame] = CGRect(x: centre.x - box.width / 2, y: centre.y - box.height / 2, width: box.width, height: box.height)
                } else {
                    boxes[frame] = AnnotationReview.placedBox(at: centre, in: rally, frame: gap.frames.lowerBound + frame)
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Every frame of the gap: the one showing outlined, boxed ones marked; tap to go to one.
    private func strip(_ band: [CGImage]) -> some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(band.indices, id: \.self) { k in
                        Image(decorative: band[k], scale: 1)
                            .resizable().scaledToFit()
                            .frame(height: 48)
                            .overlay(alignment: .bottomLeading) {
                                Text("\(k + 1)").font(.caption2.bold().monospacedDigit()).foregroundStyle(.white)
                                    .padding(.horizontal, 4).background(.black.opacity(0.5), in: Capsule()).padding(2)
                            }
                            .overlay(alignment: .topTrailing) {
                                if boxes[k] != nil { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green).padding(3) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(k == frame ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                            .onTapGesture { frame = k }
                            .id(k)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: frame) { scroller.scrollTo(frame, anchor: .center) }
        }
    }

    private func end(_ title: String, _ image: CGImage, _ point: TrackPoint?) -> some View {
        FrameCanvas(image: image, zoom: 1, centre: CGPoint(x: 0.5, y: 0.5), box: point?.box?.rect)
            .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text(title).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule()).padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func item(_ gap: AnnotationReview.Gap, _ index: Int) -> AnnotationReview.Item {
        AnnotationReview.Item(video: gap.video, track: gap.track, index: index)
    }

    private func step(_ d: Int) {
        guard let count = shown?.band.count else { return }
        frame = min(max(frame + d, 0), count - 1)
    }

    /// The box on this frame `k` times as big, about its centre.
    private func size(by k: CGFloat) {
        guard let box = boxes[frame] else { return }
        let w = max(box.width * k, 0.001), h = max(box.height * k, 0.001)
        boxes[frame] = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// Read this gap's frames (passing over gaps of rallies someone else is on).
    private func load() async {
        failure = nil
        while let gap {
            if !claimed.contains(gap.track) && !refused.contains(gap.track) {
                if await store.claim(gap.track) { claimed.insert(gap.track) } else { refused.insert(gap.track) }
            }
            guard gap == self.gap else { return }
            if refused.contains(gap.track) { at += 1; continue }
            guard let rally = store.rally(of: item(gap, gap.frames.lowerBound)),
                  let boxA = rally.points[safe: gap.frames.lowerBound - 1]?.box?.rect,
                  let boxB = rally.points[safe: gap.frames.upperBound + 1]?.box?.rect else { at += 1; continue }
            do {
                let file = try await store.videoFile(video: gap.video)
                if readers[gap.video]?.video != file { readers[gap.video] = ReviewFrames(video: file) }
                guard let reader = readers[gap.video] else { return }
                // Every frame, so the strip's nth picture is the gap's nth frame.
                var images: [CGImage] = []
                for i in (gap.frames.lowerBound - 1)...(gap.frames.upperBound + 1) {
                    guard let p = rally.points[safe: i], let image = await reader.image(at: p.time) else { break }
                    images.append(image)
                }
                guard gap == self.gap else { return }
                guard images.count == gap.frames.count + 2, let first = images.first, let last = images.last else { at += 1; continue }
                let area = Self.area(boxA, boxB)
                let band = images.dropFirst().dropLast().compactMap { Self.crop($0, to: area) }
                guard band.count == gap.frames.count else { at += 1; continue }
                shown = (gap, first, last, band, area)
                return
            } catch {
                failure = error.localizedDescription
                return
            }
        }
        shown = nil
    }

    /// The top of the picture around where the ball left and came back
    /// (Vision-normalised): the width between them and a bit more, from the
    /// top down to just below the lower of the two balls.
    static func area(_ a: CGRect, _ b: CGRect) -> CGRect {
        let width = min(1, max(0.45, abs(a.midX - b.midX) + 0.3))
        let x = min(max((a.midX + b.midX) / 2 - width / 2, 0), 1 - width)
        let height = min(1, max(0.25, 1 - min(a.midY, b.midY) + 0.12))
        return CGRect(x: x, y: 1 - height, width: width, height: height)
    }

    static func crop(_ image: CGImage, to area: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return image.cropping(to: CGRect(x: area.minX * w, y: (1 - area.maxY) * h, width: area.width * w, height: area.height * h).integral)
    }

    /// The boxed frames get their ball (checked, as a box approved in
    /// review); the rest are hidden.
    private func finish() {
        guard let gap, ready, let size = shown.map({ CGSize(width: $0.before.width, height: $0.before.height) }) else { return }
        var before: [Int: TrackPoint] = [:]
        for (k, i) in gap.frames.enumerated() {
            let old: TrackPoint?
            if let box = boxes[k] {
                let square = AnnotationReview.adjusted(box, offset: .zero, scale: 1, in: size)
                old = store.review(item(gap, i)) { AnnotationReview.approve(&$0, box: square) }
            } else {
                old = store.review(item(gap, i), AnnotationReview.confirmHidden)
            }
            if let old { before[i] = old }
        }
        done.append((gap, before))
        at += 1
    }

    private func skip() {
        guard gap != nil else { return }
        at += 1
    }

    /// Put the last gap done back as it was, and show it again.
    private func back() {
        guard let last = done.popLast() else { return }
        for (i, old) in last.before { store.review(item(last.gap, i)) { $0 = old } }
        at = gaps.firstIndex(of: last.gap) ?? max(0, at - 1)
    }
}

/// Rally or not: each pre-tracked rally plays on a loop until it's answered.
/// One that runs long can be trimmed (on the phone) — that answers Rally too.
struct RallyCheckView: View {
    let store: any ReviewStore
    @State private var checks: [AnnotationReview.RallyCheck]
    @State private var at = 0
    /// Answers in order, with the rally as it was before a trim (to put back).
    @State private var undo: [(check: AnnotationReview.RallyCheck, before: TrackedRally?)] = []
    @State private var player = RallyLoopPlayer()
    @State private var fast = true
    @State private var failure: String?
    /// Where this rally's video plays from.
    @State private var url: URL?
    @State private var trimming = false

    init(store: any ReviewStore) {
        self.store = store
        _checks = State(initialValue: store.rallyChecks())
    }

    private var check: AnnotationReview.RallyCheck? { checks.indices.contains(at) ? checks[at] : nil }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { back() } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                    .disabled(undo.isEmpty)
                Spacer()
                // Can't tell (a clip that won't play right): leave it for later.
                Button("Skip") { at += 1 }.disabled(check == nil)
                Button { fast.toggle(); player.rate = fast ? 2 : 1 } label: { Text(fast ? "2×" : "1×").monospacedDigit() }
                    .buttonStyle(.bordered)
                Text("\(max(0, checks.count - at).formatted()) left").font(.headline.monospacedDigit())
            }
            .padding(.horizontal, 8)
            Group {
                if let check {
                    VStack(spacing: 6) {
                        VideoPlayer(player: player.player)
                            .overlay { if player.waiting { ProgressView().controlSize(.large).tint(.white) } }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("\(store.videoName(video: check.video)) · \(clock(check.start))–\(clock(check.end))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    ContentUnavailableView("Every rally checked", systemImage: "checkmark.seal.fill",
                                           description: Text("The real ones' frames are in Review."))
                }
            }
            .frame(maxHeight: .infinity)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 12) {
                Button(role: .destructive) { answer(false) } label: {
                    Label("Not a rally", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                #if os(iOS)
                Button { player.stop(); trimming = true } label: {
                    Label("Trim", systemImage: "timeline.selection").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(url == nil)
                #endif
                Button { answer(true) } label: {
                    Label("Rally", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
            .disabled(check == nil)
            .padding(.horizontal, 8)
            ProgressView(value: Double(min(at, checks.count)), total: Double(max(checks.count, 1))).tint(.green)
                .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
        .navigationTitle("Rally or not")
        .inlineTitle()
        .reviewKeys { press in
            switch press.characters.lowercased() {
            case "r": answer(true)
            case "n": answer(false)
            case "s": if check != nil { at += 1 }
            case " ": player.togglePlay()
            case "\u{7F}", "\u{8}": back()
            default: return false
            }
            return true
        }
        .task(id: check) { await play() }
        .onDisappear { player.stop() }
        #if os(iOS)
        .fullScreenCover(isPresented: $trimming, onDismiss: { Task { await play() } }) {
            if let check, let url, let rally = store.rally(of: check) {
                RallyCheckTrimView(url: url, rally: rally.bounds, onConfirm: { kept in
                    trimming = false
                    trim(check, to: kept)
                }, onCancel: { trimming = false })
            } else {
                Color.clear.onAppear { trimming = false }
            }
        }
        #endif
    }

    private func play() async {
        guard let check else { player.stop(); return }
        failure = nil
        url = nil
        do {
            let url = try await store.playbackURL(video: check.video)
            guard check == self.check else { return }
            self.url = url
            player.loop(url, video: check.video, from: check.start, to: check.end, rate: fast ? 2 : 1)
        } catch {
            failure = "Couldn't load the video: \(error.localizedDescription)"
            return
        }
        // Bring this video, then the next one, onto the device while you
        // watch (not on cellular): their other rallies then play from the file.
        let next = checks[at...].first { $0.video != check.video }?.video
        for video in [check.video, next].compactMap({ $0 }) where !Task.isCancelled { await store.fetchAhead(video: video) }
    }

    private func answer(_ isRally: Bool) {
        guard let check else { return }
        store.setIsRally(isRally, check)
        undo.append((check, nil))
        at += 1
    }

    /// Cut the rally to `kept` (the frames outside it go) and call it a rally.
    private func trim(_ check: AnnotationReview.RallyCheck, to kept: LabelRally) {
        guard let before = store.rally(of: check) else { return }
        var cut = before.trimmed(start: kept.start, end: kept.end)
        cut.isRally = true
        store.replace(check, with: cut)
        store.setIsRally(true, check)
        undo.append((check, before))
        at += 1
    }

    private func back() {
        guard let last = undo.popLast() else { return }
        if let before = last.before { store.replace(last.check, with: before) }
        store.setIsRally(nil, last.check)
        at = checks.firstIndex(of: last.check) ?? max(0, at - 1)
    }

    private func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

/// One player that loops a stretch of a video, reusing the item when the
/// next stretch is in the same video (a streamed video's link is new each
/// time it's asked for, so it's known by the video; a file by its path).
@MainActor
@Observable
final class RallyLoopPlayer {
    let player = AVPlayer()
    var rate: Float = 2 { didSet { if player.rate > 0 { player.rate = rate } } }
    /// Waiting for the video to load or buffer.
    private(set) var waiting = false
    @ObservationIgnored private var source: String?
    @ObservationIgnored private var start = CMTime.zero
    @ObservationIgnored private var boundary: Any?
    @ObservationIgnored private var status: NSKeyValueObservation?

    init() {
        status = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in self?.waiting = waiting }
        }
    }

    func loop(_ url: URL, video: String, from start: Double, to end: Double, rate: Float) {
        let source = url.isFileURL ? url.path : video
        if source != self.source {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            self.source = source
        }
        if let boundary { player.removeTimeObserver(boundary) }
        self.start = CMTime(seconds: start, preferredTimescale: 600)
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
                                                  queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        self.rate = rate
        restart()
    }

    /// Back to the start and play: from the keyframe up to half a second
    /// before it, which a stream seeks to far quicker than an exact frame.
    private func restart() {
        player.seek(to: start, toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceAfter: .zero) { [weak self] done in
            guard done else { return }
            Task { @MainActor in guard let self else { return }; self.player.rate = self.rate }
        }
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() } else { player.rate = rate }
    }

    func stop() {
        player.pause()
        if let boundary { player.removeTimeObserver(boundary) }
        boundary = nil
        player.replaceCurrentItem(with: nil)
        source = nil
    }
}

/// How far through this pass: a bar along the bottom with the count.
/// Icon over title: four choices fit across a phone.
private struct StackedLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon
            configuration.title.font(.caption).lineLimit(1)
        }
    }
}

private struct ReviewPassBar: View {
    let walk: ReviewWalk

    var body: some View {
        let total = max(walk.items.count, 1), done = min(walk.at, walk.items.count)
        VStack(spacing: 4) {
            ProgressView(value: Double(done), total: Double(total))
                .tint(.green)
            HStack {
                Text("\(done.formatted()) of \(walk.items.count.formatted()) done"
                     + (walk.unreadable > 0 ? " · \(walk.unreadable) couldn't be read, left for later" : "")
                     + (walk.othersFrames > 0 ? " · \(walk.othersFrames) someone else is reviewing" : ""))
                Spacer()
                Text("\(Int((Double(done) / Double(total) * 100).rounded()))%")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

extension View {
    /// Inline navigation title where there is one (the phone).
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Key presses while the screen is showing (it takes the focus).
    func reviewKeys(_ handle: @escaping (KeyPress) -> Bool) -> some View {
        modifier(ReviewKeys(handle: handle))
    }
}

#if os(macOS)
import AppKit

/// Two fingers on the trackpad (scroll) while the pointer is over the view:
/// `handle` gets the movement in points, following the fingers.
private struct ReviewScroll: ViewModifier {
    let handle: (CGFloat, CGFloat) -> Void
    @State private var hovering = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    guard hovering else { return event }
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                    handle(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale)
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
#endif

private extension View {
    /// The trackpad's two-finger scroll, on the Mac; nothing on the phone.
    @ViewBuilder
    func reviewScroll(_ handle: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        #if os(macOS)
        modifier(ReviewScroll(handle: handle))
        #else
        self
        #endif
    }
}

private struct ReviewKeys: ViewModifier {
    let handle: (KeyPress) -> Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(phases: .down) { handle($0) ? .handled : .ignored }
        #else
        // On the phone, touch only: taking the keyboard focus can get in the
        // way of the picture's gestures.
        content
        #endif
    }
}
