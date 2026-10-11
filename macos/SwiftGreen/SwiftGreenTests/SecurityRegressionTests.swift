import XCTest
import Security
import CryptoKit
import Network
@testable import SwiftGreen

/// Regression tests for the fixes from the 2026-10 open-source readiness audit.
final class SecurityRegressionTests: XCTestCase {

    // Unpaired, a stranger's line that merely contained "publicKey" used to be dispatched.
    func testUnpairedMacAdmitsOnlyPairingRequests() {
        XCTAssertTrue(mDNSQuicServer.admitsWhileUnpaired(#"{"type":"pairing","publicKey":"AA==","pin_proof":""}"#))
        XCTAssertFalse(mDNSQuicServer.admitsWhileUnpaired(#"{"type":"clipboard_push","publicKey":"","source":"x","text":"rm -rf ~"}"#))
        XCTAssertFalse(mDNSQuicServer.admitsWhileUnpaired(#"{"appName":"Bank","title":"x","body":"y","timestamp":1,"publicKey":""}"#))
        XCTAssertFalse(mDNSQuicServer.admitsWhileUnpaired(#"SwiftGreen-Hello-Android "publicKey""#))
        XCTAssertFalse(mDNSQuicServer.admitsWhileUnpaired(""))
    }

    func testPreAuthBufferIsSmall() {
        XCTAssertEqual(mDNSQuicServer.maxBufferedBytes(verified: false), 64 * 1024)
        XCTAssertGreaterThan(mDNSQuicServer.maxBufferedBytes(verified: true), 256 * 1024 * 4 / 3) // one base64 file chunk
    }

    // The tests run inside the app; they must never touch the user's pairing key or identity.
    func testTestsUseTheirOwnKeychainItemAndIdentity() {
        XCTAssertTrue(TestHost.isActive, "the test host must recognise itself")
        XCTAssertEqual(PairingManager.keychainService, "SwiftGreen-tests")
        XCTAssertTrue(mDNSQuicServer.installIdentityURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(mDNSQuicServer.installIdentityURL.path.contains("Application Support"))
    }

    // File-transfer tests save real files; under the test host they must never resolve to ~/Downloads.
    func testTestHostNeverSavesIntoTheRealDownloads() {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").resolvingSymlinksInPath().path
        let used = FileTransferReceiver.downloadsDirectory.resolvingSymlinksInPath().path
        XCTAssertNotEqual(used, real)
        XCTAssertFalse(used.hasPrefix(real + "/"))
        XCTAssertTrue(used.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: used), "the receiver moves files into it, so it must exist")
    }

    // Used to read a developer's absolute path; on any other Mac TLS had no identity.
    func testGeneratesImportablePrivatePerInstallIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a/identity.p12"), b = dir.appendingPathComponent("b/identity.p12")
        // Off the main thread, as the app does it: generation waits for openssl and the
        // PKCS#12 import is slow enough that the system flags it on the main thread.
        var generatedA = false, generatedB = false, status: OSStatus = errSecParam
        var items: CFArray?
        let done = expectation(description: "identities generated and imported")
        DispatchQueue.global().async {
            generatedA = mDNSQuicServer.generateIdentity(at: a)
            generatedB = mDNSQuicServer.generateIdentity(at: b)
            if let p12 = try? Data(contentsOf: a) {
                status = SecPKCS12Import(p12 as CFData,
                                         [kSecImportExportPassphrase as String: "swiftgreen",
                                          kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        XCTAssertTrue(generatedA)
        XCTAssertTrue(generatedB)

        let mode = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertNotEqual(try Data(contentsOf: a), try Data(contentsOf: b), "installs must not share a key")
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil((items as? [[String: Any]])?.first?[kSecImportItemIdentity as String])
    }

    func testStreamedSha256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let (hex, count) = try XCTUnwrap(FileTransferReceiver.sha256Hex(of: url))
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(count, 3)
    }

    // Android sends the checksum only in file_transfer_complete. The Mac used to finalize
    // on the last chunk against "" and save the file unverified.
    func testAndroidStyleTransferWithWrongChecksumIsNotSaved() throws {
        let id = UUID().uuidString
        let name = "sg-test-\(id).txt"
        let saved = FileTransferReceiver.downloadsDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: saved) }
        let r = FileTransferReceiver.shared

        r.handleBegin(json: ["transfer_id": id, "filename": name, "mime_type": "text/plain",
                             "total_bytes": 5, "total_chunks": 1, "checksum_sha256": ""])
        r.handleChunk(json: ["transfer_id": id, "chunk_index": 0, "total_chunks": 1,
                             "data": Data("hello".utf8).base64EncodedString(), "is_final": true])
        r.handleComplete(json: ["transfer_id": id, "checksum_sha256": String(repeating: "0", count: 64)])

        // The receiver is one serial queue: once a good transfer queued after it is saved,
        // the bad one has been finalized. (A fixed sleep passed even if finalize never ran.)
        let marker = try XCTUnwrap(sendGoodTransfer())
        defer { try? FileManager.default.removeItem(at: marker) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path), "a file that fails its checksum must not be saved")
    }

    // begin used to hop to main while chunks ran on the socket queue, so a small file's
    // chunk could overtake its begin and be dropped. All three now go inline, in order.
    func testFileTransferLinesAreRoutedInline() {
        for type in ["file_transfer_begin", "file_transfer_chunk", "file_transfer_complete"] {
            XCTAssertNotNil(mDNSQuicServer.inlineFileTransferMessage(#"{"type":"\#(type)","transfer_id":"t"}"#), type)
        }
        XCTAssertNil(mDNSQuicServer.inlineFileTransferMessage(#"{"type":"file_transfer_cancel"}"#))
        // A notification whose text merely mentions a transfer type is not one.
        XCTAssertNil(mDNSQuicServer.inlineFileTransferMessage(#"{"appName":"x","body":"\"file_transfer_chunk\"","timestamp":1}"#))
        XCTAssertNil(mDNSQuicServer.inlineFileTransferMessage(#"{"type":"file_transfer_chunk""#))
    }

    // The app isn't sandboxed: a sender-chosen "../" name must land in Downloads only.
    func testTraversalFileNameLandsInDownloads() throws {
        let id = UUID().uuidString
        let leaf = "sg-test-\(id).plist"
        let downloads = FileTransferReceiver.downloadsDirectory
        let saved = downloads.appendingPathComponent(leaf)
        let escaped = downloads.deletingLastPathComponent().appendingPathComponent("Library/LaunchAgents/\(leaf)")
        defer { try? FileManager.default.removeItem(at: saved); try? FileManager.default.removeItem(at: escaped) }
        let body = Data("x".utf8)
        let r = FileTransferReceiver.shared
        r.handleBegin(json: ["transfer_id": id, "filename": "../Library/LaunchAgents/\(leaf)", "mime_type": "application/xml",
                             "total_bytes": 1, "total_chunks": 1, "checksum_sha256": ""])
        r.handleChunk(json: ["transfer_id": id, "chunk_index": 0, "total_chunks": 1,
                             "data": body.base64EncodedString(), "is_final": true])
        r.handleComplete(json: ["transfer_id": id,
                                "checksum_sha256": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()])

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: saved.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testBackToBackAndroidStyleTransferIsSaved() throws {
        let id = UUID().uuidString
        let name = "sg-test-\(id).txt"
        let saved = FileTransferReceiver.downloadsDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: saved) }
        let r = FileTransferReceiver.shared
        let body = Data("hello".utf8)

        // As the socket queue delivers them: one after another, no pause.
        DispatchQueue.global().sync {
            r.handleBegin(json: ["transfer_id": id, "filename": name, "mime_type": "text/plain",
                                 "total_bytes": 5, "total_chunks": 1, "checksum_sha256": ""])
            r.handleChunk(json: ["transfer_id": id, "chunk_index": 0, "total_chunks": 1,
                                 "data": body.base64EncodedString(), "is_final": true])
            r.handleComplete(json: ["transfer_id": id,
                                    "checksum_sha256": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()])
        }

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: saved.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(try Data(contentsOf: saved), body)
    }

    /// Sends a valid one-chunk transfer and waits until it is saved; nil if it never is.
    private func sendGoodTransfer() -> URL? {
        let id = UUID().uuidString, body = Data("ok".utf8)
        let url = FileTransferReceiver.downloadsDirectory.appendingPathComponent("sg-test-\(id).txt")
        let r = FileTransferReceiver.shared
        r.handleBegin(json: ["transfer_id": id, "filename": url.lastPathComponent, "mime_type": "text/plain",
                             "total_bytes": 2, "total_chunks": 1, "checksum_sha256": ""])
        r.handleChunk(json: ["transfer_id": id, "chunk_index": 0, "total_chunks": 1,
                             "data": body.base64EncodedString(), "is_final": true])
        r.handleComplete(json: ["transfer_id": id,
                                "checksum_sha256": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()])
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // SG-12: a replaced connection's late bytes used to land in the shared buffer and be
    // spliced into the next connection's first line.
    func testStaleConnectionBytesNeverReachTheNewConnection() {
        let server = mDNSQuicServer()
        let old = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let new = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        server.resetActive(old)
        XCTAssertEqual(server.ingest(Data(#"{"type":"clipboard_push","te"#.utf8), from: old), [])
        server.resetActive(new)
        XCTAssertEqual(server.ingest(Data("xt\":\"pwned\"}\n".utf8), from: old), [], "stale connection's bytes are ignored")
        XCTAssertEqual(server.ingest(Data(#"{"type":"challenge-response"}"#.utf8 + Data([0x0A])), from: new),
                       [#"{"type":"challenge-response"}"#], "the new connection starts with an empty buffer")
    }

    func testLineFramerIsByteSafeAndBounded() {
        var f = LineFramer()
        let line = Data("{\"t\":\"é\"}\n".utf8)
        let cut = line.firstIndex(of: 0xC3)! + 1          // split inside the two-byte é
        XCTAssertEqual(f.feed(line[..<cut], limit: 64), [])
        XCTAssertEqual(f.feed(line[cut...], limit: 64), ["{\"t\":\"é\"}"])
        XCTAssertEqual(f.feed(Data("a\nb\nc".utf8), limit: 64), ["a", "b"])
        XCTAssertNil(f.feed(Data(repeating: 0x41, count: 65), limit: 64), "an endless line is refused")
    }

    // Same vector as Android's MacCertPinTest: HMAC(K, "SwiftGreen-tls-id|" ‖ C ‖ F).
    func testChallengeOKCarriesTheProvenCertificateFingerprint() throws {
        let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
        let nonce = Data(repeating: 7, count: 32)
        let fingerprint = Data(SHA256.hash(data: Data("cert".utf8)))
        let line = mDNSQuicServer.challengeOK(proof: Data([1]), clientNonce: nonce, fingerprint: fingerprint, key: key)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["tls_id"] as? String, fingerprint.base64EncodedString())
        let proof = try XCTUnwrap(Data(base64Encoded: json["tls_id_proof"] as? String ?? ""))
        XCTAssertEqual(proof.map { String(format: "%02x", $0) }.joined(),
                       "6acfada117ce6bc40786d440d1f80c64363d7da65dd9a0408f7ae1883b9545ce")
        XCTAssertNil((try? JSONSerialization.jsonObject(with: Data(mDNSQuicServer.challengeOK(
            proof: Data([1]), clientNonce: nonce, fingerprint: nil, key: key).utf8)) as? [String: Any])?["tls_id"])
    }

    func testInstallIdentityHasAStableFingerprint() throws {
        let a = try XCTUnwrap(mDNSQuicServer.tlsIdentity()), b = try XCTUnwrap(mDNSQuicServer.tlsIdentity())
        XCTAssertEqual(a.fingerprint.count, 32)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
    }
}
