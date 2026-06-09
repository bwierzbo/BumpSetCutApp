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
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

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
