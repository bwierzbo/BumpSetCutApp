//
//  ReviewViews.swift
//  RallyLab (macOS and iPhone)
//
//  Annotation review, the same screens on the Mac and the phone (see
//  AnnotationReview). The Review tab shows how much is checked and opens:
//   · Review — every ball's box in finished rallies, in order, as a crop:
//     the box fixed in the middle (drag the picture to put the ball's centre
//     under it, pinch to size it, tap to approve and go on). Hidden frames
//     aren't shown: they count as checked. No ball sets a frame aside for —
//   · Find the ball — the whole frame: tap the ball and approve, or hidden.
//   · Not sure — frames set aside, on the whole frame with their box.
//  Back undoes the last decision.
//
//  On the Mac: two fingers on the trackpad move the picture, pinch sizes the
//  box (as on the phone); ↩/Space approve and go on, arrows move the box a
//  pixel (⇧ five), [ ] size it, X no ball, U not sure, ⌫ back. On the
//  whole frame: click the ball, ↩ approve, H hidden, = − zoom, arrows pan.
//

import SwiftUI

struct ReviewHomeView: View {
    let store: any ReviewStore
    let progress: (reviewed: Int, total: Int)
    /// Rallies with frames to review that someone else is on right now.
    @State private var held: Set<UUID> = []
    @State private var takingOver = false

