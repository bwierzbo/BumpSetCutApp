//
//  ContentView.swift
//  BumpSetCut
//
//  Updated with saved videos access
//

import SwiftUI

struct ContentView: View {
    @State private var showCamera = false
    @State private var showSavedVideos = false
    @StateObject private var storageManager = VideoStorageManager.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 40) {
                Text("🏐 Beach Volleyball MVP")
                    .font(.largeTitle)
                    .bold()

                VStack(spacing: 20) {
                    Button(action: {
                        showCamera = true
                    }) {
                        HStack {
                            Image(systemName: "video.circle.fill")
                                .font(.title2)
                            Text("Start New Game")
                                .font(.title2)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button(action: {
                        showSavedVideos = true
                    }) {
                        HStack {
                            Image(systemName: "play.rectangle.fill")
                                .font(.title2)
                            Text("Saved Games")
                                .font(.title2)
                            if !storageManager.savedVideos.isEmpty {
                                Text("(\(storageManager.savedVideos.count))")
                                    .font(.title3)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                Spacer()
                
                // Quick stats
                if !storageManager.savedVideos.isEmpty {
                    VStack(spacing: 8) {
                        Text("Total Games Recorded")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(storageManager.savedVideos.count)")
                            .font(.largeTitle)
                            .bold()
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }
            }
            .padding()
            .navigationTitle("Home")
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showCamera) {
                CameraView()
            }
            .sheet(isPresented: $showSavedVideos) {
                SavedVideosView()
            }
        }
    }
}

#Preview {
    ContentView()
}
