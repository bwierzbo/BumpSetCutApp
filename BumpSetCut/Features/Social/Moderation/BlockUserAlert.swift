//
//  BlockUserAlert.swift
//  BumpSetCut
//
//  Confirmation alert for blocking users.
//

import SwiftUI

struct BlockUserAlert: ViewModifier {
    @Binding var isPresented: Bool
    let username: String
    let userId: UUID
    let onBlock: () async throws -> Void

    @State private var isBlocking = false
    @State private var errorMessage: String?
    @State private var showError = false

    func body(content: Content) -> some View {
        content
            .alert("Block @\(username)?", isPresented: $isPresented) {
                Button("Cancel", role: .cancel) {}

                Button("Block", role: .destructive) {
                    Task {
                        await blockUser()
                    }
                }
            } message: {
                Text("You won't see their posts or comments, and they won't be able to see yours.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Failed to block user")
            }
    }

    private func blockUser() async {
        isBlocking = true
        defer { isBlocking = false }

        do {
            try await onBlock()
            UIImpactFeedbackGenerator.medium()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

extension View {
    func blockUserAlert(
        isPresented: Binding<Bool>,
        username: String,
        userId: UUID,
        onBlock: @escaping () async throws -> Void
    ) -> some View {
        modifier(BlockUserAlert(
            isPresented: isPresented,
            username: username,
            userId: userId,
            onBlock: onBlock
        ))
    }
}
