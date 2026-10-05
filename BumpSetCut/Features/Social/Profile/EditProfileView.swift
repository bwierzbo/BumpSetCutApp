//
//  EditProfileView.swift
//  BumpSetCut
//
//  Edit the current user's profile fields.
//

import SwiftUI
import PhotosUI

struct EditProfileView: View {
    var onSaved: () -> Void = {}

    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = EditProfileViewModel()

    // Avatar state
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingAvatarImage: UIImage?
    @State private var showAvatarConfirm = false

    private var currentAvatarURL: URL? {
        authService.currentUser?.avatarURL
    }

    var body: some View {
        ZStack {
            Color.bscBackground.ignoresSafeArea()

            Form {
                // Avatar section
                Section {
                    HStack {
                        Spacer()
                        avatarSection
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Username") {
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(AccessibilityID.EditProfile.usernameField)
                }
                Section("Bio") {
                    TextField("Tell us about yourself", text: $viewModel.bio, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier(AccessibilityID.EditProfile.bioField)
                }
                Section("Team") {
                    TextField("Team name (optional)", text: $viewModel.teamName)
                        .accessibilityIdentifier(AccessibilityID.EditProfile.teamField)
                }

                playerInfoSections

                Section("Privacy") {
                    Picker("Profile visibility", selection: $viewModel.privacyLevel) {
                        ForEach(PrivacyLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.EditProfile.privacyPicker)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.bscErrorText)
                            .bscFont(size: 13)
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
                .disabled(!viewModel.canSave)
                .fontWeight(.semibold)
                .accessibilityIdentifier(AccessibilityID.EditProfile.saveButton)
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(from: item) }
        }
        .alert("Use this photo?", isPresented: $showAvatarConfirm) {
            Button("Use Photo") {
                viewModel.avatarImage = pendingAvatarImage
                pendingAvatarImage = nil
                // Clear the picker selection, or choosing the same photo again
                // later won't fire onChange and nothing will happen.
                selectedPhotoItem = nil
            }
            Button("Cancel", role: .cancel) {
                pendingAvatarImage = nil
                selectedPhotoItem = nil
            }
        } message: {
            Text("Set this as your new profile picture? It'll be saved when you tap Save.")
        }
        .onAppear {
            if let user = authService.currentUser {
                viewModel.populate(from: user)
            }
        }
        .task {
            guard let userId = authService.currentUser?.id,
                  let profile = await viewModel.confirmDetails(userId: userId) else { return }
            authService.updateLocalProfile(profile)
        }
    }

    // MARK: - Player Info Sections

    @ViewBuilder
    private var playerInfoSections: some View {
        Section("Plays") {
            ForEach(PlayType.allCases, id: \.self) { type in
                Toggle(type.displayName, isOn: Binding(
                    get: { viewModel.playTypes.contains(type) },
                    set: { isOn in
                        if isOn { viewModel.playTypes.insert(type) } else { viewModel.playTypes.remove(type) }
                    }
                ))
                .accessibilityIdentifier(AccessibilityID.EditProfile.playType(type))
            }
        }

        Section("Level") {
            Picker("Level", selection: $viewModel.level) {
                Text("Not set").tag(PlayLevel?.none)
                ForEach(PlayLevel.allCases, id: \.self) { value in
                    Text(value.displayName).tag(Optional(value))
                }
            }
            .accessibilityIdentifier(AccessibilityID.EditProfile.levelPicker)
        }

        Section {
            HStack(spacing: 0) {
                Picker("Feet", selection: $viewModel.heightFeet) {
                    Text(verbatim: "—").tag(Int?.none)
                    ForEach(4...7, id: \.self) { feet in
                        Text("\(feet) ft", comment: "Height picker: feet").tag(Optional(feet))
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AccessibilityID.EditProfile.heightFeetPicker)

                Picker("Inches", selection: $viewModel.heightInches) {
                    ForEach(0...11, id: \.self) { inches in
                        Text("\(inches) in", comment: "Height picker: inches").tag(inches)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                // Inches alone means nothing — feet drives whether a height is set.
                .disabled(viewModel.heightFeet == nil)
                .opacity(viewModel.heightFeet == nil ? 0.4 : 1)
                .accessibilityIdentifier(AccessibilityID.EditProfile.heightInchesPicker)
            }
            .frame(height: 110)
        } header: {
            Text("Height")
        } footer: {
            if let feet = viewModel.heightFeet {
                Text("Shown as \(feet)'\(viewModel.heightInches)\"")
            } else {
                Text("Optional")
            }
        }

        Section("Handedness") {
            Picker("Handedness", selection: $viewModel.handedness) {
                Text("Not set").tag(Handedness?.none)
                ForEach(Handedness.allCases, id: \.self) { value in
                    Text(value.displayName).tag(Optional(value))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityID.EditProfile.handednessPicker)
        }

        Section {
            Picker("Position", selection: $viewModel.indoorPosition) {
                Text("None").tag(IndoorPosition?.none)
                ForEach(IndoorPosition.allCases, id: \.self) { value in
                    Text(value.displayName).tag(Optional(value))
                }
            }
            .accessibilityIdentifier(AccessibilityID.EditProfile.positionPicker)
        } header: {
            Text("Position")
        } footer: {
            Text("Mostly for indoor.")
        }

        Section {
            HStack(spacing: BSCSpacing.xxs) {
                Text(verbatim: "@")
                    .foregroundColor(.bscTextSecondary)
                TextField("username", text: $viewModel.instagram)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier(AccessibilityID.EditProfile.instagramField)
            }
        } header: {
            Text("Instagram")
        } footer: {
            if !viewModel.instagramIsValid {
                Text("Handles can only use letters, numbers, periods and underscores.")
                    .foregroundColor(.bscErrorText)
            } else {
                Text("Pasting a full instagram.com link works too.")
            }
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        VStack(spacing: BSCSpacing.sm) {
            // Read here: PhotosPicker's label closure isn't main-actor
            // isolated, so it can't read this view's state itself.
            let preview = pendingAvatarImage ?? viewModel.avatarImage
            let url = currentAvatarURL
            let name = viewModel.username.isEmpty ? "?" : viewModel.username
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                EditableAvatar(preview: preview, url: url, name: name)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change profile photo")

            if viewModel.isUploadingAvatar {
                HStack(spacing: BSCSpacing.xs) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Uploading...")
                        .bscFont(size: 12)
                        .foregroundColor(.bscTextSecondary)
                }
            } else {
                Text("Tap to change photo")
                    .bscFont(size: 12)
                    .foregroundColor(.bscTextSecondary)
            }
        }
    }

    // MARK: - Actions

    private func loadPhoto(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            pendingAvatarImage = image
            showAvatarConfirm = true
        }
    }

    private func saveProfile() {
        Task {
            guard let updated = await viewModel.save(
                userId: authService.currentUser?.id,
                currentAvatarURL: currentAvatarURL
            ) else { return }
            authService.updateLocalProfile(updated)
            onSaved()
            dismiss()
        }
    }
}

// MARK: - Editable Avatar

/// The profile photo with a camera badge, as the photo picker's label.
private struct EditableAvatar: View {
    let preview: UIImage?
    let url: URL?
    let name: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 90, height: 90)
                    .clipShape(Circle())
            } else {
                AvatarView(url: url, name: name, size: 90)
            }

            // Camera badge
            Circle()
                .fill(Color.bscPrimaryFill)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "camera.fill")
                        .bscFont(size: 12, weight: .semibold)
                        .foregroundColor(.bscOnPrimary)
                )
                .offset(x: 2, y: 2)
        }
    }
}
