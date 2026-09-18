//
//  ClipPickerSheet.swift
//  BumpSetCut
//
//  Choose which clips go into a multi-rally community post. Instagram-style
//  multi-select: distinct cells, numbered badges in tap order (which is the
//  post order), Select All when everything fits. Press and hold a cell to
//  watch the clip before deciding.
//
//  Shared by favorites folders (payload: FavoriteShareClip) and the rally
//  player's saved rallies (payload: rally index).
//

import SwiftUI
import AVFoundation

/// One selectable clip: where to find its video, how to label it, and the
/// caller's own value to hand back on confirm.
struct ClipPickerItem<Payload>: Identifiable {
    let id: UUID
    let payload: Payload
    let url: URL
    /// Slice of `url` this clip covers; nil means the whole file.
    let timeRange: CMTimeRange?
    let displayName: String
    let duration: Double
    /// Already shared to the community feed — shown as a badge so a second
    /// post from the same game doesn't repeat one by accident.
    var isPosted: Bool = false
}

struct ClipPickerSheet<Payload>: View {
    let title: String
    let items: [ClipPickerItem<Payload>]
    let maxSelection: Int
    let onConfirm: ([Payload]) -> Void
    let onCancel: () -> Void

    /// Selected ids in tap order — order in the post follows it.
    @State private var selection: [UUID] = []
    /// Suppresses the selection tap for the gesture that started a preview.
    @State private var previewingID: UUID?
    /// The held clip, played full-screen above the grid. A cell can't draw
    /// outside the scroll view that clips it, so the preview lives up here.
    @State private var previewPlayer: AVPlayer?
    @State private var previewName: String?

    private var canSelectAll: Bool { items.count <= maxSelection }
    private var atCapacity: Bool { selection.count >= maxSelection }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.md), count: 2),
                            spacing: BSCSpacing.md
                        ) {
                            ForEach(items) { item in
                                clipCell(item)
                            }
                        }
                        .padding(BSCSpacing.lg)
                    }

                    Button {
                        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.payload) })
                        onConfirm(selection.compactMap { byID[$0] })
                    } label: {
                        Text("Post \(selection.count) \(selection.count == 1 ? "Rally" : "Rallies")")
                            .bscFont(size: 16, weight: .bold)
                            .foregroundColor(.bscOnPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, BSCSpacing.md)
                            .background(LinearGradient.bscPrimaryGradient)
                            .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                            .opacity(selection.isEmpty ? 0.5 : 1)
                    }
                    .disabled(selection.isEmpty)
                    .padding(BSCSpacing.lg)
                    .background(Color.bscBackgroundElevated)
                    .accessibilityIdentifier(AccessibilityID.Favorites.clipPickerConfirm)
                }

                heldClipPreview
            }
            .animation(.bscQuick, value: previewingID)
            .navigationTitle("Choose Rallies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.bscTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: BSCSpacing.md) {
                        if canSelectAll {
                            Button(selection.count == items.count ? "Deselect All" : "Select All") {
                                if selection.count == items.count {
                                    selection = []
                                } else {
                                    selection = items.map(\.id)
                                }
                            }
                            .bscFont(size: 14, weight: .semibold)
                            .foregroundColor(.bscPrimaryText)
                            .accessibilityIdentifier(AccessibilityID.Favorites.clipPickerSelectAll)
                        }

                        Text("\(selection.count)/\(maxSelection)")
                            .bscFont(size: 14, weight: .semibold, design: .monospaced)
                            .foregroundColor(.bscTextSecondary)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: BSCSpacing.xxs) {
            if items.count > maxSelection {
                Text("\(title) has \(items.count) rallies — a post can hold up to \(maxSelection). Tap rallies in the order they should appear.")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Label("Press and hold a rally to preview it", systemImage: "hand.tap.fill")
                .bscFont(size: 12)
                .foregroundColor(.bscTextSecondary)
        }
        .padding(.horizontal, BSCSpacing.xl)
        .padding(.vertical, BSCSpacing.sm)
    }

    /// The held clip, filling the sheet. Aspect-fit rather than filled so the
    /// whole rally is visible — the point of holding is to judge it. Never
    /// hit-testable: the long press that opened it is still in progress
    /// underneath, and swallowing it would strand the preview on screen.
    @ViewBuilder
    private var heldClipPreview: some View {
        if let previewPlayer {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()

                CustomVideoPlayerView(player: previewPlayer, gravity: .resizeAspect) { _ in }
                    .ignoresSafeArea()

                if let previewName {
                    VStack {
                        Spacer()
                        Text(previewName)
                            .bscFont(size: 15, weight: .semibold)
                            .foregroundColor(.bscOnMedia)
                            .padding(.horizontal, BSCSpacing.lg)
                            .padding(.vertical, BSCSpacing.sm)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(.bottom, BSCSpacing.xxl)
                    }
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .accessibilityHidden(true)
        }
    }

    private func clipCell(_ item: ClipPickerItem<Payload>) -> some View {
        let order = selection.firstIndex(of: item.id)
        let dimmed = order == nil && atCapacity
        let isPreviewing = previewingID == item.id

        return VStack(alignment: .leading, spacing: BSCSpacing.xs) {
            ZStack(alignment: .topTrailing) {
                PressToPlayThumbnail(
                    videoURL: item.url,
                    timeRange: item.timeRange,
                    onPreviewChanged: { player in
                        previewPlayer = player
                        previewName = player == nil ? nil : item.displayName
                        previewingID = player == nil ? nil : item.id
                    }
                )
                .aspectRatio(16/10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                .opacity(dimmed ? 0.35 : 1)

                // Selection badge: tap-order number, Instagram-style. Hidden
                // while previewing so it doesn't sit over the playing clip.
                Group {
                    if let order {
                        Text("\(order + 1)")
                            .bscFont(size: 14, weight: .bold, design: .monospaced)
                            .foregroundColor(.bscOnPrimary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.bscPrimary))
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 2)
                            .background(Circle().fill(Color.black.opacity(0.25)))
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(BSCSpacing.sm)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .opacity(isPreviewing ? 0 : 1)
                .animation(.bscQuick, value: isPreviewing)

                if item.isPosted {
                    Label("Posted", systemImage: "checkmark.circle.fill")
                        .bscFont(size: 11, weight: .semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, BSCSpacing.xs)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(BSCSpacing.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .opacity(isPreviewing ? 0 : 1)
                        .animation(.bscQuick, value: isPreviewing)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: BSCSpacing.xs) {
                Text(item.displayName)
                    .bscFont(size: 12, weight: .medium)
                    .foregroundColor(.bscTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(formatDuration(item.duration))
                    .bscFont(size: 11, design: .monospaced)
                    .foregroundColor(.bscTextSecondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .stroke(order != nil ? Color.bscPrimary : Color.clear, lineWidth: 2.5)
                .padding(-2)
        )
        .contentShape(Rectangle())
        // Tap selects; the hold gesture inside the thumbnail handles preview.
        .onTapGesture { toggle(item) }
        .animation(.bscQuick, value: order)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isPosted ? "\(item.displayName), already posted" : item.displayName)
        .accessibilityAddTraits(order != nil ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle(item) }
    }

    private func toggle(_ item: ClipPickerItem<Payload>) {
        if let index = selection.firstIndex(of: item.id) {
            selection.remove(at: index)
        } else if !atCapacity {
            selection.append(item.id)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
