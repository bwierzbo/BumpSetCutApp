//
//  RallyTimelineView.swift
//  BumpSetCut
//
//  Whole-video timeline editor: detected rallies appear as segments on a
//  scrollable track, with a preview player above. Users add rallies the
//  detector missed, delete false positives, and drag segment edges — the
//  same handle interaction as trim mode.
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
    @State private var scrubbingFromPlayback = false
    @State private var showDiscardDialog = false
    @State private var showSaveError = false

    // Handle-drag anchors (segment edge value at gesture start)
    @State private var startDragAnchor: Double?
    @State private var endDragAnchor: Double?
    @State private var playheadDragAnchor: Double?

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
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, BSCSpacing.md)

            if viewModel.loadFailed {
                Spacer()
                Text("Couldn't load this video's rally data")
                    .bscFont(size: 15)
                    .foregroundColor(.bscOnMediaSecondary)
                Spacer()
            } else {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                timeReadout
                    .padding(.top, BSCSpacing.md)

                timelineStrip
                    .frame(height: trackHeight + 36)
                    .padding(.top, BSCSpacing.sm)

                editControls
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, BSCSpacing.md)
                    .padding(.bottom, BSCSpacing.lg)
            }
        }
        .background(Color.bscMediaScrimBase.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task {
            await viewModel.load()
            seek(to: viewModel.playhead)
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

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            CustomVideoPlayerView(player: player, gravity: .resizeAspect) { _ in }

            // Play/pause toggle
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .bscFont(size: 22, weight: .semibold)
                    .foregroundColor(.bscOnMedia)
                    .padding(BSCSpacing.md)
                    .background(Color.bscMediaScrimBase.opacity(0.55))
                    .clipShape(Circle())
            }
            .opacity(isPlaying ? 0.35 : 1.0)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
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
                            let time = clampTime(Double(location.x / pps))
                            setPlayhead(time)
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
            viewModel.selectedSegmentID = isSelected ? nil : segment.id
            if !isSelected { setPlayhead(segment.start) }
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
                        player.pause()
                        isPlaying = false
                        let delta = Double(value.translation.width / pps)
                        switch edge {
                        case .leading:
                            if startDragAnchor == nil { startDragAnchor = segment.start }
                            let newStart = (startDragAnchor ?? segment.start) + delta
                            viewModel.setStart(newStart, for: segment.id)
                            if let updated = viewModel.selectedSegment { seek(to: updated.start) }
                        case .trailing:
                            if endDragAnchor == nil { endDragAnchor = segment.end }
                            let newEnd = (endDragAnchor ?? segment.end) + delta
                            viewModel.setEnd(newEnd, for: segment.id)
                            if let updated = viewModel.selectedSegment { seek(to: updated.end) }
                        }
                    }
                    .onEnded { _ in
                        startDragAnchor = nil
                        endDragAnchor = nil
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
                    player.pause()
                    isPlaying = false
                    if playheadDragAnchor == nil { playheadDragAnchor = viewModel.playhead }
                    let time = clampTime((playheadDragAnchor ?? 0) + Double(value.translation.width / pps))
                    setPlayhead(time)
                }
                .onEnded { _ in playheadDragAnchor = nil }
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

    private func seek(to seconds: Double) {
        guard !scrubbingFromPlayback else { return }
        let time = CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
                scrubbingFromPlayback = true
                viewModel.playhead = CMTimeGetSeconds(time)
                scrubbingFromPlayback = false
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
