//
//  ClipPickerSheet.swift
//  BumpSetCut
//
//  Choose which favorites clips go into a multi-rally community post.
//  Instagram-style multi-select: distinct cells, numbered badges in tap
//  order (which is the post order), Select All when everything fits.
//

import SwiftUI

struct ClipPickerSheet: View {
    let title: String
    let clips: [FavoriteShareClip]
    let maxSelection: Int
    let onConfirm: ([FavoriteShareClip]) -> Void
    let onCancel: () -> Void

    /// Selected clip ids in tap order — order in the post follows it.
    @State private var selection: [UUID] = []

    private var canSelectAll: Bool { clips.count <= maxSelection }
    private var atCapacity: Bool { selection.count >= maxSelection }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    if clips.count > maxSelection {
                        Text("This folder has \(clips.count) rallies — a post can hold up to \(maxSelection). Tap rallies in the order they should appear.")
                            .bscFont(size: 13)
                            .foregroundColor(.bscTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, BSCSpacing.xl)
                            .padding(.vertical, BSCSpacing.sm)
                    }

                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.md), count: 2),
                            spacing: BSCSpacing.md
                        ) {
                            ForEach(clips) { clip in
                                clipCell(clip)
                            }
                        }
                        .padding(BSCSpacing.lg)
                    }

                    Button {
                        onConfirm(selection.compactMap { id in clips.first { $0.id == id } })
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
            }
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
                            Button(selection.count == clips.count ? "Deselect All" : "Select All") {
                                if selection.count == clips.count {
                                    selection = []
                                } else {
                                    selection = clips.map(\.id)
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

    private func clipCell(_ clip: FavoriteShareClip) -> some View {
        let order = selection.firstIndex(of: clip.id)
        let dimmed = order == nil && atCapacity

        return Button {
            toggle(clip)
        } label: {
            VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                ZStack(alignment: .topTrailing) {
                    // Thumbnail clipped to its own cell — fill without clipping
                    // smeared neighboring cells together (tester bug).
                    GeometryReader { geo in
                        VideoThumbnailView(thumbnailURL: nil, videoURL: clip.url)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    .aspectRatio(16/10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                    .opacity(dimmed ? 0.35 : 1)

                    // Selection badge: tap-order number, Instagram-style
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
                }

                HStack(spacing: BSCSpacing.xs) {
                    Text(clip.displayName)
                        .bscFont(size: 12, weight: .medium)
                        .foregroundColor(.bscTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(formatDuration(clip.duration))
                        .bscFont(size: 11, design: .monospaced)
                        .foregroundColor(.bscTextSecondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                    .stroke(order != nil ? Color.bscPrimary : Color.clear, lineWidth: 2.5)
                    .padding(-2)
            )
        }
        .buttonStyle(.plain)
        .animation(.bscQuick, value: order)
        .accessibilityLabel(clip.displayName)
        .accessibilityAddTraits(order != nil ? .isSelected : [])
    }

    private func toggle(_ clip: FavoriteShareClip) {
        if let index = selection.firstIndex(of: clip.id) {
            selection.remove(at: index)
        } else if !atCapacity {
            selection.append(clip.id)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
