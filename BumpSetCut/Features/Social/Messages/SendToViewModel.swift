//
//  SendToViewModel.swift
//  BumpSetCut
//
//  Sends an existing community post to one person as a direct message.
//  Only posts travel through DMs — anything not already posted is shared
//  with the system share sheet instead — so there is nothing to export or
//  upload here; the message references the post by id.
//
//  The conversation is created (or found) first, so a blocked or self
//  recipient fails before anything else happens.
//

import Foundation
import Observation

@MainActor
@Observable
final class SendToViewModel {

    enum Phase: Equatable {
        case idle
        case sending
        case sent(conversationId: String, username: String)
        case failed(SendFailure)
    }

    let highlight: Highlight
    var note = ""
    private(set) var recipient: UserProfile?
    private(set) var phase: Phase = .idle

    private let apiClient: any APIClient
    private var task: Task<Void, Never>?

    init(highlight: Highlight, apiClient: (any APIClient)? = nil) {
        self.highlight = highlight
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
    }

    // MARK: - State

    var isBusy: Bool { phase == .sending }

    var canSend: Bool { recipient != nil && !isBusy }

    var failure: SendFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    var displayName: String {
        if let caption = highlight.caption, !caption.isEmpty { return caption }
        return highlight.author.map { "Post by @\($0.username)" } ?? "Rally"
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
            let _: DirectMessage = try await apiClient.request(
                .sendMessage(.highlight(highlight.id, caption: caption, in: conversationId))
            )
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
