import Foundation
import Combine
import AppKit

class MediaControlStore: ObservableObject {
    static let shared = MediaControlStore()

    @Published var trackTitle: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var appName: String = ""
    @Published var packageName: String = ""
    @Published var isPlaying: Bool = false
    @Published var durationMs: Int64 = 0
    @Published var positionMs: Int64 = 0
    @Published var volume: Int = 0
    @Published var playbackSpeed: Double = 1
    /// False when the player refuses seeking (many live and ad-supported streams).
    @Published var canSeek: Bool = true
    /// Duration 0 means a live stream or a player that doesn't report length.
    var isLive: Bool { durationMs <= 0 }
    /// Decoded once per artwork change, not once per SwiftUI render. Views bind
    /// to this; re-decoding base64 in a `body` made the art flicker on every poll.
    @Published var albumArt: NSImage? = nil
    private var lastArtBase64: String? = nil
    /// Up-next list. Empty when the player exposes no queue, which is common —
    /// the UI hides the section rather than showing an empty shell.
    @Published var queue: [QueueItem] = []

    struct QueueItem: Identifiable, Codable, Equatable {
        var id: Int64 { queueId }
        let queueId: Int64
        let title: String
        let subtitle: String

        enum CodingKeys: String, CodingKey {
            case queueId = "queue_id"
            case title, subtitle
        }
    }

    var hasActiveSession: Bool {
        !trackTitle.isEmpty || !artist.isEmpty
    }

    private let cacheKey = "lastMediaState"

    private init() {
        load()
    }

    func update(from json: [String: Any]) {
        trackTitle = json["track_title"] as? String ?? ""
        artist = json["artist"] as? String ?? ""
        album = json["album"] as? String ?? ""
        appName = json["app_name"] as? String ?? ""
        packageName = json["package_name"] as? String ?? ""
        isPlaying = json["is_playing"] as? Bool ?? false
        durationMs = (json["duration_ms"] as? NSNumber)?.int64Value ?? 0
        positionMs = (json["position_ms"] as? NSNumber)?.int64Value ?? 0
        volume = (json["volume"] as? NSNumber)?.intValue ?? 0
        playbackSpeed = (json["playback_speed"] as? NSNumber)?.doubleValue ?? 1
        // Absent on older phone builds: assume seekable, as before.
        canSeek = json["can_seek"] as? Bool ?? true

        // Artwork is the heaviest field on a 2s poll, so Android omits the key
        // entirely when it hasn't changed. Absent key = keep what we have;
        // present-but-null = genuinely no art. Conflating the two made the art
        // blink out between polls.
        if json.keys.contains("album_art_base64") {
            let incomingArt = json["album_art_base64"] as? String
            if incomingArt != lastArtBase64 {
                lastArtBase64 = incomingArt
                albumArt = NSImage(base64: incomingArt)
            }
        }

        if let raw = json["queue"] as? [[String: Any]] {
            queue = raw.compactMap { entry in
                guard let qid = (entry["queue_id"] as? NSNumber)?.int64Value else { return nil }
                return QueueItem(
                    queueId: qid,
                    title: entry["title"] as? String ?? "",
                    subtitle: entry["subtitle"] as? String ?? ""
                )
            }
        } else {
            queue = []
        }
        syncTicker()
        persist()
    }

    // MARK: Local position ticker

    /// Android polls us every 2s, so without this the scrubber sat still and then
    /// jumped two seconds — the player looked frozen. This advances position
    /// locally between polls; each incoming `media_state` resnaps it to the truth.
    private var ticker: Timer?

    private func syncTicker() {
        ticker?.invalidate()
        ticker = nil
        guard isPlaying else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            let next = self.positionMs + Int64(500 * self.playbackSpeed)
            self.positionMs = self.durationMs > 0 ? min(next, self.durationMs) : next
        }
    }

    private func persist() {
        let state: [String: Any] = [
            "track_title": trackTitle,
            "artist": artist,
            "album": album,
            "app_name": appName,
            "is_playing": isPlaying,
            "duration_ms": durationMs,
            "position_ms": positionMs,
            "volume": volume
        ]
        UserDefaults.standard.set(state, forKey: cacheKey)
    }

    private func load() {
        guard let state = UserDefaults.standard.dictionary(forKey: cacheKey) else { return }
        trackTitle = state["track_title"] as? String ?? ""
        artist = state["artist"] as? String ?? ""
        album = state["album"] as? String ?? ""
        appName = state["app_name"] as? String ?? ""
        isPlaying = false
        durationMs = (state["duration_ms"] as? NSNumber)?.int64Value ?? 0
        positionMs = (state["position_ms"] as? NSNumber)?.int64Value ?? 0
        volume = (state["volume"] as? NSNumber)?.intValue ?? 0
    }
}