    var body: some View {
        let frames = store.reviewItems([.crop]).count
        let noBall = store.reviewItems([.noBall]).count
        let unsure = store.reviewItems([.unsure]).count
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(progress.reviewed.formatted()) of \(progress.total.formatted()) frames reviewed")
                        .font(.headline.monospacedDigit())
                    ProgressView(value: Double(progress.reviewed), total: Double(max(progress.total, 1)))
                    Text("Only reviewed frames of finished rallies are used for training.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                if !held.isEmpty { heldCard }
                NavigationLink { CropReviewView(store: store) } label: {
                    card("Review", "\(frames.formatted()) frames to check · drag to centre, pinch to size, tap to approve", "viewfinder", frames)
                }
                .buttonStyle(.plain).disabled(frames == 0)
                NavigationLink { WholeFrameReviewView(store: store, kind: .noBall) } label: {
                    card("Find the ball", "\(noBall.formatted()) said no ball · find it on the whole frame, or call it hidden", "scope", noBall)
                }
                .buttonStyle(.plain).disabled(noBall == 0)
                NavigationLink { WholeFrameReviewView(store: store, kind: .unsure) } label: {
                    card("Not sure", "\(unsure.formatted()) set aside · a closer look when you have time", "questionmark.circle", unsure)
                }
                .buttonStyle(.plain).disabled(unsure == 0)
            }
            .padding()
        }
        .navigationTitle("Review")
        // Who's on what changes as others review: look again now and then.
        .task {
            while !Task.isCancelled {
                await refreshHeld()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Someone else is reviewing some rallies: their frames are skipped, or take them over.
    private var heldCard: some View {
        let frames = store.reviewItems([.crop, .noBall, .unsure]).filter { held.contains($0.track) }.count
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

    /// Only rallies that still have frames for this person to review.
    private func refreshHeld() async {
        let mine = Set(store.reviewItems([.crop, .noBall, .unsure]).map(\.track))
        held = await store.heldByOthers().intersection(mine)
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

    /// The frame's ball box.
    private var ball: CGRect? { walk.point.flatMap { $0.state == .visible ? $0.box?.rect : nil } }

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
                Text("\(walk.store.videoName(of: item)) · \(clockText(p.time))").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Text("Drag to centre the ball · pinch to size the box · tap to approve")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Task { reset(); await walk.back() } } label: {
                    Label("Back", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(!walk.canGoBack)
                Button { Task { reset(); await walk.decide(AnnotationReview.markUnsure) } } label: {
                    Label("Not sure", systemImage: "questionmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange).disabled(walk.item == nil)
                Button(role: .destructive) { decide(AnnotationReview.noBall) } label: {
                    Label("No ball", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.red).disabled(walk.item == nil)
            }
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
            case "x": decide(AnnotationReview.noBall)
            case "?", "/", "u": Task { reset(); await walk.decide(AnnotationReview.markUnsure) }
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

/// The whole frame, to find the ball: pinch to zoom, drag to look around,
/// tap the ball to place it, then approve — or call it hidden. The ball's
/// boxes on the frames either side are drawn faintly (with their offsets),
/// and −2 −1 +1 +2 show those frames themselves for a moment. Starts at
/// `zoom` (2.5 = zoomed in where the ball was last seen; 1 = the whole
/// frame), with `box` if there is one.
struct FindBallView: View {
    let image: CGImage
    let rally: TrackedRally
    let index: Int
    /// Frame `offset` away, for a look; nil to leave out the look-around strip.
    var neighbour: ((Int) async -> CGImage?)?
    let onBall: (CGRect) -> Void
    let onHidden: () -> Void
    @State private var zoom: CGFloat
    @State private var centre: CGPoint
    @State private var panBase: CGPoint?
    @State private var pinchBase: CGFloat?
    @State private var placed: CGRect?
    /// Showing a neighbouring frame instead (offset and picture).
    @State private var peek: (offset: Int, image: CGImage)?

    /// How many frames either side are drawn and can be looked at.
    static let around = 2

    init(image: CGImage, rally: TrackedRally, index: Int, box: CGRect?, zoom: CGFloat = 2.5,
         neighbour: ((Int) async -> CGImage?)? = nil,
         onBall: @escaping (CGRect) -> Void, onHidden: @escaping () -> Void) {
        self.image = image
        self.rally = rally
        self.index = index
        self.neighbour = neighbour
        self.onBall = onBall
        self.onHidden = onHidden
        _zoom = State(initialValue: zoom)
        _centre = State(initialValue: zoom > 1 ? FrameCanvas.focus(rally, frame: index) : CGPoint(x: 0.5, y: 0.5))
        _placed = State(initialValue: box)
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
                        FrameCanvas(image: image, zoom: zoom, centre: centre, box: placed, neighbours: neighbours)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard peek == nil,
                          let p = FrameCanvas.framePoint(location, image: image, zoom: zoom, centre: centre, view: geo.size) else { return }
                    placed = AnnotationReview.placedBox(at: p, in: rally, frame: index)
                }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { d in
                        let base = panBase ?? centre
                        if panBase == nil { panBase = base }
                        let shown = FrameCanvas.shown(image: image, zoom: zoom, view: geo.size)
                        centre = CGPoint(x: base.x - d.translation.width / shown.width, y: base.y - d.translation.height / shown.height)
                    }
                    .onEnded { _ in panBase = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { m in
                        let base = pinchBase ?? zoom
                        if pinchBase == nil { pinchBase = base }
                        zoom = min(max(base * m.magnification, 1), 8)
                    }
                    .onEnded { _ in pinchBase = nil })
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if neighbour != nil { lookAround }
            Text(peek != nil ? "Back to this frame to place the ball"
                 : placed == nil ? "Tap the ball to place it, or call it hidden · orange: the ball on the frames either side"
                 : "Tap again to move it")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: onHidden) { Label("Hidden", systemImage: "eye.slash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { if let placed { onBall(placed) } } label: { Label("Ball here", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(placed == nil || peek != nil)
            }
            .controlSize(.large)
        }
        .padding(8)
        .reviewKeys { press in
            let pan = 0.05 / zoom
            switch press.key {
            case .return:
                guard let placed, peek == nil else { return false }
                onBall(placed)
            case .leftArrow: centre.x -= pan
            case .rightArrow: centre.x += pan
            case .upArrow: centre.y -= pan
            case .downArrow: centre.y += pan
            default:
                switch press.characters.lowercased() {
                case "h": onHidden()
                case "=", "+": zoom = min(8, zoom * 1.25)
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

    init(store: any ReviewStore, kind: AnnotationReview.Kind) {
        self.kind = kind
        _walk = State(initialValue: ReviewWalk(store: store, kinds: [kind]))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { Task { await walk.back() } } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                    .disabled(!walk.canGoBack)
                Spacer()
                Text("\(walk.left.formatted()) left").font(.headline.monospacedDigit())
            }
            .padding(.horizontal, 8)
            Group {
                if let image = walk.image, let rally = walk.rally, let item = walk.item {
                    FindBallView(image: image, rally: rally, index: item.index,
                                 box: walk.point.flatMap { $0.state == .visible ? $0.box?.rect : nil },
                                 // Not sure: the whole frame as it is, to see where the ball fits in.
                                 zoom: kind == .unsure ? 1 : 2.5,
                                 neighbour: { await walk.neighbourImage($0) },
                                 onBall: { box in Task { await walk.decide { AnnotationReview.approve(&$0, box: box) } } },
                                 onHidden: { Task { await walk.decide(AnnotationReview.confirmHidden) } })
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

/// How far through this pass: a bar along the bottom with the count.
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

private extension View {
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
