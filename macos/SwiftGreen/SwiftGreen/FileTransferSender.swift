import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Combine
import SwiftUI
import AppKit

class FileTransferSender: ObservableObject {
    static let shared = FileTransferSender()
    
    @Published var transferState: TransferState = .idle
    @Published var progress: Double = 0.0
    @Published var currentFilename: String = ""

    /// Rolling throughput history in bytes/sec, newest last, capped at 60 samples
    /// so the sparkline shows roughly the last minute of a chunked transfer.
    @Published var throughputSamples: [Double] = []
    @Published var bytesPerSecond: Double = 0
    @Published var etaSeconds: Int? = nil

    /// Files waiting behind the active transfer. The sender is single-stream by
    /// design — the protocol has one transfer_id in flight — so extra files queue
    /// here and drain automatically as each completes.
    @Published private(set) var queue: [QueuedFile] = []

    struct QueuedFile: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var filename: String { url.lastPathComponent }
        var byteCount: Int64 {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
    }

    /// Enqueue if a transfer is already running, otherwise start immediately.
    func enqueue(_ urls: [URL], via server: mDNSQuicServer) {
        for url in urls {
            if isIdle && queue.isEmpty {
                sendFile(at: url, via: server)
            } else {
                queue.append(QueuedFile(url: url))
            }
        }
    }

    func removeFromQueue(_ item: QueuedFile) {
        queue.removeAll { $0.id == item.id }
    }

    /// Called when a transfer settles. Pulls the next file off the queue.
    private func drainQueue(via server: mDNSQuicServer?) {
        guard let server, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        sendFile(at: next.url, via: server)
    }

    private var pendingTransferId: String?
    private var pendingResumeOffset: Int = 0
    private var isCancelled: Bool = false

    private var lastSampleAt: Date?
    private var lastSampleBytes: Int64 = 0

    /// Called from the chunk loop. Derives rate from the delta since the previous
    /// sample rather than an average since start, so a stall shows up immediately.
    private func recordThroughput(sentBytes: Int64, totalBytes: Int64) {
        let now = Date()
        defer {
            lastSampleAt = now
            lastSampleBytes = sentBytes
        }
        guard let previous = lastSampleAt else { return }
        let elapsed = now.timeIntervalSince(previous)
        guard elapsed > 0.15 else { return }   // ignore sub-frame deltas

        let rate = Double(sentBytes - lastSampleBytes) / elapsed
        guard rate.isFinite, rate >= 0 else { return }

        bytesPerSecond = rate
        throughputSamples.append(rate)
        if throughputSamples.count > 60 { throughputSamples.removeFirst() }

        let remaining = Double(totalBytes - sentBytes)
        etaSeconds = rate > 1 ? Int((remaining / rate).rounded()) : nil
    }

    private func resetThroughput() {
        throughputSamples = []
        bytesPerSecond = 0
        etaSeconds = nil
        lastSampleAt = nil
        lastSampleBytes = 0
    }
    
    enum TransferState: Equatable {
        case idle
        case sending
        case complete
        case error(String)
    }
    
    var isIdle: Bool {
        if case .idle = transferState { return true }
        return false
    }
    
    var isError: Bool {
        if case .error = transferState { return true }
        return false
    }
    
    private init() {}
    
