//
//  CalibrationEditorView.swift
//  BumpSetCut
//
//  The court page and the net page of the setup before processing (ProcessingSetupFlowView):
//  a person marks the court's six ground points, or the net's four corners,
//  on a frame of their video, adjusts them, and confirms. Tap to place, drag a point or a
//  line, pinch to zoom, pan with one finger off the shape, step frame by frame. While a
//  point is dragged a loupe above the finger shows what is under it. Nothing here waits
//  for, or needs, a model.
//

import SwiftUI

struct CalibrationEditorView: View {
    @State private var model: CalibrationEditorViewModel
    @State private var viewport = CalibrationViewport(canvas: .zero, frameAspect: 16 / 9)
    @State private var drag: ActiveDrag?
    @State private var pinchBaseScale: CGFloat?
    @State private var wholeShape = false
    @State private var askBeforeClosing = false
    @State private var askBeforeSkipping = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// How near a touch must be to a point, and to a line, to take hold of it.
    private static let handleRadius: CGFloat = 30
    private static let edgeTolerance: CGFloat = 16
    /// A touch that moves less than this is a tap.
    private static let tapSlop: CGFloat = 8
    private static let loupeSide: CGFloat = 132

    private struct ActiveDrag {
        var startLocation: CGPoint
        var action: CalibrationDragAction
        var shapes: CalibrationWorkingShapes
        var viewport: CalibrationViewport
        var location: CGPoint
        var moved = false
        /// A pinch took over: the rest of this touch does nothing.
        var ignored = false
    }

    /// The page the editor is in the setup before processing: one shape, a Skip beside its Confirm.
    struct Step {
        let target: CalibrationTarget
        let progress: SetupProgress
        /// The shape is confirmed, or the page skipped.
        let onDone: () -> Void
        let onCancel: () -> Void
    }
    private let step: Step

