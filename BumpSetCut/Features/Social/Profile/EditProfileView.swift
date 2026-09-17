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

    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var teamName: String = ""
    @State private var privacyLevel: PrivacyLevel = .public
    @State private var isSaving = false
    @State private var errorMessage: String?

    // Player info
    @State private var playTypes: Set<PlayType> = []
    @State private var level: PlayLevel?
    @State private var handedness: Handedness?
    @State private var indoorPosition: IndoorPosition?
    @State private var heightFeet: Int?
    @State private var heightInches: Int = 0
    @State private var instagram: String = ""

    // Avatar state
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    @State private var pendingAvatarImage: UIImage?
    @State private var showAvatarConfirm = false
    @State private var isUploadingAvatar = false

    private var currentAvatarURL: URL? {
        authService.currentUser?.avatarURL
    }

    /// Whatever the user typed, reduced to a bare handle (nil when blank).
    private var normalizedInstagram: String? {
        PlayerInfo.normalizeInstagram(instagram)
    }

    /// Blank is fine; anything else has to match the column's CHECK.
    private var instagramIsValid: Bool {
        guard let handle = normalizedInstagram else { return true }
        return PlayerInfo.isValidInstagram(handle)
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
                        .accessibilityIdentifier(AccessibilityID.EditProfile.usernameField)
                }
                Section("Bio") {
                    TextField("Tell us about yourself", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier(AccessibilityID.EditProfile.bioField)
                }
                Section("Team") {
                    TextField("Team name (optional)", text: $teamName)
                        .accessibilityIdentifier(AccessibilityID.EditProfile.teamField)
                }

                playerInfoSections

                Section("Privacy") {
                    Picker("Profile visibility", selection: $privacyLevel) {
                        ForEach(PrivacyLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.EditProfile.privacyPicker)
                }

                if let errorMessage {
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
                .disabled(isSaving || isUploadingAvatar || username.isEmpty || !instagramIsValid)
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
                avatarImage = pendingAvatarImage
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
                username = user.username
                bio = user.bio ?? ""
                teamName = user.teamName ?? ""
                privacyLevel = user.privacyLevel

                if let details = user.details {
                    playTypes = Set(details.playTypes)
                    level = details.level
                    handedness = details.handedness
                    indoorPosition = details.indoorPosition
                    instagram = details.instagramHandle ?? ""
                    if let (feet, inches) = details.heightFeetInches {
                        heightFeet = feet
                        heightInches = inches
                    }
                }
            }
        }
    }

    // MARK: - Player Info Sections

    @ViewBuilder
    private var playerInfoSections: some View {
        Section("Plays") {
            ForEach(PlayType.allCases, id: \.self) { type in
                Toggle(type.displayName, isOn: Binding(
                    get: { playTypes.contains(type) },
                    set: { isOn in
                        if isOn { playTypes.insert(type) } else { playTypes.remove(type) }
                    }
                ))
                .accessibilityIdentifier(AccessibilityID.EditProfile.playType(type))
            }
        }

        Section("Level") {
            Picker("Level", selection: $level) {
                Text("Not set").tag(PlayLevel?.none)
                ForEach(PlayLevel.allCases, id: \.self) { value in
                    Text(value.displayName).tag(Optional(value))
                }
            }
            .accessibilityIdentifier(AccessibilityID.EditProfile.levelPicker)
        }

        Section {
            HStack(spacing: 0) {
                Picker("Feet", selection: $heightFeet) {
                    Text("—").tag(Int?.none)
                    ForEach(4...7, id: \.self) { feet in
                        Text("\(feet) ft").tag(Optional(feet))
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AccessibilityID.EditProfile.heightFeetPicker)

                Picker("Inches", selection: $heightInches) {
                    ForEach(0...11, id: \.self) { inches in
                        Text("\(inches) in").tag(inches)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                // Inches alone means nothing — feet drives whether a height is set.
                .disabled(heightFeet == nil)
                .opacity(heightFeet == nil ? 0.4 : 1)
                .accessibilityIdentifier(AccessibilityID.EditProfile.heightInchesPicker)
            }
            .frame(height: 110)
        } header: {
            Text("Height")
        } footer: {
            if let feet = heightFeet {
                Text("Shown as \(feet)'\(heightInches)\"")
            } else {
                Text("Optional")
            }
        }

        Section("Handedness") {
            Picker("Handedness", selection: $handedness) {
                Text("Not set").tag(Handedness?.none)
                ForEach(Handedness.allCases, id: \.self) { value in
                    Text(value.displayName).tag(Optional(value))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityID.EditProfile.handednessPicker)
        }

        Section {
            Picker("Position", selection: $indoorPosition) {
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
                Text("@")
                    .foregroundColor(.bscTextSecondary)
                TextField("username", text: $instagram)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier(AccessibilityID.EditProfile.instagramField)
            }
        } header: {
            Text("Instagram")
        } footer: {
            if !instagramIsValid {
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
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    if let preview = pendingAvatarImage ?? avatarImage {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 90, height: 90)
                            .clipShape(Circle())
                    } else {
                        AvatarView(url: currentAvatarURL, name: username.isEmpty ? "?" : username, size: 90)
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
            .buttonStyle(.plain)
            .accessibilityLabel("Change profile photo")

            if isUploadingAvatar {
                HStack(spacing: 6) {
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
        isSaving = true
        errorMessage = nil

        Task {
            do {
                var avatarURLString: String?

                // Upload avatar if user picked a new one
                if let image = avatarImage {
                    isUploadingAvatar = true
                    defer { isUploadingAvatar = false }
                    guard let jpegData = image.resizedForAvatar().jpegData(compressionQuality: 0.8) else {
                        throw APIError.invalidRequest("That image couldn't be prepared. Try a different photo.")
                    }
                    let url = try await SupabaseAPIClient.shared.uploadAvatar(
                        imageData: jpegData,
                        replacing: currentAvatarURL
                    )
                    avatarURLString = url.absoluteString
                }

                // Player info first: the profile update below re-reads the row
                // with its details embed, so the local cache lands consistent.
                if let userId = authService.currentUser?.id {
                    let info = PlayerInfo(
                        playTypes: PlayType.allCases.filter(playTypes.contains),
                        heightCm: heightFeet.map { PlayerInfo.cm(feet: $0, inches: heightInches) },
                        level: level,
                        handedness: handedness,
                        indoorPosition: indoorPosition,
                        instagramHandle: normalizedInstagram
                    )
                    let _: PlayerInfo = try await SupabaseAPIClient.shared.request(
                        .updateProfileDetails(PlayerInfoUpdate(userId: userId, info: info))
                    )
                }

                let update = UserProfileUpdate(
                    username: username,
                    bio: bio.isEmpty ? nil : bio,
                    teamName: teamName.isEmpty ? nil : teamName,
                    privacyLevel: privacyLevel,
                    avatarURL: avatarURLString
                )

                let updated: UserProfile = try await SupabaseAPIClient.shared.request(.updateProfile(update))
                authService.updateLocalProfile(updated)
                isSaving = false
                onSaved()
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
