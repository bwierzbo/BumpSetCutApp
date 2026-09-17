//
//  PlayerInfoCard.swift
//  BumpSetCut
//
//  The volleyball card on a profile: where they play, level, height, hand,
//  position, Instagram. Hidden behind a lock on a private profile until you
//  follow them.
//

import SwiftUI

struct PlayerInfoCard<AddDestination: View>: View {
    let state: ProfileViewModel.PlayerInfoState
    let isOwnProfile: Bool
    /// Where "Add your player info" goes. A NavigationLink closure, not a
    /// stack-scoped `navigationDestination`: a profile can be pushed on top of
    /// another profile (via a follower list), and two stack-scoped destinations
    /// in one NavigationStack fight — the second push bounces straight back.
    @ViewBuilder var addDestination: () -> AddDestination

    var body: some View {
        switch state {
        case .visible(let info):
            infoCard(info)
        case .locked:
            lockedCard
        case .empty:
            if isOwnProfile { addPrompt }
        }
    }

    // MARK: - Filled In

    private func infoCard(_ info: PlayerInfo) -> some View {
        BSCCard(style: .glass) {
            VStack(alignment: .leading, spacing: BSCSpacing.md) {
                Text("Player Info")
                    .bscFont(size: 15, weight: .semibold)
                    .foregroundColor(.bscTextPrimary)

                if !info.playTypes.isEmpty {
                    FlowLayout(spacing: BSCSpacing.xs) {
                        ForEach(info.playTypes, id: \.self) { PlayTypeChip(type: $0) }
                    }
                }

                VStack(spacing: BSCSpacing.xs) {
                    if let level = info.level {
                        infoRow(label: "Level", value: level.displayName, icon: "rosette")
                    }
                    if let height = info.heightDisplay {
                        infoRow(label: "Height", value: height, icon: "ruler")
                    }
                    if let hand = info.handedness {
                        infoRow(label: "Hand", value: hand.displayName, icon: "hand.raised")
                    }
                    if let position = info.indoorPosition {
                        infoRow(label: "Position", value: position.displayName, icon: "figure.volleyball")
                    }
                }

                if let url = info.instagramURL, let handle = info.instagramHandle {
                    Link(destination: url) {
                        Label("@\(handle)", systemImage: "camera")
                            .bscFont(size: 14, weight: .medium)
                            .foregroundColor(.bscPrimaryText)
                            .frame(minHeight: BSCTouchTarget.standard, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(AccessibilityID.Profile.instagramLink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(AccessibilityID.Profile.playerInfoCard)
    }

    private func infoRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: BSCSpacing.sm) {
            Image(systemName: icon)
                .bscFont(size: 13)
                .foregroundColor(.bscTextSecondary)
                .frame(width: BSCIconSize.sm)

            Text(label)
                .bscFont(size: 13)
                .foregroundColor(.bscTextSecondary)

            Spacer(minLength: BSCSpacing.sm)

            Text(value)
                .bscFont(size: 14, weight: .medium)
                .foregroundColor(.bscTextPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    // MARK: - Locked

    private var lockedCard: some View {
        BSCCard(style: .glass) {
            HStack(spacing: BSCSpacing.sm) {
                Image(systemName: "lock.fill")
                    .bscFont(size: 14)
                    .foregroundColor(.bscTextSecondary)

                Text("Player info is visible to followers")
                    .bscFont(size: 13)
                    .foregroundColor(.bscTextSecondary)

                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Profile.playerInfoLocked)
    }

    // MARK: - Empty (own profile)

    private var addPrompt: some View {
        NavigationLink { addDestination() } label: {
            BSCCard(style: .glass) {
                HStack(spacing: BSCSpacing.sm) {
                    Image(systemName: "plus.circle")
                        .bscFont(size: 15)
                        .foregroundColor(.bscPrimaryText)

                    Text("Add your player info")
                        .bscFont(size: 14, weight: .medium)
                        .foregroundColor(.bscPrimaryText)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Profile.addPlayerInfo)
    }
}

// MARK: - Play Type Chip

/// Small capsule for a play surface. `compact` drops the icon for dense rows
/// like search results.
struct PlayTypeChip: View {
    let type: PlayType
    var compact: Bool = false

    var body: some View {
        HStack(spacing: BSCSpacing.xxs) {
            if !compact {
                Image(systemName: type.iconName)
                    .bscFont(size: 10)
            }
            Text(type.displayName)
                .bscFont(size: compact ? 11 : 12, weight: .medium)
        }
        .foregroundColor(.bscTextPrimary)
        .padding(.horizontal, compact ? BSCSpacing.sm : BSCSpacing.md)
        .padding(.vertical, compact ? 3 : BSCSpacing.xs)
        .background(Capsule().fill(Color.bscSurfaceGlass))
        .overlay(Capsule().stroke(Color.bscSurfaceBorder, lineWidth: 1))
    }
}

// MARK: - Level Badge

struct LevelBadge: View {
    let level: PlayLevel

    var body: some View {
        Text(level.displayName)
            .bscFont(size: 11, weight: .bold)
            .foregroundColor(.bscOnPrimary)
            .padding(.horizontal, BSCSpacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.bscPrimaryFill))
            .accessibilityLabel("Level \(level.displayName)")
    }
}
