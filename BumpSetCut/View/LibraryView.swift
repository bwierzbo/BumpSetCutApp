//
//  LibraryView.swift
//  BumpSetCut
//
//  Created by Benjamin Wierzbanowski on 7/30/25.
//

import SwiftUI

struct LibraryView: View {
    @Bindable var mediaStore: MediaStore

    var body: some View {
        VStack(spacing: 0) {
            createScrollableView()
        }
        .padding(.horizontal, 20)
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
// SCROLLABLE VIEW
private extension LibraryView {
    func createScrollableView() -> some View {
        ScrollView {
            createMediaView()
        }
        .navigationTitle("Saved Games")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

// MEDIA VIEW
private extension LibraryView {
    func createMediaView() -> some View {
        VStack(spacing: 24) {
            createMediaHeader()
            createMediaList()
        }
        .padding()
    }
}

// MEDIA HEADER
private extension LibraryView {
    func createMediaHeader() -> some View {
        Text("Your Captured Games")
            .font(.title)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MEDIA LIST
private extension LibraryView {
    func createMediaList() -> some View {
        VStack(spacing: 16) {
            if mediaStore.uploadedMedia.isEmpty {
                createEmptyState()
            } else {
                ForEach(mediaStore.uploadedMedia, id: \.id) { item in
                    UploadedMediaItem(
                        image: item.image,
                        title: item.title,
                        date: item.date,
                        duration: item.duration,
                        onDeleteButtonTap: {
                            mediaStore.deleteMedia(item)
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
