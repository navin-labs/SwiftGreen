//
//  ClipboardSyncManager.swift
//  SwiftGreen
//
//  Created by Navin Rana on 02/06/26.
//

import AppKit
import Foundation
import Network
import os.log
import Combine

struct ClipboardRecord: Identifiable, Codable {
    var id: String
    let text: String
    let source: String
    let timestampMs: Int64
    var pinned: Bool

    init(id: String, text: String, source: String, timestampMs: Int64, pinned: Bool = false) {
        self.id = id; self.text = text; self.source = source
        self.timestampMs = timestampMs; self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decode(String.self, forKey: .source)
        timestampMs = try c.decode(Int64.self, forKey: .timestampMs)
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
    }
}

// MARK: - ClipboardSyncManager

final class ClipboardSyncManager: ObservableObject {

    static let shared = ClipboardSyncManager()

    // Plain var — NWConnection is not weak-able in this context
    var connection: NWConnection?

    @Published var history: [ClipboardRecord] = []

    // MARK: - Private State

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastWrittenContent: String? = nil

    private let clipboardLog = OSLog(subsystem: "com.swiftgreen", category: "clipboard")

    // Max inbound text: 1 MiB
    private static let maxTextBytes = 1_048_576

    // MARK: - Init

    private init() {
        if let data = UserDefaults.standard.data(forKey: "clipboard_history"),
           let loaded = try? JSONDecoder().decode([ClipboardRecord].self, from: data) {
            self.history = loaded
            // History saved by a build without the budget can be oversized; shrink it once.
            if data.count > NotificationHistoryManager.maxPersistedBytes { persist() }
        }
    }

    private func persist() {
        UserDefaults.standard.set(Self.encodedWithinBudget(history), forKey: "clipboard_history")
    }

    /// Encodes newest-first `records` in at most `budget` bytes. A clipping can be a
    /// megabyte or more, so 20 of them overflowed UserDefaults' ~4 MiB limit and the save
    /// failed. A clipping too big to ever fit is skipped (it stays in memory for this
    /// session); then the oldest unpinned clippings go, then the oldest pinned ones.
    static func encodedWithinBudget(_ records: [ClipboardRecord],
                                    budget: Int = NotificationHistoryManager.maxPersistedBytes) -> Data {
        let encoder = JSONEncoder()
        var kept = records.map { ($0, (try? encoder.encode($0).count) ?? 0) }.filter { $0.1 + 2 <= budget }
        // JSON array: "[" + elements joined by "," + "]"
        var total = kept.reduce(2) { $0 + $1.1 } + max(kept.count - 1, 0)
        while total > budget, let i = kept.lastIndex(where: { !$0.0.pinned }) ?? kept.indices.last {
            total -= kept[i].1 + 1
            kept.remove(at: i)
        }
        var data = (try? encoder.encode(kept.map(\.0))) ?? Data("[]".utf8)
        // The size sum matches JSONEncoder's compact output; this only guards against drift.
        while data.count > budget, !kept.isEmpty {
            kept.removeLast()
            data = (try? encoder.encode(kept.map(\.0))) ?? Data("[]".utf8)
        }
        return data
    }

    func addRecord(text: String, source: String) {
        let block = {
            if let first = self.history.first, first.text == text { return }
            let record = ClipboardRecord(id: UUID().uuidString, text: text, source: source, timestampMs: Int64(Date().timeIntervalSince1970 * 1000))
            self.history.insert(record, at: 0)
            let pinned = self.history.filter { $0.pinned }
            let unpinned = self.history.filter { !$0.pinned }
            if unpinned.count > 20 {
                self.history = pinned + Array(unpinned.prefix(20))
            }
            self.persist()
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async { block() }
        }
    }

    func togglePin(id: String) {
        let block = {
            guard let idx = self.history.firstIndex(where: { $0.id == id }) else { return }
            self.history[idx].pinned.toggle()
            self.persist()
        }
        if Thread.isMainThread { block() } else { DispatchQueue.main.async { block() } }
    }

