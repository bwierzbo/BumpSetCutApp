//
//  VideoThumbnailView.swift
//  BumpSetCut
//
//  Displays a thumbnail for a video URL, generating one from the first frame if needed.
//

import SwiftUI
import AVFoundation

struct VideoThumbnailView: View {
    let thumbnailURL: URL?
    let videoURL: URL?

    @State private var generatedImage: UIImage?
    @State private var didAttemptGeneration = false

    var body: some View {
        Group {
            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.bscSurfaceGlass
                }
            } else if let generatedImage {
                Image(uiImage: generatedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.bscSurfaceGlass
            }
        }
        .task {
            guard thumbnailURL == nil, !didAttemptGeneration, let videoURL else { return }
            didAttemptGeneration = true
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            do {
                let cgImage = try await generator.image(at: .zero).image
                generatedImage = UIImage(cgImage: cgImage)
            } catch {
                // Leave as placeholder
            }
        }
    }
}
