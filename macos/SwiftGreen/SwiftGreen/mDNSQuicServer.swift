import AppKit
//
//  mDNSQuicServer.swift
//  SwiftGreen
//
//  Created by Navin Rana on 27/05/26.
//

import Foundation
import Network
import Security
import Combine
import UserNotifications
import CryptoKit
internal import CoreGraphics

extension Notification.Name {
    static let callActionResult = Notification.Name("callActionResult")
    /// Outcome of a notification_action, so in-app reply rows can show the real
    /// result instead of assuming the send succeeded.
    static let notificationActionResult = Notification.Name("notificationActionResult")
}

class mDNSQuicServer: NSObject, ObservableObject {
    static let offlineStatus = "Offline - Waiting for Android..."
    static let onlineStatus = "Online & Syncing"

    // Set by AppDelegate at launch so AppNotificationDelegate and the stores can reach the server.
    static weak var activeServer: mDNSQuicServer?

    @Published var serverStatus = mDNSQuicServer.offlineStatus {
        didSet { if serverStatus != Self.onlineStatus { CallRinger.stop() } }  // no phone, no ring
    }
    @Published var receivedMessage = ""
    @Published var activePort: UInt16?
    @Published var isRunning = false
    @Published var androidBatteryLevel: Int = -1
    @Published var androidBatteryCharging: Bool = false
    @Published var androidLatencyMs: Int? = nil

    /// Every field optional on purpose: a phone running a build older than the
    /// `device_info` message never sends these, and the UI must read that as
    /// "Not reported" rather than as a zero or an empty string.
    struct AndroidDeviceInfo {
        var name: String?
        var model: String?
        var osVersion: String?
        var appVersion: String?
        var storageTotalBytes: Int64?
        var storageFreeBytes: Int64?
    }
    @Published var androidDeviceInfo: AndroidDeviceInfo?
    /// nil = the phone never reported it (old build), not "denied".
    @Published var androidNotificationAccess: Bool?
    /// Stamped when the tunnel comes up. Never cleared — the UI only reads it while
    /// online, so a stale value is unreachable and nine offline paths stay untouched.
    @Published var connectedSince: Date?
    @Published var phoneIP: String?

    var onReady: ((UInt16) -> Void)?
    var onStop: (() -> Void)?
    var pairingManager: PairingManager?

    private var listener: NWListener?
    // Connection, challenge and buffer state is main-queue only (SG-12): the listener,
    // the connections' state and receive callbacks, and every timer hop there, and each
    // callback first checks it is still for `activeConnection`. Only the reference itself
    // is read from other threads (sendMessage from FileTransferSender), hence the lock.
    private var _activeConnection: NWConnection?
    private let activeLock = NSLock()
    private var activeConnection: NWConnection? {
        get { activeLock.withLock { _activeConnection } }
        set { activeLock.withLock { _activeConnection = newValue } }
    }
    private let socketIOQueue = DispatchQueue(label: "com.swiftgreen.socket.io", qos: .userInteractive)
    private var recentlyDeliveredIDs = Set<String>()
    private var receiveBuffer = LineFramer()
    // notificationKey → UNNotification identifier for pending reply/button actions
    private var pendingActionKeys: [String: String] = [:]
    
    // Challenge-response state
    private var pendingChallengeNonce: Data?
    private var challengeTimer: DispatchWorkItem?
    private var isChallengeVerified = false
    private var disconnectGraceTimer: DispatchWorkItem?

    private var lastKeepaliveReceivedAt: Date?
    /// The Mac drives keepalive: it pings every `pingInterval` and the phone answers. The
    /// phone keeps no timer of its own, so it can sleep between pings (Apple's model, not
    /// a wake lock). Dead after three unanswered pings plus slack.
    private let pingInterval: TimeInterval = 30
    private let keepaliveDeadThreshold: TimeInterval = 100
    private var lastPingSentAt = Date.distantPast
    private static let portKey = "swiftgreen_listen_port"
    /// Set once the saved port fails to bind, so this run uses a free port instead.
    private var fixedPortUnavailable = false
    private var keepaliveWatchdogTimer: Timer?
    private var listenerHealthTimer: Timer?
    
    var isTunnelActive: Bool {
        activeConnection != nil && isChallengeVerified
    }

