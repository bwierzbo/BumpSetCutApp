//
//  ReviewViews.swift
//  RallyLab (macOS and iPhone)
//
//  Annotation review, the same screens on the Mac and the phone (see
//  AnnotationReview). The Review tab shows how much is checked and opens:
//   · Review — every frame of finished rallies in order, as a crop: a ball's
//     box fixed in the middle (drag the picture to put the ball's centre
//     under it, pinch to size it, tap to approve and go on); a frame marked
//     hidden shows where the ball last was (tap to confirm it's hidden).
//     Find ball opens the whole frame, only when the ball isn't in the crop:
//     tap it and approve, or call it hidden — then straight back.
//   · Not sure — frames set aside, on the whole frame with their box.
//  Back undoes the last decision.
//
//  On the Mac: two fingers on the trackpad move the picture, pinch sizes the
//  box (as on the phone); ↩/Space approve (or confirm hidden) and go on, arrows move the box a
//  pixel (⇧ five), [ ] size it, F find the ball, U not sure, ⌫ back. On the whole frame: click the ball, ↩ approve,
//  H hidden, = − zoom, arrows pan, Esc back to the crop.
//

import SwiftUI

struct ReviewHomeView: View {
    let store: any ReviewStore
    let progress: (reviewed: Int, total: Int)

    var body: some View {
        let frames = store.reviewItems([.crop, .fullFrame]).count
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
                NavigationLink { CropReviewView(store: store) } label: {
                    card("Review", "\(frames.formatted()) frames to check · drag to centre, pinch to size, tap to approve", "viewfinder", frames)
                }
                .buttonStyle(.plain).disabled(frames == 0)
                NavigationLink { UnsureReviewView(store: store) } label: {
                    card("Not sure", "\(unsure.formatted()) set aside · a closer look when you have time", "questionmark.circle", unsure)
                }
                .buttonStyle(.plain).disabled(unsure == 0)
            }
            .padding()
        }
        .navigationTitle("Review")
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

/// The frame being checked, for Find ball's whole-frame view.
private struct Finding: Identifiable {
    let id = UUID()
    let image: CGImage
    let rally: TrackedRally
    let index: Int
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
    @State private var finding: Finding?

    init(store: any ReviewStore) {
        _walk = State(initialValue: ReviewWalk(store: store, kinds: [.crop, .fullFrame]))
    }

    /// The frame's ball, if it has one (else it's marked hidden or no ball).
    private var ball: CGRect? { walk.point.flatMap { $0.state == .visible ? $0.box?.rect : nil } }

