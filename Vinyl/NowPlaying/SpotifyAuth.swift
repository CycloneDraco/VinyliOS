import AuthenticationServices
import CryptoKit
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

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
    ]
}

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum SpotifyAuthError: LocalizedError {
    case cancelled
    case denied(String)
    case badResponse(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .denied(let reason): return "Spotify didn't allow the connection (\(reason))."
        case .badResponse(let detail): return "Spotify sign-in failed: \(detail)"
        case .notConnected: return "Spotify isn't connected."
        }
    }
}

/// Spotify login (Authorization Code with PKCE) and token refresh.
@MainActor
final class SpotifyAuth: NSObject, ObservableObject {
    static let shared = SpotifyAuth()

    @Published private(set) var isConnected = false
    @Published var accountName: String? {
        didSet { UserDefaults.standard.set(accountName, forKey: "spotifyAccountName") }
    }
    @Published var lastError: String?

    private var tokens: SpotifyTokens? {
        didSet {
            isConnected = tokens != nil
            if let tokens, let data = try? JSONEncoder().encode(tokens) {
                Keychain.write(data, for: "spotify")
            } else {
                Keychain.delete("spotify")
            }
        }
    }
    private var refreshTask: Task<String, Error>?
    private var session: ASWebAuthenticationSession?
    private let log = Logger(subsystem: "io.github.cyclonedraco.vinyl.ios", category: "SpotifyAuth")

    private override init() {
        super.init()
        if let data = Keychain.read("spotify"), let saved = try? JSONDecoder().decode(SpotifyTokens.self, from: data) {
            tokens = saved
        }
        accountName = UserDefaults.standard.string(forKey: "spotifyAccountName")
    }

    // MARK: Login

    func connect() async {
        lastError = nil
        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: SpotifyConfig.scopes.joined(separator: " ")),
        ]
        do {
            let callback = try await authenticate(url: components.url!)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if let error = value("error") { throw SpotifyAuthError.denied(error) }
            guard value("state") == state, let code = value("code") else {
                throw SpotifyAuthError.badResponse("the reply didn't match the request")
            }
            tokens = try await requestTokens([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": SpotifyConfig.redirectURI,
                "client_id": SpotifyConfig.clientID,
                "code_verifier": verifier,
            ], keepingRefreshToken: nil)
            accountName = try? await SpotifyAPI.shared.profileName()
        } catch SpotifyAuthError.cancelled {
            // User closed the sheet.
        } catch {
            lastError = error.localizedDescription
            log.error("login failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        accountName = nil
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SpotifyConfig.callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SpotifyAuthError.badResponse("no reply"))
                }
            }
            session.presentationContextProvider = self
            // Reuse the Safari login so people already signed in to Spotify skip the password.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: SpotifyAuthError.badResponse("couldn't open the login page"))
            }
        }
    }

    // MARK: Tokens

    /// A non-expired access token, refreshing it first if needed.
    func validAccessToken() async throws -> String {
        guard let tokens else { throw SpotifyAuthError.notConnected }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let refreshToken = tokens.refreshToken
        let task = Task<String, Error> { @MainActor in
            defer { self.refreshTask = nil }
            do {
                let fresh = try await self.requestTokens([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": SpotifyConfig.clientID,
                ], keepingRefreshToken: refreshToken)
                self.tokens = fresh
                return fresh.accessToken
            } catch SpotifyAuthError.denied(let reason) {
                // Refresh token revoked or expired: the user has to log in again.
                self.log.error("refresh rejected: \(reason, privacy: .public)")
                self.tokens = nil
                self.lastError = "Spotify signed Vinyl out. Connect again in Settings."
                throw SpotifyAuthError.notConnected
            }
        }
        refreshTask = task
        return try await task.value
    }

    /// Called after a 401 so the next request refreshes first.
    func invalidateAccessToken() {
        tokens?.expiresAt = .distantPast
    }

    private func requestTokens(_ form: [String: String], keepingRefreshToken previous: String?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        struct Reply: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let error: String?
            let error_description: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if status == 400, reply?.error == "invalid_grant" {
            throw SpotifyAuthError.denied(reply?.error_description ?? "invalid_grant")
        }
        guard status == 200, let access = reply?.access_token else {
            let detail = reply?.error_description ?? reply?.error ?? "HTTP \(status)"
            throw SpotifyAuthError.badResponse(detail)
        }
        guard let refresh = reply?.refresh_token ?? previous else {
            throw SpotifyAuthError.badResponse("no refresh token")
        }
        return SpotifyTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(reply?.expires_in ?? 3600)
        )
    }

    // MARK: Helpers

    private static func randomString(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(generator.next(upperBound: UInt(chars.count)))] })
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}