    /// Samsung reports MODEL as "SM-S911B", which is meaningless without the make.
    /// Motorola reports "motorola edge 40", which already carries it — blindly
    /// joining the two produced "motorola motorola edge 40" on a real device.
    /// Only the first letter is upper-cased: `.capitalized` would turn a model
    /// code like "SM-S911B" into "Sm-S911b".
    static func friendlyModel(manufacturer: String?, model: String?) -> String? {
        let make = manufacturer?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        let combined: String
        if model.isEmpty { combined = make }
        else if make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) { combined = model }
        else { combined = "\(make) \(model)" }
        guard !combined.isEmpty else { return nil }
        return combined.prefix(1).uppercased() + combined.dropFirst()
    }
    
    func startServer() {
        guard !isRunning && listener == nil else {
            print("Server: Already running or listener exists. Ignoring start request.")
            return
        }
        print("Server: startServer() triggered")
        pruneLegacyCategories()
        
        // Configure TLS Options (TCP + TLS)
        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        
        print("Server: Configuring TLS options with ALPN ['swiftgreen-sync']")
        sec_protocol_options_add_tls_application_protocol(securityOptions, "swiftgreen-sync")
        
        // This install's own identity; the phone pins its certificate (SG-09).
        if let tls = Self.tlsIdentity(), let secIdentity = sec_identity_create(tls.identity) {
            sec_protocol_options_set_local_identity(securityOptions, secIdentity)
        } else {
            print("Server: ERROR - no TLS identity; every handshake will fail")
        }

        // The phone presents no client certificate, so there is nothing to evaluate; it
        // proves the pairing key once TLS is up (challenge-response below).
        // On the socket queue, not main: a handshake must never wait for the UI thread,
        // which is busiest right after launch — exactly when a phone reconnects.
        sec_protocol_options_set_verify_block(securityOptions, { (_, _, completionHandler) in
            completionHandler(true)
        }, socketIOQueue)
        
        do {
            // Initialize NWParameters using the configured TCP + TLS options
            let parameters = NWParameters(tls: tlsOptions)
            parameters.allowLocalEndpointReuse = true
            
            // Reuse the last port so the phone's saved address survives a Mac restart
            // without needing mDNS (which some office networks block). Falls back to a
            // free port if that one is taken.
            let saved = UInt16(clamping: UserDefaults.standard.integer(forKey: Self.portKey))
            let fixed = saved > 0 && !fixedPortUnavailable ? NWEndpoint.Port(rawValue: saved) : nil
            print("Server: Initializing NWListener on \(fixed.map { "saved port \($0)" } ?? "dynamic port")...")
            let listener = try NWListener(using: parameters, on: fixed ?? .any)
            
            listener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
                print("Server: Listener state changed to -> \(state)")
                DispatchQueue.main.async {
                    guard self?.listener === listener else { return }
                    // serverStatus describes the phone's tunnel, not this accept socket.
                    // The listener can pass through .setup/.waiting/.ready (e.g. a Wi-Fi
                    // interface change) while the accepted connection stays up; writing
                    // "offline" here showed Disconnected over a live tunnel and, since
                    // keepalive pings only run while online, stopped pinging it too.
                    // The connection's own handlers (markConnectionIdle, closeActiveConnection)
                    // report a real disconnect; .failed/.cancelled below still end it.
                    switch state {
                    case .setup:
                        break
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        guard port > 0 else {
                            print("Server: ERROR - Listener reached ready state, but port is unknown or 0.")
                            return
                        }
                        if self?.activePort == nil {
                            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
                            self?.isRunning = true
                            self?.activePort = port
                            print("Server: Listener is fully READY on port \(port)")
                            self?.onReady?(port)
                        } else {
                            print("Server: Listener is already running or activePort was already set (activePort: \(self?.activePort ?? 0)). Ignoring.")
                        }
                    case .waiting(let error):
                        print("Server: Listener is waiting. Reason: \(error.localizedDescription)")
                    case .failed(let error):
                        if fixed != nil, let self {
                            print("Server: Saved port unavailable (\(error.localizedDescription)) — using a free one")
                            self.fixedPortUnavailable = true
                            self.listener = nil
                            listener.cancel()
                            self.startServer()
                            return
                        }
                        self?.serverStatus = mDNSQuicServer.offlineStatus
                        self?.isRunning = false
                        self?.activePort = nil
                        print("Server: Listener failed with error: \(error.localizedDescription)")
                        self?.onStop?()
                    case .cancelled:
                        self?.serverStatus = mDNSQuicServer.offlineStatus
                        self?.isRunning = false
                        self?.activePort = nil
                        print("Server: Listener was cancelled.")
                        self?.onStop?()
                    @unknown default:
                        break
                    }
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                // Timestamped so a slow reconnect can be split between this hop to main
                // and the TLS handshake itself (compare the phone's "TCP connected" line).
                print("Server: Listener caught incoming client connection request from: \(connection.endpoint) at \(Date().timeIntervalSince1970)")
                self?.handleNewConnection(connection)
            }
            
            self.listener = listener
            listener.start(queue: DispatchQueue.main)
            print("Server: Listener successfully started on main queue")

            keepaliveWatchdogTimer?.invalidate()
            keepaliveWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.checkKeepaliveHealth()
            }

            listenerHealthTimer?.invalidate()
            listenerHealthTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
                self?.checkListenerHealth()
            }
            
        } catch {
            print("Server: Critical error starting listener: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.serverStatus = mDNSQuicServer.offlineStatus
                self.isRunning = false
            }
        }
    }
    
    func stopServer() {
        print("Server: stopServer() triggered")
        keepaliveWatchdogTimer?.invalidate()
        keepaliveWatchdogTimer = nil
        listenerHealthTimer?.invalidate()
        listenerHealthTimer = nil
        disconnectGraceTimer?.cancel()
        disconnectGraceTimer = nil
        listener?.cancel()
        candidates.keys.forEach(dropCandidate)
        activeConnection?.cancel()
        listener = nil
        activeConnection = nil
        
        DispatchQueue.main.async {
            self.isRunning = false
            self.serverStatus = mDNSQuicServer.offlineStatus
            self.activePort = nil
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        print("Server: new connection from \(connection.endpoint)")

        // The tunnel is up: the newcomer must prove the key before it may replace it
        // (SG-08). Cancelling the live connection first let any host on the Wi-Fi keep
        // the phone offline with a bare TCP connect loop.
        if isTunnelActive {
            admitCandidate(connection)
            return
        }

        // The one genuinely phone-scoped network fact the Mac can see. IPv6 link-local
        // arrives as "fe80::1%en0" — the zone id is noise in a UI.
        if case .hostPort(let host, _) = connection.endpoint {
            phoneIP = "\(host)".components(separatedBy: "%").first
        }

        // A new connection arrived — cancel any pending grace timer from a prior disconnect
        disconnectGraceTimer?.cancel()
        disconnectGraceTimer = nil
        // Not verified (else isTunnelActive), so nothing is lost by replacing it.
        activeConnection?.cancel()
        resetActive(connection)
        let acceptedAt = Date()

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                // A replaced connection's late events must not touch the new one's state.
                guard let self, self.activeConnection === connection else { return }
                self.activeStateChanged(connection, state, acceptedAt: acceptedAt)
            }
        }
        connection.start(queue: socketIOQueue)
    }

    /// Makes `connection` the (unverified) tunnel with fresh challenge and buffer state. Main queue.
    func resetActive(_ connection: NWConnection) {
        pendingChallengeNonce = nil
        challengeTimer?.cancel()
        challengeTimer = nil
        isChallengeVerified = false
        receiveBuffer = LineFramer()
        activeConnection = connection
    }

    private func activeStateChanged(_ connection: NWConnection, _ state: NWConnection.State, acceptedAt: Date) {
        print("Server Connection State: \(state)")
        switch state {
        case .ready:
            print("Server Connection: TLS ready \(Int(Date().timeIntervalSince(acceptedAt) * 1000)) ms after accept.")
            if pairingManager?.isPaired == true, PairingManager.loadPairedKey() != nil {
                // Paired mode: send challenge nonce
                var nonceBytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, 32, &nonceBytes) == errSecSuccess else {
                    print("❌ [Server] Failed to generate random nonce. Cancelling connection.")
                    connection.cancel()
                    return
                }
                let nonce = Data(nonceBytes)
                pendingChallengeNonce = nonce
                sendMessage("{\"type\":\"challenge\",\"nonce\":\"\(nonce.base64EncodedString())\"}\n")

                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.activeConnection === connection, !self.isChallengeVerified else { return }
                    print("⏰ [Server] Challenge response timeout (5s). Cancelling connection.")
                    connection.cancel()
                    self.pendingChallengeNonce = nil
                    self.serverStatus = mDNSQuicServer.offlineStatus
                }
                challengeTimer = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)
            } else {
                // Unpaired mode: accept connection for pairing messages only.
                // Give the user a generous 60-second window to verify the PIN
                // and tap "Confirm & Pair" on their phone.
                print("🔓 [Server] Device is NOT paired — accepting connection for pairing flow (60s timeout)")
                // A phone that still holds a key waits for a challenge that will never
                // come; tell it, with the proof when this Mac unpaired it (PROTOCOL.md §3.4). A
                // phone that is pairing skips this line.
                sendMessage(Self.unpairedMessage())

                let pairingTimeout = DispatchWorkItem { [weak self] in
                    guard let self, self.activeConnection === connection else { return }
                    print("⏰ [Server] Pairing timeout (60s) — no pairing payload received. Cancelling connection.")
                    connection.cancel()
                    self.serverStatus = mDNSQuicServer.offlineStatus
                }
                challengeTimer = pairingTimeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 60.0, execute: pairingTimeout)
            }
            receiveData(on: connection)
        case .waiting(let error):
            print("Server Connection: Waiting state. Reason: \(error.localizedDescription)")
        case .failed(let error):
            print("Server Connection: FAILED: \(error.localizedDescription)")
            scheduleDisconnectGrace(for: connection)
        case .cancelled:
            print("Server Connection: Cancelled / Disconnected.")
            scheduleDisconnectGrace(for: connection)
        default:
            break
        }
    }

    /// The phone proved the key on `activeConnection`: open the tunnel. Main queue.
    private func didVerifyPhone(key pairedKey: SymmetricKey, clientNonce: Data, binding: Data) {
        // Cancel timeout timer and any disconnect grace period
        challengeTimer?.cancel()
        challengeTimer = nil
        disconnectGraceTimer?.cancel()
        disconnectGraceTimer = nil
        pendingChallengeNonce = nil
        isChallengeVerified = true

        // challenge-ok carries the Mac's own proof of the key and its certificate claim, then the standard hello
        let proof = HMAC<SHA256>.authenticationCode(for: Data("SwiftGreen-server|".utf8) + clientNonce + binding, using: pairedKey)
        sendMessage(Self.challengeOK(proof: Data(proof), clientNonce: clientNonce,
                                     fingerprint: Self.tlsIdentity()?.fingerprint, key: pairedKey))
        sendMessage("SwiftGreen-Hello-Mac\n")
        sendMessage("{\"type\":\"get_app_filter_list\"}\n")
        sendMessage("{\"type\":\"get_sms_threads\",\"page\":0}\n")
        sendMessage("{\"type\":\"contacts_list_request\"}\n")
        ClipboardSyncManager.shared.connection = activeConnection
        ClipboardSyncManager.shared.startMonitoring()
        lastKeepaliveReceivedAt = Date()
        if serverStatus != mDNSQuicServer.onlineStatus { SGSound.play(.connected) }
        serverStatus = mDNSQuicServer.onlineStatus
        connectedSince = Date()
        // The phone keeps no copy of the shared folder's listing; every
        // connect gets it fresh (an empty one clears a stale folder).
        MacFileBrowserStore.shared.pushListing(via: self)
    }

    /// `challenge-ok`: the Mac's proof of the key, plus this install's certificate fingerprint
    /// F and HMAC(K, "SwiftGreen-tls-id|" ‖ client_nonce ‖ F). The phone pins F only when
    /// that verifies and F is the certificate on this very connection, which is how phones
    /// paired before the QR carried F pin without re-pairing. Old phones ignore both.
    static func challengeOK(proof: Data, clientNonce: Data, fingerprint: Data?, key: SymmetricKey) -> String {
        var body: [String: Any] = ["type": "challenge-ok", "proof": proof.base64EncodedString()]
        if let fingerprint {
            let idProof = HMAC<SHA256>.authenticationCode(for: Data("SwiftGreen-tls-id|".utf8) + clientNonce + fingerprint, using: key)
            body["tls_id"] = fingerprint.base64EncodedString()
            body["tls_id_proof"] = Data(idProof).base64EncodedString()
        }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    func sendMessage(_ text: String, completion: (() -> Void)? = nil) {
        let payload = text.hasSuffix("\n") ? text : "\(text)\n"
        guard let data = payload.data(using: .utf8) else { return }
        guard let connection = activeConnection else {
            print("Server: No active connection — message dropped: [\(payload.trimmingCharacters(in: .newlines))]")
            completion?()
            return
        }
        
        print("Server: Attempting to send message [\(payload.trimmingCharacters(in: .newlines))] over TLS tunnel...")
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("Server: ERROR sending message: \(error.localizedDescription)")
            } else {
                print("Server: Message successfully sent: [\(payload.trimmingCharacters(in: .newlines))]")
            }
            if let completion = completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }))
    }
    
    /// Longest unterminated line kept: 64 KiB before the challenge, 64 MiB after (a
    /// clipboard image travels as one base64 line; file chunks are 256 KiB).
    static func maxBufferedBytes(verified: Bool) -> Int { verified ? 64 << 20 : 64 << 10 }

    /// A `file_transfer_begin`/`_chunk`/`_complete` line, parsed; nil for anything else.
    static func inlineFileTransferMessage(_ line: String) -> [String: Any]? {
        guard line.contains("\"file_transfer_"),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = json["type"] as? String,
              ["file_transfer_begin", "file_transfer_chunk", "file_transfer_complete"].contains(type) else { return nil }
        return json
    }

    /// The only line an unpaired Mac accepts: a JSON object whose `type` is `pairing`.
    static func admitsWhileUnpaired(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String == "pairing"
    }

    /// `{"type":"unpaired"}`, carrying this Mac's last unpair proof when it has one (PROTOCOL.md §3.4).
    static func unpairedMessage(proof: Data? = PairingManager.unpairTombstone) -> String {
        guard let proof else { return "{\"type\":\"unpaired\"}\n" }
        return "{\"type\":\"unpaired\",\"proof\":\"\(proof.base64EncodedString())\"}\n"
    }

    /// Tells the phone the Mac is going away (quit or sleep) and waits, briefly, until the
    /// line has left, so the phone starts reconnecting at once instead of holding a dead
    /// socket. Nothing else told it: on 2026-09-26 the phone noticed a quit 80 s late.
    /// Main thread; the send completes on the socket queue, so waiting here can't deadlock.
    func sayGoodbye(reason: String) {
        guard let connection = activeConnection, isChallengeVerified,
              let data = "{\"type\":\"disconnect\",\"reason\":\"\(reason)\"}\n".data(using: .utf8) else { return }
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { _ in sent.signal() })
        let result = sent.wait(timeout: .now() + 0.5)
        print("Server: Goodbye (\(reason)) \(result == .success ? "sent" : "timed out")")
    }

    func closeActiveConnection() {
        print("Server: closeActiveConnection() triggered")
        disconnectGraceTimer?.cancel()
        disconnectGraceTimer = nil
        candidates.keys.forEach(dropCandidate)
        activeConnection?.cancel()
        activeConnection = nil
        pendingChallengeNonce = nil
        challengeTimer?.cancel()
        challengeTimer = nil
        isChallengeVerified = false
        receiveBuffer = LineFramer()
        DispatchQueue.main.async {
            CallLogStore.shared.clearLiveCallOnDisconnect()
            self.serverStatus = mDNSQuicServer.offlineStatus
        }
    }

    /// Lines this read completes on the tunnel; [] when `connection` is no longer the
    /// tunnel (a replaced connection's late bytes must never reach the new one's buffer);
    /// nil once an unterminated line passes the cap. Main queue.
    func ingest(_ data: Data, from connection: NWConnection) -> [String]? {
        guard activeConnection === connection else { return [] }
        return receiveBuffer.feed(data, limit: Self.maxBufferedBytes(verified: isChallengeVerified))
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_194_304) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, self.activeConnection === connection else { return }
                if let error { print("Server: receive error: \(error.localizedDescription)") }
                if let data {
                    guard let lines = self.ingest(data, from: connection) else {
                        // A line with no newline: before auth any LAN host could grow this without bound.
                        print("🚫 [Server] Receive buffer over limit — closing connection")
                        connection.cancel()
                        return
                    }
                    for line in lines where self.activeConnection === connection { self.dispatch(line) }
                }
                if error != nil || isComplete {
                    print("Server Connection: socket closed (EOF: \(isComplete))")
                    self.markConnectionIdle(for: connection)
                } else if self.activeConnection === connection {
                    self.receiveData(on: connection)
                }
            }
        }
    }

    private func dispatch(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        print("Server: received line, \(trimmed.utf8.count) bytes")
        // File transfer lines skip receivedMessage (chunks are large) and go straight to
        // FileTransferReceiver's serial queue, in stream order. Same auth gate as handleIncomingPayload.
        if let json = Self.inlineFileTransferMessage(trimmed) {
            guard isChallengeVerified else {
                print("🚫 [Server] Dropping file transfer line — challenge not yet verified")
                return
            }
            switch json["type"] as? String {
            case "file_transfer_chunk": FileTransferReceiver.shared.handleChunk(json: json)
            case "file_transfer_begin": FileTransferReceiver.shared.handleBegin(json: json)
            default: FileTransferReceiver.shared.handleComplete(json: json)
            }
            return
        }
        receivedMessage = trimmed
        handleIncomingPayload(trimmed)
    }

    private func markConnectionIdle(for connection: NWConnection) {
        guard let currentConnection = activeConnection, currentConnection === connection else {
            return
        }
        ClipboardSyncManager.shared.stopMonitoring()
        activeConnection = nil
        pendingChallengeNonce = nil
        challengeTimer?.cancel()
        challengeTimer = nil
        isChallengeVerified = false
        receiveBuffer = LineFramer()
        CallLogStore.shared.clearLiveCallOnDisconnect()
        serverStatus = mDNSQuicServer.offlineStatus
    }

    private func scheduleDisconnectGrace(for connection: NWConnection) {
        disconnectGraceTimer?.cancel()
        let graceItem = DispatchWorkItem { [weak self] in
            print("Server: 10s disconnect grace expired — marking connection idle")
            self?.disconnectGraceTimer = nil
            self?.markConnectionIdle(for: connection)
        }
        disconnectGraceTimer = graceItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: graceItem)
        print("Server: Disconnect grace timer started (10s) — waiting for Android reconnect")
    }

    // MARK: - Connections that arrive while the tunnel is up

    /// A connection that arrived while the phone's tunnel was up (SG-08). It answers its
    /// own challenge, on its own buffer and 5 s timer, and replaces the tunnel only once it
    /// has proved the key; failing or timing out never touches the tunnel. A phone that
    /// really is reconnecting (new Wi-Fi, stale socket) proves the key in one round trip.
    /// Main queue only.
    private final class Candidate {
        let connection: NWConnection
        var nonce: Data?
        var framer = LineFramer()
        var timer: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private var candidates: [ObjectIdentifier: Candidate] = [:]
    // ponytail: fixed cap; a flood beyond it is refused at accept, the tunnel unaffected.
    private static let maxCandidates = 4

    private func admitCandidate(_ connection: NWConnection) {
        guard candidates.count < Self.maxCandidates else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        let candidate = Candidate(connection)
        candidates[id] = candidate
        print("Server: Tunnel is up — new connection must authenticate before it can replace it")

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    guard self.candidates[id] != nil else { return }
                    var nonce = [UInt8](repeating: 0, count: 32)
                    guard SecRandomCopyBytes(kSecRandomDefault, 32, &nonce) == errSecSuccess else {
                        self.dropCandidate(id); return
                    }
                    candidate.nonce = Data(nonce)
                    self.send("{\"type\":\"challenge\",\"nonce\":\"\(Data(nonce).base64EncodedString())\"}\n", on: connection)
                    let timeout = DispatchWorkItem { [weak self] in
                        print("⏰ [Server] New connection didn't authenticate in 5 s — closed; tunnel untouched")
                        self?.dropCandidate(id)
                    }
                    candidate.timer = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)
                    self.receiveCandidate(candidate)
                case .failed, .cancelled:
                    if self.activeConnection === connection {
                        self.scheduleDisconnectGrace(for: connection)   // promoted, then dropped
                    } else {
                        self.dropCandidate(id)
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: socketIOQueue)
    }

    private func dropCandidate(_ id: ObjectIdentifier) {
        guard let candidate = candidates.removeValue(forKey: id) else { return }
        candidate.timer?.cancel()
        candidate.connection.cancel()
    }

    private func receiveCandidate(_ candidate: Candidate) {
        candidate.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxBufferedBytes(verified: false)) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let id = ObjectIdentifier(candidate.connection)
                guard self.candidates[id] != nil else { return }
                guard let lines = candidate.framer.feed(data ?? Data(), limit: Self.maxBufferedBytes(verified: false)) else {
                    self.dropCandidate(id); return
                }
                for (i, line) in lines.enumerated() where self.handleCandidateLine(line, candidate) {
                    // Settled. If promoted, anything after the proof in this read is tunnel traffic.
                    if self.activeConnection === candidate.connection {
                        lines.dropFirst(i + 1).forEach(self.dispatch)
                        self.receiveData(on: candidate.connection)
                    }
                    return
                }
                if error != nil || isComplete { self.dropCandidate(id); return }
                self.receiveCandidate(candidate)
            }
        }
    }

    /// Returns true once the candidate is settled (promoted or dropped).
    private func handleCandidateLine(_ line: String, _ candidate: Candidate) -> Bool {
        let id = ObjectIdentifier(candidate.connection)
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return false }
        switch type {
        case "challenge-response":
            guard let nonce = candidate.nonce,
                  let key = PairingManager.loadPairedKey(),
                  let hmac = (json["hmac"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                dropCandidate(id); return true
            }
            let binding = (json["v"] as? Int ?? 1) >= 2 ? tlsBinding(candidate.connection) : Data()
            let clientNonce = (json["client_nonce"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            guard let binding, clientNonce.count >= 16,
                  HMAC<SHA256>.isValidAuthenticationCode(hmac, authenticating: nonce + binding, using: key) else {
                print("❌ [Server] New connection failed the challenge — closed; tunnel untouched")
                candidates.removeValue(forKey: id)?.timer?.cancel()
                send(Self.unpairedMessage(), on: candidate.connection) { candidate.connection.cancel() }
                return true
            }
            print("✅ [Server] New connection proved the key — it replaces the tunnel")
            candidates.removeValue(forKey: id)?.timer?.cancel()
            let previous = activeConnection
            resetActive(candidate.connection)
            receiveBuffer = candidate.framer
            if case .hostPort(let host, _) = candidate.connection.endpoint {
                phoneIP = "\(host)".components(separatedBy: "%").first
            }
            previous?.cancel()
            didVerifyPhone(key: key, clientNonce: clientNonce, binding: binding)
            return true
        case "unpaired":
            // Same as on the tunnel: only the proof made with our own key unpairs (PROTOCOL.md §3.4).
            let proof = (json["proof"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            guard let key = PairingManager.loadPairedKey(),
                  HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("SwiftGreen-unpaired".utf8), using: key) else {
                dropCandidate(id); return true
            }
            candidates.removeValue(forKey: id)?.timer?.cancel()
            send(Self.unpairedMessage(proof: proof), on: candidate.connection) { [weak self] in
                self?.pairingManager?.resetPairing(notifyPeer: false)
                candidate.connection.cancel()
            }
            return true
        default:
            return false   // nothing else counts before auth; same as the gate on the tunnel
        }
    }

    /// Sends on a specific connection (a candidate), not the tunnel.
    private func send(_ text: String, on connection: NWConnection, completion: (() -> Void)? = nil) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            if let completion { DispatchQueue.main.async { completion() } }
        })
    }

    private func handleIncomingPayload(_ text: String) {
        // STEP: Payload received from tunnel
        print("📨 [Server] handleIncomingPayload() called with: [\(text)]")
        
        // Unpaired, only a pairing request may run. This used to accept any line merely
        // containing "publicKey", so a stranger on the LAN could add that key to a
        // clipboard_push or notification and have it dispatched.
        if pairingManager?.isPaired != true {
            if !Self.admitsWhileUnpaired(text) {
                print("⚠️ [Server] Unpaired, but received non-pairing payload: [\(text)]. Rejecting connection.")
                sendMessage("{\"type\":\"error\", \"message\":\"unpaired\"}\n")
                activeConnection?.cancel()
                return
            }
        }
        
        // STEP: Check for JSON protocol messages (pairing, challenge-response)
        if let jsonData = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let messageType = json["type"] as? String {
            
            // While paired, nothing but the handshake may run until the phone has proved
            // it holds the key. This gate used to sit after the switch, so every typed
            // message below (file transfer, clipboard, unpair, pairing, file requests)
            // ran for any client that connected and ignored the challenge.
            if pairingManager?.isPaired == true && !isChallengeVerified
                && messageType != "challenge-response" && messageType != "unpaired" {
                print("🚫 [Server] Dropping '\(messageType)' — challenge not yet verified")
                return
            }

            switch messageType {
            case "pairing":
                // Pairing request from Android — cancel the 60s pairing timeout
                self.challengeTimer?.cancel()
                self.challengeTimer = nil
                print("🔑 [Server] Received pairing request (timeout cancelled)")
                guard let androidPublicKey = json["publicKey"] as? String else {
                    print("❌ [Server] Pairing message missing 'publicKey' field")
                    return
                }
                
                if let manager = pairingManager {
                    switch manager.completePairing(androidPublicKeyBase64: androidPublicKey,
                                                   pinProofBase64: json["pin_proof"] as? String ?? "") {
                    case .paired:
                        print("✅ [Server] Pairing completed successfully. Sending pairing-complete.")
                        sendMessage("{\"type\":\"pairing-complete\"}\n")
                    case .wrongPIN:
                        sendMessage("{\"type\":\"pairing-failed\",\"reason\":\"pin\"}\n")
                        DispatchQueue.main.async { SGSound.play(.failed) }
                    case .expired:
                        sendMessage("{\"type\":\"pairing-failed\",\"reason\":\"expired\"}\n")
                        DispatchQueue.main.async { SGSound.play(.failed) }
                    case .failed:
                        print("❌ [Server] Pairing failed during ECDH/HKDF derivation.")
                        DispatchQueue.main.async { SGSound.play(.failed) }
                    }
                } else {
                    print("❌ [Server] pairingManager is nil — cannot complete pairing")
                }
                return
                
            case "challenge-response":
                // Challenge response from Android
                print("🔐 [Server] Received challenge-response")
                guard let hmacBase64 = json["hmac"] as? String else {
                    print("❌ [Server] Challenge-response missing 'hmac' field")
                    activeConnection?.cancel()
                    return
                }
                
                guard let nonce = pendingChallengeNonce else {
                    print("❌ [Server] No pending challenge nonce — unexpected challenge-response")
                    activeConnection?.cancel()
                    return
                }
                
                guard let pairedKey = PairingManager.loadPairedKey() else {
                    print("❌ [Server] Cannot load paired key from Keychain for verification")
                    activeConnection?.cancel()
                    return
                }
                
                guard let receivedHmacData = Data(base64Encoded: hmacBase64) else {
                    print("❌ [Server] Failed to decode HMAC from Base64")
                    activeConnection?.cancel()
                    return
                }
                
                // v2 binds both proofs to this TLS session (RFC 5705 exporter), so a relay
                // in the middle fails both ways; v1 comes from phones below Android 12 (API 31).
                // Both sides of the handshake are documented in MdnsQuicClient.performChallengeResponse.
                let binding = (json["v"] as? Int ?? 1) >= 2 ? tlsBinding(activeConnection) : Data()
                let clientNonce = (json["client_nonce"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()

                if let binding, clientNonce.count >= 16,
                   HMAC<SHA256>.isValidAuthenticationCode(receivedHmacData, authenticating: nonce + binding, using: pairedKey) {
                    print("✅ [Server] Challenge-response verified! Client is authenticated.")
                    didVerifyPhone(key: pairedKey, clientNonce: clientNonce, binding: binding)
                } else {
                    print("❌ [Server] Challenge-response HMAC mismatch! Rejecting connection.")
                    challengeTimer?.cancel()
                    challengeTimer = nil
                    pendingChallengeNonce = nil
                    // Say so before closing, or the phone just sees a dropped socket and
                    // retries forever. With the old pairing's proof, a phone this Mac
                    // unpaired deletes its key; without one it stops and asks the user.
                    let rejected = activeConnection
                    sendMessage(Self.unpairedMessage()) { rejected?.cancel() }
                    DispatchQueue.main.async {
                        self.serverStatus = mDNSQuicServer.offlineStatus
                    }
                }
                return
                
            case "clipboard_push":
                if let jsonData = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let source = obj["source"] as? String,
                   source != "mac" {
                    let contentType = obj["content_type"] as? String ?? "text"
                    if contentType == "image",
                       let base64 = obj["image_base64"] as? String,
                       let mimeType = obj["image_mime_type"] as? String {
                        ClipboardSyncManager.shared.receiveImageFromAndroid(base64: base64, mimeType: mimeType)
                    } else if let content = obj["text"] as? String {
                        ClipboardSyncManager.shared.receiveFromAndroid(content)
                    }
                }
                return
                
            case "keepalive":
                lastKeepaliveReceivedAt = Date()
                sendMessage("{\"type\":\"heartbeat_ack\"}\n")
                // Piggybacked on the 30s ping round trip rather than another timer: a
                // banner that's showing is the only case worth re-checking, and it bounds
                // how long a stale one can survive to roughly a minute.
                if CallLogStore.shared.liveCallState != nil { requestCallState() }
                return
                
            case "unpaired":
                // The phone unpaired while this Mac was away and proves it with the key
                // (PROTOCOL.md §3.4). Accepted before the challenge: the phone no longer has the key
                // to answer one. Anything but a valid proof is dropped.
                let proof = (json["proof"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                guard let key = PairingManager.loadPairedKey(),
                      HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("SwiftGreen-unpaired".utf8), using: key) else {
                    print("🚫 [Server] 'unpaired' without a valid proof — ignored")
                    activeConnection?.cancel()
                    return
                }
                print("💔 [Server] Phone proved it unpaired while this Mac was away — unpairing here too")
                sendMessage(Self.unpairedMessage(proof: proof)) { [weak self] in
                    self?.pairingManager?.resetPairing(notifyPeer: false)
                }
                return

            case "unpair_request":
                print("💔 [Server] Received 'unpair_request' (divorce protocol) from Android client")
                if let manager = pairingManager {
                    manager.resetPairing(notifyPeer: false)
                }
                activeConnection?.cancel()
                return
                
            case "file_transfer_begin":
                FileTransferReceiver.shared.handleBegin(json: json)
                return
                
            case "file_transfer_chunk":
                FileTransferReceiver.shared.handleChunk(json: json)
                return
                
            case "file_transfer_complete":
                FileTransferReceiver.shared.handleComplete(json: json)
                return

            case "file_transfer_result":
                FileTransferSender.shared.handleResult(json: json)
                return
                
            case "find_phone_state":
                let ringing = json["ringing"] as? Bool ?? false
                DispatchQueue.main.async { DeviceStore.shared.ringing = ringing }
                return

            case "telemetry":
                if let level = json["battery_level"] as? Int {
                    DispatchQueue.main.async {
                        self.androidBatteryLevel = level
                        self.androidBatteryCharging = json["battery_charging"] as? Bool ?? false
                        if let latency = json["latency_ms"] as? Int {
                            self.androidLatencyMs = latency
                        }
                        DeviceStore.shared.record(battery: level, charging: self.androidBatteryCharging,
                                                  latency: json["latency_ms"] as? Int)
                        print("Telemetry received: battery=\(self.androidBatteryLevel) latency=\(self.androidLatencyMs ?? -1)")
                    }
                }
                if let simsArray = json["sims"] as? [[String: Any]] {
                    DispatchQueue.main.async {
                        SimStore.shared.update(from: simsArray)
                    }
                }
                // Absent on phones older than this field — stays nil, reads as
                // "Not reported", never as "Denied".
                if let access = json["notification_access"] as? Bool {
                    DispatchQueue.main.async { self.androidNotificationAccess = access }
                }
                return

            case "device_info":
                // Every field optional: unknown keys are tolerated on both sides
                // (PROTOCOL.md §5), so an older phone simply populates none.
                let makeModel = Self.friendlyModel(manufacturer: json["manufacturer"] as? String,
                                                   model: json["model"] as? String)
                DispatchQueue.main.async {
                    self.androidDeviceInfo = AndroidDeviceInfo(
                        name: json["device_name"] as? String,
                        model: makeModel,
                        osVersion: json["android_version"] as? String,
                        appVersion: json["app_version"] as? String,
                        storageTotalBytes: (json["storage_total_bytes"] as? NSNumber)?.int64Value,
                        storageFreeBytes: (json["storage_free_bytes"] as? NSNumber)?.int64Value
                    )
                }
                return

            case "call_log_sync":
                if let data = text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(CallLogSyncPayload.self, from: data) {
                    DispatchQueue.main.async {
                        CallLogStore.shared.replace(payload.calls)
                    }
                }
                return

            case "sms_thread_list":
                if let data = text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(SmsThreadListPayload.self, from: data) {
                    DispatchQueue.main.async {
                        SmsStore.shared.replaceThreads(payload.threads)
                    }
                }
                return

            case "sms_thread_messages":
                if let data = text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(SmsThreadMessagesPayload.self, from: data) {
                    DispatchQueue.main.async {
                        if payload.beforeMs != nil {
                            SmsStore.shared.appendOlderMessages(threadId: payload.threadId, incoming: payload.messages,
                                                                hasMore: payload.hasMore ?? false)
                        } else {
                            SmsStore.shared.replaceMessages(threadId: payload.threadId, incoming: payload.messages,
                                                            hasMore: payload.hasMore)
                        }
                    }
                }
                return

            case "sms_send_result":
                if let data = text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(SmsSendResultPayload.self, from: data) {
                    DispatchQueue.main.async {
                        SmsStore.shared.recordSendResult(
                            threadId: payload.threadId, success: payload.success, failureReason: payload.failureReason)
                    }
                }
                return

            case "sms_search_result":
                if let data = text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(SmsSearchResultPayload.self, from: data) {
                    DispatchQueue.main.async {
                        SmsStore.shared.replaceSearchResults(payload.messages)
                    }
                }
                return

            case "media_list_response":
                if let data = text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(MediaListResponsePayload.self, from: data) {
                    DispatchQueue.main.async {
                        MediaBrowserStore.shared.replace(from: payload)
                    }
                }
                return

            case "media_search_response":
                if let data = text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(MediaSearchResponsePayload.self, from: data) {
                    DispatchQueue.main.async {
                        MediaBrowserStore.shared.acceptSearch(query: payload.query, items: payload.items)
                    }
                }
                return

            case "media_thumbnail_response":
                if let path = json["path"] as? String {
                    DispatchQueue.main.async {
                        MediaBrowserStore.shared.acceptThumbnail(
                            path: path,
                            base64: json["thumbnail_base64"] as? String)
                    }
                }
                return

            case "mac_directory_file_request":
                if let fileId = json["file_id"] as? Int,
                   let url = MacFileBrowserStore.shared.url(forFileId: fileId) {
                    DispatchQueue.main.async {
                        FileTransferSender.shared.sendFile(at: url, via: self)
                    }
                }
                return

            case "file_transfer_cancel":
                print("[Server] File transfer cancelled by Android")
                FileTransferSender.shared.cancelTransfer(via: self)
                DispatchQueue.main.async {
                    FileTransferReceiver.shared.cancelReceive()
                }
                return

            case "media_state":
                DispatchQueue.main.async {
                    MediaControlStore.shared.update(from: json)
                }
                return

            case "app_filter_list":
                if let apps = json["apps"] as? [[String: Any]] {
                    DispatchQueue.main.async {
                        AppFilterStore.shared.updateFromAndroid(apps)
                    }
                }
                return

            case "notification_action_result":
                if let notifKey = json["notification_key"] as? String,
                   let success = json["success"] as? Bool {
                    DispatchQueue.main.async {
                        // Here, not in the row: an inline reply from the banner has no row.
                        SGSound.play(success ? .sent : .failed)
                        NotificationCenter.default.post(
                            name: .notificationActionResult,
                            object: nil,
                            userInfo: [
                                "notification_key": notifKey,
                                "success": success,
                                "error": json["error"] as? String ?? ""
                            ]
                        )
                    }
                    if success {
                        if let notifId = pendingActionKeys[notifKey] {
                            UNUserNotificationCenter.current()
                                .removeDeliveredNotifications(withIdentifiers: [notifId])
                            pendingActionKeys.removeValue(forKey: notifKey)
                        }
                    } else {
                        let errMsg = json["error"] as? String ?? "unknown error"
                        let userFacing = json["user_facing"] as? Bool ?? false
                        print("⚠️ [Server] Reply failed for \(notifKey): \(errMsg)")
                        showReplyFailedBanner(triggeredBy: pendingActionKeys[notifKey] ?? notifKey,
                                              message: userFacing ? errMsg : nil)
                        pendingActionKeys.removeValue(forKey: notifKey)
                    }
                }
                return

            case "call_action_result":
                // request_id is forwarded untouched: it is the only thing that ties this
                // result to the dial that produced it once two are in flight.
                let requestId = json["request_id"] as? String ?? ""
                let success = json["success"] as? Bool ?? false
                let error = json["error"] as? String
                DispatchQueue.main.async {
                    // Here, not in the Calls pane: the result may land while it's closed.
                    if !success { SGSound.play(.failed) }
                    NotificationCenter.default.post(
                        name: .callActionResult,
                        object: nil,
                        userInfo: ["request_id": requestId, "success": success, "error": error as Any]
                    )
                }
                return

            case "contacts_list_response":
                if let raw = json["contacts"] as? [[String: Any]],
                   let data = try? JSONSerialization.data(withJSONObject: raw),
                   let parsed = try? JSONDecoder().decode([MacContact].self, from: data) {
                    print("📇 [Server] contacts_list_response: \(parsed.count) contacts")
                    DispatchQueue.main.async { ContactsStore.shared.replace(parsed) }
                } else {
                    print("📇 [Server] contacts_list_response: could not decode payload")
                }
                return

            case "app_call":
                let app = json["app"] as? String ?? "WhatsApp"
                let state = json["state"] as? String ?? ""
                let name = json["name"] as? String ?? ""
                let key = json["key"] as? String ?? ""
                print("📞 [Server] \(app) call: \(state) '\(name)' photo=\(json["photo"] != nil)")
                DispatchQueue.main.async {
                    let store = CallLogStore.shared
                    let photo = (json["photo"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { AppKit.NSImage(data: $0) }
                    // An end for some other call (a stale key) must not clear this one's banner.
                    let owned = store.liveCallKey == nil || store.liveCallKey == key
                    store.updateAppCall(app: app, state: state, name: name, key: key, photo: photo)
                    if state == "ringing" {
                        // Only if the store took it: a cellular call keeps the banner, and
                        // its Answer must not be relabelled as a WhatsApp one.
                        if store.liveCallApp == app {
                            self.showIncomingCallNotification(number: "", name: name.isEmpty ? nil : name, title: "\(app) call")
                        }
                    } else if owned {
                        self.clearIncomingCallNotification()
                    }
                }
                return

            case "call_state":
                // Step 15.3 — incoming cellular call state pushed by Android.
                let state = json["state"] as? String ?? ""
                let number = json["phone_number"] as? String ?? ""
                let name = json["contact_name"] as? String
                DispatchQueue.main.async {
                    // Drives the Calls-tab banner and its hang-up button, for calls in
                    // both directions — including ones dialled on the phone itself.
                    CallLogStore.shared.updateLiveCall(
                        state: state,
                        number: number,
                        name: name ?? ContactsStore.shared.name(for: number)
                    )
                    switch state {
                    // A WhatsApp call arrives here too, numberless, as the phone's plain
                    // call state. Its own notification (with name and app) must win.
                    case "ringing" where CallLogStore.shared.liveCallApp == nil:
                        self.showIncomingCallNotification(number: number, name: name ?? ContactsStore.shared.name(for: number))
                    case "offhook", "idle":
                        // Answered (offhook) or ended (idle): the answer/decline banner is moot.
                        self.clearIncomingCallNotification()
                    default:
                        break
                    }
                }
                return

            case "call_control_result":
                let success = json["success"] as? Bool ?? false
                let action = json["action"] as? String ?? ""
                let error = json["error"] as? String
                let enabled = json["enabled"] as? Bool
                print("📞 [Server] call_control_result: action=\(action) success=\(success) error=\(error ?? "nil")")
                if !success, action != "mute" { DispatchQueue.main.async { SGSound.play(.failed) } }
                if action == "mute" {
                    DispatchQueue.main.async {
                        // Settle the toggle on what Android actually did. "not_applied"
                        // means the platform ignored us, so the switch must snap back
                        // rather than show a mute that isn't real.
                        CallLogStore.shared.applyAudioResult(
                            action: action, success: success,
                            enabled: enabled ?? false, error: error
                        )
                    }
                }
                return

            case "notification_dismiss":
                if let key = json["notification_key"] as? String,
                   (json["origin"] as? String) == "android" {
                    // notification_key = "package|id|postTime" → identifier = "swiftgreen-{postTime}"
                    let parts = key.split(separator: "|")
                    if parts.count == 3, let ts = parts.last {
                        UNUserNotificationCenter.current()
                            .removeDeliveredNotifications(withIdentifiers: ["swiftgreen-\(ts)"])
                    }
                    pendingActionKeys.removeValue(forKey: key)
                }
                return

            default:
                // Unknown JSON type — fall through to existing checks below
                print("📨 [Server] Unknown JSON type: '\(messageType)' — checking existing handlers")
                break
            }
        }
        
        // Gate existing message processing behind challenge verification when paired
        if pairingManager?.isPaired == true && !isChallengeVerified {
            print("🚫 [Server] Dropping message — device is paired but challenge not yet verified")
            return
        }
        
        // Check if it's the standard handshake string
        if text == "SwiftGreen-Hello-Android" {
            print("🤝 [Server] Handshake verified from Android client — not a notification")
            // A reconnect is exactly when our view of the call may have gone stale, so
            // re-sync from the phone rather than trusting whatever the banner still shows.
            requestCallState()
            return
        }
        
        // STEP: Attempt to decode as JSON Notification payload
        print("🔍 [Server] Attempting to decode payload as NotificationPayload JSON...")
        guard let jsonData = text.data(using: .utf8) else {
            print("❌ [Server] Could not convert payload string to UTF-8 data")
            return
        }
        do {
            let payload = try JSONDecoder().decode(NotificationPayload.self, from: jsonData)
            print("✅ [Server] JSON parsed successfully!")
            print("📋 [Server] appName: \(payload.appName)")
            print("📋 [Server] title: \(payload.title)")
            print("📋 [Server] body: \(payload.body)")
            print("📋 [Server] timestamp: \(payload.timestamp)")
            print("📋 [Server] senderType: \(payload.senderType ?? "<absent — treated as incoming>")")
            print("📋 [Server] appIcon present: \(payload.appIcon != nil ? "YES (\(payload.appIcon!.count) chars)" : "NO")")

            // Filter: only show incoming notifications.
            // If senderType is absent (older Android clients) we allow it through for
            // backward compatibility. If it is explicitly set to anything other than
            // "incoming", we drop it silently.
            if let senderType = payload.senderType, senderType != "incoming" {
                print("🚫 [Server] Dropping notification — senderType='\(senderType)' (not incoming)")
                return
            }

            print("📲 [Server] Calling showNativeNotification() for \(payload.appName)...")
            showNativeNotification(
                appName: payload.appName,
                title: payload.title,
                body: payload.body,
                timestamp: payload.timestamp,
                senderPhotoBase64: payload.senderPhoto,
                appIconBase64: payload.appIcon,
                notificationKey: payload.notificationKey,
                sbnKey: payload.sbnKey,
                hasReplyAction: payload.hasReplyAction ?? false,
                replyActionLabel: payload.replyActionLabel,
                actionButtons: payload.actionButtons ?? []
            )
            DispatchQueue.main.async {
                NotificationHistoryManager.shared.addRecord(
                    NotificationHistoryManager.NotificationRecord(
                        appName: payload.appName,
                        title: payload.title,
                        body: payload.body,
                        timestampMs: payload.timestamp,
                        key: "swiftgreen-\(payload.timestamp)",
                        appIcon: payload.appIcon,
                        senderPhoto: payload.senderPhoto,
                        androidKey: payload.notificationKey,
                        replyLabel: (payload.hasReplyAction ?? false)
                            ? (payload.replyActionLabel ?? "Reply") : nil,
                        sbnKey: payload.sbnKey
                    )
                )
            }
        } catch {
            print("⚠️ [Server] Payload is not a valid NotificationPayload JSON: \(error)")
            print("⚠️ [Server] Raw payload was: [\(text)]")
        }
    }
    
    private func showNativeNotification(
        appName: String,
        title: String,
        body: String,
        timestamp: Int64,
        senderPhotoBase64: String?,
        appIconBase64: String?,
        notificationKey: String?,
        sbnKey: String?,
        hasReplyAction: Bool,
        replyActionLabel: String?,
        actionButtons: [NotificationActionButton]
    ) {
        let identifier = "swiftgreen-\(timestamp)"
        if recentlyDeliveredIDs.contains(identifier) {
            print("🚫 [Server] Duplicate notification \(identifier) detected in recentlyDeliveredIDs. Dropping silently.")
            return
        }
        
        recentlyDeliveredIDs.insert(identifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.recentlyDeliveredIDs.remove(identifier)
            print("🧹 [Server] Removed \(identifier) from recentlyDeliveredIDs")
        }

        print("📲 [Server] showNativeNotification() — appName: \(appName), title: \(title), body: \(body)")
        print("📲 [Server] senderPhoto: \(senderPhotoBase64 != nil ? "YES" : "NO"), appIcon: \(appIconBase64 != nil ? "YES" : "NO")")

        // STEP: Build notification content
        // Mapping:  content.title    → appName  (e.g. "WhatsApp")   — bold banner title
        //           content.subtitle → title     (e.g. "John Doe")   — shown below title
        //           content.body    → body      (e.g. "Hey how are you") — message text
        let content = UNMutableNotificationContent()
        content.title    = appName
        content.subtitle = title
        content.body     = body
        // The received sound (Glass) rides on the banner, so macOS mutes it under Focus /
        // Do Not Disturb like any other app's notification. Off with the Sounds toggle.
        content.sound = SGSound.isEnabled ? UNNotificationSound(named: UNNotificationSoundName("Glass.aiff")) : nil
        print("📋 [Server] content.title='\(content.title)' subtitle='\(content.subtitle)' body='\(content.body)'")

        // STEP: Attachment — prefer sender contact photo, fall back to app icon.
        // senderPhoto is present when the sender is a saved contact on Android.
        // appIcon is the launcher icon of the source app (e.g. WhatsApp icon).
        // Priority: senderPhoto > appIcon > no attachment
        let attachmentBase64: String?
        let attachmentLabel: String
        if let photo = senderPhotoBase64 {
            attachmentBase64 = photo
            attachmentLabel = "senderPhoto"
            print("📸 [Server] Using senderPhoto as notification attachment")
        } else if let icon = appIconBase64 {
            attachmentBase64 = icon
            attachmentLabel = "appIcon"
            print("🖼️ [Server] No senderPhoto — falling back to appIcon as attachment")
        } else {
            attachmentBase64 = nil
            attachmentLabel = "none"
            print("ℹ️ [Server] No attachment available — banner will show generic icon")
        }

        if let base64 = attachmentBase64,
           let imageData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            print("🖼️ [Server] Decoded \(attachmentLabel) — \(imageData.count) bytes")
            let tmpDir = FileManager.default.temporaryDirectory
            let imageURL = tmpDir.appendingPathComponent("\(UUID().uuidString).png")
            do {
                try imageData.write(to: imageURL, options: .atomic)
                let attachmentOptions: [String: Any] = [
                    UNNotificationAttachmentOptionsThumbnailClippingRectKey:
                        CGRect(x: 0, y: 0, width: 1, height: 1) as AnyObject
                ]
                let attachment = try UNNotificationAttachment(
                    identifier: "\(attachmentLabel)-\(timestamp)",
                    url: imageURL,
                    options: attachmentOptions
                )
                content.attachments = [attachment]
                print("🖼️ [Server] UNNotificationAttachment (\(attachmentLabel)) attached successfully")
            } catch {
                print("⚠️ [Server] Failed to write/attach \(attachmentLabel): \(error.localizedDescription)")
            }
        }

        // Embed notification_key so the delegate can extract it when the user replies.
        if let key = notificationKey {
            content.userInfo = ["notification_key": key, "sbn_key": sbnKey ?? ""]
        }

        // Build UNNotificationActions for reply and button actions.
        var unActions: [UNNotificationAction] = []
        if hasReplyAction {
            let replyAction = UNTextInputNotificationAction(
                identifier: "swiftgreen_reply",
                title: replyActionLabel ?? "Reply",
                options: [],
                textInputButtonTitle: replyActionLabel ?? "Reply",
                textInputPlaceholder: ""
            )
            unActions.append(replyAction)
        }
        for btn in actionButtons {
            let action = UNNotificationAction(
                identifier: "btn_\(btn.actionId)",
                title: btn.label,
                options: []
            )
            unActions.append(action)
        }

        // One category per distinct set of buttons, not per notification: the old
        // "sg_<timestamp>" ids piled up (400 registered), and every call banner re-sent
        // the whole pile to usernoted. Responses are routed by action id and userInfo,
        // never by category, so sharing one is safe.
        let shape = unActions.map { "\($0.identifier)=\($0.title)" }.joined(separator: "|")
        let categoryId = unActions.isEmpty ? ""
            : "sg_" + SHA256.hash(data: Data(shape.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if !categoryId.isEmpty {
            content.categoryIdentifier = categoryId
            if let key = notificationKey {
                pendingActionKeys[key] = identifier
            }
        }

        // Use timestamp as identifier: same Android notification retried → replaces; new one → new banner
        // trigger: nil = deliver immediately with zero scheduling delay
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        print("🗓️ [Server] UNNotificationRequest created — id: \(identifier), trigger: immediate (nil)")

        // STEP: Must schedule on main thread — UNUserNotificationCenter requires it.
        // If actions are present, register the category first, then schedule.
        DispatchQueue.main.async {
            print("➡️ [Server] Dispatching UNUserNotificationCenter.add() on main thread...")

            UNUserNotificationCenter.current().getNotificationSettings { settings in
                print("🔐 [Server] Authorization status before add(): \(settings.authorizationStatus.rawValue) (2=authorized)")
                guard settings.authorizationStatus == .authorized else {
                    print("❌ [Server] Cannot post notification — NOT authorized (status=\(settings.authorizationStatus.rawValue))")
                    return
                }

                let scheduleNow = {
                    UNUserNotificationCenter.current().add(request) { error in
                        if let error = error {
                            print("❌ [Server] UNUserNotificationCenter.add() FAILED: \(error.localizedDescription)")
                        } else {
                            print("✅ [Server] Notification delivered immediately — id: \(identifier)")
                        }
                    }
                }

                if !categoryId.isEmpty {
                    let category = UNNotificationCategory(
                        identifier: categoryId,
                        actions: unActions,
                        intentIdentifiers: [],
                        options: []
                    )
                    DispatchQueue.main.async {
                        self.ensureCategory(category)
                        scheduleNow()
                    }
                } else {
                    scheduleNow()
                }
            }
        }
    }

    // Called by AppNotificationDelegate when the user submits a reply or taps an action button.
    func sendNotificationAction(
        notificationKey: String,
        sbnKey: String? = nil,
        actionType: String,
        replyText: String?,
        actionId: String?
    ) {
        // No phone: fail now, the same way a phone-side failure does, instead of
        // dropping the message and leaving the reply on "Sending…" forever.
        guard isTunnelActive else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .notificationActionResult, object: nil,
                    userInfo: ["notification_key": notificationKey, "success": false, "error": "not connected"])
            }
            showReplyFailedBanner(triggeredBy: pendingActionKeys[notificationKey] ?? notificationKey,
                                  message: "Your phone isn't connected, so the reply wasn't sent.")
            pendingActionKeys.removeValue(forKey: notificationKey)
            return
        }
        var body: [String: Any] = [
            "type": "notification_action",
            "notification_key": notificationKey,
            "action_type": actionType
        ]
        if let sbnKey, !sbnKey.isEmpty { body["sbn_key"] = sbnKey }
        body["reply_text"] = replyText as Any
        body["action_id"] = actionId as Any
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        sendMessage(json)
    }

    func sendMediaAction(action: String, volume: Int? = nil,
                         positionMs: Int64? = nil, queueId: Int64? = nil) {
        var body: [String: Any] = [
            "type": "media_action",
            "action": action
        ]
        if let vol = volume { body["volume"] = vol }
        if let positionMs { body["position_ms"] = positionMs }
        if let queueId { body["queue_id"] = queueId }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        sendMessage(json)
    }

    func sendAppFilterUpdate(packageName: String, blocked: Bool) {
        let body: [String: Any] = [
            "type": "app_filter_update",
            "package_name": packageName,
            "blocked": blocked
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        sendMessage(json)
    }

    private func checkListenerHealth() {
        guard let listener = listener else { return }
        if case .ready = listener.state { return }
        print("⚠️ [Server] Listener not ready (state: \(listener.state)) — recreating")
        stopServer()
        DispatchQueue.main.async { self.startServer() }
    }

    private func checkKeepaliveHealth() {
        guard serverStatus == mDNSQuicServer.onlineStatus else { return }
        if Date().timeIntervalSince(lastPingSentAt) >= pingInterval {
            lastPingSentAt = Date()
            sendMessage("{\"type\":\"ping\"}\n")
        }
        guard let last = lastKeepaliveReceivedAt else { return }
        guard Date().timeIntervalSince(last) > keepaliveDeadThreshold else { return }
        print("⚠️ [Server] Keepalive timeout (\(Int(keepaliveDeadThreshold))s) — declaring connection dead")
        guard let connection = activeConnection else { return }
        connection.cancel()
        markConnectionIdle(for: connection)
    }

    // Step 15.3 — incoming-call banner with Answer/Decline actions. Fixed identifier so
    // an offhook/idle push can dismiss it. Reuses the same category-merge pattern as
    // showNativeNotification; AppNotificationDelegate routes the taps to sendCallControl.
    static let incomingCallNotificationID = "swiftgreen-incoming-call"
    static let incomingCallCategoryID = "swiftgreen_incoming_call"

    /// This app's notification categories, by id — main thread only. Registered as a
    /// whole set, so ids no longer in use are dropped instead of accumulating, and only
    /// when a new one appears.
    private var registeredCategories: [String: UNNotificationCategory] = [:]

    /// Once per launch: drop the old one-per-notification "sg_swiftgreen-<ts>" categories
    /// and adopt the rest, so notifications still on screen from the last run keep their
    /// buttons when the set is next replaced.
    private var categoriesPruned = false
    private func pruneLegacyCategories() {
        guard !categoriesPruned else { return }
        categoriesPruned = true
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let kept = existing.filter { !$0.identifier.hasPrefix("sg_swiftgreen-") }
            DispatchQueue.main.async {
                for c in kept where self.registeredCategories[c.identifier] == nil { self.registeredCategories[c.identifier] = c }
                UNUserNotificationCenter.current().setNotificationCategories(Set(self.registeredCategories.values))
                print("🗂️ [Server] Notification categories: kept \(kept.count) of \(existing.count)")
            }
        }
    }

    private func ensureCategory(_ category: UNNotificationCategory) {
        guard registeredCategories[category.identifier] == nil else { return }
        registeredCategories[category.identifier] = category
        UNUserNotificationCenter.current().setNotificationCategories(Set(registeredCategories.values))
    }

    private func showIncomingCallNotification(number: String, name: String?, title: String = "Incoming call") {
        let subtitle = name ?? (number.isEmpty ? "Unknown" : number)
        let body = name != nil && !number.isEmpty ? number : ""

        // macOS runs each notification through a ~120–230 ms pipeline, and re-adding the
        // same id while the first is still in it cancels BOTH (usernoted: "removed from
        // delivery before pipeline finished" + CancellationError). A ring sends updates
        // back to back — numberless then with the number, the plain state then the
        // WhatsApp details, keepalive re-sends — and a ring once showed nothing for 16 s.
        // So each content is added once, and a changed one waits until the previous add
        // is 0.6 s old, by which point it has been delivered and is updated in place,
        // silently. A ring with neither number nor name waits 0.4 s for those instead of
        // flashing "Unknown".
        let signature = "\(title)|\(subtitle)|\(body)"
        // A repeat (keepalive re-sends during a ring) is dropped; after 90 s the same text
        // is a new ring, in case the previous one's end never arrived.
        // A reconnect mid-ring stops the ringtone; the phone's re-sent state restarts it.
        guard signature != callBannerSignature || Date().timeIntervalSince(callBannerAddedAt) > 90 else {
            CallRinger.start(); return
        }
        callBannerPending?.cancel()
        let bare = number.isEmpty && name == nil && title == "Incoming call"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            // The ringtone rings until the call is answered or ends; with ringing off, the
            // banner chimes once per ring and an update (the name arriving) only changes the text.
            let newRing = self.callBannerSignature == nil || Date().timeIntervalSince(self.callBannerAddedAt) > 90
            content.sound = newRing && !CallRinger.isOn ? .default : nil
            if newRing { CallRinger.start() }
            content.userInfo = ["call_action_request": true]
            content.categoryIdentifier = Self.incomingCallCategoryID
            self.callBannerPending = nil
            self.callBannerSignature = signature
            self.callBannerAddedAt = Date()
            self.ensureCategory(UNNotificationCategory(
                identifier: Self.incomingCallCategoryID,
                actions: [UNNotificationAction(identifier: "swiftgreen_call_answer", title: "Answer", options: []),
                          UNNotificationAction(identifier: "swiftgreen_call_decline", title: "Decline", options: [.destructive])],
                intentIdentifiers: [], options: []))
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: Self.incomingCallNotificationID, content: content, trigger: nil))
        }
        callBannerPending = work
        let wait = max(bare ? 0.4 : 0, 0.6 - Date().timeIntervalSince(callBannerAddedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    // Ring banner state — main thread only (see showIncomingCallNotification).
    private var callBannerSignature: String?
    private var callBannerAddedAt = Date.distantPast
    private var callBannerPending: DispatchWorkItem?

    /// Answered, declined or ended: drop the banner, including one not yet added or
    /// still inside usernoted's pipeline.
    private func clearIncomingCallNotification() {
        callBannerPending?.cancel()
        callBannerPending = nil
        callBannerSignature = nil
        CallRinger.stop()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.incomingCallNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.incomingCallNotificationID])
    }

    // Called by AppNotificationDelegate when the user taps Answer/Decline. Mac mints the
    // request_id; Android echoes it back and dedupes duplicates within a 16-entry window.
    func sendCallControl(action: String, enabled: Bool? = nil) {
        // A WhatsApp call is answered or ended by pressing its notification's buttons
        // on the phone; it has no mute we can reach.
        let store = CallLogStore.shared
        if store.liveCallApp != nil, let key = store.liveCallKey {
            guard ["answer", "hangup", "decline"].contains(action) else { return }
            let mapped = action == "answer" ? "answer" : "hangup"
            guard let data = try? JSONSerialization.data(withJSONObject: ["type": "app_call_action", "key": key, "action": mapped]),
                  let json = String(data: data, encoding: .utf8) else { return }
            sendMessage(json)
            return
        }
        var body: [String: Any] = [
            "type": "call_control",
            "action": action,
            "request_id": UUID().uuidString
        ]
        if let enabled { body["enabled"] = enabled }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        sendMessage(json)
    }

    /// Re-pulls the address book. Sent once on connect; the Calls tab also asks on
    /// appear so a contact added on the phone shows up without reconnecting.
    func requestContacts() {
        sendMessage("{\"type\":\"contacts_list_request\"}")
    }

    /// Asks Android what the phone's call state actually is right now. Android answers
    /// with an ordinary `call_state`, so nothing downstream needs to know this was a pull
    /// rather than a push. Sent on connect, when the Calls tab appears, and once a minute
    /// while a banner is up — the only thing that can unstick a banner whose transition
    /// was lost while the tunnel was down.
    func requestCallState() {
        sendMessage("{\"type\":\"call_state_request\"}")
    }

    /// Places an outgoing call. Returns the minted request_id so the caller can match the
    /// call_action_result that comes back — two rapid dials are otherwise indistinguishable.
    /// Returns nil if the payload could not be encoded.
    func sendCallDial(number: String, subscriptionId: Int?) -> String? {
        let requestId = UUID().uuidString
        var body: [String: Any] = [
            "type": "call_action",
            "action": "dial",
            "phone_number": number,
            "request_id": requestId
        ]
        // Omitted entirely when no SIM is chosen; Android reads -1 as "OS default".
        if let subscriptionId { body["subscription_id"] = subscriptionId }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return nil }
        sendMessage(json)
        return requestId
    }

    private func showReplyFailedBanner(triggeredBy identifier: String, message: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "SwiftGreen"
        content.body = message ?? "Reply failed — check your phone."
        let request = UNNotificationRequest(
            identifier: "swiftgreen-reply-failed-\(identifier)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    // MARK: - PKCS12 Certificate Loader
    /// RFC 5705 exporter secret of this connection's TLS session; the phone derives the
    /// same 32 bytes with the same label. nil if the session can't export.
    private func tlsBinding(_ connection: NWConnection?) -> Data? {
        guard let meta = connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = "EXPORTER-SwiftGreen-auth"
        let secret = label.withCString {
            sec_protocol_metadata_create_secret(meta.securityProtocolMetadata, label.utf8.count, $0, 32)
        }
        return secret.map { Data($0 as DispatchData) }
    }

    nonisolated struct TLSIdentityInfo: @unchecked Sendable { let identity: SecIdentity; let fingerprint: Data }   // SecIdentity is immutable
    nonisolated private static let identityLock = NSLock()
    nonisolated(unsafe) private static var cachedIdentity: TLSIdentityInfo?   // guarded by identityLock
    /// This install's TLS identity, and the SHA-256 of its certificate's DER encoding, which
    /// the QR and `challenge-ok` carry and the phone pins (SG-09). Any thread. The first call
    /// can run openssl and a PKCS#12 import, so AppDelegate makes it off the main thread.
    nonisolated static func tlsIdentity() -> TLSIdentityInfo? {
        identityLock.lock(); defer { identityLock.unlock() }
        if let cachedIdentity { return cachedIdentity }
        var cert: SecCertificate?
        guard let identity = loadSelfSignedIdentity(),
              SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        cachedIdentity = TLSIdentityInfo(identity: identity, fingerprint: Data(SHA256.hash(data: der)))
        return cachedIdentity
    }

    nonisolated private static func loadSelfSignedIdentity() -> SecIdentity? {
        // A per-install identity, generated once. This used to read a developer's
        // absolute path, so on every other Mac there was no certificate and no phone
        // could complete a TLS handshake. Self-signed is enough: the phone pins this
        // certificate's SHA-256 from the pairing QR (PROTOCOL.md §3), and no two installs share a key.
        let url = Self.installIdentityURL
        if !FileManager.default.fileExists(atPath: url.path), !Self.generateIdentity(at: url) {
            print("Server Cert: ERROR - could not generate a TLS identity")
            return nil
        }
        return loadIdentity(from: url.path)
    }

    // The tests use a throwaway identity in the temporary directory, never the install's own.
    nonisolated static let installIdentityURL = (TestHost.isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("SwiftGreen-tests", isDirectory: true)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SwiftGreen", isDirectory: true))
        .appendingPathComponent("identity.p12")

    /// Self-signed RSA-2048 identity via the system LibreSSL. RSA, not EC: SecPKCS12Import
    /// crashes on LibreSSL's EC key encoding when importing to memory only.
    // ponytail: 0600 file in Application Support; move to the Keychain if the TLS key ever has to resist local malware.
    nonisolated static func generateIdentity(at url: URL) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { return false }
        let key = tmp.appendingPathComponent("k.pem").path, cert = tmp.appendingPathComponent("c.pem").path
        func openssl(_ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        guard openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=SwiftGreen",
                       "-days", "3650", "-keyout", key, "-out", cert]),
              openssl(["pkcs12", "-export", "-inkey", key, "-in", cert,
                       "-passout", "pass:swiftgreen", "-out", url.path]) else { return false }
        return (try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil
    }

    nonisolated private static func loadIdentity(from path: String) -> SecIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("Server Cert: Failed to read the identity file")
            return nil
        }
        
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: "swiftgreen",
            // In memory only: imported into the login keychain, every TLS handshake's
            // signature went through the legacy file keychain and stalled ~6.4 s.
            kSecImportToMemoryOnly as String: true
        ]
        
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let firstItem = items.first,
              let identity = firstItem[kSecImportItemIdentity as String] else {
            print("Server Cert: SecPKCS12Import failed with status: \(status)")
            return nil
        }
        
        return (identity as! SecIdentity)
    }
}

