import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

struct MacFileBrowserItem: Identifiable {
    var id: Int { fileId }
    let fileId: Int
    let filename: String
    let sizeBytes: Int64
    let dateModifiedMs: Int64
    let mimeType: String
    let url: URL
}

/// One folder on this Mac that the phone can list and download from. Remembered
/// across launches, watched for changes, and re-announced whenever the phone
/// connects — the phone keeps no copy of its own.
class MacFileBrowserStore: ObservableObject {
    static let shared = MacFileBrowserStore()

    @Published private(set) var folderURL: URL?
    @Published private(set) var items: [MacFileBrowserItem] = []
    /// The folder has subfolders, which aren't shared — worth saying so.
    @Published private(set) var hasSubfolders = false

    var directoryName: String { folderURL?.lastPathComponent ?? "" }

    private static let pathKey = "shared_folder_path"
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingRescan: DispatchWorkItem?

    private init() {
        if let path = UserDefaults.standard.string(forKey: Self.pathKey),
           FileManager.default.fileExists(atPath: path) {
            share(URL(fileURLWithPath: path), announce: false)
        }
    }

    func url(forFileId fileId: Int) -> URL? {
        items.first { $0.fileId == fileId }?.url
    }

    func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        guard panel.runModal() == .OK, let dirURL = panel.url else { return }
        share(dirURL)
    }

    func share(_ dirURL: URL, announce: Bool = true) {
        folderURL = dirURL
        UserDefaults.standard.set(dirURL.path, forKey: Self.pathKey)
        watch(dirURL)
        rescan(announce: announce)
    }

    func stopSharing() {
        watcher?.cancel()
        watcher = nil
        folderURL = nil
        items = []
        hasSubfolders = false
        UserDefaults.standard.removeObject(forKey: Self.pathKey)
        pushListing()   // an empty listing clears it on the phone
    }

    /// Copies (never moves) files into the shared folder, so the phone can take them.
    func add(_ urls: [URL]) {
        guard let folderURL else { return }
        for url in urls where !url.hasDirectoryPath {
            var dest = folderURL.appendingPathComponent(url.lastPathComponent)
            let name = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = folderURL.appendingPathComponent(ext.isEmpty ? "\(name) \(n)" : "\(name) \(n).\(ext)")
                n += 1
            }
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        rescan()
    }

    /// Top-level files only, newest first. Ids are positions in this listing; every
    /// rescan re-announces, so the phone never holds ids from an older one.
    func rescan(announce: Bool = true) {
        guard let folderURL else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isHiddenKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        var files: [(URL, URLResourceValues)] = []
        var subfolders = false
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { subfolders = true } else { files.append((url, values)) }
        }
        files.sort { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }

        items = files.enumerated().map { index, pair in
            let (url, values) = pair
            return MacFileBrowserItem(
                fileId: index,
                filename: url.lastPathComponent,
                sizeBytes: Int64(values.fileSize ?? 0),
                dateModifiedMs: Int64((values.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000),
                mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                url: url)
        }
        hasSubfolders = subfolders
        if announce { pushListing() }
    }

    /// Sends the current listing to the phone. Called on every change and on connect.
    func pushListing(via server: mDNSQuicServer? = mDNSQuicServer.activeServer) {
        let itemsJSON = items.map { item -> [String: Any] in
            [
                "file_id": item.fileId,
                "filename": item.filename,
                "size_bytes": item.sizeBytes,
                "date_modified_ms": item.dateModifiedMs,
                "mime_type": item.mimeType
            ]
        }
        let payload: [String: Any] = [
            "type": "mac_directory_list_push",
            "directory_name": directoryName,
            "total_count": items.count,
            "items": itemsJSON
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            server?.sendMessage(json + "\n")
        }
    }

    /// Re-lists when anything is added, removed or renamed in the folder. Bursts
    /// (a copy writes several events) collapse into one rescan.
    private func watch(_ dirURL: URL) {
        watcher?.cancel()
        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.pendingRescan?.cancel()
            let work = DispatchWorkItem { self?.rescan() }
            self?.pendingRescan = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
