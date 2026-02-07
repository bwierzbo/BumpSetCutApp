//
//  EditProfileView.swift
//  BumpSetCut
//
//  Edit the current user's profile fields.
//

import SwiftUI

struct EditProfileView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var teamName: String = ""
    @State private var privacyLevel: PrivacyLevel = .public
    @State private var isSaving = false

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            Form {
                Section("Display Name") {
                    TextField("Display Name", text: $displayName)
                }
                Section("Username") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Bio") {
                    TextField("Tell us about yourself", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Team") {
                    TextField("Team name (optional)", text: $teamName)
                }
                Section("Privacy") {
                    Picker("Profile visibility", selection: $privacyLevel) {
                        ForEach(PrivacyLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveProfile()
                }
                .disabled(isSaving || displayName.isEmpty || username.isEmpty)
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            if let user = authService.currentUser {
                displayName = user.displayName
                username = user.username
                bio = user.bio ?? ""
                teamName = user.teamName ?? ""
                privacyLevel = user.privacyLevel
            }
        }
        .preferredColorScheme(.dark)
    }

    private func saveProfile() {
        isSaving = true
        // TODO: Call API to update profile
        // For now, update locally
        dismiss()
    }
}
