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

        // Use cache first
        let cacheKey = ThumbnailCache.key(for: videoURL, at: time)
        if let cached = ThumbnailCache.shared.get(for: cacheKey) {
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
                group.addTask { [time] in
                    try await generator.image(at: time).image
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
            ThumbnailCache.shared.set(image, for: cacheKey)
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

    /// One entry per file *and* moment; the file alone would hand every
    /// rally of a game the first rally's frame.
    static func key(for url: URL, at time: CMTime) -> String {
        time == .zero ? url.absoluteString : "\(url.absoluteString)#\(CMTimeGetSeconds(time))"
    }

    func get(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
