import Foundation
import Supabase

// MARK: - Supabase Configuration

enum SupabaseConfig {

    // MARK: - Project Credentials (loaded from gitignored Secrets.swift)

    static let projectURL = URL(string: Secrets.supabaseURL)!
    static let anonKey = Secrets.supabaseAnonKey

    // MARK: - Coders

    /// The encoder used for all PostgREST writes. Exposed so tests can round-trip
    /// models through the *exact* production configuration (snake_case + ISO8601).
    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The decoder used for all PostgREST reads. Exposed so tests can assert
    /// every model decodes from real snake_case payloads (catches acronym drift).
    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Postgres timestamps carry microseconds ("…04:10:02.891959+00:00"),
        // which plain .iso8601 rejects before iOS 26.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? Date(text, strategy: fractionalISO8601)) ?? (try? Date(text, strategy: .iso8601)) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO8601 date, got \(text)")
        }
        return decoder
    }

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    // MARK: - Shared Client

    static let client: SupabaseClient = {
        return SupabaseClient(
            supabaseURL: projectURL,
            supabaseKey: anonKey,
            options: .init(
                db: .init(encoder: jsonEncoder, decoder: jsonDecoder),
                auth: .init(
                    redirectToURL: URL(string: "bumpsetcut://auth-callback"),
                    autoRefreshToken: true,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(logger: nil)
            )
        )
    }()
}
