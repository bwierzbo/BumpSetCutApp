import SwiftUI
import PhotosUI

// MARK: - Unprocessed Video Picker Sheet
struct UnprocessedVideoPickerSheet: View {
    let mediaStore: MediaStore
    let viewModel: HomeViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showingImportPicker = false
    @State private var selectedImportItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importedVideo: ImportedVideo?
    @State private var importFailureToast: BSCToastMessage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BSCSpacing.lg) {
                        // Import & Process button — always visible at top
                        importAndProcessButton

                        if viewModel.unprocessedVideos.isEmpty && !isImporting {
                            BSCEmptyState.allCaughtUp()
                        } else if !viewModel.unprocessedVideos.isEmpty {
                            // Divider between import and existing videos
                            HStack {
                                Rectangle()
                                    .fill(Color.bscSurfaceBorder)
                                    .frame(height: 1)
                                Text("or select an existing video")
                                    .bscFont(size: 12, weight: .medium)
                                    .foregroundColor(.bscTextSecondary)
                                Rectangle()
                                    .fill(Color.bscSurfaceBorder)
                                    .frame(height: 1)
                            }

                            LazyVStack(spacing: BSCSpacing.sm) {
                                ForEach(viewModel.unprocessedVideos, id: \.id) { video in
                                    NavigationLink(destination: processVideoDestination(for: video)) {
                                        videoRow(video)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(BSCSpacing.lg)
                }

                if isImporting {
                    // TODO(design): modal scrim token
                    Color.bscMediaScrim.ignoresSafeArea()
                    VStack(spacing: BSCSpacing.md) {
                        ProgressView()
                            .tint(.bscPrimary)
                            .scaleEffect(1.2)
                        Text("Importing video...")
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscTextPrimary)
                    }
                    .padding(BSCSpacing.xl)
                    .background(Color.bscBackgroundElevated)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
                }
            }
            .navigationTitle("Process Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.bscTextSecondary)
                }
            }
            .photosPicker(
                isPresented: $showingImportPicker,
                selection: $selectedImportItems,
                maxSelectionCount: 1,
                matching: .videos,
                preferredItemEncoding: .current, // deliver original bytes; avoid slow re-encode on import
                photoLibrary: .shared() // items carry a PhotoKit identifier → background-capable iCloud fetch
            )
            .onChange(of: selectedImportItems) { _, items in
                guard let item = items.first else { return }
                selectedImportItems.removeAll()
                Task { await importAndNavigate(item: item) }
            }
            .navigationDestination(item: $importedVideo) { video in
                ProcessVideoView(
                    videoURL: video.url,
                    mediaStore: mediaStore,
                    // Keep the results summary on screen after completion —
                    // the user dismisses it (or taps View Rallies) themselves.
                    onComplete: {}
                )
            }
            .bscToast($importFailureToast)
            .onAppear {
                viewModel.loadUnprocessedVideos()
            }
            .onChange(of: mediaStore.contentVersion) { _, _ in
                viewModel.loadUnprocessedVideos()
            }
        }
    }

    // MARK: - Import & Process

    private var importAndProcessButton: some View {
        Button {
            showingImportPicker = true
        } label: {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "square.and.arrow.down.fill")
                    .bscFont(size: 20, weight: .semibold)

                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text("Import New Video")
                        .bscFont(size: 16, weight: .bold)
                    Text("Add from Photos and process immediately")
                        .bscFont(size: 12)
                        .opacity(0.8)
                }

                Spacer()

                Image(systemName: "chevron.forward")
                    .bscFont(size: 14, weight: .semibold)
            }
            .foregroundColor(.bscOnPrimary)
            .padding(.vertical, BSCSpacing.md)
            .padding(.horizontal, BSCSpacing.lg)
            .background(LinearGradient.bscPrimaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
            .bscShadow(BSCShadow.glowPrimary)
        }
        .buttonStyle(MainCTAButtonStyle())
        .disabled(isImporting)
    }

    private func importAndNavigate(item: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false }

        do {
            guard let videoData = try await item.loadTransferable(type: VideoTransferable.self) else { return }
            // iOS purges the Photos temp URL, so the library takes its own copy.
            let imported = try mediaStore.importVideo(
                from: videoData.url, toFolder: LibraryType.saved.rootPath, customName: nil
            )
            importedVideo = ImportedVideo(url: mediaStore.fileURL(for: imported))
        } catch {
            importFailureToast = BSCToastMessage(text: "Couldn't import that video. Try again.", style: .error)
        }
    }

    private func processVideoDestination(for video: VideoMetadata) -> some View {
        let videoURL = mediaStore.getVideoURL(for: video)
        return ProcessVideoView(
            videoURL: videoURL,
            mediaStore: mediaStore,
            // Keep the results summary on screen after completion.
            onComplete: {}
        )
    }

    private func videoRow(_ video: VideoMetadata) -> some View {
        HStack(spacing: BSCSpacing.md) {
            // Video thumbnail
            VideoThumbnailView(
                thumbnailURL: nil,
                videoURL: mediaStore.getVideoURL(for: video)
            )
            .frame(width: 80, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                Text(video.displayName)
                    .bscFont(size: 15, weight: .medium)
                    .foregroundColor(.bscTextPrimary)
                    .lineLimit(1)

                HStack(spacing: BSCSpacing.sm) {
                    if let duration = video.duration {
                        Text(verbatim: duration.formattedClock())
                            .bscFont(size: 12)
                            .foregroundColor(.bscTextSecondary)

                        Text(verbatim: "\u{2022}")
                            .foregroundColor(.bscTextTertiary)
                    }

                    Text(verbatim: StorageChecker.formatBytes(video.fileSize))
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.forward")
                .bscFont(size: 14, weight: .medium)
                .foregroundColor(.bscTextSecondary)
        }
        .padding(BSCSpacing.md)
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(Color.bscSurfaceBorder, lineWidth: 1)
        )
    }
}

// MARK: - Imported Video (Identifiable wrapper for navigation)
struct ImportedVideo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}
