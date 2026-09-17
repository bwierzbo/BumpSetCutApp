//
//  PlayerInfo.swift
//  BumpSetCut
//
//  The volleyball half of a profile: where someone plays, how they play, and
//  how to find them. Lives in the `profile_details` table rather than on
//  `profiles` because profiles are world-readable (so search and follow work)
//  while this is gated by the owner's privacy level.
//

import Foundation

// MARK: - Field Enums

enum PlayType: String, Codable, CaseIterable, Hashable {
    case grass, beach, indoor

    var displayName: String { rawValue.capitalized }

    var iconName: String {
        switch self {
        case .grass: return "leaf.fill"
        case .beach: return "sun.max.fill"
        case .indoor: return "building.2.fill"
        }
    }
}

/// Competitive rating, lowest to highest.
enum PlayLevel: String, Codable, CaseIterable, Hashable {
    case b, bb, a, aa, aaa, open

    var displayName: String { self == .open ? "Open" : rawValue.uppercased() }
}

enum Handedness: String, Codable, CaseIterable, Hashable {
    case left, right

    var displayName: String { rawValue.capitalized }
}

/// Indoor court position. Optional — it means little for beach or grass.
enum IndoorPosition: String, Codable, CaseIterable, Hashable {
    case outside, opposite, middle, setter, libero

    var displayName: String { rawValue.capitalized }
}

// MARK: - Player Info

struct PlayerInfo: Codable, Hashable {
    var playTypes: [PlayType]
    /// Canonical storage is centimetres; the editor works in feet/inches.
    var heightCm: Int?
    var level: PlayLevel?
    var handedness: Handedness?
    var indoorPosition: IndoorPosition?
    /// Bare handle, no "@" and no URL — see `normalizeInstagram`.
    var instagramHandle: String?

    init(playTypes: [PlayType] = [], heightCm: Int? = nil, level: PlayLevel? = nil,
         handedness: Handedness? = nil, indoorPosition: IndoorPosition? = nil,
         instagramHandle: String? = nil) {
        self.playTypes = playTypes
        self.heightCm = heightCm
        self.level = level
        self.handedness = handedness
        self.indoorPosition = indoorPosition
        self.instagramHandle = instagramHandle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is optional so a half-filled row still decodes.
        playTypes = try container.decodeIfPresent([PlayType].self, forKey: .playTypes) ?? []
        heightCm = try container.decodeIfPresent(Int.self, forKey: .heightCm)
        level = try container.decodeIfPresent(PlayLevel.self, forKey: .level)
        handedness = try container.decodeIfPresent(Handedness.self, forKey: .handedness)
        indoorPosition = try container.decodeIfPresent(IndoorPosition.self, forKey: .indoorPosition)
        instagramHandle = try container.decodeIfPresent(String.self, forKey: .instagramHandle)
    }

    // Plain camelCase: the Supabase decoder's `.convertFromSnakeCase` maps
    // play_types/height_cm/indoor_position/instagram_handle. No acronyms here,
    // so nothing needs pinning (unlike UserProfile.avatarURL).
    private enum CodingKeys: String, CodingKey {
        case playTypes, heightCm, level, handedness, indoorPosition, instagramHandle
    }

    // MARK: - Derived

    var isEmpty: Bool {
        playTypes.isEmpty && heightCm == nil && level == nil
            && handedness == nil && indoorPosition == nil
            && (instagramHandle?.isEmpty ?? true)
    }

    var heightFeetInches: (feet: Int, inches: Int)? {
        guard let heightCm else { return nil }
        let totalInches = Int((Double(heightCm) / 2.54).rounded())
        return (totalInches / 12, totalInches % 12)
    }

    /// e.g. `5'11"`.
    var heightDisplay: String? {
        guard let (feet, inches) = heightFeetInches else { return nil }
        return "\(feet)'\(inches)\""
    }

    var instagramURL: URL? {
        guard let handle = instagramHandle, !handle.isEmpty else { return nil }
        return URL(string: "https://instagram.com/\(handle)")
    }

    // MARK: - Conversion & Validation

    static func cm(feet: Int, inches: Int) -> Int {
        Int((Double(feet * 12 + inches) * 2.54).rounded())
    }

    /// Accepts what people actually paste — `@handle`, a full profile URL, or
    /// the bare handle — and returns the bare handle (nil when empty).
    static func normalizeInstagram(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["https://www.instagram.com/", "http://www.instagram.com/",
                       "https://instagram.com/", "http://instagram.com/",
                       "www.instagram.com/", "instagram.com/"]
        where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }

        while value.hasPrefix("@") { value = String(value.dropFirst()) }
        // Drop any path or query left over from a pasted link.
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Matches the CHECK constraint on `profile_details.instagram_handle`.
    static func isValidInstagram(_ handle: String) -> Bool {
        handle.range(of: "^[A-Za-z0-9._]{1,30}$", options: .regularExpression) != nil
    }
}
