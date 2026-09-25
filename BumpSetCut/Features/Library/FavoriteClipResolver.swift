//
//  FavoriteClipResolver.swift
//  BumpSetCut
//
//  Turns favorited videos into clips ready to export or post: the file, the
//  trim window the user set in the favorites feed, and the effective
//  duration. Shared by the favorites grid's reel export and posting.
//

import AVFoundation
import Foundation

/// One favorite resolved for use: file, optional trim window, effective duration.
struct ResolvedFavoriteClip {
    let video: VideoMetadata
    let timeRange: CMTimeRange?
    let duration: Double
}

enum FavoriteClipResolver {

    /// Resolve videos into clips in `createdDate` order, applying each clip's
    /// favorites-feed trim (a single adjustment stored under index 0).
    /// Unreadable or zero-length files are skipped. Main-actor because
    /// `MetadataStore` is.
    @MainActor
    static func resolve(_ videos: [VideoMetadata]) async -> [ResolvedFavoriteClip] {
        let metadataStore = MetadataStore()
        var clips: [ResolvedFavoriteClip] = []
        for video in videos.sorted(by: { $0.createdDate < $1.createdDate }) {
            let assetDuration = try? await AVURLAsset(url: video.originalURL).load(.duration)
            let durationSecs = assetDuration.map(CMTimeGetSeconds) ?? (video.duration ?? 0)
            guard durationSecs > 0 else { continue }

            guard let adj = metadataStore.loadTrimAdjustments(for: video.id)[0],
                  adj.before < 0 || adj.after < 0 else {
                clips.append(ResolvedFavoriteClip(video: video, timeRange: nil, duration: durationSecs))
                continue
            }
            // Negative before/after cut into the clip; positive extends don't
            // apply to standalone favorites clips (they start/end at the file).
            let start = max(0, -adj.before)
            let end = min(durationSecs, max(start + 0.1, durationSecs + min(0, adj.after)))
            clips.append(ResolvedFavoriteClip(
                video: video,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                ),
                duration: end - start
            ))
        }
        return clips
    }

    /// The same clips shaped for the share pipeline.
    static func shareClips(from videos: [VideoMetadata]) async -> [FavoriteShareClip] {
        await resolve(videos).map {
            FavoriteShareClip(
                url: $0.video.originalURL,
                timeRange: $0.timeRange,
                duration: $0.duration,
                displayName: $0.video.displayName
            )
        }
    }
}