struct NotificationActionButton: Codable {
    let label: String
    let actionId: String

    enum CodingKeys: String, CodingKey {
        case label
        case actionId = "action_id"
    }
}

struct NotificationPayload: Codable {
    let appName: String
    let title: String
    let body: String
    let timestamp: Int64
    let appIcon: String?
    let senderPhoto: String?
    let senderType: String?
    let notificationKey: String?
    let hasReplyAction: Bool?
    let replyActionLabel: String?
    let actionButtons: [NotificationActionButton]?
    /// Android's own StatusBarNotification.key, echoed back with a reply so the phone
    /// can find the conversation after the app reposts it. Absent on old phones.
    let sbnKey: String?

    enum CodingKeys: String, CodingKey {
        case appName, title, body, timestamp, appIcon, senderPhoto, senderType
        case notificationKey = "notification_key"
        case sbnKey = "sbn_key"
        case hasReplyAction = "has_reply_action"
        case replyActionLabel = "reply_action_label"
        case actionButtons = "action_buttons"
    }
}

private struct CallLogSyncPayload: Codable {
    let calls: [CallLogRecord]
}

private struct SmsSendResultPayload: Codable {
    let threadId: Int64
    let messageId: Int64
    let success: Bool
    let failureReason: String?
    let timestampMs: Int64

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case messageId = "message_id"
        case success
        case failureReason = "failure_reason"
        case timestampMs = "timestamp_ms"
    }
}