    /// What the crop is centred on: the ball's box, or for a frame without
    /// one, a ball-sized box where the ball was last seen.
    private var shownBox: CGRect? {
        if let ball { return ball }
        guard let rally = walk.rally, let item = walk.item else { return nil }
        let f = FrameCanvas.focus(rally, frame: item.index)
        return AnnotationReview.placedBox(at: CGPoint(x: f.x, y: 1 - f.y), in: rally, frame: item.index)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Group {
                    if let image = walk.image, let box = shownBox, let patch {
                        let k = CropCanvas.geometry(frameSize: patch.frameSize, box: box, view: CGSize(width: side, height: side)).k
                        CropCanvas(patch: patch, box: box, offset: offset, scale: scale, showsBox: ball != nil)
                            .overlay(alignment: .bottom) {
                                if ball == nil {
                                    Text(walk.point?.state == .hidden ? "Marked hidden · tap to confirm, or Find ball"
                                                                      : "No ball here · tap to call it hidden, or Find ball")
                                        .font(.callout.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(10)
                                }
                            }
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
                                    if tap { approve(image: image) }
                                })
                            .simultaneousGesture(MagnifyGesture()
                                .onChanged { m in
                                    pinched = true
                                    // Like zooming a photo: spreading the fingers brings the
                                    // picture closer, so the ball grows against the box — the
                                    // box shrinks to the ball.
                                    let base = pinchBase ?? scale
                                    if pinchBase == nil { pinchBase = base }
                                    scale = min(max(base / m.magnification, 0.3), 4)
                                }
                                .onEnded { _ in pinchBase = nil })
                            .reviewScroll { dx, dy in
                                // Two fingers move the picture, as a drag does.
                                offset = CGSize(width: offset.width - dx / k, height: offset.height - dy / k)
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
        .reviewKeys { press in finding == nil && cropKey(press) }
        .task { await walk.load() }
        // Cut out the part around the box once per frame.
        .onChange(of: walk.image.map(ObjectIdentifier.init), initial: true) {
            patch = walk.image.flatMap { image in shownBox.flatMap { CropPatch(frame: image, box: $0) } }
        }
        .sensoryFeedback(.success, trigger: approved)
        .sheet(item: $finding) { f in
            NavigationStack {
                FindBallView(image: f.image, rally: f.rally, index: f.index, box: nil,
                             onBall: { box in decide { AnnotationReview.approve(&$0, box: box) } },
                             onHidden: { decide(AnnotationReview.confirmHidden) })
                    .navigationTitle("Find the ball")
                    .inlineTitle()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back to crop") { finding = nil } } }
            }
            .frame(minWidth: 700, minHeight: 600)
        }
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
            Text(ball == nil ? "Tap to confirm · Find ball if you can see it on the whole frame"
                             : "Drag to centre the ball · pinch to size the box · tap to approve")
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
                Button { find() } label: {
                    Label("Find ball", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(walk.image == nil)
            }
            .controlSize(.large)
        }
    }

    private func cropKey(_ press: KeyPress) -> Bool {
        let step: CGFloat = press.modifiers.contains(.shift) ? 5 : 1
        switch press.key {
        case .return, .space:
            guard let image = walk.image else { return false }
            approve(image: image)
        case .leftArrow: offset.width -= step
        case .rightArrow: offset.width += step
        case .upArrow: offset.height -= step
        case .downArrow: offset.height += step
        case .delete, .deleteForward: Task { reset(); await walk.back() }
        default:
            switch press.characters.lowercased() {
            case "[", "-": scale = max(0.3, scale / 1.05)
            case "]", "=", "+": scale = min(4, scale * 1.05)
            case "f": find()
            case "?", "/", "u": Task { reset(); await walk.decide(AnnotationReview.markUnsure) }
            default: return false
            }
        }
        return true
    }

    /// Tap: the ball's box as adjusted, or for a frame without a ball, it's hidden.
    private func approve(image: CGImage) {
        guard let ball else { return decide(AnnotationReview.confirmHidden) }
        let size = CGSize(width: image.width, height: image.height)
        let new = AnnotationReview.adjusted(ball, offset: offset, scale: scale, in: size)
        approved += 1
        decide { AnnotationReview.approve(&$0, box: new) }
    }

    private func find() {
        guard let image = walk.image, let rally = walk.rally, let item = walk.item else { return }
        finding = Finding(image: image, rally: rally, index: item.index)
    }

    /// Decide this frame (closing Find ball if it's open) and go on.
    private func decide(_ change: @escaping (inout TrackPoint) -> Void) {
        reset()
        finding = nil
        Task { await walk.decide(change) }
    }

    private func reset() {
        offset = .zero
        scale = 1
    }
}

/// The whole frame, to find the ball: pinch to zoom, drag to look around,
/// tap the ball to place it, then approve — or call it hidden. Starts
/// zoomed in where the ball was last seen, with `box` if there is one.
struct FindBallView: View {
    let image: CGImage
    let rally: TrackedRally
    let index: Int
    let onBall: (CGRect) -> Void
    let onHidden: () -> Void
    @State private var zoom: CGFloat = 2.5
    @State private var centre: CGPoint
    @State private var panBase: CGPoint?
    @State private var pinchBase: CGFloat?
    @State private var placed: CGRect?

    init(image: CGImage, rally: TrackedRally, index: Int, box: CGRect?,
         onBall: @escaping (CGRect) -> Void, onHidden: @escaping () -> Void) {
        self.image = image
        self.rally = rally
        self.index = index
        self.onBall = onBall
        self.onHidden = onHidden
        _centre = State(initialValue: FrameCanvas.focus(rally, frame: index))
        _placed = State(initialValue: box)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                FrameCanvas(image: image, zoom: zoom, centre: centre, box: placed)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let p = FrameCanvas.framePoint(location, image: image, zoom: zoom, centre: centre, view: geo.size) else { return }
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
            Text(placed == nil ? "Tap the ball to place it, or call it hidden" : "Tap again to move it")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: onHidden) { Label("Hidden", systemImage: "eye.slash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { if let placed { onBall(placed) } } label: { Label("Ball here", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(placed == nil)
            }
            .controlSize(.large)
        }
        .padding(8)
        .reviewKeys { press in
            let pan = 0.05 / zoom
            switch press.key {
            case .return:
                guard let placed else { return false }
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
                default: return false
                }
            }
            return true
        }
    }
}

/// Not sure: the frames set aside, each on the whole frame with its box.
struct UnsureReviewView: View {
    @State private var walk: ReviewWalk

    init(store: any ReviewStore) {
        _walk = State(initialValue: ReviewWalk(store: store, kinds: [.unsure]))
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
                                 onBall: { box in Task { await walk.decide { AnnotationReview.approve(&$0, box: box) } } },
                                 onHidden: { Task { await walk.decide(AnnotationReview.confirmHidden) } })
                        .id(item)
                } else if let failure = walk.failure {
                    ContentUnavailableView("Can't show this frame", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if walk.item == nil {
                    ContentUnavailableView("Nothing set aside", systemImage: "checkmark.seal.fill", description: Text(""))
                } else {
                    ProgressView()
                }
            }
            .frame(maxHeight: .infinity)
            ReviewPassBar(walk: walk)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle("Not sure")
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