    init(videoId: UUID, videoURL: URL, reviewer: String, step: Step) {
        self.step = step
        _model = State(wrappedValue: CalibrationEditorViewModel(videoId: videoId, url: videoURL, store: .app, reviewer: reviewer,
                                                                target: step.target))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let why):
                    // A calibration that can't be opened must not hold up the run: the page can still be skipped.
                    VStack(spacing: BSCSpacing.lg) {
                        BSCEmptyState(icon: "exclamationmark.triangle", title: "Court & Net can't open", message: LocalizedStringResource(stringLiteral: why))
                        BSCButton(title: "Skip", icon: "forward.fill", style: .secondary, size: .medium, isFullWidth: false, action: step.onDone)
                            .accessibilityIdentifier(AccessibilityID.Process.setupSkip)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    editor
                }
            }
            .background(Color.bscBackground.ignoresSafeArea())
            .navigationTitle("Court & Net")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if model.hasUnsavedChanges { askBeforeClosing = true } else { step.onCancel() } }
                        .accessibilityIdentifier(AccessibilityID.Calibration.close)
                }
                ToolbarItem(placement: .principal) { SetupStepTitle(title: step.target == .court ? "Court" : "Net", progress: step.progress) }
                if model.phase == .ready {
                    ToolbarItem(placement: .primaryAction) { moreMenu }
                }
            }
            .confirmationDialog("Save your changes?", isPresented: $askBeforeClosing, titleVisibility: .visible) {
                Button("Save draft and close") { model.saveDraft(); if !model.hasUnsavedChanges { step.onCancel() } }
                Button("Close without saving", role: .destructive) { step.onCancel() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Skip without saving these marks?", isPresented: $askBeforeSkipping, titleVisibility: .visible) {
                Button("Skip without them", role: .destructive) { step.onDone() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(model.notice ?? String(localized: "What is on the picture could not be saved as a draft."))
            }
        }
        .task { await model.load() }
        .onDisappear { model.close() }
        .onChange(of: model.frameAspect, initial: true) { _, aspect in viewport.frameAspect = aspect }
    }

    // MARK: - Layout

    @ViewBuilder
    private var editor: some View {
        if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                canvas
                ScrollView { controls.padding(BSCSpacing.md) }.frame(width: 320)
            }
        } else {
            VStack(spacing: 0) {
                canvas
                // At a large text size, or on a short phone, the controls are taller than the room under the
                // picture: they scroll then, instead of being squeezed into each other.
                ViewThatFits(in: .vertical) {
                    controls.padding(BSCSpacing.md)
                    ScrollView { controls.padding(BSCSpacing.md) }
                }
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                CalibrationOverlayCanvas(image: model.frame, viewport: viewport, shapes: model.shapes, showCourt: model.showCourt,
                                         showNet: model.showNet, target: model.isStableView ? model.target : nil, selected: model.selected)
                    .contentShape(Rectangle())
                    .gesture(dragGesture.simultaneously(with: pinchGesture))
                    .accessibilityLabel(Text("Video frame with the court and net marks"))
                    .accessibilityIdentifier(AccessibilityID.Calibration.canvas)
                loupe
            }
            .onChange(of: geometry.size, initial: true) { _, size in viewport.canvas = size }
        }
        .background(Color.bscMediaBackground)
        .clipped()
    }

    @ViewBuilder
    private var loupe: some View {
        if let drag, drag.moved, !drag.ignored, case .handle(let handle) = drag.action, let at = model.shapes.position(handle) {
            let side = Self.loupeSide
            // Above the finger; below it when there is no room above.
            let above = drag.location.y - side / 2 - 56
            let y = above > side / 2 ? above : drag.location.y + side / 2 + 56
            let x = min(max(side / 2 + 4, drag.location.x), max(side / 2 + 4, viewport.canvas.width - side / 2 - 4))
            CalibrationOverlayCanvas(image: model.frame, viewport: viewport.loupe(onX: at.x, y: at.y, side: side, magnification: 2.5),
                                     shapes: model.shapes, showCourt: model.showCourt, showNet: model.showNet, target: nil, selected: nil)
                .frame(width: side, height: side)
                .background(Color.bscMediaBackground)
                .overlay {
                    // Cross-hairs on the point itself.
                    Path { p in
                        p.move(to: CGPoint(x: side / 2 - 10, y: side / 2)); p.addLine(to: CGPoint(x: side / 2 + 10, y: side / 2))
                        p.move(to: CGPoint(x: side / 2, y: side / 2 - 10)); p.addLine(to: CGPoint(x: side / 2, y: side / 2 + 10))
                    }
                    .stroke(Color.white, lineWidth: 1)
                }
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(radius: 6)
                .position(x: x, y: y)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Beside the picture, not over it: a button on the frame would sit on a corner someone needs to reach.
    private var viewRow: some View {
        HStack(spacing: 0) {
            visibilityToggle(isOn: $model.showCourt, color: CalibrationOverlayCanvas.courtColor, label: "Show the court")
            visibilityToggle(isOn: $model.showNet, color: CalibrationOverlayCanvas.netColor, label: "Show the net")
            Toggle(isOn: $wholeShape) {
                // The words go when the row is too narrow for them (landscape, large text); the label is still read out.
                ViewThatFits(in: .horizontal) {
                    Label("Move all", systemImage: "arrow.up.and.down.and.arrow.left.and.right").lineLimit(1)
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                }
                .bscFont(size: 13, weight: .medium)
                .frame(minHeight: BSCTouchTarget.compact)
            }
            .toggleStyle(.button)
            .accessibilityLabel(Text("Dragging moves the whole shape"))
            Spacer(minLength: BSCSpacing.sm)
            iconButton("minus.magnifyingglass", "Zoom out") { zoom(by: 1 / 1.5) }
            iconButton("arrow.up.left.and.arrow.down.right", "Fit the picture") {
                viewport.scale = 1
                viewport.offset = .zero
            }
            iconButton("plus.magnifyingglass", "Zoom in") { zoom(by: 1.5) }
        }
    }

    private func iconButton(_ icon: String, _ label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .bscFont(size: 17, weight: .medium)
                .foregroundColor(.bscTextPrimary)
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func zoom(by factor: CGFloat) {
        viewport = viewport.zoomed(to: viewport.scale * factor, keeping: CGPoint(x: viewport.canvas.width / 2, y: viewport.canvas.height / 2))
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag?.startLocation != value.startLocation {
                    let action: CalibrationDragAction = model.isStableView
                        ? model.shapes.dragAction(at: value.startLocation, in: viewport, target: model.target, wholeShape: wholeShape,
                                                  handleRadius: Self.handleRadius, edgeTolerance: Self.edgeTolerance)
                        : .pan
                    drag = ActiveDrag(startLocation: value.startLocation, action: action, shapes: model.shapes, viewport: viewport,
                                      location: value.location, ignored: pinchBaseScale != nil)
                }
                guard var active = drag, !active.ignored else { return }
                active.location = value.location
                if !active.moved, hypot(value.translation.width, value.translation.height) < Self.tapSlop {
                    drag = active
                    return
                }
                active.moved = true
                drag = active
                let frame = active.viewport.frameRect
                switch active.action {
                case .pan:
                    viewport = active.viewport.panned(by: value.translation)
                default:
                    guard frame.width > 0, frame.height > 0 else { return }
                    model.drag(active.action, from: active.shapes, dx: Double(value.translation.width / frame.width),
                               dy: Double(-value.translation.height / frame.height))
                }
            }
            .onEnded { value in
                defer { drag = nil }
                guard let active = drag, !active.ignored, !active.moved else { return }
                let at = viewport.normalized(value.location)
                let hit = model.shapes.handle(near: value.location, in: viewport, target: model.target, radius: Self.handleRadius)
                model.tap(x: at.x, y: at.y, on: hit)
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBaseScale == nil {
                    pinchBaseScale = viewport.scale
                    // The first finger of a pinch was a drag until now: undo what it moved.
                    if var active = drag {
                        model.restore(active.shapes)
                        active.ignored = true
                        drag = active
                    }
                }
                viewport = viewport.zoomed(to: (pinchBaseScale ?? 1) * value.magnification, keeping: value.startLocation)
            }
            .onEnded { _ in pinchBaseScale = nil }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.sm) {
            banners
            statusLine
            viewRow
            pointChips
            Text(hint)
                .bscFont(size: 14)
                .foregroundColor(.bscTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                .accessibilityIdentifier(AccessibilityID.Calibration.hint)
            frameRow
            HStack(spacing: BSCSpacing.sm) {
                // What is on the picture is kept as a draft; the run goes on without it.
                BSCButton(title: "Skip", icon: "forward.fill", style: .ghost, size: .medium, isFullWidth: false) {
                    if model.hasUnsavedChanges { model.saveDraft() }
                    // What could not be saved (a net short of four corners, a file that would not write) is not
                    // dropped without a word: the page stays until the person says to go on without it.
                    if model.hasUnsavedChanges { askBeforeSkipping = true } else { step.onDone() }
                }
                .accessibilityIdentifier(AccessibilityID.Process.setupSkip)
                BSCButton(title: confirmTitle, style: .primary, size: .medium) {
                    if model.confirm() { step.onDone() }
                }
                    .accessibilityIdentifier(AccessibilityID.Calibration.confirm)
                    .disabled(!model.isStableView)
                    .opacity(model.isStableView ? 1 : 0.5)
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let reason = model.staleReason {
            banner(icon: "exclamationmark.triangle.fill", text: String(localized: "Marks were saved for a different version of this video (\(reason)), so they aren't used."),
                   action: "Use them as a starting point") { model.startFromStaleFile() }
        }
        if !model.isStableView {
            banner(icon: "video.slash", text: String(localized: "This part of the video is marked as not a stable court view."),
                   action: "It is a stable view") { model.setView(.stable) }
        }
    }

    private func banner(icon: String, text: String, action: LocalizedStringResource, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            Label(text, systemImage: icon)
                .bscFont(size: 13)
                .foregroundColor(.bscWarningText)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: perform) {
                Text(action).bscFont(size: 13, weight: .semibold).frame(minHeight: BSCTouchTarget.standard).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.bscPrimaryText)
        }
        .padding(BSCSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous).fill(Color.bscSurfaceGlass))
    }

    private var statusLine: some View {
        HStack(spacing: BSCSpacing.xs) {
            Text(model.status.title)
                .bscFont(size: 13, weight: .semibold)
                .foregroundColor(model.status == .bothConfirmed ? .bscSuccessText : .bscTextPrimary)
            if model.segmentCount > 1 {
                Text("· Camera view \(model.segmentNumber) of \(model.segmentCount)")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }
            Spacer(minLength: 0)
            if let notice = model.notice {
                Text(notice)
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.hasUnsavedChanges {
                Text("Not saved").bscFont(size: 13).foregroundColor(.bscWarningText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Calibration.status)
    }

    /// A shape confirmed earlier and not touched since needs no second confirming: the button moves on.
    private var confirmTitle: LocalizedStringResource {
        if model.partState(model.target) == .confirmed { return "Continue" }
        return model.target == .court ? "Confirm court" : "Confirm net"
    }

    private func visibilityToggle(isOn: Binding<Bool>, color: Color, label: LocalizedStringResource) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: isOn.wrappedValue ? "eye.fill" : "eye.slash")
                .bscFont(size: 15)
                .foregroundColor(isOn.wrappedValue ? color : .bscTextTertiary)
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private var pointChips: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            HStack(spacing: BSCSpacing.xxs) {
                ForEach(CalibrationWorkingShapes.handles(of: model.target), id: \.self) { handle in
                    let placed = model.shapes.position(handle) != nil
                    Button { model.selected = handle } label: {
                        Text(handle.shortName)
                            .bscFont(size: 12, weight: .medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: BSCTouchTarget.standard)
                            .foregroundColor(model.selected == handle ? .bscOnPrimary : (placed ? .bscTextPrimary : .bscTextTertiary))
                            .background(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                                .fill(model.selected == handle ? Color.bscPrimaryFill : Color.bscSurfaceGlass))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(placed ? "Placed" : "Not placed"))
                    .accessibilityAddTraits(model.selected == handle ? .isSelected : [])
                }
            }
            if let selected = model.selected, model.shapes.position(selected) != nil {
                HStack(spacing: BSCSpacing.md) {
                    if case .court(let role) = selected, let at = model.shapes.position(selected), (0...1).contains(at.x), (0...1).contains(at.y) {
                        Toggle("Hidden — my best guess", isOn: Binding(get: { model.shapes.court[role].status == .estimated },
                                                                       set: { model.setSelectedEstimated($0) }))
                            .bscFont(size: 13)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) { model.removeSelected() } label: {
                        Label(selected.target == .court ? "Can't place it" : "Remove", systemImage: "xmark.circle")
                            .bscFont(size: 13)
                            .frame(minHeight: BSCTouchTarget.standard)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.bscErrorText)
                }
            }
        }
    }

    private var hint: String {
        guard model.isStableView else { return String(localized: "Nothing is marked on a part of the video that isn't a stable court view.") }
        let next = model.selected.flatMap { model.shapes.position($0) == nil ? $0 : nil } ?? model.shapes.nextToPlace(model.target)
        guard let next else { return String(localized: "Drag a point or a line to adjust it. Pinch to zoom; drag the picture to move it.") }
        return model.target == .court
            ? String(localized: "\(next.prompt) Out of the picture? Zoom out and tap where it would be.")
            : next.prompt
    }

    private var frameRow: some View {
        VStack(spacing: BSCSpacing.xxs) {
            HStack(spacing: BSCSpacing.xs) {
                stepButton("gobackward.5", "Back 5 seconds") { model.step(seconds: -5) }
                stepButton("chevron.backward", "Back one frame") { model.step(frames: -1) }
                Text(Self.clock(model.time))
                    .bscFont(size: 14, weight: .medium)
                    .monospacedDigit()
                    .foregroundColor(.bscTextPrimary)
                    .frame(maxWidth: .infinity)
                stepButton("chevron.forward", "Forward one frame") { model.step(frames: 1) }
                stepButton("goforward.5", "Forward 5 seconds") { model.step(seconds: 5) }
            }
            Slider(value: Binding(get: { model.time }, set: { model.seek(to: $0) }), in: 0...max(model.durationSec, 0.1))
                .accessibilityLabel(Text("Position in the video"))
        }
    }

    private func stepButton(_ icon: String, _ label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .bscFont(size: 17, weight: .semibold)
                .foregroundColor(.bscTextPrimary)
                .frame(width: BSCTouchTarget.standard + 8, height: BSCTouchTarget.standard)
                .background(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous).fill(Color.bscSurfaceGlass))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// Minutes, seconds and hundredths: frames are told apart.
    private static func clock(_ t: Double) -> String {
        let hundredths = Int((max(0, t) * 100).rounded())
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    // MARK: - More

    private var moreMenu: some View {
        Menu {
            Section("Camera") {
                Menu {
                    Button("Start from these marks") { model.cameraChangedHere(reuse: true) }
                    Button("Start with nothing marked") { model.cameraChangedHere(reuse: false) }
                } label: {
                    Label("Camera changed here", systemImage: "scissors")
                }
                if model.isStableView {
                    Button { model.setView(.unsuitable) } label: { Label("Not a stable court view", systemImage: "video.slash") }
                    Button { model.setView(.unknown) } label: { Label("Can't tell what this view is", systemImage: "questionmark.circle") }
                } else {
                    Button { model.setView(.stable) } label: { Label("This is a stable court view", systemImage: "video") }
                }
            }
            Section("Court") {
                Picker("Surface", selection: Binding(get: { model.setup.surface }, set: { model.setSetup(surface: $0, format: model.setup.format) })) {
                    Text("Not set").tag(CourtSetup.Surface?.none)
                    Text("Beach").tag(CourtSetup.Surface?.some(.beach))
                    Text("Grass").tag(CourtSetup.Surface?.some(.grass))
                    Text("Indoor").tag(CourtSetup.Surface?.some(.indoor))
                }
                .pickerStyle(.menu)
                Picker("Players a side", selection: Binding(get: { model.setup.format }, set: { model.setSetup(surface: model.setup.surface, format: $0) })) {
                    Text("Not set").tag(CourtSetup.Format?.none)
                    Text("2 v 2").tag(CourtSetup.Format?.some(.twos))
                    Text("4 v 4").tag(CourtSetup.Format?.some(.fours))
                    Text("6 v 6").tag(CourtSetup.Format?.some(.sixes))
                }
                .pickerStyle(.menu)
            }
            Section {
                Button(role: .destructive) { model.startOver() } label: {
                    Label(model.target == .court ? "Start the court over" : "Start the net over", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("More"))
    }
}
