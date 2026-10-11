//
//  PairingManager.swift
//  SwiftGreen
//
//  Created by Navin Rana on 28/05/26.
//

import Foundation
import SwiftUI
import Security
import CryptoKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Pairing Manager
class PairingManager: ObservableObject {
    @Published var isPaired: Bool = false
    @Published var pairingPIN: String = ""
    @Published var qrPayloadJSON: String = ""
    
    weak var quicServer: mDNSQuicServer?
    
    private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    // The PIN is shown on screen only, never in the QR (PROTOCOL.md §3.1): the
    // phone must type it, so a stolen QR or a LAN host that never saw the screen can't pair.
    private var sessionPIN = ""
    private var sessionCreated = Date()
    private var failedPINAttempts = 0
    
    // Keychain constants
    // The tests get their own item, so they never read (or prompt for) the real pairing key.
    static let keychainService = TestHost.isActive ? "SwiftGreen-tests" : "SwiftGreen"
    private static let keychainAccount = "SwiftGreen-PairedKey"
    
    init() {
        self.ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        
        // Check if already paired by looking for key in Keychain
        if PairingManager.loadPairedKeyData() != nil {
            self.isPaired = true
            print("🔑 [PairingManager] init — Found existing paired key in Keychain. isPaired = true")
        } else {
            self.isPaired = false
            print("🔑 [PairingManager] init — No paired key in Keychain. isPaired = false")
            generatePairingSession()
        }
    }
    
