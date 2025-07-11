//
//  SavedVideosView.swift
//  BumpSetCut
//
//  View to display all saved videos
//

import SwiftUI
import AVKit

struct SavedVideosView: View {
    @StateObject private var storageManager = VideoStorageManager.shared
    @State private var selectedVideo: SavedVideo?
    @State private var showingDeleteConfirmation = false
    @State private var videoToDelete: SavedVideo?
    
    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                if storageManager.savedVideos.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No saved videos yet")
                            .font(.title2)
                            .foregroundColor(.gray)
                        
                        Text("Record your first game!")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 100)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(storageManager.savedVideos) { video in
                            VideoThumbnailView(video: video)
                                .onTapGesture {
                                    selectedVideo = video
                                }
                                .contextMenu {
                                    Button {
                                        videoToDelete = video
                                        showingDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    
                                    Button {
                                        Task {
                                            await storageManager.exportToPhotoLibrary(video)
                                        }
                                    } label: {
                                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Saved Games")
            .fullScreenCover(item: $selectedVideo) { video in
                VideoPlayerView(video: video)
            }
            .confirmationDialog(
                "Delete Video?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let video = videoToDelete {
                        storageManager.deleteVideo(video)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone.")
            }
        }
    }
}

// Thumbnail view for grid
struct VideoThumbnailView: View {
    let video: SavedVideo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                if let thumbnailURL = video.thumbnailURL,
                   let uiImage = UIImage(contentsOfFile: thumbnailURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 120)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 120)
                        .overlay(
                            Image(systemName: "video.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.gray)
                        )
                }
                
                // Play button overlay
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .shadow(radius: 2)
            }
            
            // Date
            Text(video.formattedDate)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

// Full screen video player
struct VideoPlayerView: View {
    let video: SavedVideo
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        // Play video automatically
                        player.play()
                    }
            } else {
                Color.black
                    .ignoresSafeArea()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white, .gray.opacity(0.7))
                    }
                    .padding()
                    
                    Spacer()
                }
                
                Spacer()
            }
        }
        .background(Color.black)
        .onAppear {
            player = AVPlayer(url: video.videoURL)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
