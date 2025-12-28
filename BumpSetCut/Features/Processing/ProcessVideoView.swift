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
    @Environment(\.dismiss) private var dismiss

    init(videoURL: URL, mediaStore: MediaStore, folderPath: String, onComplete: @escaping () -> Void, onShowPlayer: (() -> Void)? = nil) {
        self._viewModel = State(wrappedValue: ProcessVideoViewModel(
            videoURL: videoURL,
            mediaStore: mediaStore,
            folderPath: folderPath,
            onComplete: onComplete,
            onShowPlayer: onShowPlayer
        ))
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                backgroundGradient

                VStack(spacing: BSCSpacing.xxl) {
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

                    Spacer()

                    // Action buttons
                    actionButtons
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(.bscSpring.delay(0.3), value: hasAppeared)
                }
                .padding(BSCSpacing.xl)
            }
            .navigationTitle("AI Processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onDisappear { viewModel.cancelProcessing() }
            .onAppear {
                viewModel.loadCurrentVideoMetadata()
                withAnimation {
                    hasAppeared = true
                }
            }
            .alert("Processing Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
        }
        .preferredColorScheme(.dark)
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
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("AI will analyze your video to remove dead time and keep only active rallies")
                    .font(.system(size: 15))
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
        case .complete:
            completeContent
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
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.bscTextSecondary)
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var completeContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.bscSuccess.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.bscSuccess)
            }

            VStack(spacing: BSCSpacing.xs) {
                Text("Processing Complete!")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Your video has been processed and saved")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var hasMetadataContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.bscBlue.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.bscBlue)
            }

            VStack(spacing: BSCSpacing.xs) {
                Text("Rallies Detected!")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Tap below to view the detected rallies")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var readyContent: some View {
        VStack(spacing: BSCSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.bscBlue.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundColor(.bscBlue)
            }

            VStack(spacing: BSCSpacing.xs) {
                Text("Ready to Process")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Choose a processing mode below")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }

    var alreadyProcessedContent: some View {
        let info = viewModel.statusInfo

        return VStack(spacing: BSCSpacing.xl) {
            ZStack {
                Circle()
                    .fill(info.color.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: info.icon)
                    .font(.system(size: 40))
                    .foregroundColor(info.color)
            }

            VStack(spacing: BSCSpacing.md) {
                Text(info.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text(info.description)
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)

                if let detail = info.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.bscTextTertiary)
                        .padding(.horizontal, BSCSpacing.md)
                        .padding(.vertical, BSCSpacing.xs)
                        .background(Color.bscSurfaceGlass)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(BSCSpacing.xl)
        .bscGlass(cornerRadius: BSCRadius.xl, padding: BSCSpacing.xl)
    }
}

// MARK: - Action Buttons
private extension ProcessVideoView {
    @ViewBuilder
    var actionButtons: some View {
        switch viewModel.processingState {
        case .processing:
            EmptyView()
        case .complete:
            doneButton
        case .hasMetadata:
            viewRalliesButton
        case .alreadyProcessed:
            EmptyView()
        case .ready:
            processingButtons
        }
    }

    var processingButtons: some View {
        VStack(spacing: BSCSpacing.md) {
            // AI Processing - Primary
            BSCButton(title: "Start AI Processing", icon: "brain.head.profile", style: .primary, size: .large) {
                viewModel.startProcessing(isDebugMode: false)
            }

            // Debug Processing - Secondary
            BSCButton(title: "Debug Processing", icon: "ladybug", style: .secondary, size: .medium) {
                viewModel.startProcessing(isDebugMode: true)
            }

            Text("AI Processing removes dead time\nDebug Processing includes analysis overlay")
                .font(.system(size: 12))
                .foregroundColor(.bscTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, BSCSpacing.xs)
        }
    }

    var doneButton: some View {
        BSCButton(title: "Done", icon: "checkmark", style: .primary, size: .large) {
            dismiss()
        }
    }

    var viewRalliesButton: some View {
        BSCButton(title: "View Rallies", icon: "play.fill", style: .primary, size: .large) {
            dismiss()
            viewModel.onComplete()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                viewModel.onShowPlayer?()
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
                    .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isAnimating)
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
                            isComplete ? AnyShapeStyle(Color.bscSuccess) : AnyShapeStyle(LinearGradient.bscPrimaryGradient),
                            lineWidth: 2
                        )
                )

            // Brain icon
            Image(systemName: isComplete ? "checkmark" : "brain.head.profile")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(isComplete ? AnyShapeStyle(Color.bscSuccess) : AnyShapeStyle(LinearGradient.bscPrimaryGradient))
                .offset(y: isProcessing && !isComplete ? (isAnimating ? -4 : 0) : 0)
        }
        .onAppear {
            if isProcessing {
                isAnimating = true
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.1
                }
            }
        }
        .onChange(of: isProcessing) { _, newValue in
            if newValue {
                isAnimating = true
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
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
    ProcessVideoView(
        videoURL: URL(fileURLWithPath: "/test.mp4"),
        mediaStore: MediaStore(),
        folderPath: "",
        onComplete: {},
        onShowPlayer: nil
    )
}
