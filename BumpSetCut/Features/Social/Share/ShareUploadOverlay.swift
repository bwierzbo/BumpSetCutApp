//
//  ShareUploadOverlay.swift
//  BumpSetCut
//
//  Full-screen blocking modal shown while a post uploads, with per-state content.
//

import SwiftUI

struct ShareUploadOverlay: View {
    let viewModel: ShareRallyViewModel

    var body: some View {
        ZStack {
            Color.bscMediaScrim
                .ignoresSafeArea()
                .onTapGesture {
                    // Only a failed upload can be dismissed (back to editing) by tapping out.
                    if case .failed = viewModel.state { viewModel.cancel() }
                }

            VStack(spacing: BSCSpacing.md) {
                stateView
            }
            .frame(maxWidth: BSCContentWidth.compact)
            .padding(BSCSpacing.xl)
            .bscSurfaceChrome(cornerRadius: BSCRadius.xl, shadow: BSCShadow.xl)
            .padding(BSCSpacing.xl)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var stateView: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .uploading(let progress):
            VStack(spacing: BSCSpacing.sm) {
                ProgressView(value: progress)
                    .tint(.bscPrimary)
                (viewModel.postAllSaved && viewModel.postCount > 1
                    ? Text("Uploading \(viewModel.postCount) rallies... \(progress.formattedPercent())", comment: "Post upload progress: rally count, percentage")
                    : Text("Uploading... \(progress.formattedPercent())", comment: "Post upload progress percentage"))
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }

        case .processing:
            HStack(spacing: BSCSpacing.sm) {
                ProgressView()
                    .tint(.bscPrimary)
                Text("Processing...")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }

        case .complete:
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .bscFont(size: 36)
                    .foregroundColor(.bscSuccessText)
                Text("Shared successfully!")
                    .bscFont(size: 15, weight: .medium)
                    .foregroundColor(.bscTextPrimary)
                Text("Opening in feed...")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
            }

        case .failed(let message):
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .bscFont(size: 36)
                    .foregroundColor(.bscError)
                Text(message)
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.retry() }
                    .bscFont(size: 15, weight: .medium)
                    .foregroundColor(.bscPrimaryText)
            }
        }
    }
}
