//
//  ConversationView.swift
//  BumpSetCut
//
//  One thread: history, bubbles, and the composer.
//

import SwiftUI

struct ConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ConversationViewModel
    @State private var toast: BSCToastMessage?
    @State private var showLeaveConfirm = false
    @State private var reportingMessage: DirectMessage?
    @State private var blockingUser = false
    /// Attach a rally: the source chooser, then whichever picker was chosen.
    @State private var showingAttachOptions = false
    @State private var showingMyPosts = false
    @State private var favoriteClipsToPick: [FavoriteShareClip]?
    @FocusState private var isComposerFocused: Bool

    private let route: ConversationRoute
    private let currentUserId: String
    /// For the favorites picker — attaching a favorite means listing the library.
    private let mediaStore: MediaStore

    init(route: ConversationRoute, currentUserId: String, mediaStore: MediaStore) {
        self.route = route
        self.currentUserId = currentUserId
        self.mediaStore = mediaStore
        _viewModel = State(initialValue: ConversationViewModel(route: route, currentUserId: currentUserId))
    }

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                messageList

                if let error = viewModel.sendError {
                    errorBanner(error)
                }

                if viewModel.isRequest {
                    requestBanner
                } else {
                    composer
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .bscToast($toast)
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .sheet(item: $reportingMessage) { message in
            ReportContentSheet(
                contentType: .message,
                contentId: UUID(uuidString: message.id) ?? UUID(),
                reportedUserId: UUID(uuidString: message.senderId) ?? UUID()
            )
        }
        .confirmationDialog("Attach a rally", isPresented: $showingAttachOptions, titleVisibility: .visible) {
            Button("From my posts") { showingMyPosts = true }
            Button("From favorites") { pickFromFavorites() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingMyPosts) {
            MyPostsPickerSheet(
                currentUserId: currentUserId,
                onPick: { highlight in
                    showingMyPosts = false
                    viewModel.attach(.highlight(highlight))
                },
                onCancel: { showingMyPosts = false }
            )
        }
        .sheet(isPresented: Binding(
            get: { favoriteClipsToPick != nil },
            set: { if !$0 { favoriteClipsToPick = nil } }
        )) {
            if let clips = favoriteClipsToPick {
                // The same picker posting uses, so a favorite can be held to
                // play full size before it's chosen. One clip per message.
                ClipPickerSheet(
                    title: "Favorites",
                    items: clips.map { clip in
                        ClipPickerItem(
                            id: clip.id, payload: clip, url: clip.url, timeRange: clip.timeRange,
                            displayName: clip.displayName, duration: clip.duration
                        )
                    },
                    maxSelection: 1,
                    confirmTitle: { _ in "Attach" },
                    onConfirm: { picked in
                        favoriteClipsToPick = nil
                        if let clip = picked.first { viewModel.attach(.clip(clip)) }
                    },
                    onCancel: { favoriteClipsToPick = nil }
                )
            }
        }
        .blockUserAlert(
            isPresented: $blockingUser,
            username: viewModel.otherUser?.username ?? "user",
            userId: UUID(uuidString: viewModel.otherUser?.id ?? "") ?? UUID()
        ) {
            try await ModerationService.shared.blockUser(UUID(uuidString: viewModel.otherUser?.id ?? "") ?? UUID())
        }
        .confirmationDialog("Leave this conversation?", isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                Task { if await viewModel.leave() { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop receiving messages here. They can still message you again.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let other = viewModel.otherUser {
                NavigationLink(value: other.id) {
                    HStack(spacing: BSCSpacing.sm) {
                        AvatarView(url: other.avatarURL, name: other.username, size: 28)
                        Text(other.username)
                            .bscFont(size: 16, weight: .semibold)
                            .foregroundColor(.bscTextPrimary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Messages.threadHeader)
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                if let other = viewModel.otherUser {
                    NavigationLink(value: other.id) {
                        Label("View Profile", systemImage: "person")
                    }
                    Button(role: .destructive) {
                        blockingUser = true
                    } label: {
                        Label("Block @\(other.username)", systemImage: "hand.raised")
                    }
                }
                Button(role: .destructive) {
                    showLeaveConfirm = true
                } label: {
                    Label("Leave Conversation", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextSecondary)
                    .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Conversation options")
            .accessibilityIdentifier(AccessibilityID.Messages.threadMenu)
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: BSCSpacing.xs) {
                    if viewModel.hasOlder && !viewModel.items.isEmpty {
                        ProgressView()
                            .tint(.bscPrimary)
                            .padding(.vertical, BSCSpacing.sm)
                            .onAppear { Task { await viewModel.loadOlder() } }
                    }

                    ForEach(viewModel.sections) { section in
                        daySeparator(section.day)
                        ForEach(section.items) { item in
                            MessageBubble(
                                item: item,
                                otherUsername: viewModel.otherUser?.username,
                                highlightLoader: { id in await viewModel.highlight(for: id) },
                                onRetry: { Task { await viewModel.retry(item.id) } },
                                onDiscard: { viewModel.discard(item.id) },
                                onReport: { reportingMessage = item.message }
                            )
                            .id(item.id)
                        }
                    }

                    // Anchor so the list can scroll past the last bubble.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, BSCSpacing.md)
                .padding(.vertical, BSCSpacing.sm)
            }
            .accessibilityIdentifier(AccessibilityID.Messages.threadList)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.scrollToBottomToken) { _, _ in
                withAnimation(.bscStandard) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .overlay {
                if viewModel.items.isEmpty && !viewModel.isLoadingInitial {
                    emptyThread
                }
            }
        }
    }

    private static let bottomAnchor = "thread.bottom"

    private func daySeparator(_ day: Date) -> some View {
        Text(dayLabel(day))
            .bscFont(size: 11, weight: .medium)
            .foregroundColor(.bscTextTertiary)
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.xxs)
            .background(Capsule().fill(Color.bscSurfaceGlass))
            .padding(.vertical, BSCSpacing.sm)
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }

    private var emptyThread: some View {
        VStack(spacing: BSCSpacing.sm) {
            Image(systemName: "bubble.left.and.bubble.right")
                .bscFont(size: 32)
                .foregroundColor(.bscTextTertiary)
            Text("Say hi, or send a rally.")
                .bscFont(size: 14)
                .foregroundColor(.bscTextSecondary)
        }
    }

    // MARK: - Request banner

    private var requestBanner: some View {
        VStack(spacing: BSCSpacing.sm) {
            Text("@\(viewModel.otherUser?.username ?? "This person") wants to message you")
                .bscFont(size: 14, weight: .medium)
                .foregroundColor(.bscTextPrimary)
                .multilineTextAlignment(.center)

            HStack(spacing: BSCSpacing.sm) {
                Button {
                    Task { await viewModel.acceptRequest() }
                } label: {
                    Text("Accept")
                        .bscFont(size: 15, weight: .semibold)
                        .foregroundColor(.bscOnPrimary)
                        .frame(maxWidth: .infinity, minHeight: BSCTouchTarget.standard)
                        .background(Capsule().fill(Color.bscPrimaryFill))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Messages.acceptRequest)

                Button {
                    Task { if await viewModel.leave() { dismiss() } }
                } label: {
                    Text("Delete")
                        .bscFont(size: 15, weight: .semibold)
                        .foregroundColor(.bscTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: BSCTouchTarget.standard)
                        .background(Capsule().fill(Color.bscSurfaceGlass))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Messages.deleteRequest)
            }
        }
        .padding(BSCSpacing.lg)
        .background(Color.bscBackgroundElevated)
    }

    // MARK: - Composer

    /// Favorites resolve asynchronously (each clip's trim window is read from
    /// its sidecar), then open in the shared picker. Same per-clip length cap
    /// as posting — a message clip is exported and uploaded the same way.
    private func pickFromFavorites() {
        Task {
            let all = await FavoriteClipResolver.shareClips(from: mediaStore.getAllVideos(in: .favorites))
            let eligible = all.filter { $0.duration <= ShareRallyViewModel.maxDurationSeconds }
            guard !eligible.isEmpty else {
                toast = BSCToastMessage(
                    text: all.isEmpty ? "No favorites yet" : "All favorites are over 1 minute",
                    style: .error
                )
                return
            }
            favoriteClipsToPick = eligible
        }
    }

    /// The rally waiting in the composer — a thumbnail, its name, and a way
    /// to change your mind before it goes.
    private func pendingAttachmentChip(_ payload: SendToViewModel.Payload) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            Group {
                switch payload {
                case .clip(let clip):
                    VideoThumbnailView(thumbnailURL: nil, videoURL: clip.url, time: clip.timeRange?.start ?? .zero)
                case .highlight(let highlight):
                    AsyncImage(url: highlight.thumbnailImageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.bscSurfaceGlass
                    }
                }
            }
            .frame(width: 48, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

            Text({
                switch payload {
                case .clip(let clip): return clip.displayName
                case .highlight(let highlight):
                    return highlight.caption.flatMap { $0.isEmpty ? nil : $0 } ?? "Your post"
                }
            }())
            .bscFont(size: 13, weight: .semibold)
            .foregroundColor(.bscTextPrimary)
            .lineLimit(1)

            Spacer()

            Button {
                viewModel.clearAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .bscFont(size: 18)
                    .foregroundColor(.bscTextSecondary)
                    .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.leading, BSCSpacing.md)
        .padding(.trailing, BSCSpacing.xs)
        .padding(.vertical, BSCSpacing.xs)
        .background(Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
        .padding(.horizontal, BSCSpacing.md)
    }

    private var composer: some View {
        VStack(spacing: BSCSpacing.xxs) {
            if viewModel.showsCharacterCount {
                HStack {
                    Spacer()
                    Text("\(viewModel.draftText.count)/\(ConversationViewModel.maxLength)")
                        .bscFont(size: 11, design: .monospaced)
                        .foregroundColor(
                            viewModel.draftText.count >= ConversationViewModel.maxLength
                                ? .bscErrorText : .bscTextSecondary
                        )
                }
                .padding(.horizontal, BSCSpacing.md)
            }

            if let payload = viewModel.pendingAttachment {
                pendingAttachmentChip(payload)
            }

            if let progress = viewModel.attachmentProgress, let stage = viewModel.attachmentStage {
                HStack(spacing: BSCSpacing.sm) {
                    BSCProgressRing(progress: progress) {
                        Text("\(Int(progress * 100))")
                            .bscFont(size: 10, weight: .bold)
                            .foregroundColor(.bscTextPrimary)
                    }
                    .frame(width: 28, height: 28)
                    Text(stage)
                        .bscFont(size: 13, weight: .semibold)
                        .foregroundColor(.bscTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, BSCSpacing.md)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: BSCSpacing.sm) {
                BSCIconButton(
                    icon: "video.badge.plus",
                    style: .glass,
                    size: .compact,
                    accessibilityLabel: "Attach a rally"
                ) {
                    showingAttachOptions = true
                }
                .disabled(viewModel.isClosed || viewModel.attachmentProgress != nil)
                .accessibilityIdentifier(AccessibilityID.Messages.attachButton)

                TextField("Message…", text: $viewModel.draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextPrimary)
                    .padding(.vertical, BSCSpacing.sm)
                    .padding(.horizontal, BSCSpacing.md)
                    .frame(minHeight: BSCTouchTarget.standard)
                    .background(Color.bscSurfaceGlass)
                    .clipShape(Capsule())
                    .focused($isComposerFocused)
                    .disabled(viewModel.isClosed)
                    .accessibilityIdentifier(AccessibilityID.Messages.inputField)

                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .bscFont(size: 30)
                        .foregroundColor(viewModel.canSend ? .bscPrimary : .bscTextTertiary)
                        .frame(width: BSCTouchTarget.standard, height: BSCTouchTarget.standard)
                        .contentShape(Rectangle())
                }
                .disabled(!viewModel.canSend)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier(AccessibilityID.Messages.sendButton)
            }
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.sm)
        }
        .background(Color.bscBackgroundElevated)
    }

    private func errorBanner(_ error: SendFailure) -> some View {
        Text(error.userMessage)
            .bscFont(size: 13)
            .foregroundColor(.bscErrorText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BSCSpacing.lg)
            .padding(.vertical, BSCSpacing.sm)
            .background(Color.bscErrorFill.opacity(0.15))
    }
}
