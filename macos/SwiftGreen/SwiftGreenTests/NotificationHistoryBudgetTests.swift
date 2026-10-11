import XCTest
@testable import SwiftGreen

/// Histories with base64 photos (notifications) or 1 MiB clippings outgrew UserDefaults'
/// ~4 MiB per-value limit, so saving them failed.
@MainActor
final class NotificationHistoryBudgetTests: XCTestCase {
    private typealias Record = NotificationHistoryManager.NotificationRecord
    private let budget = NotificationHistoryManager.maxPersistedBytes

    private func record(_ n: Int, photoBytes: Int, bodyBytes: Int = 6) -> Record {
        let photo = String(repeating: "A", count: photoBytes)
        return Record(appName: "App", title: "Title \(n)", body: String(repeating: "b", count: bodyBytes),
                      timestampMs: Int64(n), key: "k\(n)", appIcon: photo, senderPhoto: photo)
    }

    private func decode(_ data: Data) throws -> [Record] {
        try JSONDecoder().decode([Record].self, from: data)
    }

    func testBudgetIsWellUnderTheUserDefaultsLimit() {
        XCTAssertLessThanOrEqual(budget, 1 << 20)
    }

    func testSmallHistoryIsSavedUnchanged() throws {
        let records = (0..<5).map { record($0, photoBytes: 100) }
        let saved = try decode(NotificationHistoryManager.encodedWithinBudget(records))
        XCTAssertEqual(saved.map(\.key), records.map(\.key))
        XCTAssertTrue(saved.allSatisfy { $0.appIcon != nil && $0.senderPhoto != nil })
    }

    func testOversizedHistoryDropsOldMediaBeforeAnyText() throws {
        // 50 records × 2 × 200 KB of photos ≈ 20 MB; the text alone fits easily.
        let records = (0..<50).map { record($0, photoBytes: 200_000) }
        let data = NotificationHistoryManager.encodedWithinBudget(records)
        XCTAssertLessThanOrEqual(data.count, budget)
        let saved = try decode(data)
        XCTAssertEqual(saved.map(\.key), records.map(\.key), "every notification's text is kept")
        XCTAssertNotNil(saved.first?.senderPhoto, "the newest record keeps its photo")
        XCTAssertNil(saved.last?.senderPhoto, "the oldest record loses its photo first")
        XCTAssertNil(saved.last?.appIcon)
    }

    func testRecordWhoseOnlyExcessIsMediaKeepsItsText() throws {
        let data = NotificationHistoryManager.encodedWithinBudget([record(0, photoBytes: 6_000_000)])
        XCTAssertLessThanOrEqual(data.count, budget)
        let saved = try decode(data)
        XCTAssertEqual(saved.first?.title, "Title 0")
        XCTAssertNil(saved.first?.senderPhoto, "the 6 MB photos are what was dropped")
    }

    func testTextOverBudgetDropsOldestRecordsAndKeepsNewest() throws {
        let records = (0..<50).map { record($0, photoBytes: 0, bodyBytes: 1_000) }
        let data = NotificationHistoryManager.encodedWithinBudget(records, budget: 20_000)
        XCTAssertLessThanOrEqual(data.count, 20_000)
        let saved = try decode(data)
        XCTAssertFalse(saved.isEmpty)
        XCTAssertEqual(saved.map(\.key), Array(records.prefix(saved.count)).map(\.key))
    }

    func testSingleRecordWhoseTextAloneExceedsBudgetIsNotSaved() throws {
        let data = NotificationHistoryManager.encodedWithinBudget([record(0, photoBytes: 0, bodyBytes: 2 << 20)])
        XCTAssertLessThanOrEqual(data.count, budget)
        XCTAssertEqual(try decode(data).count, 0)
    }

    func testOversizedStoredHistoryIsRepairedOnLoad() throws {
        let suite = "SwiftGreen-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // As a build without the budget saved it: about 3 MB, under the 4 MiB limit.
        let records = (0..<15).map { record($0, photoBytes: 100_000) }
        let oversized = try JSONEncoder().encode(records)
        XCTAssertGreaterThan(oversized.count, budget)
        defaults.set(oversized, forKey: "swiftgreen_notification_history")

        let manager = NotificationHistoryManager(defaults: defaults)

        XCTAssertEqual(manager.history.map(\.key), records.map(\.key), "this session still has everything")
        let stored = try XCTUnwrap(defaults.data(forKey: "swiftgreen_notification_history"))
        XCTAssertLessThanOrEqual(stored.count, budget)
        XCTAssertEqual(try decode(stored).map(\.key), records.map(\.key), "text survives the repair")
    }

    func testClipboardHistoryDropsOldestUnpinnedFirst() throws {
        let clip = { (n: Int, pinned: Bool) in
            ClipboardRecord(id: "c\(n)", text: String(repeating: "x", count: 1 << 20), source: "mac",
                            timestampMs: Int64(n), pinned: pinned)
        }
        // Newest first, as stored: 20 one-MiB clippings, the oldest one pinned.
        let records = (0..<20).map { clip($0, $0 == 19) }
        let data = ClipboardSyncManager.encodedWithinBudget(records, budget: 3 << 20)
        XCTAssertLessThanOrEqual(data.count, 3 << 20)
        let saved = try JSONDecoder().decode([ClipboardRecord].self, from: data)
        XCTAssertEqual(saved.map(\.id), ["c0", "c19"], "the newest clipping and the pinned one")
    }

    func testOneHugeClippingDoesNotPushOutTheRest() throws {
        let small = (1...5).map { ClipboardRecord(id: "s\($0)", text: "hello \($0)", source: "android", timestampMs: Int64($0)) }
        let huge = ClipboardRecord(id: "huge", text: String(repeating: "x", count: 5 << 20), source: "mac", timestampMs: 9)
        let data = ClipboardSyncManager.encodedWithinBudget([huge] + small)
        XCTAssertLessThanOrEqual(data.count, budget)
        let saved = try JSONDecoder().decode([ClipboardRecord].self, from: data)
        XCTAssertEqual(saved.map(\.id), small.map(\.id))
    }
}
