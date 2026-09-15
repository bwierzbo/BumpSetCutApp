//
//  BlockedUsersView.swift
//  BumpSetCut
//
//  Settings screen for reviewing and undoing user blocks — without this,
//  unblocking would be impossible in the app.
//

import SwiftUI

struct BlockedUsersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var moderationService = ModerationService.shared
    @State private var profiles: [UserProfile] = []
    @State private var isLoading = true
    @State private var unblockError: String?

    private let apiClient: any APIClient = SupabaseAPIClient.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bscBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                } else if profiles.isEmpty {
                    BSCEmptyState(
                        icon: "hand.raised",
                        title: "No Blocked Users",
                        message: "People you block will appear here."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: BSCSpacing.sm) {
                            ForEach(profiles, id: \.id) { profile in
                                blockedRow(profile)
                            }
                        }
                        .padding(BSCSpacing.lg)
                    }
                }
            }
            .navigationTitle("Blocked Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.bscPrimaryText)
                }
            }
            .alert("Couldn't Unblock", isPresented: Binding(
                get: { unblockError != nil },
                set: { if !$0 { unblockError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(unblockError ?? "")
            }
            .task {
                await loadProfiles()
            }
        }
    }

    private func blockedRow(_ profile: UserProfile) -> some View {
        HStack(spacing: BSCSpacing.md) {
            AvatarView(url: profile.avatarURL, name: profile.username, size: 40)

            Text("@\(profile.username)")
                .bscFont(size: 16, weight: .medium)
                .foregroundColor(.bscTextPrimary)

            Spacer()

            Button {
                Task { await unblock(profile) }
            } label: {
                Text("Unblock")
                    .bscFont(size: 14, weight: .semibold)
                    .foregroundColor(.bscPrimaryText)
                    .padding(.horizontal, BSCSpacing.md)
                    .padding(.vertical, BSCSpacing.xs)
                    .background(Capsule().fill(Color.bscPrimary.opacity(0.15)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(BSCSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous)
                .fill(Color.bscSurfaceGlass)
        )
    }

    private func loadProfiles() async {
        await moderationService.ensureBlocksLoaded()
        var loaded: [UserProfile] = []
        for userId in moderationService.blockedUserIds {
            if let profile: UserProfile = try? await apiClient.request(.getProfile(userId: userId.uuidString.lowercased())) {
                loaded.append(profile)
            }
        }
        profiles = loaded.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
        isLoading = false
    }

    private func unblock(_ profile: UserProfile) async {
        do {
            guard let userId = UUID(uuidString: profile.id) else { return }
            try await moderationService.unblockUser(userId)
            profiles.removeAll { $0.id == profile.id }
        } catch {
            unblockError = error.localizedDescription
        }
    }
}
