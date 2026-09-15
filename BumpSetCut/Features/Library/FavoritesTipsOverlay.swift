//
//  FavoritesTipsOverlay.swift
//  BumpSetCut
//
//  First-visit feature tour for the Favorites library: how rallies get here,
//  collections, and what folders/clips can do. Shown once (see
//  AppSettings.hasSeenFavoritesOnboarding); styled after GestureTipsOverlay.
//

import SwiftUI

struct FavoritesTipsOverlay: View {
    let onDismiss: () -> Void
    @State private var showingContent = false

    var body: some View {
        ZStack {
            Color.bscMediaScrimBase.opacity(0.9)
                .ignoresSafeArea()
                .opacity(showingContent ? 1 : 0)

            VStack(spacing: BSCSpacing.xl) {
                VStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "star.fill")
                        .bscFont(size: 40)
                        .foregroundColor(.bscPrimary)

                    Text("Favorite Rallies")
                        .bscFont(size: 28, weight: .bold)
                        .foregroundColor(.bscOnMedia)
                }
                .opacity(showingContent ? 1 : 0)
                .offset(y: showingContent ? 0 : -20)

                VStack(alignment: .leading, spacing: BSCSpacing.lg) {
                    tipRow(
                        icon: "arrow.up",
                        color: .bscPrimary,
                        title: "Swipe up to favorite",
                        detail: "In the rally player, swipe a rally up to save it here."
                    )
                    tipRow(
                        icon: "folder.fill.badge.plus",
                        color: .bscBlue,
                        title: "File into collections",
                        detail: "Tap Choose Folder on the toast to organize by weekend, team, or play."
                    )
                    tipRow(
                        icon: "hand.tap.fill",
                        color: .bscWarningText,
                        title: "Long-press a rally",
                        detail: "Rename, move, post it to the community, or save it to Photos."
                    )
                    tipRow(
                        icon: "square.stack.fill",
                        color: .bscSuccessText,
                        title: "Post a folder",
                        detail: "Share a collection as one post you swipe through rally by rally."
                    )
                    tipRow(
                        icon: "film.stack",
                        color: .bscTealText,
                        title: "Export a highlight video",
                        detail: "Stitch a collection into a single video saved to Photos."
                    )
                }
                .padding(BSCSpacing.xl)
                .background(
                    RoundedRectangle(cornerRadius: BSCRadius.xl, style: .continuous)
                        .fill(Color.bscMediaScrim)
                )
                .opacity(showingContent ? 1 : 0)
                .offset(y: showingContent ? 0 : 10)

                Text("Tap anywhere to continue")
                    .bscFont(size: 15)
                    .foregroundColor(.bscOnMediaSecondary)
                    .opacity(showingContent ? 1 : 0)
            }
            .padding(.horizontal, BSCSpacing.xl)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.bscQuick) {
                showingContent = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + BSCDuration.fast) {
                onDismiss()
            }
        }
        .onAppear {
            withAnimation(.bscSpring.delay(0.1)) {
                showingContent = true
            }
        }
        .accessibilityIdentifier(AccessibilityID.Favorites.tipsOverlay)
    }

    private func tipRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: BSCSpacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: BSCSpacing.xxs) {
                Text(title)
                    .bscFont(size: 15, weight: .bold)
                    .foregroundColor(.bscOnMedia)
                Text(detail)
                    .bscFont(size: 13)
                    .foregroundColor(.bscOnMediaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    FavoritesTipsOverlay(onDismiss: {})
}
