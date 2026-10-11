import AppKit
import Combine
import CoreBluetooth
import CryptoKit

/// Apple-style presence for the phone. While the server is up and the phone isn't
/// connected, the Mac broadcasts a tiny Bluetooth LE beacon; the phone's Bluetooth chip
/// watches for it in hardware and wakes SwiftGreen the moment the Mac is in range, so it
/// reconnects in seconds instead of waiting on a timer. Phone side: MacPresence.kt.
///
/// The beacon carries only a service UUID: HMAC(pairing key, UTC day). No name, nothing
/// readable. Only the paired phone recognises it, and it changes daily, so it can't be
/// used to follow the Mac around. Stops the moment the phone connects.
final class ProximityBeacon: NSObject, CBPeripheralManagerDelegate {
    static let shared = ProximityBeacon()

    private weak var server: mDNSQuicServer?
    private var manager: CBPeripheralManager?
    private var advertised: CBUUID?
    private var timer: Timer?
    private var watchers: Set<AnyCancellable> = []

    func start(server: mDNSQuicServer) {
        self.server = server
        // React the instant the server comes up or the phone drops, so the phone sees the
        // beacon within a second or two. The 10s tick covers the rest (pairing, midnight).
        server.$serverStatus.combineLatest(server.$isRunning)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &watchers)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        // Radios reset across sleep; advertise afresh on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.advertised = nil
            self?.refresh()
        }
        refresh()
    }

    /// Days since the Unix epoch in UTC — the phone computes the same value.
    static func utcDay(_ date: Date = Date()) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }

    /// Same derivation as MacPresence.kt: first 16 bytes of HMAC-SHA256.
    static func presenceUUID(key: SymmetricKey, day: Int) -> CBUUID {
        let code = HMAC<SHA256>.authenticationCode(for: Data("SwiftGreen-presence-v1|\(day)".utf8), using: key)
        return CBUUID(data: Data(code).prefix(16))
    }

    private func refresh() {
        guard let server else { return }
        let phoneConnected = server.serverStatus == mDNSQuicServer.onlineStatus
        let want = server.isRunning && !phoneConnected
            ? PairingManager.loadPairedKey().map { Self.presenceUUID(key: $0, day: Self.utcDay()) }
            : nil

        guard let want else {
            if advertised != nil { manager?.stopAdvertising(); advertised = nil }
            return
        }
        // Created on first need, so the Bluetooth prompt appears only once there's a phone to find.
        guard let manager else {
            // No system "turn on Bluetooth" nag: without it the phone still reconnects over Wi-Fi.
            manager = CBPeripheralManager(delegate: self, queue: nil,
                                          options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
            return
        }
        guard manager.state == .poweredOn else { return }
        if advertised == want && manager.isAdvertising { return }
        manager.stopAdvertising()
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [want]])
        advertised = want
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state != .poweredOn { advertised = nil }
        refresh()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            print("⚠️ [ProximityBeacon] Advertising failed: \(error.localizedDescription)")
            advertised = nil
        }
    }
}
