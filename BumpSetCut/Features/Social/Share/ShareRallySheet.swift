//
//  ShareRallySheet.swift
//  BumpSetCut
//
//  Sheet for sharing a local rally as a highlight to the social feed.
//

import SwiftUI
import AVKit

struct ShareRallySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ShareRallyViewModel

    init(videoURL: URL, rallyIndex: Int, videoId: UUID, metadata: RallyHighlightMetadata) {
        _viewModel = State(initialValue: ShareRallyViewModel(
            videoURL: videoURL,
            rallyIndex: rallyIndex,
            videoId: videoId,
            metadata: metadata
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.lg) {
                        // Video preview
                        videoPreview

                        // Caption
                        captionField

                        // Tags
                        tagSection

                        // Rally info
                        rallyInfo

                        // Upload state
                        uploadStateView
                    }
                    .padding(BSCSpacing.lg)
                }
            }
            .navigationTitle("Share Rally")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    shareButton
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Video Preview

    private var videoPreview: some View {
        VideoPlayer(player: AVPlayer(url: viewModel.videoURL))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
    }

    // MARK: - Caption

    private var captionField: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            Text("Caption")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.bscTextSecondary)

            TextField("Describe this rally...", text: $viewModel.caption, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(.bscTextPrimary)
                .lineLimit(3...6)
                .padding(BSCSpacing.sm)
                .background(Color.bscSurfaceGlass)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        }
    }

    // MARK: - Tags

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            Text("Tags")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.bscTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BSCSpacing.xs) {
                    ForEach(["volleyball", "rally", "beach", "indoor", "spike", "dig", "set"], id: \.self) { tag in
                        let isSelected = viewModel.tags.contains(tag)
                        Button {
                            if isSelected {
                                viewModel.tags.removeAll { $0 == tag }
                            } else {
                                viewModel.tags.append(tag)
                            }
                        } label: {
                            Text("#\(tag)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(isSelected ? .white : .bscTextSecondary)
                                .padding(.horizontal, BSCSpacing.sm)
                                .padding(.vertical, BSCSpacing.xs)
                                .background(isSelected ? Color.bscOrange : Color.bscSurfaceGlass)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Rally Info

    private var rallyInfo: some View {
        HStack(spacing: BSCSpacing.lg) {
            Label("\(String(format: "%.1f", viewModel.metadata.duration))s", systemImage: "timer")
            Label("\(Int(viewModel.metadata.quality * 100))% quality", systemImage: "sparkles")
            Label("\(viewModel.metadata.detectionCount) detections", systemImage: "eye")
        }
        .font(.system(size: 12))
        .foregroundColor(.bscTextTertiary)
    }

    // MARK: - Upload State

    @ViewBuilder
    private var uploadStateView: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .uploading(let progress):
            VStack(spacing: BSCSpacing.sm) {
                ProgressView(value: progress)
                    .tint(.bscOrange)
                Text("Uploading... \(Int(progress * 100))%")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

        case .processing:
            HStack(spacing: BSCSpacing.sm) {
                ProgressView()
                    .tint(.bscOrange)
                Text("Processing...")
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
            }

        case .complete:
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)
                Text("Shared successfully!")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscTextPrimary)
                Button("Done") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscOrange)
            }

        case .failed(let message):
            VStack(spacing: BSCSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.red)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.retry() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.bscOrange)
            }
        }
    }

    // MARK: - Share Button

    private var shareButton: some View {
        Button("Share") {
            viewModel.upload()
        }
        .disabled(viewModel.state != .idle)
        .fontWeight(.semibold)
    }
}
