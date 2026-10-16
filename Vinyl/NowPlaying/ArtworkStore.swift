import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Finds album artwork, downsizes it and keeps it on disk so both the native
/// scene and the three.js renderer (`vinyl://app/artwork/<file>`) can use it.
///
/// - Spotify: the cover URL from the Web API, falling back to the public
///   oEmbed endpoint.
/// - Apple Music: the artwork embedded in the playing item, falling back to a
///   strict iTunes Search match.
actor ArtworkStore {
    static let shared = ArtworkStore()

    let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "Vinyl/1.0 (iOS; +https://github.com/CycloneDraco/Vinyl)"]
        return URLSession(configuration: config)
    }()

    private let log = Logger(subsystem: "io.github.cyclonedraco.vinyl.ios", category: "Artwork")
    private var inFlight: [String: Task<String?, Never>] = [:]

    nonisolated func fileName(for track: Track) -> String {
        "\(Self.fnv1a(track.albumKey)).jpg"
    }

    nonisolated func url(forFile name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Returns the cached file name holding this track's artwork, fetching it
    /// first if needed. `embedded` is artwork straight from the player.
    func artwork(for track: Track, embedded: Data? = nil) async -> String? {
        let name = fileName(for: track)
        if FileManager.default.fileExists(atPath: url(forFile: name).path) {
            touch(name)
            return name
        }
        if let running = inFlight[name] { return await running.value }
        let task = Task<String?, Never> {
            let data = await self.fetch(track, embedded: embedded)
            guard let data, let jpeg = Self.normalized(data) else { return nil }
            do {
                try jpeg.write(to: self.url(forFile: name), options: .atomic)
                return name
            } catch {
                return nil
            }
        }
        inFlight[name] = task
        let result = await task.value
        inFlight[name] = nil
        pruneIfNeeded()
        return result
    }

    private func fetch(_ track: Track, embedded: Data?) async -> Data? {
        if let embedded { return embedded }
        if let direct = track.artworkURL, let data = try? await download(direct) { return data }
        switch track.source {
        case .spotify:
            if let data = await spotifyArtwork(trackID: track.id) { return data }
        case .appleMusic:
            break
        }
        return await iTunesArtwork(for: track)
    }

    // MARK: Spotify

    private func spotifyArtwork(trackID: String) async -> Data? {
        // spotify:track:ID / spotify:episode:ID → https://open.spotify.com/track/ID
        let parts = trackID.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", ["track", "episode", "show"].contains(String(parts[1])) else {
            return nil
        }
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
        guard let url = components.url else { return nil }
        struct OEmbed: Decodable { let thumbnail_url: String? }
        do {
            let (data, _) = try await session.data(from: url)
            guard let thumb = try JSONDecoder().decode(OEmbed.self, from: data).thumbnail_url else { return nil }
            // oEmbed hands out the 300 px rendition; the 640 px one shares the id.
            let large = thumb.replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d0000b273")
            if let big = URL(string: large), let image = try? await download(big) { return image }
            if let small = URL(string: thumb) { return try await download(small) }
        } catch {
            log.debug("oEmbed failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    // MARK: iTunes Search (fallback)

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    /// Only accepts results whose album *and* artist match, so we never show
    /// a cover from a compilation or another artist's song with the same name.
    private func iTunesArtwork(for track: Track) async -> Data? {
        guard !track.title.isEmpty || !track.album.isEmpty else { return nil }
        let country = Locale.current.region?.identifier ?? "US"
        let searches: [(term: String, entity: String)] = [
            ("\(track.artist) \(track.album)", "album"),
            ("\(track.artist) \(track.title)", "song"),
        ]
        let wantAlbum = Self.normalize(track.album)
        let wantArtist = Self.normalize(track.albumArtist?.isEmpty == false ? track.albumArtist! : track.artist)
        let wantTitle = Self.normalize(track.title)
        for search in searches {
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [
                URLQueryItem(name: "term", value: search.term),
                URLQueryItem(name: "entity", value: search.entity),
                URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "limit", value: "25"),
            ]
            guard let url = components.url,
                  let result = try? await session.data(from: url),
                  let response = try? JSONDecoder().decode(SearchResponse.self, from: result.0)
            else { continue }
            let match = response.results.first { item in
                let album = Self.normalize(item.collectionName ?? "")
                let artist = Self.normalize(item.artistName ?? "")
                let artistOK = !wantArtist.isEmpty && (artist == wantArtist || artist.contains(wantArtist) || wantArtist.contains(artist))
                if search.entity == "album" { return artistOK && !wantAlbum.isEmpty && album == wantAlbum }
                return artistOK && Self.normalize(item.trackName ?? "") == wantTitle && (wantAlbum.isEmpty || album == wantAlbum)
            }
            if let art = match?.artworkUrl100,
               let big = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")),
               let image = try? await download(big) {
                return image
            }
        }
        return nil
    }

    // MARK: Helpers

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 64 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Re-encodes any image as a ≤1024 px JPEG.
    private static func normalized(_ data: Data) -> Data? {
        jpeg(from: data, maxPixel: 1024, quality: 0.9)
    }

    static func jpeg(from data: Data, maxPixel: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// A cover small enough to ride inside a Live Activity update (whose whole
    /// payload must stay under 4 KB once base64-encoded).
    nonisolated func liveActivityThumbnail(forFile name: String, maxBytes: Int = 2300) -> Data? {
        guard let data = try? Data(contentsOf: url(forFile: name)) else { return nil }
        for (pixels, quality) in [(72, 0.6), (60, 0.5), (48, 0.45), (40, 0.35)] {
            if let small = Self.jpeg(from: data, maxPixel: pixels, quality: quality), small.count <= maxBytes {
                return small
            }
        }
        return nil
    }

    /// The cover's average colour (sRGB, 0…1), used to tint the record label.
    static func averageColor(ofFile url: URL) -> (red: Double, green: Double, blue: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        // Drop edition suffixes: "Album (Deluxe Edition)", "Song - Remastered 2011"
        for marker in [" (", " [", " - "] {
            if let r = t.range(of: marker) { t = String(t[..<r.lowerBound]) }
        }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(kept)
    }

    private static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private func touch(_ name: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(forFile: name).path)
    }

    /// Keeps the cache to the 300 most recently used covers.
    private func pruneIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 300
        else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - 300) { try? fm.removeItem(at: file) }
    }
}
