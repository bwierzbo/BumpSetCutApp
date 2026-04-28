//
//  PreTrimView.swift
//  BumpSetCut
//
//  Full-screen trim UI presented before AI processing.
//  Users can set start/end boundaries or skip to process the entire video.
//

import SwiftUI
import AVFoundation

struct PreTrimView: View {
    let videoURL: URL
    let onSkip: () -> Void
    let onTrimmed: (URL) -> Void

    @State private var viewModel: PreTrimViewModel
    @Environment(\.dismiss) private var dismiss

    init(videoURL: URL, onSkip: @escaping () -> Void, onTrimmed: @escaping (URL) -> Void) {
        self.videoURL = videoURL
        self.onSkip = onSkip
        self.onTrimmed = onTrimmed
        self._viewModel = State(wrappedValue: PreTrimViewModel(videoURL: videoURL))
    }

    // MARK: - Layout Constants
    private let handleWidth: CGFloat = 14
    private let barHeight: CGFloat = 56
    private let borderThickness: CGFloat = 3
    private let handleHitPadding: CGFloat = 12

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                topBar
                    .padding(.horizontal, BSCSpacing.lg)
                    .padding(.top, BSCSpacing.md)

                Spacer()

                // Video player
                if let player = viewModel.player {
                    videoPlayerSection(player: player)
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()

                // Time labels
                timeLabels
                    .padding(.horizontal, BSCSpacing.xl)
                    .padding(.bottom, BSCSpacing.sm)

                // Filmstrip trim bar
                if viewModel.videoDuration > 0 {
                    GeometryReader { geo in
                        trimBar(totalWidth: geo.size.width)
                    }
                    .frame(height: barHeight)
                    .padding(.horizontal, BSCSpacing.lg)
                }

                // Duration label
                Text("Duration: \(formatTime(viewModel.selectionDuration))")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.bscTextSecondary)
                    .padding(.top, BSCSpacing.sm)

