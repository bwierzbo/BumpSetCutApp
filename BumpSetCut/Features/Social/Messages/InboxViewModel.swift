//
//  InboxViewModel.swift
//  BumpSetCut
//
//  Two lists: accepted chats, and requests from people you don't follow.
//

import Foundation
import Observation

@MainActor
@Observable
final class InboxViewModel {

    enum Segment: Hashable {
        case chats, requests
    }

    var segment: Segment = .chats

    private(set) var chats: [ConversationSummary] = []
    private(set) var requests: [ConversationSummary] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private(set) var hasMoreChats = true
    private(set) var hasMoreRequests = true
    /// Transient failure the view turns into a toast.
    var actionError: String?

    let currentUserId: String
    private let apiClient: any APIClient
    private let inserts: () -> AsyncStream<DirectMessage>
    private var chatsPage = 0
    private var requestsPage = 0
    private var listenTask: Task<Void, Never>?

    static let pageSize = 30

    init(currentUserId: String,
         apiClient: (any APIClient)? = nil,
         inserts: (() -> AsyncStream<DirectMessage>)? = nil) {
        self.currentUserId = currentUserId
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
        self.inserts = inserts ?? { DirectMessageService.shared.inserts() }
    }

    var visible: [ConversationSummary] {
        segment == .chats ? chats : requests
    }

    var hasMore: Bool {
        segment == .chats ? hasMoreChats : hasMoreRequests
    }

    // MARK: - Loading

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        async let chatsResult: [ConversationSummary] = apiClient.request(.getConversations(page: 0))
        async let requestsResult: [ConversationSummary] = apiClient.request(.getConversationRequests(page: 0))

        do {
            let (loadedChats, loadedRequests) = try await (chatsResult, requestsResult)
            chats = loadedChats
            requests = loadedRequests
            chatsPage = 0
            requestsPage = 0
            hasMoreChats = loadedChats.count >= Self.pageSize
            hasMoreRequests = loadedRequests.count >= Self.pageSize
        } catch is CancellationError {
            // Dismissed mid-load; not a failure worth showing.
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            loadFailed = true
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            if segment == .chats {
                let next: [ConversationSummary] = try await apiClient.request(.getConversations(page: chatsPage + 1))
                chatsPage += 1
                chats = merge(chats, next)
                hasMoreChats = next.count >= Self.pageSize
            } else {
                let next: [ConversationSummary] = try await apiClient.request(.getConversationRequests(page: requestsPage + 1))
                requestsPage += 1
                requests = merge(requests, next)
                hasMoreRequests = next.count >= Self.pageSize
            }
        } catch {
            // Stop paging rather than spinning on a broken cursor.
            if segment == .chats { hasMoreChats = false } else { hasMoreRequests = false }
        }
    }

    /// A conversation can move between pages while we're reading them, so
    /// dedupe on id instead of blindly appending.
    private func merge(_ existing: [ConversationSummary], _ next: [ConversationSummary]) -> [ConversationSummary] {
        let known = Set(existing.map(\.id))
        return existing + next.filter { !known.contains($0.id) }
    }

    func summary(for conversationId: String) -> ConversationSummary? {
        chats.first { $0.id == conversationId } ?? requests.first { $0.id == conversationId }
    }

    // MARK: - Actions

    func accept(_ conversation: ConversationSummary) async {
        do {
            let _: EmptyResponse = try await apiClient.request(.acceptConversation(id: conversation.id))
            requests.removeAll { $0.id == conversation.id }
            var moved = conversation
            moved.unreadCount = conversation.unreadCount
            chats.insert(moved, at: 0)
            await DirectMessageService.shared.refreshCounts()
        } catch {
            actionError = "Couldn't accept that request"
        }
    }

    /// Declining a request and leaving a chat are the same operation — drop
    /// your own membership.
    func leave(_ conversation: ConversationSummary) async {
        do {
            let _: EmptyResponse = try await apiClient.request(.leaveConversation(id: conversation.id))
            chats.removeAll { $0.id == conversation.id }
            requests.removeAll { $0.id == conversation.id }
            await DirectMessageService.shared.refreshCounts()
        } catch {
            actionError = "Couldn't remove that conversation"
        }
    }

    func openThread(with userId: String) async -> ConversationRoute? {
        do {
            let id: String = try await apiClient.request(.getOrCreateConversation(otherUserId: userId))
            return ConversationRoute(conversationId: id, summary: summary(for: id))
        } catch {
            actionError = SendFailure(error).userMessage
            return nil
        }
    }

    func markLocallyRead(_ conversationId: String) {
        if let index = chats.firstIndex(where: { $0.id == conversationId }) {
            chats[index].unreadCount = 0
        }
        if let index = requests.firstIndex(where: { $0.id == conversationId }) {
            requests[index].unreadCount = 0
        }
    }

    // MARK: - Live updates

    func startListening() {
        guard listenTask == nil else { return }
        let stream = inserts()
        listenTask = Task { [weak self] in
            for await message in stream {
                await self?.handleInsert(message)
            }
        }
    }

    func stopListening() {
        listenTask?.cancel()
        listenTask = nil
    }

    func handleInsert(_ message: DirectMessage) async {
        if let index = chats.firstIndex(where: { $0.id == message.conversationId }) {
            var updated = chats[index]
            apply(message, to: &updated)
            chats.remove(at: index)
            chats.insert(updated, at: 0)
        } else if let index = requests.firstIndex(where: { $0.id == message.conversationId }) {
            var updated = requests[index]
            apply(message, to: &updated)
            requests.remove(at: index)
            requests.insert(updated, at: 0)
        } else {
            // A conversation we haven't loaded yet — a reload is cheaper to
            // reason about than trying to patch one in.
            await loadInitial()
        }
    }

    private func apply(_ message: DirectMessage, to summary: inout ConversationSummary) {
        summary = ConversationSummary(
            conversationId: summary.conversationId,
            myStatus: summary.myStatus,
            lastReadAt: summary.lastReadAt,
            otherUserId: summary.otherUserId,
            otherStatus: summary.otherStatus,
            otherUsername: summary.otherUsername,
            otherAvatarURL: summary.otherAvatarURL,
            createdAt: summary.createdAt,
            lastMessageAt: message.createdAt,
            lastMessagePreview: message.body,
            lastMessageAttachmentType: message.attachmentType,
            lastMessageSenderId: message.senderId,
            unreadCount: summary.unreadCount
                + (message.senderId == currentUserId
                   || message.conversationId == DirectMessageService.shared.activeConversationId ? 0 : 1)
        )
    }

    // MARK: - Display

    /// "You: nice dig" / "Sent a rally" / the message itself.
    func previewText(for summary: ConversationSummary) -> String {
        let base: String
        if let preview = summary.lastMessagePreview, !preview.isEmpty {
            base = preview
        } else if let attachment = summary.lastMessageAttachmentType {
            base = attachment == .highlight ? "Sent a post" : "Sent a rally"
        } else {
            base = "No messages yet"
        }
        let isMine = summary.lastMessageSenderId == currentUserId
        return isMine ? "You: \(base)" : base
    }
}
