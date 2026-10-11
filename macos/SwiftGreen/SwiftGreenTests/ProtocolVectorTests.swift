import XCTest
import CryptoKit
@testable import SwiftGreen

/// Same vectors as the Android tests (UnpairProofTest, HkdfTest), computed independently
/// with Python's hmac over K = bytes 0x00..0x1f. If either side drifts, pairing or unpair breaks.
final class ProtocolVectorTests: XCTestCase {
    private let key = SymmetricKey(data: Data(0..<32))
    private func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testUnpairProofMatchesAndroid() {
        XCTAssertEqual(hex(PairingManager.unpairProof(key)),
                       "f3c964442808f6b63f3176acab49d0f8b48bd8542fc2ad2789ab2f8acd2669a2")
    }

    func testHkdfParametersMatchAndroid() {
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(), info: Data("SwiftGreen-v1".utf8), outputByteCount: 32)
        XCTAssertEqual(okm.withUnsafeBytes { hex($0) },
                       "0c63b3717a267c7747352a06f49369af034f356e4dabdf2dae067afdd5664129")
    }

    func testPinProofMatchesPython() {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("SwiftGreen-pin|123456".utf8), using: key)
        XCTAssertEqual(hex(mac), "219e636fca18b7641f3465abb6a4cca462d248ae82e62b60b6f7afc36476efbb")
    }
}
