//
//  MessageBubble.swift
//  BumpSetCut
//
//  One message: mine on the right, theirs on the left, with an attached rally
//  rendered as a tappable thumbnail.
//

import SwiftUI
import AVKit

struct MessageBubble: View {
    let item: ConversationViewModel.Item
    let otherUsername: String?
    let highlightLoader: (String) async -> Highlight?
    var onRetry: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onReport: () -> Void = {}

    @State private var hydrated: Highlight?
    @State private var didAttemptHydration = false
    @State private var presentedHighlight: Highlight?
    @State private var presentedClipPath: String?

    var body: some View {
        HStack {
            if item.isMine { Spacer(minLength: BSCSpacing.xxl) }

            VStack(alignment: item.isMine ? .trailing : .leading, spacing: BSCSpacing.xxs) {
                bubbleContent
                deliveryFooter
            }

            if !item.isMine { Spacer(minLength: BSCSpacing.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(AccessibilityID.Messages.bubble)
        .contextMenu {
            if let body = item.message.body, !body.isEmpty {
                Button {
                    UIPasteboard.general.string = body
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            if !item.isMine {
                Button(role: .destructive, action: onReport) {
                    Label("Report Message", systemImage: "exclamationmark.shield")
                }
            }
        }
        .fullScreenCover(item: $presentedHighlight) { highlight in
            HighlightDetailCover(highlight: highlight) { presentedHighlight = nil }
        }
        .fullScreenCover(item: Binding(
            get: { presentedClipPath.map(ClipPath.init) },
            set: { presentedClipPath = $0?.path }
        )) { clip in
            MessageClipPlayerView(path: clip.path) { presentedClipPath = nil }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            if let attachment = item.message.attachment {
                attachmentView(attachment)
            }
            if let body = item.message.body, !body.isEmpty {
                Text(body)
                    .bscFont(size: 15)
                    .foregroundColor(item.isMine ? .bscOnPrimary : .bscTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, BSCSpacing.md)
        .padding(.vertical, BSCSpacing.sm)
        .background(item.isMine ? Color.bscPrimaryFill : Color.bscSurfaceGlass)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.lg, style: .continuous)
                .stroke(item.isMine ? Color.clear : Color.bscSurfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func attachmentView(_ attachment: MessageAttachment) -> some View {
        switch attachment {
        case .highlight(let id, let embedded):
            let highlight = embedded ?? hydrated
            if let highlight {
                Button {
                    presentedHighlight = highlight
                } label: {
                    thumbnail(
                        thumbnailURL: highlight.thumbnailImageURL,
                        videoURL: highlight.allVideoURLs.first ?? highlight.videoURL,
                        caption: highlight.author.map { "@\($0.username)" }
                    )
                }
                .buttonStyle(.plain)
            } else if didAttemptHydration || id == nil {
                unavailableAttachment
            } else {
                ProgressView()
                    .tint(.bscOnMediaSecondary)
                    .frame(width: 220, height: 124)
                    .task {
                        guard let id else { return }
                        hydrated = await highlightLoader(id)
                        didAttemptHydration = true
                    }
            }

        case .clip(let path, let duration):
            Button {
                presentedClipPath = path
            } label: {
                thumbnail(
                    thumbnailURL: nil,
                    videoURL: nil,
                    caption: duration.map(Self.formatDuration)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func thumbnail(thumbnailURL: URL?, videoURL: URL?, caption: String?) -> some View {
        ZStack {
            if thumbnailURL != nil || videoURL != nil {
                VideoThumbnailView(thumbnailURL: thumbnailURL, videoURL: videoURL)
            } else {
                Color.bscMediaBackground
            }

            Image(systemName: "play.circle.fill")
                .bscFont(size: 36)
                .foregroundColor(.bscOnMedia)
                .shadow(radius: 4)

            if let caption {
                VStack {
                    Spacer()
                    HStack {
                        Text(caption)
                            .bscFont(size: 11, weight: .medium)
                            .foregroundColor(.bscOnMedia)
                            .padding(.horizontal, BSCSpacing.xs)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.bscMediaScrimBase.opacity(0.6)))
                        Spacer()
                    }
                }
                .padding(BSCSpacing.xs)
            }
        }
        .frame(width: 220, height: 124)
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
    }

    /// The post was deleted, or its author's privacy no longer lets us see it.
    private var unavailableAttachment: some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: "video.slash")
                .bscFont(size: 14)
            Text("Rally unavailable")
                .bscFont(size: 13)
        }
        .foregroundColor(item.isMine ? .bscOnPrimary.opacity(0.8) : .bscTextSecondary)
        .frame(width: 220, height: 60)
        .background(Color.bscSurfaceGlass.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
    }

    // MARK: - Delivery

    @ViewBuilder
    private var deliveryFooter: some View {
        switch item.delivery {
        case .sent:
            Text(item.message.createdAt.formatted(date: .omitted, time: .shortened))
                .bscFont(size: 10)
                .foregroundColor(.bscTextTertiary)
        case .sending:
            HStack(spacing: BSCSpacing.xxs) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
                    .bscFont(size: 10)
                    .foregroundColor(.bscTextTertiary)
            }
        case .failed(let failure):
            Menu {
                if failure.isRetryable {
                    Button("Try Again", action: onRetry)
                }
                Button("Delete", role: .destructive, action: onDiscard)
            } label: {
                Text(failure.isRetryable ? "Failed — tap to retry" : failure.userMessage)
                    .bscFont(size: 10, weight: .medium)
                    .foregroundColor(.bscErrorText)
            }
            .accessibilityIdentifier(AccessibilityID.Messages.retry)
        }
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let who = item.isMine ? "You" : "@\(otherUsername ?? "them")"
        let when = item.message.createdAt.formatted(.relative(presentation: .named))
        var description = "\(who), \(when): \(item.message.body ?? "")"
        if item.message.attachment != nil {
            description += item.isMine ? ", rally attached" : ", rally from \(otherUsername ?? "them")"
        }
        switch item.delivery {
        case .sending: description += ", sending"
        case .failed: description += ", failed to send, double tap to retry"
        case .sent: break
        }
        return description
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// `fullScreenCover(item:)` needs an Identifiable; a bare path isn't one.
private struct ClipPath: Identifiable {
    let path: String
    var id: String { path }
}
