//
//  EditProfileViewModel.swift
//  BumpSetCut
//
//  Form state and persistence for Edit Profile: profile fields, player info,
//  and the avatar upload.
//

import UIKit
import Observation

/// Uploads a profile photo, replacing (and cleaning up) the previous one.
protocol AvatarUploading: Sendable {
    func uploadAvatar(imageData: Data, replacing previous: URL?) async throws -> URL
}

extension SupabaseAPIClient: AvatarUploading {}

@MainActor
@Observable
final class EditProfileViewModel {
    var username = ""
    var bio = ""
    var teamName = ""
    var privacyLevel: PrivacyLevel = .public

    // Player info
    var playTypes: Set<PlayType> = []
    var level: PlayLevel?
    var handedness: Handedness?
    var indoorPosition: IndoorPosition?
    var heightFeet: Int?
    var heightInches = 0
    var instagram = ""

    /// A newly picked photo, uploaded on save.
    var avatarImage: UIImage?

    private(set) var isSaving = false
    private(set) var isUploadingAvatar = false
    private(set) var errorMessage: String?

    /// True once we've read the player-info row from a source that can tell
    /// "no values set" apart from "not loaded". Saving sends explicit nulls so
    /// fields can be cleared, so an unloaded form must never be saved.
    private(set) var detailsLoaded = false

    private let apiClient: any APIClient
    private let avatarUploader: any AvatarUploading

    init(apiClient: (any APIClient)? = nil, avatarUploader: (any AvatarUploading)? = nil) {
        self.apiClient = apiClient ?? SupabaseAPIClient.shared
        self.avatarUploader = avatarUploader ?? SupabaseAPIClient.shared
    }

    /// Whatever the user typed, reduced to a bare handle (nil when blank).
    var normalizedInstagram: String? {
        PlayerInfo.normalizeInstagram(instagram)
    }

    /// Blank is fine; anything else has to match the column's CHECK.
    var instagramIsValid: Bool {
        guard let handle = normalizedInstagram else { return true }
        return PlayerInfo.isValidInstagram(handle)
    }

    var canSave: Bool {
        !isSaving && !isUploadingAvatar && !username.isEmpty && instagramIsValid
    }

    // MARK: - Loading

    /// Fill the form from the cached profile.
    func populate(from user: UserProfile) {
        username = user.username
        bio = user.bio ?? ""
        teamName = user.teamName ?? ""
        privacyLevel = user.privacyLevel
        if let details = user.details {
            apply(details)
        }
    }

    /// The cached profile can predate the player-info embed (or an older build
    /// that never fetched it). Confirm against the server before letting Save
    /// write nulls over fields we never showed. Returns the fresh profile.
    func confirmDetails(userId: String) async -> UserProfile? {
        guard !detailsLoaded,
              let profile: UserProfile = try? await apiClient.request(.getProfile(userId: userId))
        else { return nil }
        // A nil embed from a successful read genuinely means "nothing set" —
        // record that without touching fields the user may already be editing.
        if let details = profile.details {
            apply(details)
        } else {
            detailsLoaded = true
        }
        return profile
    }

    private func apply(_ details: PlayerInfo) {
        playTypes = Set(details.playTypes)
        level = details.level
        handedness = details.handedness
        indoorPosition = details.indoorPosition
        instagram = details.instagramHandle ?? ""
        if let (feet, inches) = details.heightFeetInches {
            heightFeet = feet
            heightInches = inches
        }
        detailsLoaded = true
    }

    // MARK: - Saving

    /// Upload the avatar (if changed), player info, then the profile. Returns
    /// the updated profile, or nil with `errorMessage` set.
    func save(userId: String?, currentAvatarURL: URL?) async -> UserProfile? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            var avatarURLString: String?
            if let image = avatarImage {
                isUploadingAvatar = true
                defer { isUploadingAvatar = false }
                guard let jpegData = image.resizedForAvatar().jpegData(compressionQuality: 0.8) else {
                    throw APIError.invalidRequest("That image couldn't be prepared. Try a different photo.")
                }
                let url = try await avatarUploader.uploadAvatar(imageData: jpegData, replacing: currentAvatarURL)
                avatarURLString = url.absoluteString
            }

            // Player info first: the profile update below re-reads the row
            // with its details embed, so the local cache lands consistent.
            // Skipped when the form never loaded the existing values —
            // PlayerInfoUpdate encodes nils as explicit nulls, so saving an
            // unloaded form would wipe every field instead of leaving them.
            if detailsLoaded, let userId {
                let info = PlayerInfo(
                    playTypes: PlayType.allCases.filter(playTypes.contains),
                    heightCm: heightFeet.map { PlayerInfo.cm(feet: $0, inches: heightInches) },
                    level: level,
                    handedness: handedness,
                    indoorPosition: indoorPosition,
                    instagramHandle: normalizedInstagram
                )
                let _: PlayerInfo = try await apiClient.request(
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
            let updated: UserProfile = try await apiClient.request(.updateProfile(update))
            return updated
        } catch {
            errorMessage = error.localizedDescription
            return nil
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
