//
//  SendToSheet.swift
//  BumpSetCut
//
//  "Send to Friend": pick a person, optionally add a note, send. Presented
//  from the rally player, favorites, and feed cards. On success the presenter
//  gets the conversation id and username back to show a "Sent to @x — View"
//  toast; the sheet itself just closes.
//

import SwiftUI

struct SendToSheet: View {
    @State private var viewModel: SendToViewModel
    /// Called once on success with the conversation id and the recipient's
    /// username, after the sheet has asked to dismiss.
    let onSent: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthenticationService.self) private var authService

    init(payload: SendToViewModel.Payload,
         apiClient: (any APIClient)? = nil,
         media: (any MessageMediaClient)? = nil,
         onSent: @escaping (String, String) -> Void) {
        _viewModel = State(initialValue: SendToViewModel(payload: payload, apiClient: apiClient, media: media))
        self.onSent = onSent
    }

    var body: some View {
        NavigationStack {
            if viewModel.recipient == nil {
                RecipientPickerSheet(
                    currentUserId: authService.currentUser?.id ?? "",
                    onSelect: { viewModel.choose($0) },
                    onCancel: { dismiss() }
                )
            } else {
                compose
            }
        }
        .interactiveDismissDisabled(viewModel.isBusy)
        .onChange(of: viewModel.phase) { _, phase in
            if case .sent(let conversationId, let username) = phase {
                dismiss()
                onSent(conversationId, username)
            }
        }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - Compose

    private var compose: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: BSCSpacing.lg) {
                    recipientRow
                    payloadPreview
                    noteField
                    if let failure = viewModel.failure {
                        failureCard(failure)
                    }
                }
                .padding(BSCSpacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)

            footer
        }
        .background(Color.bscBackground.ignoresSafeArea())
        .navigationTitle("Send Rally")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // Also the way out of a send in flight: the export/upload
                // task is cancelled and any uploaded object is cleaned up.
                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
                .foregroundColor(.bscTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var recipientRow: some View {
        if let recipient = viewModel.recipient {
            HStack(spacing: BSCSpacing.md) {
                AvatarView(url: recipient.avatarURL, name: recipient.username, size: 44)
                VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                    Text("To")
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                    Text(recipient.username)
                        .bscFont(size: 16, weight: .semibold)
                        .foregroundColor(.bscTextPrimary)
                }
                Spacer()
                Button("Change") { viewModel.changeRecipient() }
                    .bscFont(size: 14, weight: .semibold)
                    .foregroundColor(.bscPrimaryText)
                    .disabled(viewModel.isBusy)
            }
            .padding(BSCSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(Color.bscSurfaceGlass)
            )
        }
    }

    private var payloadPreview: some View {
        HStack(spacing: BSCSpacing.md) {
            Group {
                switch viewModel.payload {
                case .clip(let clip):
                    VideoThumbnailView(thumbnailURL: nil, videoURL: clip.url, time: clip.timeRange?.start ?? .zero)
                case .highlight(let highlight):
                    AsyncImage(url: highlight.thumbnailURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.bscSurfaceGlass
                    }
                }
            }
            .frame(width: 96, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(viewModel.payloadDisplayName)
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)
                    .lineLimit(2)
                if case .clip(let clip) = viewModel.payload {
                    Text(Self.durationText(clip.duration))
                        .bscFont(size: 13)
                        .foregroundColor(.bscTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var noteField: some View {
        TextField("Add a note (optional)", text: $viewModel.note, axis: .vertical)
            .lineLimit(1...4)
            .bscFont(size: 15)
            .foregroundColor(.bscTextPrimary)
            .padding(.horizontal, BSCSpacing.md)
            .padding(.vertical, BSCSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .fill(Color.bscSurfaceGlass)
            )
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier(AccessibilityID.Messages.sendToNote)
    }

    private func failureCard(_ failure: SendFailure) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.bscErrorText)
            Text(failure.userMessage)
                .bscFont(size: 14)
                .foregroundColor(.bscTextPrimary)
            Spacer()
            if failure.isRetryable {
                Button("Retry") { viewModel.retry() }
                    .bscFont(size: 14, weight: .bold)
                    .foregroundColor(.bscPrimaryText)
                    .accessibilityIdentifier(AccessibilityID.Messages.sendToRetry)
            }
        }
        .padding(BSCSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .fill(Color.bscErrorFill.opacity(0.25))
        )
    }

    /// One indicator at a time: the Send button while idle, a single
    /// progress ring (overall, 0–100) while a send is in flight.
    @ViewBuilder
    private var footer: some View {
        VStack(spacing: BSCSpacing.sm) {
            if let progress = viewModel.progress, let label = viewModel.busyLabel {
                HStack(spacing: BSCSpacing.md) {
                    BSCProgressRing(progress: progress) {
                        Text("\(Int(progress * 100))")
                            .bscFont(size: 11, weight: .bold)
                            .foregroundColor(.bscTextPrimary)
                    }
                    .frame(width: 36, height: 36)
                    Text(label)
                        .bscFont(size: 14, weight: .semibold)
                        .foregroundColor(.bscTextSecondary)
                    Spacer()
                }
                .frame(minHeight: BSCTouchTarget.standard)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Messages.sendToProgress)
            } else {
                BSCButton(
                    title: "Send",
                    icon: "paperplane.fill",
                    style: .primary,
                    action: { viewModel.send() }
                )
                .disabled(!viewModel.canSend)
                .accessibilityIdentifier(AccessibilityID.Messages.sendButton)
            }
        }
        .padding(BSCSpacing.lg)
        .background(Color.bscBackgroundElevated)
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
