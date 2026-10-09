//
//  ReviewViews.swift
//  RallyLab (macOS and iPhone)
//
//  Annotation review, the same screens on the Mac and the phone (see
//  AnnotationReview). The Review tab
//  shows how much is checked and opens the two passes:
//   · Boxes — a crop around each box, the box fixed in the middle: drag the
//     picture to put the ball's centre under it, pinch to size it, tap to
//     approve and go on. No ball sends the frame to Whole frames.
//   · Whole frames — the full frame: tap the ball to place it and approve,
//     or confirm it's hidden.
//  Back undoes the last decision.
//
//  Keys (the Mac, or a keyboard): Boxes — ↩/Space approve, arrows move the
//  box a pixel (⇧ five), [ ] size it, X no ball, ⌫ back. Whole frames —
//  click the ball, ↩ approve, H hidden, = − zoom, arrows pan, ⌫ back.
//

import SwiftUI

struct ReviewHomeView: View {
    let store: any ReviewStore
    let progress: (reviewed: Int, total: Int)

    var body: some View {
        let crops = store.reviewItems(.crop).count, whole = store.reviewItems(.fullFrame).count
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
                    card("Boxes", "\(crops.formatted()) to check · drag to centre, pinch to size, tap to approve", "viewfinder", crops)
                }
                .buttonStyle(.plain).disabled(crops == 0)
                NavigationLink { WholeFrameReviewView(store: store) } label: {
                    card("Whole frames", "\(whole.formatted()) to check · hidden frames and ones you said had no ball", "rectangle.dashed", whole)
                }
                .buttonStyle(.plain).disabled(whole == 0)
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

/// Boxes: one crop at a time.
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