    func sendFile(at url: URL, via server: mDNSQuicServer) {
        guard server.isTunnelActive else {
            self.transferState = .error("Not connected")
            self.resetToIdleAfterDelay()
            return
        }
        
        self.isCancelled = false
        self.transferState = .sending
        self.progress = 0.0
        self.currentFilename = url.lastPathComponent
        self.resetThroughput()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let fileData: Data
            do {
                fileData = try Data(contentsOf: url)
            } catch {
                DispatchQueue.main.async {
                    self.transferState = .error("Cannot read file")
                    self.resetToIdleAfterDelay()
                }
                return
            }
            
            do {
                let hash = SHA256.hash(data: fileData)
                let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
                
                let filename = url.lastPathComponent
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                
                let totalBytes = fileData.count
                let chunkSize = 262144
                let totalChunks = max(1, Int(ceil(Double(totalBytes) / Double(chunkSize))))
                let transferId = UUID().uuidString
                self.pendingTransferId = transferId
                self.pendingResumeOffset = 0
                
                let beginJSONObj: [String: Any] = [
                    "type": "file_transfer_begin",
                    "transfer_id": transferId,
                    "filename": filename,
                    "mime_type": mimeType,
                    "total_bytes": totalBytes,
                    "total_chunks": totalChunks,
                    "checksum_sha256": hexString,
                    "resume_offset": 0
                ]
                
                guard let beginData = try? JSONSerialization.data(withJSONObject: beginJSONObj),
                      let beginString = String(data: beginData, encoding: .utf8) else {
                    throw NSError(domain: "FileTransferSender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to build start message"])
                }
                
                server.sendMessage(beginString)

                if totalBytes == 0 {
                    let chunkJSONObj: [String: Any] = [
                        "type": "file_transfer_chunk",
                        "transfer_id": transferId,
                        "chunk_index": 0,
                        "total_chunks": 1,
                        "data": "",
                        "is_final": true
                    ]
                    guard let chunkData = try? JSONSerialization.data(withJSONObject: chunkJSONObj),
                          let chunkString = String(data: chunkData, encoding: .utf8) else {
                        throw NSError(domain: "FileTransferSender", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to build chunk message"])
                    }
                    server.sendMessage(chunkString)
                    DispatchQueue.main.async {
                        self.progress = 1.0
                    }
                } else {
                    var lastProgressUpdateNs: UInt64 = 0
                    for chunkIndex in 0..<totalChunks {
                        if self.isCancelled { break }
                        let offset = chunkIndex * chunkSize
                        let end = min(offset + chunkSize, totalBytes)
                        let slice = fileData.subdata(in: offset..<end)
                        let base64String = slice.base64EncodedString()
                        let isFinal = (chunkIndex == totalChunks - 1)
                        
                        let chunkJSONObj: [String: Any] = [
                            "type": "file_transfer_chunk",
                            "transfer_id": transferId,
                            "chunk_index": chunkIndex,
                            "total_chunks": totalChunks,
                            "data": base64String,
                            "is_final": isFinal
                        ]
                        
                        guard let chunkData = try? JSONSerialization.data(withJSONObject: chunkJSONObj),
                              let chunkString = String(data: chunkData, encoding: .utf8) else {
                            throw NSError(domain: "FileTransferSender", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to build chunk \(chunkIndex)"])
                        }
                        
                        server.sendMessage(chunkString)
                        self.pendingResumeOffset = end

                        let nowNs = DispatchTime.now().uptimeNanoseconds
                        if nowNs - lastProgressUpdateNs >= 50_000_000 || isFinal {
                            lastProgressUpdateNs = nowNs
                            DispatchQueue.main.async {
                                self.progress = Double(chunkIndex + 1) / Double(totalChunks)
                                self.recordThroughput(sentBytes: Int64(end),
                                                      totalBytes: Int64(totalBytes))
                            }
                        }
                    }
                    if self.isCancelled {
                        DispatchQueue.main.async {
                            self.transferState = .idle
                            self.progress = 0.0
                            self.currentFilename = ""
                            self.pendingTransferId = nil
                        }
                        return
                    }
                }
                
                DispatchQueue.main.async {
                    self.awaitResult(transferId: transferId, filename: filename, bytes: Int64(totalBytes), path: url.path)
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.transferState = .error(error.localizedDescription)
                    self.resetToIdleAfterDelay()
                }
            }
        }
    }
    
