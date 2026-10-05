//
//  DeleteAccountConfirmationView.swift
//  BumpSetCut
//
//  Type-your-username confirmation before deleting the account.
//

import SwiftUI

// MARK: - Delete Account Confirmation

/// Requires the user to type their exact username before the destructive action
/// is enabled — guards against accidental account deletion.
struct DeleteAccountConfirmationView: View {
    let username: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var matches: Bool {
        !username.isEmpty && typed.trimmingCharacters(in: .whitespacesAndNewlines) == username
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: BSCSpacing.lg) {
                ZStack {
                    Circle()
                        .fill(Color.bscError.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .bscFont(size: 28)
                        .foregroundColor(.bscErrorText)
                }
                .padding(.top, BSCSpacing.xl)

                Text("Delete Account")
                    .bscFont(size: 22, weight: .bold)
                    .foregroundColor(.bscTextPrimary)

                Text("This permanently deletes your account and all associated data. This cannot be undone.")
                    .bscFont(size: 15)
                    .foregroundColor(.bscTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BSCSpacing.lg)

                VStack(alignment: .leading, spacing: BSCSpacing.xs) {
                    Text("Type \(Text(verbatim: username).fontWeight(.bold).foregroundColor(.bscTextPrimary)) to confirm",
                         comment: "Delete-account confirmation; the argument is the user's username, shown bold")
                        .foregroundColor(.bscTextSecondary)
                        .bscFont(size: 13)

                    TextField("Username", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.done)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, BSCSpacing.lg)
                .padding(.top, BSCSpacing.sm)

                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text("Delete Account")
                        .bscFont(size: 16, weight: .semibold)
                        .foregroundColor(.bscOnPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: BSCTouchTarget.standard)
                        .background(matches ? Color.bscErrorFill : Color.bscErrorFill.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: BSCRadius.md, style: .continuous))
                }
                .disabled(!matches)
                .padding(.horizontal, BSCSpacing.lg)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bscBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
