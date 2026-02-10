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
    @State private var didFail = false

    var body: some View {
        Group {
            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        fallbackView
                    default:
                        Color.bscSurfaceGlass
                    }
                }
            } else if let generatedImage {
                Image(uiImage: generatedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fallbackView
            }
        }
        .task(id: videoURL) {
            await generateThumbnail()
        }
    }

    private var fallbackView: some View {
        ZStack {
            Color.bscSurfaceGlass
            Image(systemName: "play.fill")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func generateThumbnail() async {
        guard thumbnailURL == nil, generatedImage == nil, let videoURL else { return }

        // Use cache first
        if let cached = ThumbnailCache.shared.get(for: videoURL) {
            generatedImage = cached
            return
        }

        guard !didFail else { return }

        let asset = AVURLAsset(url: videoURL, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "video/mp4",
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        do {
            let cgImage = try await withThrowingTaskGroup(of: CGImage.self) { group in
                group.addTask {
                    try await generator.image(at: .zero).image
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            let image = UIImage(cgImage: cgImage)
            ThumbnailCache.shared.set(image, for: videoURL)
            generatedImage = image
        } catch is CancellationError {
            // Task cancelled by scroll or timeout — don't mark as failed so it retries
        } catch {
            didFail = true
        }
    }
}

// MARK: - Thumbnail Cache

/// In-memory LRU cache for generated video thumbnails.
private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 100
    }

    func get(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }
}