    func writeLocalOnly(_ text: String) {
        lastWrittenContent = text
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.lastChangeCount = NSPasteboard.general.changeCount
        }
    }

    func clearAll() {
        let block = {
            self.history = []
            UserDefaults.standard.removeObject(forKey: "clipboard_history")
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async { block() }
        }
    }

    // MARK: - Monitoring
    // All methods that touch timer or NSPasteboard must run on main thread only.

    func startMonitoring() {
        guard timer == nil else { return }
        // Safe: startMonitoring() is always dispatched via DispatchQueue.main.async
        // in mDNSQuicServer.swift before this is called.
        lastChangeCount = NSPasteboard.general.changeCount

        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        os_log("Clipboard monitoring started", log: clipboardLog, type: .info)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        os_log("Clipboard monitoring stopped", log: clipboardLog, type: .info)
    }

    // MARK: - Poll (Main thread only — called by Timer)

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        // A file copied in Finder also carries its name as plain text. That name isn't
        // what anyone meant to copy, so don't sync it; the Overview offers to send
        // the file itself instead.
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return }
        // Text path (unchanged)
        if let text = pb.string(forType: .string), !text.isEmpty {
            // Loop guard: if this is content we just wrote ourselves, skip it
            if text == lastWrittenContent {
                lastWrittenContent = nil
                return
            }
            pushToMac(text: text)
            addRecord(text: text, source: "mac")
            return
        }
        // Text first: when a source puts both text and an image on the pasteboard (e.g. an
        // RTF copy in Preview), the text is sent and the image is not.
        pushImageToAndroid(pb: pb)
    }

    // MARK: - Send (Mac → Android)

    private func pushToMac(text: String) {
        guard connection != nil else {
            os_log("No active connection — clipboard push dropped", log: clipboardLog, type: .error)
            return
        }

        // JSONSerialization, not hand escaping: the hand-rolled version escaped only
        // \\ \" \n \r \t, so any other control character in copied text made invalid JSON.
        let payload: [String: Any] = [
            "type": "clipboard_push", "content_type": "text", "text": text,
            "image_base64": NSNull(), "image_mime_type": NSNull(), "source": "mac",
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            os_log("Failed to encode clipboard payload", log: clipboardLog, type: .error)
            return
        }
        data.append(0x0A)

        connection?.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .idempotent
        )
        os_log("CLIPBOARD_PUSH sent (%d chars)", log: clipboardLog, type: .info, text.count)
    }

    private func pushImageToAndroid(pb: NSPasteboard) {
        guard connection != nil else {
            os_log("No active connection — image clipboard push dropped", log: clipboardLog, type: .error)
            return
        }
        guard let tiffData = pb.data(forType: .tiff) ?? pb.data(forType: .png) else { return }
        guard let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            os_log("Failed to normalize pasteboard image to PNG", log: clipboardLog, type: .error)
            return
        }
        let base64 = pngData.base64EncodedString()
        guard base64.count <= 10 * 1024 * 1024 else {
            os_log("Image exceeds 10 MiB base64 cap (%d chars) — skipping", log: clipboardLog, type: .info, base64.count)
            return
        }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let json = "{\"type\":\"clipboard_push\",\"content_type\":\"image\",\"text\":null,\"image_base64\":\"\(base64)\",\"image_mime_type\":\"image/png\",\"source\":\"mac\",\"timestamp_ms\":\(timestamp)}\n"
        guard let data = json.data(using: .utf8) else { return }
        connection?.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .idempotent)
        os_log("CLIPBOARD_PUSH image sent (%d base64 chars)", log: clipboardLog, type: .info, base64.count)
    }

    // MARK: - Receive (Android → Mac)

    func receiveImageFromAndroid(base64: String, mimeType: String) {
        guard let imageData = Data(base64Encoded: base64),
              let image = NSImage(data: imageData) else {
            os_log("Failed to decode incoming image clipboard", log: clipboardLog, type: .error)
            return
        }
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            self.lastChangeCount = pb.changeCount
            os_log("Clipboard image written from Android", log: self.clipboardLog, type: .info)
        }
    }

    func receiveFromAndroid(_ text: String) {
        // Double-guard: source check should already be done by caller
        guard text.count <= Self.maxTextBytes else {
            os_log("Dropping incoming clipboard — exceeds 1 MiB (%d bytes)", log: clipboardLog, type: .error, text.utf8.count)
            return
        }

        guard !text.isEmpty else {
            os_log("Dropping incoming clipboard — empty text", log: clipboardLog, type: .debug)
            return
        }

        // Set loop guard BEFORE writing so checkPasteboard() skips the echo
        lastWrittenContent = text

        DispatchQueue.main.async {
            self.addRecord(text: text, source: "android")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            // Snapshot the new changeCount so the poller doesn't re-fire on it
            self.lastChangeCount = NSPasteboard.general.changeCount
            os_log("Clipboard written from Android (%d chars)", log: self.clipboardLog, type: .info, text.count)
        }
    }
}
