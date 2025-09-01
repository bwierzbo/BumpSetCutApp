//
//  VideoCardView.swift
//  BumpSetCut
//
//  Created by Claude on 9/1/25.
//

import SwiftUI
import AVKit

struct VideoCardView: View {
    let video: VideoMetadata
    let onDelete: () -> Void
    let onRefresh: () -> Void
    
    @State private var showingVideoPlayer = false
    @State private var showingProcessVideo = false
    @State private var showingDeleteConfirmation = false
    @State private var thumbnail: UIImage?
    
    var body: some View {
        VStack(spacing: 8) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .aspectRatio(16/9, contentMode: .fit)
                
                Group {
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "video.fill")
                            .font(.title)
                            .foregroundColor(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Play overlay
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundColor(.white)
                    )
            }
            .onTapGesture {
                showingVideoPlayer = true
            }
            
            // Video info
            VStack(alignment: .leading, spacing: 4) {
                Text(video.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                
                HStack {
                    if let duration = video.duration {
                        Text(formatDuration(duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(formatFileSize(video.fileSize))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                showingProcessVideo = true
            } label: {
                Label("Process Video", systemImage: "gearshape")
            }
            
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onAppear {
            generateThumbnail()
        }
        .sheet(isPresented: $showingVideoPlayer) {
            VideoPlayer(player: AVPlayer(url: video.originalURL))
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showingProcessVideo) {
            ProcessVideoView(videoURL: video.originalURL, onComplete: onRefresh)
        }
        .alert("Delete Video", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("Are you sure you want to delete this video? This action cannot be undone.")
        }
    }
    
    private func generateThumbnail() {
        let asset = AVURLAsset(url: video.originalURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        
        imageGenerator.generateCGImageAsynchronously(for: time) { image, actualTime, error in
            if let image = image {
                DispatchQueue.main.async {
                    self.thumbnail = UIImage(cgImage: image)
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}