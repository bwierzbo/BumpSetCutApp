//
//  ClipPickerSheet.swift
//  BumpSetCut
//
//  Choose which favorites clips go into a multi-rally community post when a
//  folder holds more than the per-post maximum. Tap to toggle; selection
//  order is kept (badge numbers show post order).
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

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    Text("This folder has \(clips.count) rallies — a post can hold up to \(maxSelection). Tap the ones to include.")
                        .bscFont(size: 13)
                        .foregroundColor(.bscTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, BSCSpacing.xl)
                        .padding(.vertical, BSCSpacing.sm)

                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: BSCSpacing.xs), count: 3),
                            spacing: BSCSpacing.xs
                        ) {
                            ForEach(clips) { clip in
                                clipCell(clip)
                            }
                        }
                        .padding(BSCSpacing.md)
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
                    Text("\(selection.count)/\(maxSelection)")
                        .bscFont(size: 14, weight: .semibold, design: .monospaced)
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
    }

    private func clipCell(_ clip: FavoriteShareClip) -> some View {
        let order = selection.firstIndex(of: clip.id)

        return Button {
            toggle(clip)
        } label: {
            ZStack(alignment: .topTrailing) {
                VideoThumbnailView(thumbnailURL: nil, videoURL: clip.url)
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous))
                    .opacity(order != nil || selection.count < maxSelection ? 1 : 0.4)

                if let order {
                    Text("\(order + 1)")
                        .bscFont(size: 13, weight: .bold, design: .monospaced)
                        .foregroundColor(.bscOnPrimary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.bscPrimary))
                        .padding(BSCSpacing.xs)
                } else {
                    Circle()
                        .stroke(Color.bscOnMedia.opacity(0.8), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                        .padding(BSCSpacing.xs)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: BSCRadius.sm, style: .continuous)
                    .stroke(order != nil ? Color.bscPrimary : Color.clear, lineWidth: 2.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clip.displayName)
        .accessibilityAddTraits(order != nil ? .isSelected : [])
    }

    private func toggle(_ clip: FavoriteShareClip) {
        if let index = selection.firstIndex(of: clip.id) {
            selection.remove(at: index)
        } else if selection.count < maxSelection {
            selection.append(clip.id)
        }
    }
}