private struct SmsSearchResultPayload: Codable {
    let messages: [SmsMessage]

    // Android (SmsThreadStore.fetchSearchResults) sends the rows as "results". Decoding
    // "messages" failed every time, so search never showed a result and the spinner
    // never cleared.
    enum CodingKeys: String, CodingKey {
        case messages = "results"
    }
}

private struct SmsThreadListPayload: Codable {
    let threads: [SmsThread]
}

private struct SmsThreadMessagesPayload: Codable {
    let threadId: Int64
    let messages: [SmsMessage]
    /// Older messages remain on the phone. Absent from phones on older builds.
    let hasMore: Bool?
    /// Set when this answers a "Load earlier" request rather than the latest page.
    let beforeMs: Int64?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case messages
        case hasMore = "has_more"
        case beforeMs = "before_ms"
    }
}

/// Newline framing over raw bytes, with a cap on the unterminated tail. Bytes, not String:
/// a UTF-8 character split across two TCP reads made String(data:) nil, and that whole
/// read was silently dropped from the stream.
struct LineFramer {
    private var buffer = Data()

    /// The lines `data` completes, or nil once the unterminated remainder passes `limit`.
    mutating func feed(_ data: Data, limit: Int) -> [String]? {
        buffer.append(data)
        var lines: [String] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[start..<newline], as: UTF8.self))
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        return buffer.count > limit ? nil : lines
    }
}
