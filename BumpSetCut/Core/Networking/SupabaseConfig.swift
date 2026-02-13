import Foundation
import Supabase

// MARK: - Supabase Configuration

enum SupabaseConfig {

    // MARK: - Project Credentials (loaded from gitignored Secrets.swift)

    static let projectURL = URL(string: Secrets.supabaseURL)!
    static let anonKey = Secrets.supabaseAnonKey

    // MARK: - Shared Client

    static let client: SupabaseClient = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        return SupabaseClient(
            supabaseURL: projectURL,
            supabaseKey: anonKey,
            options: .init(
                db: .init(encoder: encoder, decoder: decoder),
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