    // MARK: - Generate Pairing Session
    /// Creates a fresh ephemeral key, random PIN, and QR payload JSON.
    func generatePairingSession() {
        // Generate new ephemeral Curve25519 key
        ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyBase64 = ephemeralPrivateKey.publicKey.rawRepresentation.base64EncodedString()
        
        // Generate random 6-digit PIN
        let pin = String(format: "%06d", Int.random(in: 0...999999))
        
        // Build hostname
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        
        sessionPIN = pin
        sessionCreated = Date()
        failedPINAttempts = 0

        // Build JSON payload — deliberately without the PIN. "tls" is this install's
        // certificate fingerprint: the phone checks the pairing connection against it
        // (a man in the middle presents another certificate) and pins it (SG-09).
        var payload: [String: String] = [
            "publicKey": publicKeyBase64,
            "hostname": hostname
        ]
        if let fingerprint = mDNSQuicServer.tlsIdentity()?.fingerprint {
            payload["tls"] = fingerprint.base64EncodedString()
        }
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            DispatchQueue.main.async {
                self.pairingPIN = pin
                self.qrPayloadJSON = jsonString
            }
            print("🔑 [PairingManager] generatePairingSession() — New session created")
        } else {
            print("❌ [PairingManager] generatePairingSession() — Failed to serialize JSON payload")
        }
    }
    
    /// The QR payload plus where to dial. Many routers (ISP, office, guest) drop mDNS
    /// between devices but pass direct connections, so the phone tries these first.
    /// Built at render time so it carries the Mac's current address and listener port.
    func qrPayload(port: UInt16?) -> String {
        let ips = Self.localIPv4Addresses()
        guard let port, !ips.isEmpty,
              var obj = (try? JSONSerialization.jsonObject(with: Data(qrPayloadJSON.utf8))) as? [String: Any]
        else { return qrPayloadJSON }
        obj["ips"] = ips
        obj["port"] = Int(port)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return qrPayloadJSON }
        return json
    }

    /// IPv4 addresses of active Wi-Fi/Ethernet interfaces (en*), skipping link-local.
    private static func localIPv4Addresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ips: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254.") { ips.append(ip) }
        }
        return ips
    }

    // MARK: - Complete Pairing (ECDH + HKDF)
    enum PairingResult { case paired, wrongPIN, expired, failed }

    /// Receives the Android device's public key, performs ECDH key agreement,
    /// derives a symmetric key via HKDF-SHA256, checks the phone's proof of the typed
    /// PIN against it, and only then stores the key in the Keychain. 3 wrong PINs or a
    /// code older than 3 minutes retire the session: a new QR and PIN appear.
    func completePairing(androidPublicKeyBase64: String, pinProofBase64: String) -> PairingResult {
        print("🔑 [PairingManager] completePairing() — Received Android public key: \(androidPublicKeyBase64)")
        
        guard let androidPublicKeyData = Data(base64Encoded: androidPublicKeyBase64) else {
            print("❌ [PairingManager] completePairing() — Failed to decode Android public key from Base64")
            return .failed
        }
        
        do {
            let androidPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: androidPublicKeyData)
            
            // Perform ECDH key agreement
            let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: androidPublicKey)
            print("🔑 [PairingManager] completePairing() — ECDH shared secret derived successfully")
            
            // Derive symmetric key via HKDF-SHA256
            let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: "SwiftGreen-v1".data(using: .utf8)!,
                outputByteCount: 32
            )
            print("🔑 [PairingManager] completePairing() — HKDF-SHA256 derived 32-byte symmetric key")

            if Date().timeIntervalSince(sessionCreated) > 180 {
                print("❌ [PairingManager] completePairing() — Pairing code expired")
                generatePairingSession()
                return .expired
            }
            // Keyed by the ECDH result, so only the device that scanned this QR (it has the
            // Mac's public key) and read the PIN off this screen can produce it.
            let proof = Data(base64Encoded: pinProofBase64) ?? Data()
            guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("SwiftGreen-pin|\(sessionPIN)".utf8),
                                                         using: derivedKey) else {
                failedPINAttempts += 1
                print("❌ [PairingManager] completePairing() — Wrong PIN (attempt \(failedPINAttempts)/3)")
                if failedPINAttempts >= 3 { generatePairingSession(); return .expired }
                return .wrongPIN
            }
            
            // Extract raw bytes and store in Keychain
            let keyData = derivedKey.withUnsafeBytes { Data($0) }
            let saved = PairingManager.savePairedKey(keyData)
            
            if saved {
                // A new key: the old unpair proof is for a pairing that no longer exists.
                PairingManager.unpairTombstone = nil
                DispatchQueue.main.async {
                    self.isPaired = true
                }
                print("✅ [PairingManager] completePairing() — Paired key stored in Keychain. isPaired = true")
                return .paired
            } else {
                print("❌ [PairingManager] completePairing() — Failed to store paired key in Keychain")
                return .failed
            }
        } catch {
            print("❌ [PairingManager] completePairing() — Cryptographic error: \(error.localizedDescription)")
            return .failed
        }
    }
    
    // MARK: - Reset Pairing
    /// Deletes the Keychain entry, clears cached state, and sets isPaired to false.
    func resetPairing(notifyPeer: Bool = true) {
        print("🔑 [PairingManager] resetPairing() — Deleting paired key from Keychain")
        
        if notifyPeer, let server = quicServer, server.isTunnelActive {
            print("🔑 [PairingManager] resetPairing() — Sending unpair_request to Android client before local wipe")
            server.sendMessage("{\"type\":\"unpair_request\"}") { [weak self, weak server] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.wipeLocalPairingState()
                    server?.closeActiveConnection()
                }
            }
            return
        } else if notifyPeer {
            print("🔑 [PairingManager] resetPairing() — No active tunnel; local wipe only")
        }
        
        wipeLocalPairingState()
        quicServer?.closeActiveConnection()
    }
    
    private func wipeLocalPairingState() {
        // Kept after the key is gone, so a phone that was away when this Mac unpaired
        // learns it on its next connect instead of retrying forever (PROTOCOL.md §3.4).
        if let key = PairingManager.loadPairedKey() {
            PairingManager.unpairTombstone = PairingManager.unpairProof(key)
        }
        PairingManager.deletePairedKey()
        
        DispatchQueue.main.async {
            self.isPaired = false
            self.pairingPIN = ""
            self.qrPayloadJSON = ""
        }
        
        // Generate a fresh session so the QR view is ready
        generatePairingSession()
        print("✅ [PairingManager] resetPairing() — Pairing cleared. New session generated.")
    }
    
    // MARK: - Unpair Proof

    /// HMAC(K, "SwiftGreen-unpaired"). Proves an unpair came from the paired peer. One-way,
    /// so it gives nothing toward K, and no other check accepts it. Same value on the phone
    /// (PairingManager.unpairProof in the Android app).
    static func unpairProof(_ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("SwiftGreen-unpaired".utf8), using: key))
    }

    /// The last pairing's unpair proof, kept after unpairing until the next pairing. Not a
    /// secret: it authenticates nothing but "that pairing is over".
    static var unpairTombstone: Data? {
        get { UserDefaults.standard.data(forKey: "swiftgreen_unpair_proof") }
        set { UserDefaults.standard.set(newValue, forKey: "swiftgreen_unpair_proof") }
    }

    // MARK: - Static Key Loader
    /// Reads the paired symmetric key from the Keychain and returns it as a CryptoKit SymmetricKey.
    static func loadPairedKey() -> SymmetricKey? {
        guard let data = loadPairedKeyData() else { return nil }
        return SymmetricKey(data: data)
    }
    
    // MARK: - Keychain Helpers (Private)
    
    /// Saves the raw key bytes to the Keychain.
    @discardableResult
    private static func savePairedKey(_ keyData: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        
        let attributes: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        cacheLock.lock(); cachedKeyData = nil; cacheLock.unlock()
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            print("🔐 [Keychain] savePairedKey — Successfully updated \(keyData.count) bytes")
            return true
        } else if updateStatus != errSecItemNotFound {
            print("❌ [Keychain] savePairedKey — SecItemUpdate failed with status: \(updateStatus)")
            return false
        }
        
        var addQuery = query
        attributes.forEach { key, value in
            addQuery[key] = value
        }
        
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            print("🔐 [Keychain] savePairedKey — Successfully stored \(keyData.count) bytes")
            return true
        } else {
            print("❌ [Keychain] savePairedKey — SecItemAdd failed with status: \(addStatus)")
            return false
        }
    }
    
    /// Deletes the paired key from the Keychain.
    private static func deletePairedKey() {
        cacheLock.lock(); cachedKeyData = nil; cacheLock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            print("🔐 [Keychain] deletePairedKey — Key deleted successfully")
        } else if status == errSecItemNotFound {
            print("🔐 [Keychain] deletePairedKey — No key found to delete (expected on first run)")
        } else {
            print("❌ [Keychain] deletePairedKey — SecItemDelete failed with status: \(status)")
        }
    }
    
    /// The key as last read or saved. Every reconnect checks it, and an ad-hoc signed build
    /// gets a Keychain prompt per read until the user chooses Always Allow, so it is read once.
    private static let cacheLock = NSLock()
    private static var cachedKeyData: Data?

    /// Loads the raw paired key bytes from the Keychain.
    private static func loadPairedKeyData() -> Data? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedKeyData { return cachedKeyData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data {
            print("🔐 [Keychain] loadPairedKeyData — Loaded \(data.count) bytes from Keychain")
            cachedKeyData = data
            return data
        } else if status == errSecItemNotFound {
            print("🔐 [Keychain] loadPairedKeyData — No key found in Keychain")
            return nil
        } else {
            print("❌ [Keychain] loadPairedKeyData — SecItemCopyMatching failed with status: \(status)")
            return nil
        }
    }
}

