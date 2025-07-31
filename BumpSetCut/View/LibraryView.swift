//
//  LibraryView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import SwiftUI

struct LibraryView: View {
    @State private var savedVideos: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            createScrollableView()
        }
        .padding(.horizontal, 20)
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: loadSavedVideos)
    }
}

// MARK: - Scrollable View
private extension LibraryView {
    func createScrollableView() -> some View {
        ScrollView {
            createMediaView()
        }
        .navigationTitle("Saved Games")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: - Media View
private extension LibraryView {
    func createMediaView() -> some View {
        VStack(spacing: 24) {
            createMediaHeader()
            createMediaList()
        }
        .padding()
    }
}

// MARK: - Header
private extension LibraryView {
    func createMediaHeader() -> some View {
        Text("Your Captured Games")
            .font(.title)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Media List
private extension LibraryView {
    func createMediaList() -> some View {
        VStack(spacing: 16) {
            if savedVideos.isEmpty {
                createEmptyState()
            } else {
                ForEach(savedVideos, id: \.self) { url in
                    StoredVideo(
                        videoURL: url,
                        onDelete: {
                            deleteVideo(url)
                        }
                    )
                }
            }
        }
    }

    func createEmptyState() -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("No games saved yet.")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
    }

    func loadSavedVideos() {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first

        guard let docsURL = docs else { return }

        if let files = try? fileManager.contentsOfDirectory(at: docsURL, includingPropertiesForKeys: nil) {
            savedVideos = files.filter { $0.pathExtension == "mov" || $0.pathExtension == "mp4" }
        }
    }

    func deleteVideo(_ url: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: url)
            savedVideos.removeAll { $0 == url }
        } catch {
            print("Failed to delete video: \(error)")
        }
    }
}
