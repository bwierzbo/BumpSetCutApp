//
//  ProcessingSetupFlowView.swift
//  BumpSetCut
//
//  The pages between "Start AI Processing" and the run: trim the video, say where the camera was, mark the
//  court, mark the net. One page each, in that order (the court and net are marked on the video as trimmed),
//  each with the same heading and each with a Skip.
//

import SwiftUI

/// Where a page is in the run of pages.
struct SetupProgress: Equatable {
    let number: Int
    let count: Int
}

/// A setup page's heading: its name, and which page of how many it is.
struct SetupStepTitle: View {
    let title: LocalizedStringResource
    let progress: SetupProgress
    /// Over the video's dark surface rather than the app's background.
    var onMedia = false

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .bscFont(size: 17, weight: .semibold)
                .foregroundColor(onMedia ? .bscOnMedia : .bscTextPrimary)
            Text("Step \(progress.number) of \(progress.count)")
                .bscFont(size: 12)
                .foregroundColor(onMedia ? .bscOnMedia.opacity(0.7) : .bscTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(AccessibilityID.Process.setupProgress)
    }
}

struct ProcessingSetupFlowView: View {
    let viewModel: ProcessVideoViewModel
    /// Who confirms a court or net marked here.
    let reviewer: String

    var body: some View {
        if let setup = viewModel.setup {
            page(setup)
                .id(setup.step)
                .transition(.opacity)
                .animation(.bscSnappy, value: setup.step)
        }
    }

    @ViewBuilder
    private func page(_ setup: ProcessVideoViewModel.Setup) -> some View {
        switch setup.step {
        case .trim:
            PreTrimView(videoURL: viewModel.videoURL, progress: setup.progress,
                        onSkip: viewModel.advanceSetup,
                        onTrimmed: viewModel.useTrimmedVideo(at:),
                        onCancel: viewModel.cancelSetup)
        case .camera:
            CameraSetupPickerView(initial: viewModel.initialCameraSetup, progress: setup.progress,
                                  onContinue: viewModel.confirmCameraSetup,
                                  onSkip: viewModel.advanceSetup,
                                  onCancel: viewModel.cancelSetup)
        case .court, .net:
            if let videoId = viewModel.currentVideoMetadata?.id {
                CalibrationEditorView(videoId: videoId, videoURL: viewModel.videoURL, reviewer: reviewer,
                                      step: .init(target: setup.step == .court ? .court : .net, progress: setup.progress,
                                                  onDone: viewModel.advanceSetup, onCancel: viewModel.cancelSetup))
            }
        }
    }
}
