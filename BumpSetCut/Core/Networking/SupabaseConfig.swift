import Foundation
import Supabase

// MARK: - Supabase Configuration

enum SupabaseConfig {

    // MARK: - Project Credentials
    // Replace with your Supabase project URL and anon key
    static let projectURL = URL(string: "https://nodxhfrdefmaksisuylb.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5vZHhoZnJkZWZtYWtzaXN1eWxiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA0MTUzMTksImV4cCI6MjA4NTk5MTMxOX0.mDkABYzOV3NJzgCeFbicUEkG7JTPGr2h_DvGfV8Fi9c"

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
                    autoRefreshToken: true
                ),
                global: .init(logger: nil)
            )
        )
    }()
}