                // Action buttons
                actionButtons
                    .padding(.horizontal, BSCSpacing.xl)
                    .padding(.top, BSCSpacing.lg)
                    .padding(.bottom, BSCSpacing.huge)
            }
        }
        .task {
            await viewModel.loadVideo()
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }

            Spacer()

            Text("Trim Video")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            // Invisible spacer to balance the X button
            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: - Video Player

    private func videoPlayerSection(player: AVPlayer) -> some View {
        CustomVideoPlayerView(
            player: player,
            gravity: .resizeAspect,
            onReadyForDisplay: { _ in }
        )
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md))
        .padding(.horizontal, BSCSpacing.lg)
        .contentShape(Rectangle())
        .onTapGesture {
            togglePlayback(player: player)
        }
    }

    private func togglePlayback(player: AVPlayer) {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            // If at end, seek to start of selection
            let currentTime = CMTimeGetSeconds(player.currentTime())
            if currentTime >= viewModel.endTime - 0.1 {
                let seekTime = CMTime(seconds: viewModel.startTime, preferredTimescale: 600)
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        }
    }

    // MARK: - Time Labels

    private var timeLabels: some View {
        HStack {
            Text(formatTime(viewModel.startTime))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.bscPrimary)
            Spacer()
            Text(formatTime(viewModel.endTime))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.bscPrimary)
        }
    }

    // MARK: - Trim Bar

    @ViewBuilder
    private func trimBar(totalWidth: CGFloat) -> some View {
        let leftX = xForTime(viewModel.startTime, in: totalWidth)
        let rightX = xForTime(viewModel.endTime, in: totalWidth)

        ZStack(alignment: .leading) {
            // Filmstrip thumbnails
            filmstrip(width: totalWidth)

            // Dim overlay left of selection
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: max(0, leftX), height: barHeight)
                .allowsHitTesting(false)

            // Dim overlay right of selection
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: max(0, totalWidth - rightX), height: barHeight)
                .offset(x: rightX)
                .allowsHitTesting(false)

            // Yellow top/bottom borders between handles
            let innerWidth = max(0, rightX - leftX - 2 * handleWidth)
            VStack(spacing: 0) {
                Rectangle().fill(Color.bscPrimary).frame(height: borderThickness)
                Spacer()
                Rectangle().fill(Color.bscPrimary).frame(height: borderThickness)
            }
            .frame(width: innerWidth, height: barHeight)
            .offset(x: leftX + handleWidth)
            .allowsHitTesting(false)

            // Left handle
            trimHandle(isLeft: true)
                .offset(x: leftX - handleHitPadding)
                .gesture(leftHandleDrag(totalWidth: totalWidth))

            // Right handle
            trimHandle(isLeft: false)
                .offset(x: rightX - handleWidth - handleHitPadding)
                .gesture(rightHandleDrag(totalWidth: totalWidth))
        }
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm))
    }

    // MARK: - Filmstrip

    @ViewBuilder
    private func filmstrip(width: CGFloat) -> some View {
        if viewModel.thumbnails.isEmpty {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: width, height: barHeight)
        } else {
            HStack(spacing: 0) {
                ForEach(viewModel.thumbnails.indices, id: \.self) { i in
                    Image(uiImage: viewModel.thumbnails[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(viewModel.thumbnails.count), height: barHeight)
                        .clipped()
                }
            }
            .frame(width: width, height: barHeight)
        }
    }

    // MARK: - Handle

    @ViewBuilder
    private func trimHandle(isLeft: Bool) -> some View {
        ZStack {
            Color.clear
                .frame(width: handleWidth + handleHitPadding * 2, height: barHeight)
                .contentShape(Rectangle())

            UnevenRoundedRectangle(
                topLeadingRadius: isLeft ? BSCRadius.sm : 0,
                bottomLeadingRadius: isLeft ? BSCRadius.sm : 0,
                bottomTrailingRadius: isLeft ? 0 : BSCRadius.sm,
                topTrailingRadius: isLeft ? 0 : BSCRadius.sm
            )
            .fill(Color.bscPrimary)
            .frame(width: handleWidth, height: barHeight)
            .overlay(
                Image(systemName: isLeft ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    @State private var leftDragBase: Double?
    @State private var rightDragBase: Double?

    private func leftHandleDrag(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if leftDragBase == nil { leftDragBase = viewModel.startTime }
                let baseX = xForTime(leftDragBase ?? 0, in: totalWidth)
                let newTime = timeForX(baseX + value.translation.width, in: totalWidth)
                viewModel.updateStartTime(newTime)
            }
            .onEnded { _ in leftDragBase = nil }
    }

    private func rightHandleDrag(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if rightDragBase == nil { rightDragBase = viewModel.endTime }
                let baseX = xForTime(rightDragBase ?? viewModel.videoDuration, in: totalWidth)
                let newTime = timeForX(baseX + value.translation.width, in: totalWidth)
                viewModel.updateEndTime(newTime)
            }
            .onEnded { _ in rightDragBase = nil }
    }

    // MARK: - Position Mapping

    private func xForTime(_ time: Double, in width: CGFloat) -> CGFloat {
        guard viewModel.videoDuration > 0 else { return 0 }
        return CGFloat(time / viewModel.videoDuration) * width
    }

    private func timeForX(_ x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(x / width) * viewModel.videoDuration
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if viewModel.isExporting {
            VStack(spacing: BSCSpacing.md) {
                ProgressView(value: viewModel.exportProgress)
                    .tint(.bscPrimary)

                Text("Trimming video... \(Int(viewModel.exportProgress * 100))%")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.bscTextSecondary)
            }
        } else if let error = viewModel.exportError {
            VStack(spacing: BSCSpacing.md) {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.bscError)
                    .multilineTextAlignment(.center)

                BSCButton(title: "Try Again", icon: "arrow.clockwise", style: .primary, size: .large) {
                    performTrim()
                }
            }
        } else {
            HStack(spacing: BSCSpacing.md) {
                BSCButton(title: "Skip", icon: "forward.fill", style: .ghost, size: .large) {
                    onSkip()
                }

                BSCButton(title: "Trim & Process", icon: "scissors", style: .primary, size: .large) {
                    performTrim()
                }
                .disabled(!viewModel.canTrim)
                .opacity(viewModel.canTrim ? 1.0 : 0.5)
            }
        }
    }

    private func performTrim() {
        Task {
            if let trimmedURL = await viewModel.exportTrimmed() {
                onTrimmed(trimmedURL)
            }
        }
    }

    // MARK: - Formatting

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Preview

#Preview {
    PreTrimView(
        videoURL: URL(fileURLWithPath: "/dev/null"),
        onSkip: {},
        onTrimmed: { _ in }
    )
}
