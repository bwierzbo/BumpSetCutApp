//
//  ProcessedLibraryView.swift
//  BumpSetCut
//
//  Flat list view for processed videos with direct rally viewer navigation
//

import SwiftUI

struct ProcessedLibraryView: View {
    let mediaStore: MediaStore

    @State private var processedVideos: [VideoMetadata] = []
    @State private var selectedVideo: VideoMetadata?
    @State private var hasAppeared = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            if processedVideos.isEmpty {
                emptyState
            } else {
                videoList
            }
        }
        .navigationTitle("Processed Games")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            loadProcessedVideos()
            withAnimation(.bscSpring.delay(0.1)) {
                hasAppeared = true
            }
        }
        .onChange(of: mediaStore.contentVersion) { _, _ in
            loadProcessedVideos()
        }
        .fullScreenCover(item: $selectedVideo) { processedVideo in
            // Videos in this library have processing metadata - show rally viewer
            RallyPlayerView(videoMetadata: processedVideo)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: BSCSpacing.lg) {
            Image(systemName: "film.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.bscTextTertiary)

            VStack(spacing: BSCSpacing.sm) {
                Text("No Processed Videos")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.bscTextPrimary)

                Text("Process a video from your Saved Games\nto see rallies here")
                    .font(.system(size: 14))
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }

            NavigationLink {
                LibraryView(mediaStore: mediaStore, libraryType: .saved)
            } label: {
                Text("Go to Saved Games")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.bscOrange)
            }
            .padding(.top, BSCSpacing.md)
        }
        .padding(BSCSpacing.xl)
    }

    // MARK: - Video List

    private var videoList: some View {
        ScrollView {
            LazyVStack(spacing: BSCSpacing.md) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                        Text("\(processedVideos.count) Processed Video\(processedVideos.count == 1 ? "" : "s")")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.bscTextSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.top, BSCSpacing.md)
                .opacity(hasAppeared ? 1 : 0)

                // Video cards
                ForEach(Array(processedVideos.enumerated()), id: \.element.id) { index, video in
                    ProcessedVideoCard(
                        video: video,
                        mediaStore: mediaStore,
                        onTap: { selectedVideo = video },
                        onDelete: { deleteVideo(video) }
                    )
                    .padding(.horizontal, BSCSpacing.lg)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(.bscSpring.delay(Double(index) * 0.05), value: hasAppeared)
                }
            }
            .padding(.bottom, BSCSpacing.xl)
        }
        .refreshable {
            loadProcessedVideos()
        }
    }

    // MARK: - Data Loading

    private func loadProcessedVideos() {
        // Get all videos that have processing metadata (rally detection completed)
        processedVideos = mediaStore.getAllVideos()
            .filter { $0.hasProcessingMetadata }
            .sorted { $0.createdDate > $1.createdDate }
    }

    private func deleteVideo(_ video: VideoMetadata) {
        _ = mediaStore.deleteVideo(fileName: video.fileName)
        loadProcessedVideos()
    }
}

// MARK: - Processed Video Card

struct ProcessedVideoCard: View {
    let video: VideoMetadata
    let mediaStore: MediaStore
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?
    @State private var showingDeleteConfirmation = false
    @State private var rallyCount: Int?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: BSCSpacing.md) {
                // Thumbnail
                ZStack {
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                            .fill(Color.bscSurfaceGlass)
                            .frame(width: 100, height: 70)
                            .overlay {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 24))
                                    .foregroundColor(.bscTextTertiary)
                            }
                    }

                    // Play overlay
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                }

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.bscTextPrimary)
                        .lineLimit(2)

                    HStack(spacing: BSCSpacing.sm) {
                        // Rally count badge
                        if let count = rallyCount {
                            HStack(spacing: 4) {
                                Image(systemName: "film.stack.fill")
                                    .font(.system(size: 10))
                                Text("\(count) \(count == 1 ? "Rally" : "Rallies")")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.bscTeal)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.bscTeal.opacity(0.15))
                            .clipShape(Capsule())
                        }

                        // Date
                        Text(formatDate(video.createdDate))
                            .font(.system(size: 12))
                            .foregroundColor(.bscTextTertiary)
                    }
                }

                Spacer()

                // Arrow
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.bscTextTertiary)
            }
            .padding(BSCSpacing.md)
            .background(Color.bscSurfaceGlass)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(Color.bscSurfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete Video?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this processed video.")
        }
        .task {
            await loadThumbnail()
            await loadRallyCount()
        }
    }

    private func loadThumbnail() async {
        let videoURL = mediaStore.getVideoURL(for: video)
        thumbnail = await ThumbnailGenerator.shared.generateThumbnail(for: videoURL)
    }

    private func loadRallyCount() async {
        guard video.hasMetadata else { return }

        // Load metadata to get rally count
        let metadataStore = MetadataStore()
        do {
            let metadata = try metadataStore.loadMetadata(for: video.id)
            rallyCount = metadata.rallySegments.count
        } catch {
            // If metadata can't be loaded, don't show badge
            rallyCount = nil
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Thumbnail Generator

actor ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    private var cache: [URL: UIImage] = [:]

    func generateThumbnail(for url: URL) async -> UIImage? {
        if let cached = cache[url] {
            return cached
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)

        let image: UIImage? = await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, error in
                if let cgImage = cgImage {
                    let image = UIImage(cgImage: cgImage)
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }

        if let image = image {
            cache[url] = image
        }
        return image
    }
}

import AVFoundation

// MARK: - Preview

#Preview {
    NavigationStack {
        ProcessedLibraryView(mediaStore: MediaStore())
    }
}
