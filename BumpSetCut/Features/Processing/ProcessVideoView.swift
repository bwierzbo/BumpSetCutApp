//
//  ProcessVideoView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import SwiftUI

// MARK: - ProcessVideoView
struct ProcessVideoView: View {
    // MARK: - Properties
    @State private var viewModel: ProcessVideoViewModel
    @State private var hasAppeared = false
    @State private var showReprocessConfirm = false
    @State private var showTimelineEditor = false
    @Environment(\.dismiss) private var dismiss

    init(videoURL: URL, mediaStore: MediaStore, onComplete: @escaping () -> Void) {
        self._viewModel = State(wrappedValue: ProcessVideoViewModel(
            videoURL: videoURL,
            mediaStore: mediaStore,
            onComplete: onComplete
        ))
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    // MARK: - Body
    var body: some View {
        ZStack {
            // Background
            backgroundGradient

            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: isLandscape ? BSCSpacing.lg : BSCSpacing.xxl) {
                        // Animated header
                        headerSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.1), value: hasAppeared)

                        // Processing state content
                        stateContent
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 20)
                            .animation(.bscSpring.delay(0.2), value: hasAppeared)

                        // Action buttons (non-processing states)
                        if viewModel.processingState != .processing {
                            actionButtons
                                .opacity(hasAppeared ? 1 : 0)
                                .offset(y: hasAppeared ? 0 : 20)
                                .animation(.bscSpring.delay(0.3), value: hasAppeared)
                        }
                    }
                    .padding(BSCSpacing.xl)
                    .frame(maxWidth: isLandscape ? BSCContentWidth.regular : .infinity)
                    .frame(maxWidth: .infinity)
                }

                // Cancel button pinned to bottom during processing
                if viewModel.processingState == .processing {
                    cancelButton
                        .padding(.horizontal, BSCSpacing.xl)
                        .padding(.bottom, BSCSpacing.lg)
                        .padding(.top, BSCSpacing.sm)
                        .opacity(hasAppeared ? 1 : 0)
                        .animation(.bscSpring.delay(0.3), value: hasAppeared)
                }
            }
        }
        .navigationTitle("AI Processing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            viewModel.loadCurrentVideoMetadata()
            viewModel.checkForPendingResults()
            withAnimation {
                hasAppeared = true
            }
        }
        .alert("Processing Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .alert("Storage Full", isPresented: $viewModel.showStorageWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.storageWarningMessage)
        }
        .alert("Weekly Limit Reached", isPresented: $viewModel.showProcessingLimit) {
            Button("Upgrade to Pro") { viewModel.showPaywall = true }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(viewModel.processingLimitMessage)
        }
        .sheet(isPresented: $viewModel.showPaywall) {
            PaywallView()
        }
        .fullScreenCover(isPresented: $showTimelineEditor) {
            if let videoMetadata = viewModel.currentVideoMetadata {
                RallyTimelineView(
                    videoURL: videoMetadata.originalURL,
                    videoId: videoMetadata.originalVideoId ?? videoMetadata.id,
                    metadataStore: MetadataStore(),
                    onSaved: {
                        // Jump straight into reviewing what was just added
                        // (delay lets the editor cover finish dismissing).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            viewModel.showRallyPlayer = true
                        }
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $viewModel.showRallyPlayer) {
            if let videoMetadata = viewModel.currentVideoMetadata {
                RallyPlayerView(videoMetadata: videoMetadata, mediaStore: viewModel.mediaStore)
                    .environment(AppNavigationState())
            } else {
                // Safety fallback — dismiss if metadata unexpectedly nil
                Color.bscBackground
                    .ignoresSafeArea()
                    .onAppear { viewModel.showRallyPlayer = false }
            }
        }
        .onChange(of: viewModel.isProcessing) { old, new in
            // When processing finishes, consume results from the coordinator
            if old && !new {
                viewModel.checkForPendingResults()
            }
        }
        .onChange(of: viewModel.showRallyPlayer) { old, new in
            // When rally player is dismissed, go all the way back to library
            if old && !new {
                dismiss()
            }
        }
        .fullScreenCover(isPresented: $viewModel.showPreTrim) {
            PreTrimView(
                videoURL: viewModel.videoURL,
                onSkip: {
                    viewModel.showPreTrim = false
                    viewModel.startProcessing(isDebugMode: viewModel.pendingDebugModeForTrim)
                },
                onTrimmed: { trimmedURL in
                    viewModel.showPreTrim = false
                    // Replace the original file on disk with the trimmed version
                    if let videoId = viewModel.currentVideoMetadata?.id {
                        let replaced = viewModel.mediaStore.replaceVideoFile(id: videoId, withFileAt: trimmedURL)
                        if replaced {
                            viewModel.loadCurrentVideoMetadata()
                        }
                    }
                    viewModel.startProcessing(isDebugMode: viewModel.pendingDebugModeForTrim)
                }
            )
        }
    }
}

