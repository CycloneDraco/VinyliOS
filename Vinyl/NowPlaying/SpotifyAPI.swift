import Foundation
import os

enum SpotifyAPIError: LocalizedError {
    case notConnected
    case premiumRequired
    case noActiveDevice
    /// A 403 for another reason; carries Spotify's own message.
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval)
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Spotify isn't connected."
        case .premiumRequired: return "Spotify says this account needs Premium for play, pause and skip."
        case .noActiveDevice: return "Spotify isn't open on any device. Open Spotify on your phone, Mac or speaker, then try again."
        case .forbidden(let message): return "Spotify refused: \(message)"
        case .rateLimited: return "Spotify asked Vinyl to slow down; it'll catch up in a moment."
        case .http(let code, let message): return "Spotify returned an error (\(code))\(message.map { ": \($0)" } ?? ".")"
        }
    }
}

/// Spotify's error body: {"error": {"status": 403, "message": "…", "reason": "PREMIUM_REQUIRED"}}.
private struct SpotifyErrorBody: Decodable {
    struct Detail: Decodable {
        let message: String?
        let reason: String?
    }
    let error: Detail
}

/// What Spotify says is playing on the account, on any device.
struct SpotifyPlayback {
    var track: Track?
    var isPlaying: Bool
    var progress: TimeInterval
    var device: String?
    var fetchedAt: Date
    /// What Spotify won't take from other apps right now.
    var control = SpotifyControl()
}

/// Spotify's limits on remote control: some devices refuse it outright, and
/// some content (ads, Jams, certain radio modes) disallows particular actions.
struct SpotifyControl: Equatable {
    var deviceType: String?
    /// The device doesn't accept Web API commands at all.
    var deviceRestricted = false
    /// e.g. "pausing", "resuming", "skipping_next", "skipping_prev", "seeking".
    var disallows: Set<String> = []

    /// Plain-English reason a command was refused, best guess first.
    func explanation(device: String?) -> String {
        let name = device.map { "“\($0)”" } ?? "the device that's playing"
        if deviceRestricted {
            return "Spotify doesn't allow other apps to control \(name)\(deviceType.map { " (\($0.lowercased()))" } ?? ""). Control it there, or play on another device."
        }
        // "pausing"/"resuming" only mirror whether it's playing; they're not limits.
        let limits = disallows.subtracting(["pausing", "resuming"])
        if !limits.isEmpty {
            let actions = limits.sorted().map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
            return "Spotify isn't allowing \(actions) for what's playing on \(name) right now."
        }
        return "Spotify refused the command on \(name) (restriction violated)."
    }
}

/// The few Spotify Web API endpoints Vinyl uses.
@MainActor
final class SpotifyAPI {
    static let shared = SpotifyAPI()

    private let base = URL(string: "https://api.spotify.com/v1")!
    private let log = Logger(subsystem: "io.github.cyclonedraco.vinyl.ios", category: "SpotifyAPI")
    #if DEBUG
    private var lastLoggedControl: SpotifyControl?
    #endif

    // MARK: Endpoints

    /// Current playback on any of the user's devices; nil when nothing is active.
    func playback() async throws -> SpotifyPlayback? {
        let started = Date()
        let (data, response) = try await send("GET", "me/player", query: [URLQueryItem(name: "additional_types", value: "episode")])
        if response.statusCode == 204 || data.isEmpty { return nil }
        let reply = try JSONDecoder().decode(PlayerReply.self, from: data)
        // Halfway through the round trip is the best guess for when progress_ms was sampled.
        let sampledAt = started.addingTimeInterval(Date().timeIntervalSince(started) / 2)
        let control = SpotifyControl(
            deviceType: reply.device?.type,
            deviceRestricted: reply.device?.is_restricted ?? false,
            disallows: Set((reply.actions?.disallows ?? [:]).filter { $0.value }.keys)
        )
        #if DEBUG
        if control != lastLoggedControl {
            lastLoggedControl = control
            print("Spotify device \(reply.device?.name ?? "-") type=\(control.deviceType ?? "-") restricted=\(control.deviceRestricted) disallows=\(control.disallows.sorted())")
        }
        #endif
        if let id = reply.device?.id { lastDeviceID = id }
        return SpotifyPlayback(
            track: reply.item.map(Self.track(from:)),
            isPlaying: reply.is_playing,
            progress: Double(reply.progress_ms ?? 0) / 1000,
            device: reply.device?.name,
            fetchedAt: sampledAt,
            control: control
        )
    }

    func play() async throws {
        try await waking { deviceQuery in _ = try await self.send("PUT", "me/player/play", query: deviceQuery) }
    }

    /// Starts an album (or playlist) from its first track or from `trackURI`.
    func play(contextURI: String, startingAt trackURI: String? = nil) async throws {
        var payload: [String: Any] = ["context_uri": contextURI]
        if let trackURI { payload["offset"] = ["uri": trackURI] }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await waking { deviceQuery in _ = try await self.send("PUT", "me/player/play", query: deviceQuery, body: body) }
    }

    /// The device Spotify last reported playing on.
    private var lastDeviceID: String?

