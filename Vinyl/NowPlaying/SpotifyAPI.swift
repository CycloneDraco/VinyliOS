import Foundation
import os

enum SpotifyAPIError: LocalizedError {
    case notConnected
    case premiumRequired
    case noActiveDevice
    case rateLimited(retryAfter: TimeInterval)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Spotify isn't connected."
        case .premiumRequired: return "Spotify only allows play, pause and skip from other apps with Premium."
        case .noActiveDevice: return "Nothing is playing on Spotify right now. Start a song in Spotify first."
        case .rateLimited: return "Spotify asked Vinyl to slow down; it'll catch up in a moment."
        case .http(let code): return "Spotify returned an error (\(code))."
        }
    }
}

/// What Spotify says is playing on the account, on any device.
struct SpotifyPlayback {
    var track: Track?
    var isPlaying: Bool
    var progress: TimeInterval
    var device: String?
    var fetchedAt: Date
}

/// The few Spotify Web API endpoints Vinyl uses.
@MainActor
final class SpotifyAPI {
    static let shared = SpotifyAPI()

    private let base = URL(string: "https://api.spotify.com/v1")!
    private let log = Logger(subsystem: "io.github.cyclonedraco.vinyl.ios", category: "SpotifyAPI")

    // MARK: Endpoints

    /// Current playback on any of the user's devices; nil when nothing is active.
    func playback() async throws -> SpotifyPlayback? {
        let started = Date()
        let (data, response) = try await send("GET", "me/player", query: [URLQueryItem(name: "additional_types", value: "episode")])
        if response.statusCode == 204 || data.isEmpty { return nil }
        let reply = try JSONDecoder().decode(PlayerReply.self, from: data)
        // Halfway through the round trip is the best guess for when progress_ms was sampled.
        let sampledAt = started.addingTimeInterval(Date().timeIntervalSince(started) / 2)
        return SpotifyPlayback(
            track: reply.item.map(Self.track(from:)),
            isPlaying: reply.is_playing,
            progress: Double(reply.progress_ms ?? 0) / 1000,
            device: reply.device?.name,
            fetchedAt: sampledAt
        )
    }

    func play() async throws { _ = try await send("PUT", "me/player/play") }
    func pause() async throws { _ = try await send("PUT", "me/player/pause") }
    func next() async throws { _ = try await send("POST", "me/player/next") }
    func previous() async throws { _ = try await send("POST", "me/player/previous") }

    func seek(to seconds: TimeInterval) async throws {
        _ = try await send("PUT", "me/player/seek", query: [URLQueryItem(name: "position_ms", value: String(Int(seconds * 1000)))])
    }

    func profileName() async throws -> String? {
        let (data, _) = try await send("GET", "me")
        struct Me: Decodable { let display_name: String?; let id: String? }
        let me = try JSONDecoder().decode(Me.self, from: data)
        return me.display_name ?? me.id
    }

    // MARK: Transport

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], retried: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let token: String
        do {
            token = try await SpotifyAuth.shared.validAccessToken()
        } catch {
            throw SpotifyAPIError.notConnected
        }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method == "PUT" || method == "POST" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse else { throw SpotifyAPIError.http(0) }

        switch response.statusCode {
        case 200...299:
            return (data, response)
        case 401 where !retried:
            SpotifyAuth.shared.invalidateAccessToken()
            return try await send(method, path, query: query, retried: true)
        case 401:
            throw SpotifyAPIError.notConnected
        case 403:
            throw SpotifyAPIError.premiumRequired
        case 404:
            throw SpotifyAPIError.noActiveDevice
        case 429:
            let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
            log.info("rate limited for \(wait)s")
            throw SpotifyAPIError.rateLimited(retryAfter: wait)
        default:
            throw SpotifyAPIError.http(response.statusCode)
        }
    }

    // MARK: Decoding

    private struct PlayerReply: Decodable {
        struct Device: Decodable { let name: String? }
        struct Image: Decodable { let url: String; let width: Int? }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let name: String; let images: [Image]?; let artists: [Artist]? }
        struct Show: Decodable { let name: String; let publisher: String?; let images: [Image]? }
        struct Item: Decodable {
            let uri: String?
            let name: String
            let duration_ms: Int?
            let artists: [Artist]?
            let album: Album?
            let show: Show?
            let images: [Image]?
        }
        let is_playing: Bool
        let progress_ms: Int?
        let device: Device?
        let item: Item?
    }

    private static func track(from item: PlayerReply.Item) -> Track {
        let artists = (item.artists ?? []).map(\.name).joined(separator: ", ")
        let images = item.album?.images ?? item.show?.images ?? item.images ?? []
        // Largest rendition up to 640 px (Spotify lists them largest first).
        let cover = images.filter { ($0.width ?? 640) <= 640 }.max { ($0.width ?? 0) < ($1.width ?? 0) } ?? images.first
        return Track(
            id: item.uri ?? "spotify:unknown:\(item.name)",
            title: item.name,
            artist: artists.isEmpty ? (item.show?.publisher ?? item.show?.name ?? "") : artists,
            album: item.album?.name ?? item.show?.name ?? "",
            albumArtist: item.album?.artists?.first?.name,
            duration: item.duration_ms.map { Double($0) / 1000 },
            source: .spotify,
            artworkURL: cover.flatMap { URL(string: $0.url) }
        )
    }
}
