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

    var body: some View {
        HStack(spacing: 16) {
            createThumbnail()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            createText()
            Spacer()
            createDeleteButton()
        }
    }
}

// MARK: - Thumbnail
private extension StoredVideo {
    func createThumbnail() -> some View {
        Image(systemName: "video.fill") // placeholder icon
            .resizable()
            .scaledToFit()
            .foregroundColor(.gray)
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
    func createDeleteButton() -> some View {
        Button(action: onDelete) {
            Image(systemName: "trash.fill")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundColor(.red)
                .frame(width: 40, height: 30)
        }
    }
}
