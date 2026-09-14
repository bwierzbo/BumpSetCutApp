//
//  RallyTimelineView.swift
//  BumpSetCut
//
//  Whole-video timeline editor: full-screen preview with the rally track
//  overlaid at the bottom. Users add rallies the detector missed, delete
//  false positives, drag segment edges (same handle language as trim mode),
//  and scrub by dragging on the video itself.
//

import SwiftUI
import AVFoundation

struct RallyTimelineView: View {
    let videoURL: URL
    let videoId: UUID
    let metadataStore: MetadataStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: RallyTimelineViewModel
    @State private var player: AVPlayer
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var showDiscardDialog = false
    @State private var showSaveError = false

    // Drag anchors (value at gesture start)
    @State private var startDragAnchor: Double?
    @State private var endDragAnchor: Double?
    @State private var playheadDragAnchor: Double?
    @State private var videoScrubAnchor: Double?
    @State private var lastSeekedTime: Double = -1

    private let trackHeight: CGFloat = 64
    private let handleWidth: CGFloat = 18
    private let horizontalInset: CGFloat = BSCSpacing.lg

    init(videoURL: URL, videoId: UUID, metadataStore: MetadataStore, onSaved: @escaping () -> Void) {
        self.videoURL = videoURL
        self.videoId = videoId
        self.metadataStore = metadataStore
        self.onSaved = onSaved
        _viewModel = State(initialValue: RallyTimelineViewModel(
            videoURL: videoURL, videoId: videoId, metadataStore: metadataStore))
        _player = State(initialValue: AVPlayer(url: videoURL))
    }

    var body: some View {
        ZStack {
            Color.bscMediaScrimBase.ignoresSafeArea()

            // Full-screen preview — drag horizontally to scrub, tap to play/pause.
            CustomVideoPlayerView(player: player, gravity: .resizeAspect) { _ in }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(videoScrubGesture)
                .onTapGesture { togglePlayback() }

            // Center play affordance (hidden while playing — tap video to pause)
            if !isPlaying {
                Image(systemName: "play.fill")
                    .bscFont(size: 22, weight: .semibold)
                    .foregroundColor(.bscOnMedia)
                    .padding(BSCSpacing.md)
                    .background(Color.bscMediaScrimBase.opacity(0.55))
                    .clipShape(Circle())
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, BSCSpacing.sm)
                    .background(
                        LinearGradient(colors: [Color.bscMediaScrimBase.opacity(0.85), .clear],
                                       startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                    )

                Spacer()

                if viewModel.loadFailed {
                    Text("Couldn't load this video's rally data")
                        .bscFont(size: 15)
                        .foregroundColor(.bscOnMediaSecondary)
                    Spacer()
                } else {
                    // Bottom control cluster over a scrim so the video stays visible
                    VStack(spacing: BSCSpacing.sm) {
                        timeReadout
                        timelineStrip
                            .frame(height: trackHeight + 36)
                        editControls
                            .padding(.horizontal, horizontalInset)
                    }
                    .padding(.top, BSCSpacing.md)
                    .padding(.bottom, BSCSpacing.md)
                    .background(
                        LinearGradient(colors: [.clear, Color.bscMediaScrimBase.opacity(0.9)],
                                       startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                    )
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            await viewModel.load()
            seek(to: viewModel.playhead, precise: true)
            installTimeObserver()
        }
        .onDisappear {
            player.pause()
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
        }
        .confirmationDialog("Discard timeline changes?", isPresented: $showDiscardDialog, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Couldn't Save", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong writing the rally data. Your video is untouched — try again.")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                if viewModel.hasChanges {
                    showDiscardDialog = true
                } else {
                    dismiss()
                }
            } label: {
                Text("Cancel")
                    .bscFont(size: 16)
                    .foregroundColor(.bscOnMedia)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }

            Spacer()

            VStack(spacing: 0) {
                Text("Edit Rallies")
                    .bscFont(size: 16, weight: .semibold)
                    .foregroundColor(.bscOnMedia)
                Text("\(viewModel.segments.count) \(viewModel.segments.count == 1 ? "rally" : "rallies")")
                    .bscFont(size: 12)
                    .foregroundColor(.bscOnMediaSecondary)
            }

            Spacer()

            Button {
                do {
                    try viewModel.save()
                    onSaved()
                    dismiss()
                } catch {
                    showSaveError = true
                }
            } label: {
                Text("Save")
                    .bscFont(size: 16, weight: .semibold)
                    .foregroundColor(viewModel.hasChanges ? .bscPrimary : .bscOnMediaSecondary)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .disabled(!viewModel.hasChanges)
        }
    }

    // MARK: - Scrubbing on the video

    /// Horizontal pan over the full-screen preview scrubs the playhead —
    /// fine control independent of the timeline's pixel scale.
    private var videoScrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                pausePlayback()
                if videoScrubAnchor == nil { videoScrubAnchor = viewModel.playhead }
                let secondsPerPoint = min(0.08, max(0.01, viewModel.videoDuration / 400))
                let time = clampTime((videoScrubAnchor ?? 0) + Double(value.translation.width) * secondsPerPoint)
                setPlayhead(time)
            }
            .onEnded { _ in
                videoScrubAnchor = nil
                seek(to: viewModel.playhead, precise: true)
            }
    }