    init(store: any ReviewStore) {
        _walk = State(initialValue: ReviewWalk(store: store, kind: .crop))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Group {
                    if let image = walk.image, let box = walk.point?.box?.rect, let patch {
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
                                    if tap { approve(box: box, image: image) }
                                })
                            .simultaneousGesture(MagnifyGesture()
                                .onChanged { m in
                                    let base = pinchBase ?? scale
                                    if pinchBase == nil { pinchBase = base }
                                    pinched = true
                                    scale = min(max(base * m.magnification, 0.3), 4)
                                }
                                .onEnded { _ in pinchBase = nil })
                    } else if let failure = walk.failure {
                        ContentUnavailableView("Can't show this frame", systemImage: "exclamationmark.triangle", description: Text(failure))
                    } else if walk.item == nil {
                        ContentUnavailableView("All boxes checked", systemImage: "checkmark.seal.fill",
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
            ReviewProgress(walk: walk)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle("Boxes")
        .inlineTitle()
        .reviewKeys { press in cropKey(press) }
        .task { await walk.load() }
        // Cut out the part around the box once per frame.
        .onChange(of: walk.image.map(ObjectIdentifier.init), initial: true) {
            patch = walk.image.flatMap { image in walk.point?.box.flatMap { CropPatch(frame: image, box: $0.rect) } }
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
                Button(role: .destructive) { Task { reset(); await walk.decide(AnnotationReview.noBall) } } label: {
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
            guard let image = walk.image, let box = walk.point?.box?.rect else { return false }
            approve(box: box, image: image)
        case .leftArrow: offset.width -= step
        case .rightArrow: offset.width += step
        case .upArrow: offset.height -= step
        case .downArrow: offset.height += step
        case .delete, .deleteForward: Task { reset(); await walk.back() }
        default:
            switch press.characters.lowercased() {
            case "[", "-": scale = max(0.3, scale / 1.05)
            case "]", "=", "+": scale = min(4, scale * 1.05)
            case "x": Task { reset(); await walk.decide(AnnotationReview.noBall) }
            default: return false
            }
        }
        return true
    }

    private func approve(box: CGRect, image: CGImage) {
        let size = CGSize(width: image.width, height: image.height)
        let new = AnnotationReview.adjusted(box, offset: offset, scale: scale, in: size)
        reset()
        approved += 1
        Task { await walk.decide { AnnotationReview.approve(&$0, box: new) } }
    }

    private func reset() {
        offset = .zero
        scale = 1
    }
}

/// Whole frames: place the ball or confirm it's hidden.
struct WholeFrameReviewView: View {
    @State private var walk: ReviewWalk
    @State private var zoom: CGFloat = 2.5
    @State private var centre = CGPoint(x: 0.5, y: 0.5)
    @State private var panBase: CGPoint?
    @State private var pinchBase: CGFloat?
    @State private var placed: CGRect?

    init(store: any ReviewStore) {
        _walk = State(initialValue: ReviewWalk(store: store, kind: .fullFrame))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(walk.left.formatted()) left").font(.headline.monospacedDigit())
                Spacer()
                if let p = walk.point {
                    Text(p.state == .hidden ? "marked hidden" : "you said no ball here").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            GeometryReader { geo in
                Group {
                    if let image = walk.image {
                        FrameCanvas(image: image, zoom: zoom, centre: centre, box: placed)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let rally = walk.rally, let item = walk.item,
                                      let p = FrameCanvas.framePoint(location, image: image, zoom: zoom, centre: centre, view: geo.size)
                                else { return }
                                placed = AnnotationReview.placedBox(at: p, in: rally, frame: item.index)
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
                    } else if let failure = walk.failure {
                        ContentUnavailableView("Can't show this frame", systemImage: "exclamationmark.triangle", description: Text(failure))
                    } else if walk.item == nil {
                        ContentUnavailableView("All whole frames checked", systemImage: "checkmark.seal.fill", description: Text(""))
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(spacing: 8) {
                Text(placed == nil ? "Tap the ball to place it, or confirm it can't be seen" : "Tap again to move it")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { Task { await go { await walk.back() } } } label: {
                        Image(systemName: "arrow.uturn.backward").frame(maxWidth: 44)
                    }
                    .buttonStyle(.bordered).disabled(!walk.canGoBack)
                    Button { Task { await go { await walk.decide(AnnotationReview.confirmHidden) } } } label: {
                        Label("Hidden", systemImage: "eye.slash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).disabled(walk.item == nil)
                    Button {
                        guard let placed else { return }
                        Task { await go { await walk.decide { AnnotationReview.approve(&$0, box: placed) } } }
                    } label: { Label("Ball here", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(placed == nil)
                }
                .controlSize(.large)
            }
            ReviewProgress(walk: walk)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .navigationTitle("Whole frames")
        .inlineTitle()
        .reviewKeys { press in wholeKey(press) }
        .task { await go { await walk.load() } }
    }

    private func wholeKey(_ press: KeyPress) -> Bool {
        let pan = 0.05 / zoom
        switch press.key {
        case .return:
            guard let placed else { return false }
            Task { await go { await walk.decide { AnnotationReview.approve(&$0, box: placed) } } }
        case .leftArrow: centre.x -= pan
        case .rightArrow: centre.x += pan
        case .upArrow: centre.y -= pan
        case .downArrow: centre.y += pan
        case .delete, .deleteForward: Task { await go { await walk.back() } }
        default:
            switch press.characters.lowercased() {
            case "h": Task { await go { await walk.decide(AnnotationReview.confirmHidden) } }
            case "=", "+": zoom = min(8, zoom * 1.25)
            case "-": zoom = max(1, zoom / 1.25)
            default: return false
            }
        }
        return true
    }

    /// Do `step`, then start the new frame centred where the ball was last seen.
    private func go(_ step: () async -> Void) async {
        placed = nil
        await step()
        if let rally = walk.rally, let item = walk.item { centre = FrameCanvas.focus(rally, frame: item.index) }
    }
}

/// How far through this pass: a bar along the bottom with the count.
private struct ReviewProgress: View {
    let walk: ReviewWalk

    var body: some View {
        let total = max(walk.items.count, 1), done = min(walk.at, walk.items.count)
        VStack(spacing: 4) {
            ProgressView(value: Double(done), total: Double(total))
                .tint(.green)
            HStack {
                Text("\(done.formatted()) of \(walk.items.count.formatted()) done")
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
