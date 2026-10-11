import Foundation
import Combine
import AppKit

/// One entry in a phone folder. `path` is relative to shared-storage root and is the
/// only handle Android accepts back — for listing, pulling, and thumbnails.
struct MediaBrowserItem: Identifiable, Codable {
    var id: String { path }
    let path: String
    let filename: String
    let isDir: Bool
    let sizeBytes: Int64
    let dateModifiedMs: Int64
    let mimeType: String

    enum CodingKeys: String, CodingKey {
        case path, filename
        case isDir = "is_dir"
        case sizeBytes = "size_bytes"
        case dateModifiedMs = "date_modified_ms"
        case mimeType = "mime_type"
    }
}

struct MediaListResponsePayload: Codable {
    let directory: String
    let items: [MediaBrowserItem]
    /// "permission_required" (All files access off) or "not_found".
    let error: String?
}

struct MediaSearchResponsePayload: Codable {
    let query: String
    let items: [MediaBrowserItem]
}

/// Remote browser over the phone's whole shared storage. Read-only.
class MediaBrowserStore: ObservableObject {
    static let shared = MediaBrowserStore()

    @Published var items: [MediaBrowserItem] = []
    /// Current folder, relative to phone storage root. "" = root.
    @Published var directory: String = ""
    @Published var error: String? = nil
    /// True between asking Android for a listing and the reply landing.
    @Published var isLoading: Bool = false
    /// True once any listing has been asked for, so the pane loads root on first open.
    private(set) var hasRequested = false

    private init() {}

    func replace(from payload: MediaListResponsePayload) {
        // A slow reply for a folder the user already left must not overwrite this one.
        guard payload.directory == directory else { return }
        isLoading = false
        error = payload.error
        items = payload.items
    }

    /// path → decoded 200x200 preview. Images only; in-memory only, so a relaunch
    /// re-fetches. Cleared on every folder change, which bounds it to one folder.
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    /// Paths already asked for, so scrolling back up over a row doesn't re-request it.
    private var requestedThumbnails: Set<String> = []

    /// Android may never answer — a deleted file, a dropped tunnel. The row is already
    /// showing its type glyph, so this only decides whether a later re-appear retries.
    private static let thumbnailTimeout: TimeInterval = 5

    /// Clears the previous folder's rows first, so a slow reply never shows the
    /// wrong directory's contents under the new heading.
    func requestList(directory: String) {
        hasRequested = true
        self.directory = directory
        items = []
        error = nil
        thumbnails = [:]
        requestedThumbnails = []

        // Offline: leave isLoading false. Setting it and waiting for a reply that
        // cannot arrive is what left the skeletons up forever.
        guard let server = mDNSQuicServer.activeServer, server.isTunnelActive else {
            isLoading = false
            return
        }
        isLoading = true
        send(["type": "media_list_request", "directory": directory])

        // A request that crosses a reconnect is simply lost. Ask once more, then stop
        // showing skeletons and say so — never spin forever.
        let asked = directory
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.isLoading, self.directory == asked else { return }
            self.send(["type": "media_list_request", "directory": asked])
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.isLoading, self.directory == asked else { return }
                self.isLoading = false
                self.error = "no_response"
            }
        }
    }

    /// Parent of the current folder; nil at root.
    var parentDirectory: String? {
        guard !directory.isEmpty else { return nil }
        return (directory as NSString).deletingLastPathComponent
    }

    /// Called when the tunnel drops so an in-flight request can't hang the skeletons.
    func cancelLoading() {
        isLoading = false
    }

    /// Asked for per row as it scrolls into view, never for a whole folder at once —
    /// a folder of 500 photos would otherwise decode 500 bitmaps on the phone to show six.
    func requestThumbnail(path: String) {
        guard thumbnails[path] == nil,
              !requestedThumbnails.contains(path),
              mDNSQuicServer.activeServer?.isTunnelActive == true else { return }

        requestedThumbnails.insert(path)
        send(["type": "media_thumbnail_request", "path": path])

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.thumbnailTimeout) { [weak self] in
            guard let self, self.thumbnails[path] == nil else { return }
            self.requestedThumbnails.remove(path)
        }
    }

    /// `base64` is nil when Android answered with an explicit error. The row keeps its glyph.
    func acceptThumbnail(path: String, base64: String?) {
        requestedThumbnails.remove(path)
        guard let image = NSImage(base64: base64) else { return }
        thumbnails[path] = image
    }

    func requestFile(path: String) {
        send(["type": "media_file_request", "path": path])
    }

    // MARK: Search — names anywhere on the phone

    @Published private(set) var searchResults: [MediaBrowserItem] = []
    @Published private(set) var isSearching = false
    /// The phone never answered: an older SwiftGreen on Android without search.
    @Published private(set) var searchUnavailable = false
    /// The query the phone was last asked about.
    @Published private(set) var searchQuery = ""

    /// Empty or one-letter queries clear the results instead of asking the phone.
    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        searchQuery = q
        guard q.count >= 2, mDNSQuicServer.activeServer?.isTunnelActive == true else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchUnavailable = false
        send(["type": "media_search_request", "query": q])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.isSearching, self.searchQuery == q else { return }
            self.isSearching = false
            self.searchUnavailable = true
        }
    }

    /// A reply for anything but the latest query is dropped.
    func acceptSearch(query: String, items: [MediaBrowserItem]) {
        guard query == searchQuery else { return }
        isSearching = false
        searchResults = items
    }

    private func send(_ payload: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            mDNSQuicServer.activeServer?.sendMessage(json + "\n")
        }
    }
}
