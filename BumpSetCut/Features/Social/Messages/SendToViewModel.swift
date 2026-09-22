//
//  SendToViewModel.swift
//  BumpSetCut
//
//  Sends one rally to one person as a direct message. Two payloads:
//  - an existing community post, attached by id;
//  - a private clip (from the rally player or favorites), exported, uploaded
//    to the private message-media bucket, then attached by path.
//
//  Order matters: the conversation is created (or found) first, so a blocked
//  or self recipient fails in milliseconds instead of after a video export.
//

import Foundation
import Observation

@MainActor
@Observable
final class SendToViewModel {

    enum Payload {
        case highlight(Highlight)
        case clip(FavoriteShareClip)
    }

    enum Phase: Equatable {
        case idle
        case preparing(Double)
        case uploading(Double)
        case sending
        case sent(conversationId: String, username: String)
        case failed(SendFailure)
    }

    let payload: Payload
    var note = ""
    private(set) var recipient: UserProfile?
    private(set) var phase: Phase = .idle

    private let apiClient: any APIClient
    private let media: any MessageMediaClient
    /// Exports a clip to a temp file. Injectable so tests never touch
    /// AVFoundation. The default never watermarks: a 1:1 message isn't
    /// distribution, and the recipient can't save or re-share it.
    private let exportClip: @Sendable (FavoriteShareClip) async throws -> URL
    private var task: Task<Void, Never>?

    init(payload: Payload,
         apiClient: (any APIClient)? = nil,
         media: (any MessageMediaClient)? = nil,
         exportClip: (@Sendable (FavoriteShareClip) async throws -> URL)? = nil) {
        self.payload = payload
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
        self.media = media ?? SupabaseAPIClient.shared
        self.exportClip = exportClip ?? { clip in
            try await RallyClipExporter().export(
                url: clip.url,
                timeRange: clip.timeRange,
                addWatermark: false,
                fileTag: "send_rally"
            )
        }
    }

    // MARK: - State

    var isBusy: Bool {
        switch phase {
        case .preparing, .uploading, .sending: return true
        case .idle, .sent, .failed: return false
        }
    }

    var canSend: Bool { recipient != nil && !isBusy }

    var failure: SendFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    /// Progress for the busy card, 0…1, or nil when not busy.
    var progress: Double? {
        switch phase {
        case .preparing(let value): return value * 0.4
        case .uploading(let value): return 0.4 + value * 0.55
        case .sending: return 0.97
        default: return nil
        }
    }

    var busyLabel: String? {
        switch phase {
        case .preparing: return "Preparing rally…"
        case .uploading(let value): return "Uploading… \(Int(value * 100))%"
        case .sending: return "Sending…"
        default: return nil
        }
    }

    var payloadDisplayName: String {
        switch payload {
        case .highlight(let highlight):
            if let caption = highlight.caption, !caption.isEmpty { return caption }
            return highlight.author.map { "Post by @\($0.username)" } ?? "Rally"
        case .clip(let clip):
            return clip.displayName
        }
    }

    // MARK: - Actions

    func choose(_ user: UserProfile) {
        recipient = user
        if case .failed = phase { phase = .idle }
    }

    func changeRecipient() {
        guard !isBusy else { return }
        recipient = nil
        phase = .idle
    }

    func send() {
        guard let recipient, !isBusy else { return }
        let caption = note.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task { [weak self] in
            await self?.perform(to: recipient, caption: caption.isEmpty ? nil : caption)
        }
    }

    func retry() {
        guard failure?.isRetryable == true else { return }
        send()
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isBusy { phase = .idle }
    }

    // MARK: - Pipeline

    private func perform(to recipient: UserProfile, caption: String?) async {
        do {
            phase = .sending
            let conversationId: String = try await apiClient.request(
                .getOrCreateConversation(otherUserId: recipient.id)
            )
            try Task.checkCancellation()

            switch payload {
            case .highlight(let highlight):
                let _: DirectMessage = try await apiClient.request(
                    .sendMessage(.highlight(highlight.id, caption: caption, in: conversationId))
                )

            case .clip(let clip):
                phase = .preparing(0)
                let fileURL = try await exportClip(clip)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                try Task.checkCancellation()

                phase = .uploading(0)
                let path = try await media.uploadMessageClip(fileURL: fileURL) { [weak self] value in
                    Task { @MainActor in
                        if case .uploading = self?.phase { self?.phase = .uploading(value) }
                    }
                }
                try Task.checkCancellation()

                phase = .sending
                do {
                    let _: DirectMessage = try await apiClient.request(
                        .sendMessage(.clip(path: path, duration: clip.duration, caption: caption, in: conversationId))
                    )
                } catch {
                    // The object is orphaned without a message row pointing at it.
                    try? await media.deleteMessageClip(path: path)
                    throw error
                }
            }

            phase = .sent(conversationId: conversationId, username: recipient.username)
        } catch is CancellationError {
            phase = .idle
        } catch let error as URLError where error.code == .cancelled {
            phase = .idle
        } catch {
            phase = .failed(SendFailure(error))
        }
    }
}
