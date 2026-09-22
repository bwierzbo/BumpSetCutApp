//
//  ConversationViewModel.swift
//  BumpSetCut
//
//  One thread: a page of history, optimistic sends, and live inserts.
//

import Foundation
import Observation

@MainActor
@Observable
final class ConversationViewModel {

    enum Delivery: Equatable {
        case sent
        case sending
        case failed(SendFailure)
    }

    /// A message plus how it's doing. `id` stays stable across the optimistic
    /// insert and the server's copy so SwiftUI doesn't animate a replacement.
    struct Item: Identifiable, Equatable {
        let id: String
        var message: DirectMessage
        var delivery: Delivery
        var isMine: Bool
    }

    struct DaySection: Identifiable {
        var id: Date { day }
        let day: Date
        let items: [Item]
    }

    let conversationId: String
    private(set) var summary: ConversationSummary?
    private(set) var otherUser: UserProfile?
    private(set) var items: [Item] = []
    private(set) var isLoadingInitial = false
    private(set) var isLoadingOlder = false
    private(set) var hasOlder = true
    private(set) var loadFailed = false
    private(set) var sendError: SendFailure?
    /// A block or removal survives a retry — the composer stays disabled.
    private(set) var isClosed = false
    /// Bumped whenever the list should jump to the newest message.
    private(set) var scrollToBottomToken = 0
    /// One of your posts waiting in the composer; the draft text becomes its
    /// caption. Only posts can be attached — a message references one by id.
    private(set) var pendingAttachment: Highlight?

    var draftText = "" {
        didSet {
            if draftText.count > Self.maxLength {
                draftText = String(draftText.prefix(Self.maxLength))
            }
        }
    }

    private let currentUserId: String
    private let apiClient: any APIClient
    private let service: DirectMessageService
    private let inserts: () -> AsyncStream<DirectMessage>
    /// The post behind each in-flight or failed attachment item, so a retry
    /// can rebuild its params.
    private var attachmentPayloads: [String: Highlight] = [:]
    private var listenTask: Task<Void, Never>?
    private var highlightCache: [String: Highlight?] = [:]

    static let maxLength = 2000
    static let warnLength = 1800
    static let pageSize = 50

    init(route: ConversationRoute,
         currentUserId: String,
         apiClient: (any APIClient)? = nil,
         service: DirectMessageService = .shared,
         inserts: (() -> AsyncStream<DirectMessage>)? = nil) {
        self.conversationId = route.conversationId
        self.summary = route.summary
        self.otherUser = route.otherUser ?? route.summary?.otherUser
        self.currentUserId = currentUserId
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
        self.service = service
        self.inserts = inserts ?? { DirectMessageService.shared.inserts() }
    }

    // MARK: - Derived

    var isRequest: Bool { summary?.myStatus == .pending }

    var canSend: Bool {
        let hasText = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isClosed
            && !isRequest
            && (hasText || pendingAttachment != nil)
    }

    var showsCharacterCount: Bool { draftText.count >= Self.warnLength }