// MARK: - Background
private extension ProcessVideoView {
    var backgroundGradient: some View {
        ZStack {
            Color.bscBackground
                .ignoresSafeArea()

            // Animated gradient orbs
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscBlue.opacity(0.1), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 250
                    )
                )
                .frame(width: 500, height: 500)
                .offset(x: -100, y: -150)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscTeal.opacity(0.08), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: 150, y: 250)
        }
    }
}

// MARK: - Header Section
private extension ProcessVideoView {
    var headerSection: some View {
        VStack(spacing: BSCSpacing.lg) {
            // Animated brain icon
            ProcessingIconView(isProcessing: viewModel.isProcessing, isComplete: viewModel.isComplete)

            // Title
            VStack(spacing: BSCSpacing.sm) {
                Text("Rally Detection")
                    .bscFont(size: 28, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text("AI will analyze your video to remove dead time and keep only active rallies")
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - State Content
private extension ProcessVideoView {
    @ViewBuilder
    var stateContent: some View {
        switch viewModel.processingState {
        case .processing:
            processingContent
        case .pendingSave:
            pendingSaveContent
        case .complete:
            completeContent
        case .noRallies:
            noRalliesContent
        case .hasMetadata:
            hasMetadataContent
        case .alreadyProcessed:
            alreadyProcessedContent
        case .ready:
            readyContent
        }
    }

    var processingContent: some View {
        VStack(spacing: BSCSpacing.xl) {
            // Circular progress
            BSCProgressView(
                progress: viewModel.progress,
                style: .volleyball,
                showPercentage: true
            )
            .frame(width: 120, height: 120)

            Text("Analyzing video...")
                .bscFont(size: 14, weight: .medium)
                .foregroundColor(.bscTextSecondary)

            // Reflects what leaving actually does: with a continued-processing
            // task (iOS 26+) the run follows the user out; otherwise
            // checkpoints mean leaving only pauses it.
            HStack(spacing: BSCSpacing.xs) {
                Image(systemName: ProcessingBackgroundKeeper.processing.isActive
                      ? "checkmark.circle.fill" : "info.circle.fill")
                    .bscFont(size: 11)
                    .foregroundColor(ProcessingBackgroundKeeper.processing.isActive
                                     ? .bscSuccessText : .bscTextSecondary)
                Text(ProcessingBackgroundKeeper.processing.isActive
                     ? "You can leave the app — processing continues in the background and you'll get a notification when it's done."
                     : "You can leave the app — progress is saved, and processing picks up where it left off next time.")
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
        }
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var pendingSaveContent: some View {
        completionSummary(
            subtitle: "Here's what the AI found in your video",
            showsRallyStats: true
        )
    }

    var completeContent: some View {
        completionSummary(
            subtitle: "Your video has been processed and saved",
            showsRallyStats: false
        )
    }

    var noRalliesContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            statusBadge(
                icon: "volleyball.fill",
                iconSize: 40,
                iconColor: .bscWarningText,
                background: .bscWarning
            )

            VStack(spacing: BSCSpacing.sm) {
                Text("No Rallies Detected")
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text("The AI analyzed this video but couldn't identify any active volleyball rallies. This usually means the video angle, lighting, or content wasn't ideal for rally detection.")
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: BSCSpacing.sm) {
                Text("For best results with a different video:")
                    .bscFont(size: 13, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)

                tipRow(icon: "camera.fill", text: "Film from a steady, elevated angle with the full court visible")
                tipRow(icon: "sun.max.fill", text: "Good lighting so the ball is clearly visible")
                tipRow(icon: "figure.volleyball", text: "Active volleyball play with the ball in frame")
                tipRow(icon: "arrow.up.circle.fill", text: "Higher resolution video (1080p or above)")
            }
        }
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: BSCSpacing.sm) {
            Image(systemName: icon)
                .bscFont(size: 14)
                .foregroundColor(.bscPrimary)
                .frame(width: BSCIconSize.md)
            Text(text)
                .bscFont(size: 13)
                .foregroundColor(.bscTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var hasMetadataContent: some View {
        completionSummary(
            subtitle: "Here's what the AI found in your video",
            showsRallyStats: true
        )
    }

    var readyContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            statusBadge(
                icon: "sparkles",
                iconSize: 36,
                iconColor: .bscBlue,
                background: .bscBlue
            )

            VStack(spacing: BSCSpacing.xs) {
                Text("Ready to Process")
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text("Choose a processing mode below")
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var alreadyProcessedContent: some View {
        let info = viewModel.statusInfo

        return VStack(spacing: BSCSpacing.xl) {
            statusBadge(
                icon: info.icon,
                iconSize: 40,
                iconColor: info.color,
                background: info.color
            )

            VStack(spacing: BSCSpacing.md) {
                Text(info.title)
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text(info.description)
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)

                if let detail = info.detail {
                    Text(detail)
                        .bscFont(size: 12, weight: .medium)
                        .foregroundColor(.bscTextSecondary)
                        .padding(.horizontal, BSCSpacing.md)
                        .padding(.vertical, BSCSpacing.xs)
                        .background(Color.bscSurfaceGlass)
                        .clipShape(Capsule())
                }
            }
        }
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }
}

// MARK: - Shared State Content Pieces
private extension ProcessVideoView {
    /// Circular icon badge that heads every state card.
    func statusBadge(icon: String, iconSize: CGFloat, iconColor: Color, background: Color) -> some View {
        ZStack {
            Circle()
                .fill(background.opacity(0.15))
                .frame(width: 80, height: 80)

            Image(systemName: icon)
                .bscFont(size: iconSize)
                .foregroundColor(iconColor)
        }
    }

    /// Results summary shown once processing has finished — the state the view
    /// stays on instead of auto-dismissing, so it must survive a background return.
    func completionSummary(subtitle: String, showsRallyStats: Bool) -> some View {
        VStack(spacing: BSCSpacing.lg) {
            statusBadge(
                icon: "checkmark.circle.fill",
                iconSize: 48,
                iconColor: .bscSuccessText,
                background: .bscSuccess
            )

            VStack(spacing: BSCSpacing.xs) {
                Text("Processing Complete!")
                    .bscFont(size: 20, weight: .bold)
                    .foregroundColor(.bscTextPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)
            }

            if showsRallyStats && viewModel.detectedRallyCount > 0 {
                rallyStats
            }
        }
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var rallyStats: some View {
        HStack(spacing: BSCSpacing.xl) {
            statTile(
                value: "\(viewModel.detectedRallyCount)",
                label: viewModel.detectedRallyCount == 1 ? "Rally" : "Rallies",
                color: .bscPrimaryText
            )

            if let timeCut = viewModel.timeCutFormatted {
                statTile(value: timeCut, label: "Time Saved", color: .bscTealText)
            }

            if let percent = viewModel.timeCutPercent {
                statTile(value: "\(percent)%", label: "Dead Time Cut", color: .bscPrimaryText)
            }
        }
        .padding(.top, BSCSpacing.xs)
    }

    func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: BSCSpacing.xxs) {
            Text(value)
                .bscFont(size: 24, weight: .bold)
                .foregroundColor(color)
            Text(label)
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
    }
}

// MARK: - Action Buttons
private extension ProcessVideoView {
    @ViewBuilder
    var actionButtons: some View {
        switch viewModel.processingState {
        case .processing:
            EmptyView()
        case .pendingSave:
            reviewModeButtons
        case .complete:
            doneButton
        case .noRallies:
            noRalliesButtons
        case .hasMetadata:
            reviewModeButtons
        case .alreadyProcessed:
            alreadyProcessedButtons
        case .ready:
            processingButtons
        }
    }

    var processingButtons: some View {
        VStack(spacing: BSCSpacing.md) {
            if viewModel.isAnotherVideoProcessing {
                // Another video is processing — block concurrent processing
                HStack(spacing: BSCSpacing.sm) {
                    ProgressView()
                        .tint(.bscPrimary)
                    Text("Another video is processing...")
                        .bscFont(size: 14, weight: .medium)
                        .foregroundColor(.bscTextSecondary)
                }
                .padding(BSCSpacing.md)
                .frame(maxWidth: .infinity)
                .bscGlass(cornerRadius: BSCRadius.md, padding: 0)
            }

            // Estimated processing time for the full video (refined on the trim screen)
            if let duration = viewModel.cachedOriginalDuration ?? viewModel.currentVideoMetadata?.duration,
               duration > 0 {
                Label(
                    "Est. processing: \(ProcessingTimeEstimator.formatEstimate(ProcessingTimeEstimator.estimate(forVideoDuration: duration)))",
                    systemImage: "clock"
                )
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
            }

            // AI Processing - Primary (shows trim screen first)
            BSCButton(title: "Start AI Processing", icon: "brain.head.profile", style: .primary, size: .large) {
                viewModel.pendingDebugModeForTrim = false
                viewModel.showPreTrim = true
            }
            .accessibilityIdentifier(AccessibilityID.Process.startButton)
            .disabled(viewModel.isAnotherVideoProcessing)
            .opacity(viewModel.isAnotherVideoProcessing ? 0.5 : 1.0)

            if AppSettings.shared.enableDebugFeatures {
                // Debug Processing - Secondary (only when debug features enabled in Settings)
                BSCButton(title: "Debug Processing", icon: "ladybug", style: .secondary, size: .medium) {
                    viewModel.pendingDebugModeForTrim = true
                    viewModel.showPreTrim = true
                }
                .disabled(viewModel.isAnotherVideoProcessing)
                .opacity(viewModel.isAnotherVideoProcessing ? 0.5 : 1.0)

                Text("AI Processing removes dead time\nDebug Processing includes analysis overlay")
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, BSCSpacing.xs)
            } else {
                Text("AI Processing removes dead time")
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, BSCSpacing.xs)
            }
        }
    }

    var cancelButton: some View {
        BSCButton(title: "Cancel Processing", icon: "xmark", style: .ghost, size: .medium) {
            viewModel.cancelProcessing()
            dismiss()
        }
        .accessibilityIdentifier(AccessibilityID.Process.cancelButton)
    }

    var noRalliesButtons: some View {
        VStack(spacing: BSCSpacing.md) {
            BSCButton(title: "Add Rallies Manually", icon: "plus.circle.fill", style: .primary, size: .large) {
                showTimelineEditor = true
            }

            if !viewModel.didTrySensitiveReprocess {
                BSCButton(title: "Retry with Higher Sensitivity", icon: "dial.high.fill", style: .secondary, size: .medium) {
                    viewModel.reprocessHighSensitivity()
                }
            }

            BSCButton(title: "Back to Library", icon: "chevron.left", style: .ghost, size: .medium) {
                dismiss()
            }
        }
    }

    var alreadyProcessedButtons: some View {
        BSCButton(title: "Back to Library", icon: "chevron.left", style: .secondary, size: .large) {
            dismiss()
        }
    }

    var doneButton: some View {
        BSCButton(title: "Done", icon: "checkmark", style: .primary, size: .large) {
            dismiss()
        }
        .accessibilityIdentifier(AccessibilityID.Process.doneButton)
    }

    var reviewModeButtons: some View {
        VStack(spacing: BSCSpacing.md) {
            BSCButton(title: "View Rallies", icon: "play.fill", style: .primary, size: .large) {
                viewModel.showRallyPlayer = true
            }
            .accessibilityIdentifier(AccessibilityID.Process.viewRallies)

            BSCButton(title: "Missed a Rally? Add It Manually", icon: "plus.circle", style: .secondary, size: .medium) {
                showTimelineEditor = true
            }

            BSCButton(title: "Done", icon: "checkmark", style: .ghost, size: .medium) {
                dismiss()
            }
            .accessibilityIdentifier(AccessibilityID.Process.doneButton)

            // Dev tool (gated behind Debug Features): re-run detection on the full video
            // after updating the model. Deletes the current rallies first.
            if AppSettings.shared.enableDebugFeatures {
                BSCButton(title: "Reprocess Video", icon: "arrow.clockwise", style: .secondary, size: .medium) {
                    showReprocessConfirm = true
                }
                .confirmationDialog("Reprocess this video?", isPresented: $showReprocessConfirm, titleVisibility: .visible) {
                    Button("Delete rallies & reprocess", role: .destructive) { viewModel.reprocess() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes the current rallies and runs detection again on the full video.")
                }
            }
        }
    }
}

// MARK: - Toolbar
private extension ProcessVideoView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !viewModel.isProcessing {
                Button("Cancel") {
                    viewModel.cancelProcessing()
                    dismiss()
                }
                .foregroundColor(.bscTextSecondary)
            }
        }
    }
}

// MARK: - Processing Icon View
private struct ProcessingIconView: View {
    let isProcessing: Bool
    let isComplete: Bool

    @State private var isAnimating = false
    @State private var pulseScale: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Outer glow ring
            if isProcessing {
                Circle()
                    .stroke(
                        LinearGradient.bscPrimaryGradient,
                        lineWidth: 3
                    )
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(isAnimating ? .bscSpin : .bscStandard, value: isAnimating)
            }

            // Pulse circle
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.bscBlue.opacity(0.3), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .scaleEffect(pulseScale)

            // Icon background
            Circle()
                .fill(Color.bscSurfaceGlass)
                .frame(width: 80, height: 80)
                .overlay(
                    Circle()
                        .stroke(
                            isComplete ? AnyShapeStyle(Color.bscSuccessText) : AnyShapeStyle(LinearGradient.bscPrimaryGradient),
                            lineWidth: 2
                        )
                )

            // Brain icon
            Image(systemName: isComplete ? "checkmark" : "brain.head.profile")
                .bscFont(size: 36, weight: .medium)
                .foregroundStyle(isComplete ? AnyShapeStyle(Color.bscSuccessText) : AnyShapeStyle(LinearGradient.bscPrimaryGradient))
                .offset(y: isProcessing && !isComplete ? (isAnimating ? -4 : 0) : 0)
        }
        .onAppear {
            if isProcessing && !reduceMotion {
                isAnimating = true
                withAnimation(.bscPulse) {
                    pulseScale = 1.1
                }
            }
        }
        .onChange(of: isProcessing) { _, newValue in
            if newValue && !reduceMotion {
                isAnimating = true
                withAnimation(.bscPulse) {
                    pulseScale = 1.1
                }
            } else {
                isAnimating = false
                withAnimation(.bscBounce) {
                    pulseScale = 1.0
                }
            }
        }
    }
}

// MARK: - Preview
#Preview("ProcessVideoView - Ready") {
    NavigationStack {
        ProcessVideoView(
            videoURL: URL(fileURLWithPath: "/test.mp4"),
            mediaStore: MediaStore(),
            onComplete: {}
        )
    }
}
