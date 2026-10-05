//
//  BlockUserAlert.swift
//  BumpSetCut
//
//  The one confirm-then-block flow for every Block action (posts, comments,
//  profiles, threads).
//

import SwiftUI

/// Who a Block action targets. Failable so a malformed id can never turn into
/// a block on some random UUID.
struct BlockTarget: Identifiable, Equatable {
    let id: UUID
    let username: String

    init?(userId: String, username: String?) {
        guard let uuid = UUID(uuidString: userId) else { return nil }
        self.id = uuid
        self.username = username ?? "user"
    }
}

private struct BlockUserAlert: ViewModifier {
    @Binding var target: BlockTarget?
    let onBlocked: () -> Void

    /// Survives the binding clearing as the alert dismisses, so the title
    /// doesn't flicker while it animates out.
    @State private var shownTarget: BlockTarget?
    /// A failed block is a transient failure of the user's action → error toast.
    @State private var failureToast: BSCToastMessage?

    private var current: BlockTarget? { target ?? shownTarget }

    func body(content: Content) -> some View {
        content
            .onChange(of: target) { _, newValue in
                if let newValue { shownTarget = newValue }
            }
            .alert(
                (current?.username).map { Text("Block @\($0)?") } ?? Text("Block user?"),
                isPresented: Binding(
                    get: { target != nil },
                    set: { if !$0 { target = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {}
                if let blocked = current {
                    Button("Block", role: .destructive) {
                        Task { await block(blocked) }
                    }
                }
            } message: {
                Text("You won't see their posts or comments, and they won't be able to see yours.")
            }
            .bscToast($failureToast)
    }

    private func block(_ blocked: BlockTarget) async {
        do {
            try await ModerationService.shared.blockUser(blocked.id)
            UIImpactFeedbackGenerator.medium()
            onBlocked()
        } catch {
            failureToast = BSCToastMessage(text: "Couldn't block @\(blocked.username). Check your connection.", style: .error)
        }
    }
}

extension View {
    /// Confirms, then blocks `target`. `onBlocked` runs only on success.
    func blockUserAlert(target: Binding<BlockTarget?>, onBlocked: @escaping () -> Void = {}) -> some View {
        modifier(BlockUserAlert(target: target, onBlocked: onBlocked))
    }
}