// MARK: - QR Code Generation Helper
private func generateQRCodeNSImage(from string: String) -> NSImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    
    guard let ciImage = filter.outputImage else {
        print("❌ [QR] Failed to generate CIImage from QR filter")
        return nil
    }
    
    // Scale up for crisp rendering (QR codes are tiny by default)
    let scale = CGAffineTransform(scaleX: 12, y: 12)
    let scaledImage = ciImage.transformed(by: scale)
    
    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
        print("❌ [QR] Failed to create CGImage from scaled CIImage")
        return nil
    }
    
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    return nsImage
}

// MARK: - Pairing QR View
struct PairingQRView: View {
    @ObservedObject var pairingManager: PairingManager
    @ObservedObject var quicServer: mDNSQuicServer
    @State private var confirmReset = false

    private var isOnline: Bool { quicServer.serverStatus == mDNSQuicServer.onlineStatus }
    private var phoneName: String {
        let n = quicServer.androidDeviceInfo?.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? (quicServer.androidDeviceInfo?.model ?? "Your Android phone") : n
    }

    /// Inline section content for Settings — no title or scroll view of its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pairingManager.isPaired {
                // Like the account card atop System Settings: who you're linked to.
                HStack(spacing: SG.Space.lg) {
                    Image(systemName: "smartphone")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Color.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.sgSurfaceHigh))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phoneName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.white)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isOnline ? Color.sgSuccess : Color.sgDanger)
                                .frame(width: 6, height: 6)
                            Text(isOnline ? "Connected" : "Not connected")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white)
                        }
                        Text("Encrypted on your local network · no cloud")
                            .font(SG.Font.caption)
                            .foregroundStyle(Color.sgTextSecondary)
                    }
                    Spacer()
                    // Irreversible: the Keychain key is gone and both sides must
                    // re-scan a QR code, so it always asks first.
                    Button("Unpair…") { confirmReset = true }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.sgDanger)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(Color(white: 0.2)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .buttonStyle(.plain)
                        .confirmationDialog("Unpair \(phoneName)?", isPresented: $confirmReset) {
                            Button("Unpair", role: .destructive) {
                                pairingManager.resetPairing()
                            }
                        } message: {
                            Text("Sync stops right away. You'll scan a new code to connect again.")
                        }
                }
                .sgCard()
            } else {
                Text("Open SwiftGreen on your Android phone and scan this code.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sgTextSecondary)
                HStack(alignment: .top, spacing: 16) {
                    qrCodeCard
                    VStack(spacing: 12) {
                        pinDisplayCard
                        Button(action: { pairingManager.generatePairingSession() }) {
                            Label("Generate New Code", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }

            if !pairingManager.isPaired {
            HStack(spacing: 6) {
                Circle()
                    .fill(quicServer.isRunning ? Color.white : Color.sgTextSecondary)
                    .frame(width: 6, height: 6)
                Text(quicServer.isRunning ? "Server broadcasting on your network" : "Server idle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.sgTextSecondary)
            }
            }
        }
        .onAppear {
            // Auto-start the TLS server and mDNS broadcast when pairing is shown,
            // so Android can discover and connect immediately.
            if !quicServer.isRunning {
                print("🚀 [PairingQRView] Auto-starting server for pairing readiness")
                quicServer.startServer()
            }
        }
    }

    // MARK: - QR Code Card
    private var qrCodeCard: some View {
        VStack(spacing: 16) {
            Text("SCAN TO PAIR")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.sgTextSecondary)
            
            if let qrImage = generateQRCodeNSImage(from: pairingManager.qrPayload(port: quicServer.activePort)),
               !pairingManager.qrPayloadJSON.isEmpty {
                // White background inset for crisp QR rendering
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .frame(width: 260, height: 260)
                    
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                }
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 2)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.sgTextSecondary)
                    Text("Generating QR Code...")
                        .font(.caption)
                        .foregroundStyle(Color.sgTextSecondary)
                }
                .frame(width: 260, height: 260)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .sgGlass()
    }
    
    // MARK: - PIN Display Card
    private var pinDisplayCard: some View {
        VStack(spacing: 10) {
            Text("VERIFICATION PIN")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.sgTextSecondary)
            
            HStack(spacing: 8) {
                ForEach(Array(pairingManager.pairingPIN.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 56)
                        .background(Color.sgSurfaceHigh)
                        .cornerRadius(8)
                }
            }
            
            Text("Enter this PIN on your phone")
                .font(.caption)
                .foregroundStyle(Color.sgTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .sgGlass()
    }
}
