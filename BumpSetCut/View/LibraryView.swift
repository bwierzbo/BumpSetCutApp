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
        ScrollView {
            VStack(spacing: 24) {
                createHeader()
                createMediaList()
            }
            .padding()
        }
        .navigationTitle("Saved Games")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: - Header
private extension LibraryView {
    func createHeader() -> some View {
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
