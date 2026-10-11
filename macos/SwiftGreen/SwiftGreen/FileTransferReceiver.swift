import Foundation
import CryptoKit
import CoreServices
import UserNotifications
import Combine

class FileTransferReceiver: ObservableObject {
    static let shared = FileTransferReceiver()
    
    private var activeTransferId: String?
    private var activeFilename: String?
    private var totalChunks: Int = 0
    private var expectedSha256: String?
    private var awaitingComplete = false
    private var totalBytes: Int64 = 0
    
    // Streaming write state
    private var fileHandle: FileHandle?
    private var tempFileURL: URL?
    private var lastProgressUpdateNs: UInt64 = 0
    
    private init() {
        loadHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: FileTransferReceiver.historyDefaultsKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let records = try? decoder.decode([TransferRecord].self, from: data) {
            transferHistory = records
        }
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(transferHistory) {
            UserDefaults.standard.set(data, forKey: FileTransferReceiver.historyDefaultsKey)
        }
    }
    
    struct TransferRecord: Identifiable, Codable {
        let id: UUID
        let filename: String
        let bytes: Int64
        let state: String // "complete" | "error" | "cancelled" | "sent"
        let path: String  // absolute path on disk; empty string when unknown/cancelled
        let date: Date

        init(filename: String, bytes: Int64, state: String, path: String = "", date: Date = Date()) {
            self.id = UUID()
            self.filename = filename
            self.bytes = bytes
            self.state = state
            self.path = path
            self.date = date
        }
    }

    private static let historyDefaultsKey = "fileTransferHistory"

    @Published var transferHistory: [TransferRecord] = [] {
        didSet { saveHistory() }
    }
    @Published var activeFilenamePublished: String? = nil
    @Published var receiveProgress: Double = 0.0
    @Published var receiveFilename: String = ""
    @Published var isReceiving: Bool = false

    /// Every entry point runs here, in the order the socket delivered the lines. `begin`
    /// used to hop to main while chunks ran on the socket queue, so a small file's first
    /// chunk could overtake its begin, be dropped, and leave the transfer stuck; the two
    /// threads also shared the file handle unsynchronised.
    private let queue = DispatchQueue(label: "com.swiftgreen.filetransfer.receive")

    func handleBegin(json: [String: Any]) { queue.async { self.begin(json) } }
    func handleChunk(json: [String: Any]) { queue.async { self.chunk(json) } }
    func handleComplete(json: [String: Any]) { queue.async { self.complete(json) } }
    func cancelReceive() { queue.async { self.cancel() } }