    /// Spotify drops a device from "active" after it sits paused for a while,
    /// and then refuses to play ("no active device"). Like Spotify's own app,
    /// wake the device that was last playing (or the first one available) and try again.
    private func waking(_ command: ([URLQueryItem]) async throws -> Void) async throws {
        do {
            try await command([])
        } catch SpotifyAPIError.noActiveDevice {
            struct Devices: Decodable {
                struct Device: Decodable { let id: String?; let is_restricted: Bool?; let is_active: Bool? }
                let devices: [Device]
            }
            let (data, _) = try await send("GET", "me/player/devices")
            let devices = (try? JSONDecoder().decode(Devices.self, from: data).devices) ?? []
            let usable = devices.filter { $0.id != nil && $0.is_restricted != true }
            guard let id = usable.first(where: { $0.id == lastDeviceID })?.id ?? usable.first?.id else {
                throw SpotifyAPIError.noActiveDevice
            }
            try await command([URLQueryItem(name: "device_id", value: id)])
        }
    }

    /// An album's details and full tracklist.
    func album(uri: String) async throws -> AlbumDetail {
        let id = String(uri.split(separator: ":").last ?? "")
        struct Artist: Decodable { let name: String }
        struct TrackItem: Decodable {
            let uri: String
            let name: String
            let track_number: Int
            let disc_number: Int
            let duration_ms: Int
            let artists: [Artist]
        }
        struct Page: Decodable { let items: [TrackItem]; let next: String? }
        struct Album: Decodable {
            let name: String
            let artists: [Artist]
            let release_date: String?
            let tracks: Page
        }
        let (data, _) = try await send("GET", "albums/\(id)")
        let album = try JSONDecoder().decode(Album.self, from: data)
        var items = album.tracks.items
        // Albums over 50 tracks come in pages.
        var next = album.tracks.next
        while next != nil, items.count < 500 {
            let (more, _) = try await send("GET", "albums/\(id)/tracks", query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(items.count)),
            ])
            let page = try JSONDecoder().decode(Page.self, from: more)
            items += page.items
            next = page.items.isEmpty ? nil : page.next
        }
        let albumArtist = album.artists.map(\.name).joined(separator: ", ")
        return AlbumDetail(
            title: album.name,
            artist: albumArtist,
            year: album.release_date.map { String($0.prefix(4)) },
            tracks: items.map { item in
                let artist = item.artists.map(\.name).joined(separator: ", ")
                return AlbumTrack(
                    id: item.uri,
                    number: item.track_number,
                    disc: item.disc_number,
                    title: item.name,
                    artist: artist == albumArtist ? nil : artist,
                    duration: Double(item.duration_ms) / 1000
                )
            }
        )
    }

    /// One page of the user's saved albums, newest first.
    func savedAlbums(offset: Int, limit: Int = 50) async throws -> (albums: [SpotifyAlbum], total: Int) {
        let (data, _) = try await send("GET", "me/albums", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
        struct Page: Decodable {
            struct Saved: Decodable { let album: PlayerReply.Album }
            let items: [Saved]
            let total: Int
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let albums = page.items.compactMap { saved -> SpotifyAlbum? in
            guard let uri = saved.album.uri else { return nil }
            let images = saved.album.images ?? []
            // ~300 px is plenty for a grid cell.
            let cover = images.min { abs(($0.width ?? 640) - 300) < abs(($1.width ?? 640) - 300) }
            return SpotifyAlbum(
                uri: uri,
                title: saved.album.name,
                artist: (saved.album.artists ?? []).map(\.name).joined(separator: ", "),
                artworkURL: cover.flatMap { URL(string: $0.url) }
            )
        }
        return (albums, page.total)
    }
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

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, retried: Bool = false) async throws -> (Data, HTTPURLResponse) {
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
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method == "PUT" || method == "POST" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse else { throw SpotifyAPIError.http(0, nil) }

        let detail = (200...299).contains(response.statusCode) ? nil : (try? JSONDecoder().decode(SpotifyErrorBody.self, from: data))?.error
        if let detail {
            #if DEBUG
            print("Spotify \(method) \(path) → \(response.statusCode) \(detail.reason ?? "-") \(detail.message ?? "")")
            #endif
            log.error("\(method, privacy: .public) \(path, privacy: .public) → \(response.statusCode): \(detail.reason ?? "-", privacy: .public) \(detail.message ?? "", privacy: .public)")
        }

        switch response.statusCode {
        case 200...299:
            return (data, response)
        case 401 where !retried:
            SpotifyAuth.shared.invalidateAccessToken()
            return try await send(method, path, query: query, body: body, retried: true)
        case 401:
            throw SpotifyAPIError.notConnected
        case 403:
            if detail?.reason == "PREMIUM_REQUIRED" { throw SpotifyAPIError.premiumRequired }
            let message = [detail?.message, detail?.reason.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            throw SpotifyAPIError.forbidden(message.isEmpty ? "403 with no reason given" : message)
        case 404:
            throw SpotifyAPIError.noActiveDevice
        case 429:
            let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
            log.info("rate limited for \(wait)s")
            throw SpotifyAPIError.rateLimited(retryAfter: wait)
        default:
            throw SpotifyAPIError.http(response.statusCode, detail?.message)
        }
    }

    // MARK: Decoding

    private struct PlayerReply: Decodable {
        struct Device: Decodable { let id: String?; let name: String?; let type: String?; let is_restricted: Bool? }
        struct Actions: Decodable { let disallows: [String: Bool]? }
        struct Image: Decodable { let url: String; let width: Int? }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let uri: String?; let name: String; let images: [Image]?; let artists: [Artist]? }
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
        let actions: Actions?
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
            artworkURL: cover.flatMap { URL(string: $0.url) },
            albumURI: item.album?.uri
        )
    }
}

/// A saved album in the user's Spotify library.
struct SpotifyAlbum: Identifiable, Equatable {
    var uri: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var id: String { uri }
}
