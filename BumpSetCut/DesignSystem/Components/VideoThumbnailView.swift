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
    var contentMode: ContentMode = .fill
    /// Where in `videoURL` to take the still from. Rallies are slices of one
    /// source file, so each needs its own moment or every card looks alike.
    var time: CMTime = .zero

    @State private var generatedImage: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                            .transition(.opacity)
                    case .failure:
                        fallbackView
                    default:
                        Color.bscSurfaceGlass
                    }
                }
            } else if let generatedImage {
                Image(uiImage: generatedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                fallbackView
                    .transition(.opacity)
            }
        }
        // Fade the generated/loaded thumbnail in over the placeholder instead of snapping.
        .animation(.bscStandard, value: generatedImage != nil)
        .task(id: videoURL) {
            await generateThumbnail()
        }
    }

    private var fallbackView: some View {
        ZStack {
            Color.bscSurfaceGlass
            Circle()
                .fill(Color.bscMediaScrim)
                .frame(width: 36, height: 36)
            Image(systemName: "play.fill")
                .bscFont(size: 20)
                .foregroundColor(Color.bscOnMedia.opacity(0.6))
        }
    }

    private func generateThumbnail() async {
        guard thumbnailURL == nil, generatedImage == nil, let videoURL else { return }

        if let cached = ThumbnailService.shared.cachedStill(url: videoURL, at: time) {
            generatedImage = cached
            return
        }

        guard !didFail else { return }

        do {
            generatedImage = try await ThumbnailService.shared.still(url: videoURL, at: time)
        } catch is CancellationError {
            // Task cancelled by scroll or timeout — don't mark as failed so it retries
        } catch {
            didFail = true
        }
    }
}