    private func begin(_ json: [String: Any]) {
        guard let transfer_id = json["transfer_id"] as? String,
              let rawFilename = json["filename"] as? String,
              let _ = json["mime_type"] as? String,
              let total_bytes_num = json["total_bytes"] as? NSNumber,
              let total_chunks_num = json["total_chunks"] as? NSNumber,
              let checksum_sha256 = json["checksum_sha256"] as? String else {
            print("[FileTransferReceiver] Error: Missing fields in file_transfer_begin")
            return
        }
        
        let total_bytes = total_bytes_num.int64Value
        let total_chunks = total_chunks_num.intValue
        // Sender-controlled, and this app isn't sandboxed: keep only the last path
        // component so "../Library/LaunchAgents/x.plist" can't escape ~/Downloads.
        let lastComponent = (rawFilename as NSString).lastPathComponent
        let filename = ["", ".", ".."].contains(lastComponent) ? "file" : lastComponent
        
        
        // Resume: if same transfer_id arrives again, preserve existing file handle
        if transfer_id == activeTransferId {
            print("[FileTransferReceiver] Resume detected for transfer \(transfer_id)")
            self.totalChunks = total_chunks
            self.totalBytes = total_bytes
            return
        }
        
        // Reset state for new transfer
        resetState()
        
        activeTransferId = transfer_id
        activeFilename = filename
        DispatchQueue.main.async {
            self.activeFilenamePublished = filename
            self.isReceiving = true
            self.receiveFilename = filename
            self.receiveProgress = 0.0
        }
        expectedSha256 = checksum_sha256
        totalChunks = total_chunks
        totalBytes = total_bytes
        
        // Open temp file for streaming writes
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent((transfer_id as NSString).lastPathComponent + ".tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        self.tempFileURL = tempURL
        self.fileHandle = try? FileHandle(forWritingTo: tempURL)

        print("[FileTransferReceiver] Transfer begun — id: \(transfer_id), file: \(filename), chunks: \(total_chunks), bytes: \(total_bytes)")
    }
    
    private func chunk(_ json: [String: Any]) {
        guard let transfer_id = json["transfer_id"] as? String,
              let chunk_index_num = json["chunk_index"] as? NSNumber,
              let total_chunks_num = json["total_chunks"] as? NSNumber,
              let dataBase64 = json["data"] as? String,
              let is_final = json["is_final"] as? Bool else {
            print("[FileTransferReceiver] Error: Missing fields in file_transfer_chunk")
            return
        }
        
        let chunk_index = chunk_index_num.intValue
        let total_chunks = total_chunks_num.intValue
        
        guard transfer_id == activeTransferId else {
            print("[FileTransferReceiver] Chunk transfer_id mismatch — ignoring")
            return
        }
        
        let chunkData: Data
        if dataBase64.isEmpty {
            chunkData = Data()
        } else {
            guard let decoded = Data(base64Encoded: dataBase64) else {
                print("[FileTransferReceiver] Error: Failed to decode Base64 data for chunk \(chunk_index)")
                return
            }
            chunkData = decoded
        }

        fileHandle?.write(chunkData)
        print("[FileTransferReceiver] Chunk \(chunk_index + 1)/\(total_chunks) received")
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if nowNs - lastProgressUpdateNs >= 50_000_000 || is_final {
            lastProgressUpdateNs = nowNs
            DispatchQueue.main.async {
                self.receiveProgress = Double(chunk_index + 1) / Double(total_chunks)
            }
        }

        // Android sends the checksum only in file_transfer_complete, which follows the
        // final chunk; finalizing here used to compare against "" and skip the check.
        if is_final {
            if expectedSha256?.isEmpty ?? true { awaitingComplete = true } else { finalizeTransfer() }
        }
    }
    
    private func complete(_ json: [String: Any]) {
        guard let transfer_id = json["transfer_id"] as? String else { return }
        let receivedSha256 = json["checksum_sha256"] as? String ?? ""
        guard transfer_id == activeTransferId else { return }
        print("[FileTransferReceiver] file_transfer_complete received — sha256: \(receivedSha256)")
        guard awaitingComplete else { return }
        awaitingComplete = false
        expectedSha256 = receivedSha256
        finalizeTransfer()
    }
    
    /// Where received files are saved: the user's ~/Downloads. The unit tests run inside the
    /// app, so they get a fresh temporary folder instead and never write to the real one.
    nonisolated static let downloadsDirectory: URL = {
        guard TestHost.isActive else {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGreen-tests-\(UUID().uuidString)/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Lowercase hex SHA-256 and byte count, read 1 MiB at a time.
    static func sha256Hex(of url: URL) -> (String, Int64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            count += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    /// Runs on `queue`, so the next transfer's lines wait until this one is settled.
    private func finalizeTransfer() {
        fileHandle?.closeFile()
        guard let tempURL = tempFileURL else { return }

        let filename = activeFilename ?? "file"
        let expectedHash = expectedSha256
        defer { resetState() }

        // Streamed: loading the whole file to hash it held a multi-GB transfer in memory.
        // Fails closed: no checksum from the sender is a mismatch, not a pass.
        guard let (hexString, byteCount) = Self.sha256Hex(of: tempURL), hexString == expectedHash else {
            print("[FileTransferReceiver] SHA-256 MISMATCH")
            try? FileManager.default.removeItem(at: tempURL)
            finishOnMain(TransferRecord(filename: filename, bytes: 0, state: "error"), saved: nil)
            return
        }

        let downloadsURL = Self.downloadsDirectory
        var destinationURL = downloadsURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let nameWithoutExt = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            var counter = 1
            repeat {
                let newName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
                destinationURL = downloadsURL.appendingPathComponent(newName)
                counter += 1
            } while FileManager.default.fileExists(atPath: destinationURL.path) && counter <= 99
        }

        do {
            // Never overwrites: moveItem fails if the 99th name is taken too.
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            // From the network: let Gatekeeper check it before it runs, as a browser would.
            var quarantine = URLResourceValues()
            quarantine.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                               kLSQuarantineAgentNameKey as String: "SwiftGreen"]
            try? destinationURL.setResourceValues(quarantine)
            print("[FileTransferReceiver] ✅ File saved: \(destinationURL.path)")
            finishOnMain(TransferRecord(filename: filename, bytes: byteCount, state: "complete", path: destinationURL.path),
                         saved: destinationURL)
        } catch {
            print("[FileTransferReceiver] Failed to move file: \(error)")
            try? FileManager.default.removeItem(at: tempURL)
            finishOnMain(TransferRecord(filename: filename, bytes: 0, state: "error"), saved: nil)
        }
    }

    /// The UI's view of a finished transfer, saved or not. A mismatch used to leave
    /// "Receiving" on screen with no record of the failure.
    private func finishOnMain(_ record: TransferRecord, saved: URL?) {
        DispatchQueue.main.async {
            if let saved {
                self.postNotification(filename: record.filename, destinationURL: saved)
                SGSound.play(.transfer)
            } else {
                SGSound.play(.failed)
            }
            self.transferHistory.insert(record, at: 0)
            if self.transferHistory.count > 20 { self.transferHistory = Array(self.transferHistory.prefix(20)) }
            self.activeFilenamePublished = nil
            self.isReceiving = false
            self.receiveProgress = saved == nil ? 0.0 : 1.0
        }
    }

    private func postNotification(filename: String, destinationURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "File Received"
        content.body = "\(filename) saved to Downloads"
        content.sound = nil   // Hero (SGSound.transfer) marks it
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[FileTransferReceiver] Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
    
    private func cancel() {
        guard activeTransferId != nil else { return }
        let cancelledFilename = activeFilename ?? "unknown"
        let cancelledBytes = totalBytes
        if let handle = fileHandle {
            try? handle.close()
        }
        if let tmpURL = tempFileURL {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        resetState()
        DispatchQueue.main.async {
            self.transferHistory.insert(
                TransferRecord(filename: cancelledFilename, bytes: cancelledBytes, state: "cancelled", path: ""),
                at: 0)
            if self.transferHistory.count > 20 { self.transferHistory = Array(self.transferHistory.prefix(20)) }
            self.isReceiving = false
            self.receiveProgress = 0.0
            self.receiveFilename = ""
        }
        print("[FileTransferReceiver] File transfer cancelled by Android")
    }
    
    func clearHistory() {
        DispatchQueue.main.async {
            self.transferHistory = []
        }
    }
    
    private func resetState() {
        fileHandle?.closeFile()
        fileHandle = nil
        lastProgressUpdateNs = 0
        if let tempURL = tempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        tempFileURL = nil
        activeTransferId = nil
        activeFilename = nil
        totalChunks = 0
        expectedSha256 = nil
        awaitingComplete = false
        totalBytes = 0
        DispatchQueue.main.async { self.activeFilenamePublished = nil }
    }
}

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
