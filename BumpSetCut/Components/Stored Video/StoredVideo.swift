//
//  StoredVideo.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/31/25.
//

import SwiftUI
import AVKit

struct StoredVideo: View {
    let videoURL: URL
    let onDelete: () -> ()
    let onRefresh: () -> ()
    @State private var showingVideoPlayer = false
    @State private var showingDeleteConfirmation = false
    @State private var showingProcessVideo = false
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 16) {
            createThumbnail()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            createText()
            Spacer()
            createProcessButton()
            createDeleteButton()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: presentVideoPlayer)
        .onAppear(perform: generateThumbnail)
        .sheet(isPresented: $showingVideoPlayer, content: createVideoPlayerSheet)
        .sheet(isPresented: $showingProcessVideo, content: createProcessVideoSheet)
        .alert("Delete Video", isPresented: $showingDeleteConfirmation, actions: createDeleteAlert)
    }
}

// MARK: - Thumbnail
private extension StoredVideo {
    func createThumbnail() -> some View {
        Group {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.gray)
            }
        }
    }
    
    func generateThumbnail() {
        Task {
            let thumbnailImage = await createVideoThumbnail(from: videoURL)
            await MainActor.run {
                thumbnail = thumbnailImage
            }
        }
    }
    
    func createVideoThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 200, height: 200)
        
        do {
            let cgImage = try await imageGenerator.image(at: .zero).image
            return UIImage(cgImage: cgImage)
        } catch {
            print("Failed to generate thumbnail: \(error)")
            return nil
        }
    }
}

// MARK: - Text Content
private extension StoredVideo {
    func createText() -> some View {
        VStack(alignment: .leading, spacing: -2) {
            createTitleText()
            createDateText()
            Spacer()
            createExtensionText()
        }.frame(height: 72)
    }

    func createTitleText() -> some View {
        Text(videoURL.deletingPathExtension().lastPathComponent)
            .font(.headline)
            .foregroundColor(.primary)
    }

    func createDateText() -> some View {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
           let modifiedDate = attrs[.modificationDate] as? Date {
            return Text(modifiedDate.formatted(date: .long, time: .shortened))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            return Text("Unknown date")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    func createExtensionText() -> some View {
        Text(videoURL.pathExtension.uppercased())
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

// MARK: - Delete Button
private extension StoredVideo {
    func createProcessButton() -> some View {
        Button(action: presentProcessVideo) {
            Image(systemName: "brain.head.profile.fill")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundColor(.blue)
                .frame(width: 40, height: 30)
        }
        .onTapGesture {} // Prevents tap from propagating to parent
    }
    
    func createDeleteButton() -> some View {
        Button(action: presentDeleteConfirmation) {
            Image(systemName: "trash.fill")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundColor(.red)
                .frame(width: 40, height: 30)
        }
        .onTapGesture {} // Prevents tap from propagating to parent
    }
    
    func presentDeleteConfirmation() {
        showingDeleteConfirmation = true
    }
    
    func presentProcessVideo() {
        showingProcessVideo = true
    }
    
    func createDeleteAlert() -> some View {
        Group {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Video Player
private extension StoredVideo {
    func presentVideoPlayer() {
        showingVideoPlayer = true
    }
    
    func createVideoPlayerSheet() -> some View {
        VideoPlayerView(videoURL: videoURL)
    }
    
    func createProcessVideoSheet() -> some View {
        ProcessVideoView(videoURL: videoURL, onComplete: onRefresh)
    }
}
