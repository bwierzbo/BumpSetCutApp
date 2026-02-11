//
//  EditProfileView.swift
//  BumpSetCut
//
//  Edit the current user's profile fields.
//

import SwiftUI
import PhotosUI

struct EditProfileView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var teamName: String = ""
    @State private var privacyLevel: PrivacyLevel = .public
    @State private var isSaving = false
    @State private var errorMessage: String?

    // Avatar state
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    @State private var isUploadingAvatar = false

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

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.system(size: 13))
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
                .disabled(isSaving || isUploadingAvatar || username.isEmpty)
                .fontWeight(.semibold)
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(from: item) }
        }
        .onAppear {
            if let user = authService.currentUser {
                username = user.username
                bio = user.bio ?? ""
                teamName = user.teamName ?? ""
                privacyLevel = user.privacyLevel
            }
        }
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        VStack(spacing: BSCSpacing.sm) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    if let avatarImage {
                        Image(uiImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 90, height: 90)
                            .clipShape(Circle())
                    } else {
                        AvatarView(url: currentAvatarURL, name: username.isEmpty ? "?" : username, size: 90)
                    }

                    // Camera badge
                    Circle()
                        .fill(Color.bscOrange)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        )
                        .offset(x: 2, y: 2)
                }
            }
            .buttonStyle(.plain)

            if isUploadingAvatar {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Uploading...")
                        .font(.system(size: 12))
                        .foregroundColor(.bscTextSecondary)
                }
            } else {
                Text("Tap to change photo")
                    .font(.system(size: 12))
                    .foregroundColor(.bscTextTertiary)
            }
        }
    }

    // MARK: - Actions

    private func loadPhoto(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            avatarImage = image
        }
    }

    private func saveProfile() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                var avatarURLString: String?

                // Upload avatar if user picked a new one
                if let image = avatarImage {
                    isUploadingAvatar = true
                    let jpegData = image.resizedForAvatar().jpegData(compressionQuality: 0.8)!
                    let url = try await SupabaseAPIClient.shared.uploadAvatar(imageData: jpegData)
                    avatarURLString = url.absoluteString
                    isUploadingAvatar = false
                }

                let update = UserProfileUpdate(
                    username: username,
                    bio: bio.isEmpty ? nil : bio,
                    teamName: teamName.isEmpty ? nil : teamName,
                    privacyLevel: privacyLevel,
                    avatarURL: avatarURLString
                )

                let updated: UserProfile = try await SupabaseAPIClient.shared.request(.updateProfile(update))
                await authService.updateLocalProfile(updated)
                dismiss()
            } catch {
                isUploadingAvatar = false
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - UIImage Resize

private extension UIImage {
    func resizedForAvatar(maxDimension: CGFloat = 400) -> UIImage {
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        guard ratio < 1 else { return self }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
