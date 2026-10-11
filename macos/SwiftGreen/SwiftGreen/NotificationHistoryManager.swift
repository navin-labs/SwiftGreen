import Foundation
import Combine

class NotificationHistoryManager: ObservableObject {
    static let shared = NotificationHistoryManager()

    struct NotificationRecord: Identifiable, Codable {
        var id: String { key }
        let appName: String
        let title: String
        let body: String
        let timestampMs: Int64
        let key: String
        var appIcon: String?       // base64 PNG
        var senderPhoto: String?   // base64 PNG

        /// Android's own notification key, needed to route a reply back. Distinct
        /// from `key`, which is a locally-synthesised de-duplication id.
        /// Optional so history persisted before in-app reply shipped still decodes.
        var androidKey: String? = nil
        var replyLabel: String? = nil
        /// Android's StatusBarNotification.key, sent back with a reply.
        var sbnKey: String? = nil

        var canReply: Bool { androidKey != nil && replyLabel != nil }
    }

    @Published var history: [NotificationRecord] = []

    var unreadCount: Int {
        history.filter { $0.timestampMs > lastReadTimestampMs }.count
    }

    private let prefsKey = "swiftgreen_notification_history"
    private let kLastReadKey = "notification_last_read_ms"
    private let maxItems = 50
    /// UserDefaults refuses values over ~4 MiB, and base64 photos make records large.
    static let maxPersistedBytes = 1 << 20
    private var lastReadTimestampMs: Int64 = 0
    private let defaults: UserDefaults

    /// `defaults` is a parameter only so the tests can use their own suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        lastReadTimestampMs = Int64(defaults.integer(forKey: kLastReadKey))
    }

    func addRecord(_ record: NotificationRecord) {
        history.removeAll { $0.key == record.key }
        history.insert(record, at: 0)
        if history.count > maxItems {
            history = Array(history.prefix(maxItems))
        }
        persist()
    }

    func markAllRead() {
        lastReadTimestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        defaults.set(lastReadTimestampMs, forKey: kLastReadKey)
        objectWillChange.send()
    }

    func clearAll() {
        history = []
        defaults.removeObject(forKey: prefsKey)
    }

    private func persist() {
        defaults.set(Self.encodedWithinBudget(history), forKey: prefsKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: prefsKey),
              let decoded = try? JSONDecoder().decode([NotificationRecord].self, from: data) else {
            return
        }
        history = decoded
        // History saved by a build without the budget can be oversized; shrink it once.
        if data.count > Self.maxPersistedBytes { persist() }
    }

    /// Encodes newest-first `records` in at most `budget` bytes. Media goes first,
    /// oldest record first; only then are the oldest records dropped, so text survives longest.
    static func encodedWithinBudget(_ records: [NotificationRecord], budget: Int = maxPersistedBytes) -> Data {
        let encoder = JSONEncoder()
        func size(_ r: NotificationRecord) -> Int { (try? encoder.encode(r).count) ?? 0 }
        var kept = records
        var sizes = kept.map(size)
        // JSON array: "[" + elements joined by "," + "]"
        var total = sizes.reduce(0, +) + max(kept.count - 1, 0) + 2
        var i = kept.count - 1
        while total > budget && i >= 0 {
            if kept[i].appIcon != nil || kept[i].senderPhoto != nil {
                kept[i].appIcon = nil
                kept[i].senderPhoto = nil
                let s = size(kept[i])
                total -= sizes[i] - s
                sizes[i] = s
            }
            i -= 1
        }
        while total > budget, let last = sizes.popLast() {
            kept.removeLast()
            total -= last + (kept.isEmpty ? 0 : 1)
        }
        var data = (try? encoder.encode(kept)) ?? Data("[]".utf8)
        // The size sum matches JSONEncoder's compact output; this only guards against drift.
        while data.count > budget, !kept.isEmpty {
            kept.removeLast()
            data = (try? encoder.encode(kept)) ?? Data("[]".utf8)
        }
        return data
    }
}
