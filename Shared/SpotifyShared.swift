import Foundation

/// Values from the Spotify developer dashboard. The client ID isn't a secret;
/// Vinyl uses PKCE, so there is no client secret anywhere in the app.
enum SpotifyConfig {
    static let clientID = "74488018efed4a05be59568ba4b2c1ab"
    static let callbackScheme = "vinyl-ios"
    static let redirectURI = "vinyl-ios://spotify-login-callback"
    static let scopes = [
        "user-read-playback-state",
        "user-read-currently-playing",
        "user-modify-playback-state",
        "user-library-read", // saved albums, for the Crate
    ]
}

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// Space-separated scopes Spotify granted. Nil for logins from before 1.1.
    var scope: String?
}

/// The Spotify login, kept in the shared keychain so the widgets can check
/// what's playing on their own.
enum SpotifyTokenStore {
    static func load() -> SpotifyTokens? {
        Keychain.read("spotify").flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
    }

    static func save(_ tokens: SpotifyTokens?) {
        if let tokens, let data = try? JSONEncoder().encode(tokens) {
            Keychain.write(data, for: "spotify")
        } else {
            Keychain.delete("spotify")
        }
    }

    /// A usable access token, refreshing (and saving) it first if needed.
    /// The widgets use this; the app has its own copy in `SpotifyAuth`, and
    /// both re-read the keychain first, so whichever refreshes, the other
    /// picks up the newest tokens.
    static func validAccessToken() async throws -> String {
        guard let tokens = load() else { throw URLError(.userAuthenticationRequired) }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": SpotifyConfig.clientID,
        ]
        request.httpBody = form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Reply: Decodable { let access_token: String?; let refresh_token: String?; let expires_in: Double?; let scope: String? }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let access = reply.access_token
        else { throw URLError(.userAuthenticationRequired) }
        let fresh = SpotifyTokens(
            accessToken: access,
            refreshToken: reply.refresh_token ?? tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(reply.expires_in ?? 3600),
            scope: reply.scope ?? tokens.scope
        )
        save(fresh)
        return access
    }
}
