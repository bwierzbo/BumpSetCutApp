//
//  LibraryView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import SwiftUI
import PhotosUI

struct LibraryView: View {
    @State private var savedVideos: [URL] = []
    @State private var showingPhotoPicker = false
    @State private var selectedVideo: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            createScrollableView()
        }
        .padding(.horizontal, 20)
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: loadSavedVideos)
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedVideo, matching: .videos)
        .onChange(of: selectedVideo) { _, newValue in
            handleVideoSelection(newValue)
        }
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
        .toolbar(content: createToolbar)
    }
}

// MARK: - Toolbar
private extension LibraryView {
    func createToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            createUploadButton()
        }
    }
    
    func createUploadButton() -> some View {
        Button("Upload") {
            showingPhotoPicker = true
        }
        .foregroundColor(.blue)
        .fontWeight(.medium)
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
        HStack {
            Text("Your Captured Games")
                .font(.title)
                .fontWeight(.bold)
            Spacer()
        }
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
}

// MARK: - Video Management
private extension LibraryView {
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

// MARK: - Photo Picker
private extension LibraryView {
    func handleVideoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await saveUploadedVideo(data)
            }
        }
    }
    
    func saveUploadedVideo(_ data: Data) async {
        let fileName = UUID().uuidString + ".mp4"
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsURL.appendingPathComponent(fileName)
        
        do {
            try data.write(to: destinationURL)
            await MainActor.run {
                savedVideos.append(destinationURL)
                selectedVideo = nil
            }
        } catch {
            print("Failed to save uploaded video: \(error)")
        }
    }
}