    /// Messages grouped by day, oldest first — the order they're displayed in.
    var sections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.message.createdAt) }
        return grouped.keys.sorted().map { DaySection(day: $0, items: grouped[$0] ?? []) }
    }

    // MARK: - Lifecycle

    func onAppear() async {
        await service.didOpenConversation(conversationId)
        startListening()
        if summary == nil { await loadSummary() }
        await loadInitial()
    }

    func onDisappear() {
        service.didCloseConversation(conversationId)
        listenTask?.cancel()
        listenTask = nil
    }

    /// A thread opened straight from a profile has no messages yet, so the
    /// overview view legitimately has no row for it — that isn't an error.
    private func loadSummary() async {
        summary = try? await apiClient.request(.getConversation(id: conversationId))
        if otherUser == nil { otherUser = summary?.otherUser }
    }

    // MARK: - History

    func loadInitial() async {
        guard !isLoadingInitial else { return }
        isLoadingInitial = true
        loadFailed = false
        defer { isLoadingInitial = false }

        do {
            let page: [DirectMessage] = try await apiClient.request(
                .getMessages(conversationId: conversationId, before: nil, limit: Self.pageSize)
            )
            // The server returns newest-first; the thread reads oldest-first.
            items = page.reversed().map(makeItem)
            hasOlder = page.count >= Self.pageSize
            scrollToBottomToken += 1
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            loadFailed = true
        }
    }

    func loadOlder() async {
        guard !isLoadingOlder, hasOlder, let oldest = items.first?.message.createdAt else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let page: [DirectMessage] = try await apiClient.request(
                .getMessages(conversationId: conversationId, before: oldest, limit: Self.pageSize)
            )
            let known = Set(items.map(\.id))
            let older = page.reversed().map(makeItem).filter { !known.contains($0.id) }
            items.insert(contentsOf: older, at: 0)
            hasOlder = page.count >= Self.pageSize
        } catch {
            hasOlder = false
        }
    }

    private func makeItem(_ message: DirectMessage) -> Item {
        Item(id: message.id, message: message, delivery: .sent,
             isMine: message.isMine(currentUserId))
    }

    // MARK: - Sending

    func send() async {
        let body = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draftText = ""
        sendError = nil

        guard let highlight = pendingAttachment else {
            let localId = "local-\(UUID().uuidString)"
            let optimistic = DirectMessage(
                id: localId, conversationId: conversationId, senderId: currentUserId,
                recipientId: summary?.otherUserId ?? "", body: body, createdAt: Date()
            )
            items.append(Item(id: localId, message: optimistic, delivery: .sending, isMine: true))
            scrollToBottomToken += 1
            await deliver(SendMessageParams.text(body, in: conversationId), itemId: localId)
            return
        }

        pendingAttachment = nil
        let localId = "local-\(UUID().uuidString)"
        let caption = body.isEmpty ? nil : body
        // The optimistic row carries the post itself so the bubble renders now.
        let optimistic = DirectMessage(
            id: localId, conversationId: conversationId, senderId: currentUserId,
            recipientId: summary?.otherUserId ?? "", body: caption,
            attachmentType: .highlight, highlightId: highlight.id, createdAt: Date(), highlight: highlight
        )
        items.append(Item(id: localId, message: optimistic, delivery: .sending, isMine: true))
        attachmentPayloads[localId] = highlight
        scrollToBottomToken += 1

        await deliver(.highlight(highlight.id, caption: caption, in: conversationId), itemId: localId)
    }

    /// Put one of your posts in the composer. Replaces any earlier choice;
    /// the draft text becomes the caption when it goes.
    func attach(_ highlight: Highlight) {
        guard !isClosed, !isRequest else { return }
        pendingAttachment = highlight
    }

    func clearAttachment() {
        pendingAttachment = nil
    }

    func retry(_ itemId: String) async {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].delivery = .sending
        sendError = nil

        if let highlight = attachmentPayloads[itemId] {
            await deliver(.highlight(highlight.id, caption: items[index].message.body, in: conversationId), itemId: itemId)
            return
        }
        guard let body = items[index].message.body else { return }
        await deliver(SendMessageParams.text(body, in: conversationId), itemId: itemId)
    }

    func discard(_ itemId: String) {
        items.removeAll { $0.id == itemId }
        attachmentPayloads[itemId] = nil
        sendError = nil
    }

    private func deliver(_ params: SendMessageParams, itemId: String) async {
        do {
            let sent: DirectMessage = try await apiClient.request(.sendMessage(params))
            merge(sent, into: itemId)
            // The first message makes the conversation visible in the overview.
            if summary == nil { await loadSummary() }
        } catch {
            let failure = SendFailure(error)
            if let index = items.firstIndex(where: { $0.id == itemId }) {
                items[index].delivery = .failed(failure)
            }
            sendError = failure
            if !failure.isRetryable { isClosed = true }
        }
    }

    /// Keep the optimistic row's identity; only its contents graduate.
    private func merge(_ server: DirectMessage, into itemId: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].message = server
        items[index].delivery = .sent
        attachmentPayloads[itemId] = nil
    }

    // MARK: - Requests

    func acceptRequest() async {
        do {
            let _: EmptyResponse = try await apiClient.request(.acceptConversation(id: conversationId))
            await loadSummary()
            await service.refreshCounts()
        } catch {
            sendError = SendFailure(error)
        }
    }

    func leave() async -> Bool {
        do {
            let _: EmptyResponse = try await apiClient.request(.leaveConversation(id: conversationId))
            await service.refreshCounts()
            return true
        } catch {
            sendError = SendFailure(error)
            return false
        }
    }

    // MARK: - Live inserts

    private func startListening() {
        guard listenTask == nil else { return }
        let stream = inserts()
        listenTask = Task { [weak self] in
            for await message in stream {
                await self?.handleInsert(message)
            }
        }
    }

    func handleInsert(_ message: DirectMessage) async {
        guard message.conversationId == conversationId else { return }
        guard !items.contains(where: { $0.message.id == message.id }) else { return }

        // Our own message can arrive over Realtime before the RPC returns —
        // match it to the optimistic row instead of showing it twice.
        // Attachment rows often have no body, so type and post id take part
        // in the match — otherwise a pending clip and a pending post could
        // claim each other's server copy.
        if message.senderId == currentUserId,
           let index = items.firstIndex(where: {
               $0.delivery == .sending
                   && $0.message.body == message.body
                   && $0.message.attachmentType == message.attachmentType
                   && $0.message.highlightId == message.highlightId
                   && abs($0.message.createdAt.timeIntervalSince(message.createdAt)) < 120
           }) {
            items[index].message = message
            items[index].delivery = .sent
            return
        }

        // Older than everything we've loaded and there's more history to
        // fetch — it belongs to a page we haven't pulled in.
        if hasOlder, let oldest = items.first?.message.createdAt, message.createdAt < oldest { return }

        items.append(makeItem(message))
        scrollToBottomToken += 1
        await service.didOpenConversation(conversationId)
    }

    // MARK: - Attachments

    /// Hydrates a highlight attachment. Nil means deleted or not visible to
    /// this viewer; the bubble says so rather than showing an empty frame.
    func highlight(for id: String) async -> Highlight? {
        if let cached = highlightCache[id] { return cached }
        let fetched: Highlight? = try? await apiClient.request(.getHighlight(id: id))
        highlightCache[id] = fetched
        return fetched
    }
}
