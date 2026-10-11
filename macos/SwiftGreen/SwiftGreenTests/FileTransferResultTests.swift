import XCTest
@testable import SwiftGreen

/// The Mac used to show "complete" once the last chunk was queued, before the phone had
/// written and verified the file. Now only the phone's file_transfer_result settles it.
@MainActor
final class FileTransferResultTests: XCTestCase {
    private let sender = FileTransferSender.shared

    private func settle(_ json: [String: Any]) async {
        sender.handleResult(json: json)
        await Task.yield()
        await MainActor.run {}   // handleResult hops to the main queue
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testOnlyTheMatchingResultSettlesTheTransfer() async {
        sender.transferState = .sending
        sender.awaitResult(transferId: "t1", filename: "a.txt", bytes: 1, path: "/tmp/a.txt")
        XCTAssertTrue(sender.finishingOnPhone, "all sent, waiting on the phone")

        await settle(["type": "file_transfer_result", "transfer_id": "other", "ok": true])
        XCTAssertEqual(sender.transferState, .sending, "a result for another transfer is ignored")

        await settle(["type": "file_transfer_result", "transfer_id": "t1", "ok": true])
        XCTAssertEqual(sender.transferState, .complete)
        XCTAssertFalse(sender.finishingOnPhone)
    }

    func testPhoneDiscardIsAnError() async {
        sender.transferState = .sending
        sender.awaitResult(transferId: "t2", filename: "b.txt", bytes: 1, path: "/tmp/b.txt")
        await settle(["type": "file_transfer_result", "transfer_id": "t2", "ok": false])
        XCTAssertEqual(sender.transferState, .error("Phone discarded the file"))
    }
}