    func resumeIfNeeded(via server: mDNSQuicServer, fileURL: URL?) {
        guard let transferId = pendingTransferId,
              let url = fileURL,
              pendingResumeOffset > 0,
              server.isTunnelActive else { return }

        let offset = pendingResumeOffset
        let filename = url.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let fileData = try? Data(contentsOf: url) else { return }

            let hash = SHA256.hash(data: fileData)
            let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let totalBytes = fileData.count
            let chunkSize = 262144
            let totalChunks = max(1, Int(ceil(Double(totalBytes) / Double(chunkSize))))

            let beginJSONObj: [String: Any] = [
                "type": "file_transfer_begin",
                "transfer_id": transferId,
                "filename": filename,
                "mime_type": mimeType,
                "total_bytes": totalBytes,
                "total_chunks": totalChunks,
                "checksum_sha256": hexString,
                "resume_offset": offset
            ]
            guard let beginData = try? JSONSerialization.data(withJSONObject: beginJSONObj),
                  let beginString = String(data: beginData, encoding: .utf8) else { return }
            server.sendMessage(beginString)

            let startChunk = offset / chunkSize
            for chunkIndex in startChunk..<totalChunks {
                let chunkOffset = chunkIndex * chunkSize
                let end = min(chunkOffset + chunkSize, totalBytes)
                let slice = fileData.subdata(in: chunkOffset..<end)
                let base64String = slice.base64EncodedString()
                let isFinal = chunkIndex == totalChunks - 1
                let chunkJSONObj: [String: Any] = [
                    "type": "file_transfer_chunk",
                    "transfer_id": transferId,
                    "chunk_index": chunkIndex,
                    "total_chunks": totalChunks,
                    "data": base64String,
                    "is_final": isFinal
                ]
                guard let chunkData = try? JSONSerialization.data(withJSONObject: chunkJSONObj),
                      let chunkString = String(data: chunkData, encoding: .utf8) else { continue }
                server.sendMessage(chunkString)
                DispatchQueue.main.async { self.pendingResumeOffset = end }
            }

            DispatchQueue.main.async {
                self.awaitResult(transferId: transferId, filename: filename, bytes: Int64(totalBytes), path: url.path)
            }
        }
    }
    
    func cancelTransfer(via server: mDNSQuicServer) {
        isCancelled = true
        guard let transferId = pendingTransferId else { return }
        let msg: [String: Any] = [
            "type": "file_transfer_cancel",
            "transfer_id": transferId
        ]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            server.sendMessage(str)
        }
        DispatchQueue.main.async {
            self.transferState = .idle
            self.progress = 0.0
            self.currentFilename = ""
            self.pendingTransferId = nil
            self.pendingResumeOffset = 0
            self.awaiting = nil
        }
    }

    /// The last chunk is only queued on the socket; the phone still has to write and verify the
    /// file. It answers with `file_transfer_result`, and only that marks the transfer complete.
    private var awaiting: (id: String, filename: String, bytes: Int64, path: String)? {
        didSet { finishingOnPhone = awaiting != nil }
    }
    /// All sent, waiting for the phone to save and verify: the UI says so instead of a bare 100%.
    @Published private(set) var finishingOnPhone = false
    static let resultTimeout: TimeInterval = 60

    func awaitResult(transferId: String, filename: String, bytes: Int64, path: String) {
        progress = 1.0
        awaiting = (transferId, filename, bytes, path)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultTimeout) { [weak self] in
            guard let self, self.awaiting?.id == transferId else { return }
            self.settle(ok: false, error: "No confirmation from phone")
        }
    }

    /// `{"type":"file_transfer_result","transfer_id","ok"}` from the phone.
    func handleResult(json: [String: Any]) {
        DispatchQueue.main.async {
            guard let id = json["transfer_id"] as? String, id == self.awaiting?.id else { return }
            self.settle(ok: json["ok"] as? Bool ?? false, error: "Phone discarded the file")
        }
    }

    private func settle(ok: Bool, error: String) {
        guard let done = awaiting else { return }
        awaiting = nil
        pendingTransferId = nil
        pendingResumeOffset = 0
        if ok {
            transferState = .complete
            let history = FileTransferReceiver.shared
            history.transferHistory.insert(
                FileTransferReceiver.TransferRecord(filename: done.filename, bytes: done.bytes, state: "sent", path: done.path),
                at: 0)
            if history.transferHistory.count > 20 {
                history.transferHistory = Array(history.transferHistory.prefix(20))
            }
        } else {
            transferState = .error(error)
        }
        resetToIdleAfterDelay()
    }

    private func resetToIdleAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            switch self.transferState {
            case .complete, .error:
                self.transferState = .idle
                self.drainQueue(via: mDNSQuicServer.activeServer)
            default:
                break
            }
        }
    }
}

