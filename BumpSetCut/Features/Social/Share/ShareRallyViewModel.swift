//
//  ShareRallyViewModel.swift
//  BumpSetCut
//
//  Manages the rally-to-highlight upload flow.
//

import Foundation
import Observation

enum ShareState: Equatable {
    case idle
    case uploading(progress: Double)
    case processing
    case complete(Highlight)
    case failed(String)

    static func == (lhs: ShareState, rhs: ShareState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.uploading(let a), .uploading(let b)): return a == b
        case (.processing, .processing): return true
        case (.complete(let a), .complete(let b)): return a.id == b.id
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

@MainActor
@Observable
final class ShareRallyViewModel {
    var caption: String = ""
    var tags: [String] = ["volleyball"]
    private(set) var state: ShareState = .idle

    let videoURL: URL
    let rallyIndex: Int
    let videoId: UUID
    let metadata: RallyHighlightMetadata

    private let apiClient: any APIClient
    private var uploadTask: Task<Void, Never>?

    init(videoURL: URL, rallyIndex: Int, videoId: UUID, metadata: RallyHighlightMetadata,
         apiClient: (any APIClient)? = nil) {
        self.videoURL = videoURL
        self.rallyIndex = rallyIndex
        self.videoId = videoId
        self.metadata = metadata
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    func upload() {
        guard state == .idle else { return }
        startUpload()
    }

    func retry() {
        state = .idle
        startUpload()
    }

    func cancel() {
        uploadTask?.cancel()
        uploadTask = nil
        state = .idle
    }

    private func startUpload() {
        uploadTask = Task {
            state = .uploading(progress: 0)

            do {
                // Step 1: Upload video to Mux via signed URL
                let uploadURL = try await apiClient.upload(
                    fileURL: videoURL,
                    to: .createUploadURL
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.state = .uploading(progress: progress)
                    }
                }

                try Task.checkCancellation()
                state = .processing

                // Step 2: Create highlight record with Mux asset info
                let upload = HighlightUpload(
                    muxAssetId: uploadURL.lastPathComponent,
                    muxPlaybackId: uploadURL.lastPathComponent,
                    caption: caption.isEmpty ? nil : caption,
                    tags: tags,
                    localVideoId: videoId,
                    localRallyIndex: rallyIndex,
                    rallyMetadata: metadata
                )

                let highlight: Highlight = try await apiClient.request(.createHighlight(upload))
                state = .complete(highlight)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

}