    private var timeReadout: some View {
        HStack(spacing: BSCSpacing.sm) {
            Text(timeString(viewModel.playhead))
                .bscFont(size: 14, weight: .semibold, design: .monospaced)
                .foregroundColor(.bscOnMedia)
            Text("/ \(timeString(viewModel.videoDuration))")
                .bscFont(size: 14, design: .monospaced)
                .foregroundColor(.bscOnMediaSecondary)
        }
    }

    // MARK: - Timeline Strip

    /// Points per second: short videos fill the width; long ones scroll.
    private func pointsPerSecond(fitting width: CGFloat) -> CGFloat {
        guard viewModel.videoDuration > 0 else { return 8 }
        return max(8, (width - horizontalInset * 2) / viewModel.videoDuration)
    }

    private var timelineStrip: some View {
        GeometryReader { geo in
            let pps = pointsPerSecond(fitting: geo.size.width)
            let contentWidth = CGFloat(viewModel.videoDuration) * pps

            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Base track — tap to move the playhead
                    RoundedRectangle(cornerRadius: BSCRadius.sm)
                        .fill(Color.bscOnMedia.opacity(0.12))
                        .frame(width: contentWidth, height: trackHeight)
                        .onTapGesture { location in
                            pausePlayback()
                            let time = clampTime(Double(location.x / pps))
                            setPlayhead(time)
                            seek(to: time, precise: true)
                        }
                        .accessibilityIdentifier("timeline.track")

                    // Minute ticks
                    ticks(pps: pps)

                    // Rally segments
                    ForEach(viewModel.segments) { segment in
                        segmentBlock(segment, pps: pps)
                    }

                    // Playhead
                    playheadMarker(pps: pps)
                }
                .frame(width: contentWidth, height: trackHeight + 36, alignment: .topLeading)
                .padding(.horizontal, horizontalInset)
            }
        }
    }

    @ViewBuilder
    private func ticks(pps: CGFloat) -> some View {
        let interval: Double = viewModel.videoDuration > 600 ? 60 : (viewModel.videoDuration > 120 ? 30 : 10)
        let count = viewModel.videoDuration > 0 ? Int(viewModel.videoDuration / interval) : 0
        if count >= 1 {
            ForEach(1...count, id: \.self) { i in
                let time = Double(i) * interval
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.bscOnMedia.opacity(0.25))
                        .frame(width: 1, height: 8)
                    Text(timeString(time))
                        .bscFont(size: 9, design: .monospaced)
                        .foregroundColor(.bscOnMediaSecondary)
                }
                .offset(x: CGFloat(time) * pps, y: trackHeight + 2)
            }
        }
    }

    @ViewBuilder
    private func segmentBlock(_ segment: RallyTimelineViewModel.EditableSegment, pps: CGFloat) -> some View {
        let isSelected = viewModel.selectedSegmentID == segment.id
        let x = CGFloat(segment.start) * pps
        let width = max(CGFloat(segment.duration) * pps, 8)

        ZStack {
            RoundedRectangle(cornerRadius: BSCRadius.sm)
                .fill(Color.bscPrimary.opacity(isSelected ? 0.55 : 0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: BSCRadius.sm)
                        .stroke(isSelected ? Color.bscPrimary : Color.bscPrimary.opacity(0.5),
                                lineWidth: isSelected ? 2 : 1)
                )

            HStack(spacing: 2) {
                if segment.isManual {
                    Image(systemName: "hand.raised.fill")
                        .bscFont(size: 8)
                }
                Text("\(Int(segment.duration.rounded()))s")
                    .bscFont(size: 10, weight: .semibold, design: .monospaced)
            }
            .foregroundColor(.bscOnMedia)
            .lineLimit(1)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: trackHeight)
        .offset(x: x)
        .onTapGesture {
            UIImpactFeedbackGenerator.light()
            pausePlayback()
            viewModel.selectedSegmentID = isSelected ? nil : segment.id
            if !isSelected {
                setPlayhead(segment.start)
                seek(to: segment.start, precise: true)
            }
        }
        .overlay(alignment: .topLeading) {
            if isSelected {
                edgeHandle(edge: .leading, segment: segment, pps: pps)
                    .offset(x: x - handleWidth)
                edgeHandle(edge: .trailing, segment: segment, pps: pps)
                    .offset(x: x + width)
            }
        }
    }

    private enum HandleEdge { case leading, trailing }

    private func edgeHandle(edge: HandleEdge, segment: RallyTimelineViewModel.EditableSegment, pps: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: BSCRadius.sm)
            .fill(Color.bscPrimary)
            .frame(width: handleWidth, height: trackHeight)
            .overlay(
                Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                    .bscFont(size: 14, weight: .bold)
                    .foregroundColor(.bscOnPrimary)
            )
            .contentShape(Rectangle().inset(by: -8))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        pausePlayback()
                        let delta = Double(value.translation.width / pps)
                        switch edge {
                        case .leading:
                            if startDragAnchor == nil { startDragAnchor = segment.start }
                            let newStart = (startDragAnchor ?? segment.start) + delta
                            viewModel.setStart(newStart, for: segment.id)
                            if let updated = viewModel.selectedSegment {
                                viewModel.playhead = updated.start
                                seek(to: updated.start)
                            }
                        case .trailing:
                            if endDragAnchor == nil { endDragAnchor = segment.end }
                            let newEnd = (endDragAnchor ?? segment.end) + delta
                            viewModel.setEnd(newEnd, for: segment.id)
                            if let updated = viewModel.selectedSegment {
                                viewModel.playhead = updated.end
                                seek(to: updated.end)
                            }
                        }
                    }
                    .onEnded { _ in
                        startDragAnchor = nil
                        endDragAnchor = nil
                        seek(to: viewModel.playhead, precise: true)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
            )
            .accessibilityLabel(edge == .leading ? "Rally start handle" : "Rally end handle")
    }

    private func playheadMarker(pps: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.bscOnMedia)
                .frame(width: 11, height: 11)
            Rectangle()
                .fill(Color.bscOnMedia)
                .frame(width: 2, height: trackHeight - 5)
        }
        .frame(width: 30) // widened hit area
        .contentShape(Rectangle())
        .offset(x: CGFloat(viewModel.playhead) * pps - 15, y: -6)
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    pausePlayback()
                    if playheadDragAnchor == nil { playheadDragAnchor = viewModel.playhead }
                    let time = clampTime((playheadDragAnchor ?? 0) + Double(value.translation.width / pps))
                    setPlayhead(time)
                }
                .onEnded { _ in
                    playheadDragAnchor = nil
                    seek(to: viewModel.playhead, precise: true)
                }
        )
        .accessibilityLabel("Playhead")
    }

    // MARK: - Edit Controls

    private var editControls: some View {
        HStack(spacing: BSCSpacing.md) {
            // Add rally at playhead
            Button {
                UIImpactFeedbackGenerator.light()
                if let id = viewModel.addSegmentAtPlayhead() {
                    viewModel.selectedSegmentID = id
                }
            } label: {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "plus.circle.fill")
                        .bscFont(size: 16, weight: .semibold)
                    Text("Add Rally")
                        .bscFont(size: 15, weight: .semibold)
                }
                .foregroundColor(.bscOnPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: BSCTouchTarget.standard)
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                        .fill(LinearGradient.bscPrimaryGradient)
                )
                .opacity(viewModel.canAddAtPlayhead ? 1 : 0.4)
            }
            .disabled(!viewModel.canAddAtPlayhead)

            // Delete selected rally
            if viewModel.selectedSegment != nil {
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    withAnimation(.bscQuick) { viewModel.deleteSelected() }
                } label: {
                    HStack(spacing: BSCSpacing.sm) {
                        Image(systemName: "trash")
                            .bscFont(size: 15, weight: .semibold)
                        Text("Delete")
                            .bscFont(size: 15, weight: .semibold)
                    }
                    .foregroundColor(.bscOnPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .background(
                        RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                            .fill(Color.bscErrorFill)
                    )
                }
            }
        }
        .animation(.bscQuick, value: viewModel.selectedSegmentID)
    }

    // MARK: - Playback Helpers

    private func clampTime(_ time: Double) -> Double {
        min(max(time, 0), viewModel.videoDuration)
    }

    private func setPlayhead(_ time: Double) {
        viewModel.playhead = time
        seek(to: time)
    }

    /// Coarse, throttled seeks while dragging keep scrubbing smooth on long
    /// videos; a precise (frame-exact) seek lands on gesture end.
    private func seek(to seconds: Double, precise: Bool = false) {
        if !precise, abs(seconds - lastSeekedTime) < 0.06 { return }
        lastSeekedTime = seconds
        let time = CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tolerance = CMTimeMakeWithSeconds(0.2, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    private func pausePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func installTimeObserver() {
        let interval = CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                guard isPlaying else { return }
                viewModel.playhead = CMTimeGetSeconds(time)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
