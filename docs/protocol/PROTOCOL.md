# SwiftGreen protocol (as built)

**This is the authoritative description of what the two apps exchange.** It was written from the code of both apps (`macos/…/mDNSQuicServer.swift`, `PairingManager.swift`, `FileTransferReceiver.swift`; `android/…/MdnsQuicClient.kt`, `PairingManager.kt`, `FileTransferReceiver.kt`, `FileTransferManager.kt`) on 2026-10-10. Where this file and the code disagree, the code is right and this file is a bug; fix one or the other in the same change.

It is the only protocol document. Earlier design documents (a binary framed protocol, Ed25519 identities, a relay) were never built and were removed from the public tree; decisions are in `docs/adr/`.

---

## 1. Transport

| | |
|---|---|
| Discovery | mDNS/DNS-SD service `_swiftgreen._tcp.` (Mac registers it, phone browses). Fallbacks, in order: the last address that worked, the Mac's IPv4 addresses and port carried in the pairing QR, a TCP probe of the phone's /24 subnet on the saved port. |
| Connection | One TCP connection, phone → Mac. The Mac listens on a port it saves and reuses across launches (a free port if that one is taken). |
| Security layer | TLS (whatever version both sides support; TLS 1.3 on current OSes). The Mac presents a self-signed RSA-2048 certificate made on first launch by `/usr/bin/openssl` and stored as `~/Library/Application Support/SwiftGreen/identity.p12` (file mode 0600, fixed passphrase, so the file mode is its only protection; not in the Keychain). If it can't be made or read, the Mac has no identity and every handshake fails. **The phone pins this certificate** by the SHA-256 of its DER encoding (§3.1, §3.2) and checks it right after the handshake, before it sends anything. Peer authentication is still the pairing key (§3). The Mac offers ALPN `swiftgreen-sync`; the phone sends none. |
| Framing | Newline-delimited UTF-8, split on bytes (a character split across two TCP reads is reassembled, not dropped). One message per line; almost every message is a JSON object with a string `type`. Exceptions: the bare lines `SwiftGreen-Hello-Android` and `SwiftGreen-Hello-Mac` after authentication, and notification payloads (a JSON object with no `type`, §6). |
| Line limits | Before authentication, either side drops the connection on an unterminated line over **64 KiB**. After it, **64 MiB** (the largest real line is a clipboard image, capped at 10 MiB of base64 by its sender). |
| Unknown messages | Ignored (logged). Unknown fields are ignored. There is no version negotiation beyond the `v` field of the challenge response (§3.2). |

## 2. Connection lifecycle

```
phone                                   Mac
  |---- TCP + TLS ----------------------->|   Mac, unpaired: sends {"type":"unpaired"[,"proof"]} (§3.4)
  |<--- {"type":"challenge","nonce":N} ---|   Mac, paired: 32 random bytes, 5 s to answer
  |---- {"type":"challenge-response",...}>|
  |<--- {"type":"challenge-ok","proof":P}-|   phone verifies P or hangs up
  |<--- SwiftGreen-Hello-Mac -------------|
  |---- SwiftGreen-Hello-Android -------->|
  |<--> feature traffic ----------------->|
```

- **One phone at a time.** While no authenticated tunnel is up, a new connection replaces any unauthenticated one. While a tunnel is up, a newcomer gets its own challenge, buffer (64 KiB) and 5 s timer, and replaces the tunnel only after it proves `K`; failing or timing out never touches the tunnel. At most 4 newcomers are held at once; more are closed on accept. An `unpaired` with a valid proof (§3.4) is honoured from a newcomer too.
- **One context.** On the Mac, all connection, challenge and receive-buffer state lives on the main queue, and every callback first checks it still belongs to the current connection, so a replaced connection's late bytes or events can't reach the new one.
- **Keepalive is Mac-driven.** Every 30 s the Mac sends `{"type":"ping"}`; the phone answers `{"type":"keepalive","timestamp":<ms>}`; the Mac replies `{"type":"heartbeat_ack"}` and the phone reads the round-trip time from it. The Mac drops a connection with no keepalive for 100 s. The phone drops one with nothing read for 100 s (`IDLE_TIMEOUT_MS`). The phone keeps no timer of its own, so it can sleep between pings. (Older docs say "phone every 60 s, Mac 75 s"; that is no longer true.)
- **Going away.** On quit or sleep the Mac sends `{"type":"disconnect","reason":…}` so the phone reconnects at once instead of waiting out the timeout.
- **Reconnect.** The phone retries with backoff (2 s doubling to 10 s, then 30 s, about 10 minutes in all), then falls back to a 15-minute JobScheduler job (unmetered network) and the Mac's Bluetooth LE beacon. When a connection fails, the Mac waits 10 s for the phone to come back before showing "offline"; a clean close shows it at once.

## 3. Pairing and authentication

All keys are 32 bytes. `HMAC` is HMAC-SHA256. `‖` is byte concatenation. Strings are UTF-8.

### 3.1 Pairing (first time)

1. The Mac creates an ephemeral X25519 key pair and a 6-digit PIN (CSPRNG). It shows a QR code containing `{"publicKey": base64(32-byte raw X25519 public key), "hostname": …, "tls": base64(SHA-256 of its certificate's DER), "ips": [IPv4…], "port": …}` (`ips` and `port` only when known) and, **separately on screen, the PIN**. The PIN is never in the QR.
2. The phone scans the QR (a QR without a valid 32-byte `tls` is refused), makes its own X25519 key pair, and the user types the PIN. It connects, and **closes the connection unless the certificate presented is the one named by `tls`**; only then does step 4 happen. After pairing it stores that fingerprint as the pin.
3. Both sides compute `K = HKDF-SHA256(ikm: X25519(own private, peer public), salt: empty, info: "SwiftGreen-v1", length: 32)`.
4. Phone → Mac: `{"type":"pairing","publicKey":base64(phone public key),"pin_proof":base64(HMAC(K, "SwiftGreen-pin|" ‖ PIN))}`.
5. The Mac derives `K` itself and checks the proof in constant time. Replies:
   - `{"type":"pairing-complete"}`: both sides store `K` (Mac: Keychain, `kSecAttrAccessibleAfterFirstUnlock`, not synchronised; phone: AES-256-GCM-sealed under the Android Keystore key `swiftgreen_pairing_wrap`, stored as `gcm1:base64(iv ‖ ciphertext ‖ tag)` in app-private SharedPreferences, excluded from backup and device transfer. A bare-base64 value written by an older build is re-sealed on first read; a value that can't be opened is deleted and the phone asks to pair again).
   - `{"type":"pairing-failed","reason":"pin"}`: wrong PIN.
   - `{"type":"pairing-failed","reason":"expired"}`: a session older than 3 minutes, or the third wrong PIN. The Mac shows a new QR and PIN.

While unpaired, the Mac acts on **only** a JSON object whose `type` is `pairing`; anything else gets `{"type":"error","message":"unpaired"}` and the connection is closed. It allows 60 s for the pairing message.

Test vectors (K = bytes 0x00…0x1f), checked by both test suites:

| Value | Hex |
|---|---|
| `HKDF-SHA256(ikm: K, salt: "", info: "SwiftGreen-v1", 32)` | `0c63b3717a267c7747352a06f49369af034f356e4dabdf2dae067afdd5664129` |
| `HMAC(K, "SwiftGreen-pin|123456")` | `219e636fca18b7641f3465abb6a4cca462d248ae82e62b60b6f7afc36476efbb` |
| `HMAC(K, "SwiftGreen-unpaired")` | `f3c964442808f6b63f3176acab49d0f8b48bd8542fc2ad2789ab2f8acd2669a2` |
| `F = SHA-256("cert")` (a stand-in fingerprint) | `06298432e8066b29e2223bcc23aa9504b56ae508fabf3435508869b9c3190e22` |
| `HMAC(K, "SwiftGreen-tls-id|" ‖ C ‖ F)`, `C` = 32 bytes of `0x07` | `6acfada117ce6bc40786d440d1f80c64363d7da65dd9a0408f7ae1883b9545ce` |

### 3.2 Every later connection (mutual challenge)

0. The phone checks the certificate against its pin. On a mismatch it sends nothing and closes; only an `unpaired` carrying a valid proof (§3.4) is acted on, and a bare `unpaired` from that host doesn't stop reconnecting.
1. Mac → `{"type":"challenge","nonce":base64(N)}`, `N` = 32 random bytes, single use, 5 s deadline.
2. Phone → `{"type":"challenge-response","v":2,"hmac":base64(HMAC(K, N ‖ B)),"client_nonce":base64(C)}`, `C` = 32 random bytes.
3. Mac checks the HMAC (constant time) and that `C` is at least 16 bytes, then → `{"type":"challenge-ok","proof":base64(HMAC(K, "SwiftGreen-server|" ‖ C ‖ B)),"tls_id":base64(F),"tls_id_proof":base64(HMAC(K, "SwiftGreen-tls-id|" ‖ C ‖ F))}`, `F` = its certificate fingerprint. The phone checks `proof` and closes the connection if it is wrong ("not your Mac"). It then checks the `tls_id` claim: if present, it must verify under `K` and equal this connection's certificate, or the phone closes. A phone with no pin yet (paired by an older build) pins `F` here; see SECURITY.md for the one-connection residual risk this leaves on Android 8–11.

`B` is the TLS session's RFC 5705 exporter value: label `EXPORTER-SwiftGreen-auth`, no context, 32 bytes. A relay in the middle runs two TLS sessions with different `B`, so neither proof passes through it. **Android below 12 (API 31) cannot export it**, so it sends `"v":1` and both sides use an empty `B`; there the certificate pin (step 0) is what stops a relay. The Mac accepts v1 from any phone that asks for it, because it can't tell an old phone from a downgrade. A relay can't make a v2 phone pass as v1: the phone's HMAC already covers its own `B`.

Until the challenge succeeds, the Mac drops every message except `challenge-response` and a proven `unpaired`, including the file-transfer fast path.

### 3.3 Unpair while connected

Either side sends `{"type":"unpair_request"}` inside the authenticated session; both delete `K`.

### 3.4 Unpair while apart

An `unpaired` notice the phone delivers later goes only to a host presenting the pinned certificate. The side that unpaired keeps `P = HMAC(K, "SwiftGreen-unpaired")` after deleting `K` and presents it at the next meeting as `{"type":"unpaired","proof":base64(P)}`. The Mac sends it as the first line of every connection while it is unpaired; the phone sends it in place of a challenge response. The receiver deletes its own `K` only if `P` verifies against it. An `unpaired` without a valid proof never deletes a key: the phone stops reconnecting and asks the user. `P` is one-way and no other check accepts it, so it is not a secret.

## 4. File transfer

Both directions, newline-delimited JSON:

1. `{"type":"file_transfer_begin","transfer_id","filename","mime_type","total_bytes","total_chunks","checksum_sha256","resume_offset"}`. Mac → phone fills `checksum_sha256`; phone → Mac sends `""` and puts the checksum in step 3.
2. `{"type":"file_transfer_chunk","transfer_id","chunk_index","total_chunks","data":base64(≤ 256 KiB),"is_final"}`, in order.
3. `{"type":"file_transfer_complete","transfer_id","checksum_sha256"}` (phone → Mac).
4. `{"type":"file_transfer_cancel","transfer_id"}` from either side.
5. `{"type":"file_transfer_result","transfer_id","ok"}` (phone → Mac), after the phone has saved and verified a file, or discarded it. The Mac shows a transfer complete only on `"ok":true`; `false`, or no result within 60 s, is shown as an error.

Receiver rules, as implemented on both sides:

- **The name is reduced to its last path component** (`/` and, on Android, `\`); empty, `.` and `..` are refused (Android) or replaced with `file` (Mac). Files land in the user's Downloads folder only.
- Data streams to a temporary destination. Nothing is held whole in memory, and hashing is streamed. On the Mac that is a temporary file. On Android 10+ (API 29) it is a pending MediaStore Downloads row (`IS_PENDING=1`, no storage permission needed), made visible only after the checksum passes; on Android 8–9 it is a `.part` file in Downloads, which needs `WRITE_EXTERNAL_STORAGE` (requested at first launch; without it the phone refuses the transfer with `file_transfer_cancel` and tells the user).
- **Success needs a matching SHA-256** (lowercase hex). A missing or wrong checksum, a gap in chunk order, a wrong byte count, a failed write, a cancel from either side or a refused publish deletes the temporary file or row and saves nothing.
- An existing file is never overwritten. Mac and Android 8–9: `name_1.ext` … `name_99.ext` (on Android the name is reserved atomically), then the transfer fails. Android 10+: MediaStore chooses a free name.
- The Mac tags saved files with `com.apple.quarantine` so Gatekeeper checks them before they run.
- On the Mac, all four messages are handled on one serial queue in stream order.
- The Mac→phone sender can resume after a reconnect (`resume_offset`); the phone keeps its partial file across a dropped connection for that reason.

## 5. Message catalogue

Every message below is accepted only after authentication (§3.2). "→ Mac" is phone to Mac.

| Direction | `type` | Purpose |
|---|---|---|
| → Mac | `telemetry` | Battery level and charging state, latency, SIMs, notification access (phone → Mac only; nothing leaves the LAN) |
| → Mac | `device_info` | Phone name, model, Android and app version, storage |
| → Mac | *(no type)* notification object | Mirrored notification: `appName`, `title`, `body`, `timestamp`, optional `appIcon`/`senderPhoto` (base64), `notification_key`, `sbn_key`, `has_reply_action`, `reply_action_label`, `action_buttons`, `senderType` |
| → Mac | `notification_dismiss` | Phone-side dismissal of a mirrored notification |
| ← Mac | `notification_action` | Inline reply or button press on a mirrored notification; answered by `notification_action_result` |
| both | `clipboard_push` | `content_type` `text` (`text`) or `image` (`image_base64`, `image_mime_type`); `source` prevents echo |
| → Mac | `call_state`, `call_log_sync`, `app_call` | Cellular call state, call history, WhatsApp-style VoIP calls |
| ← Mac | `call_control`, `call_action`, `app_call_action`, `call_state_request` | Answer, decline, hang up, mute, dial (with `request_id`), VoIP call buttons |
| → Mac | `call_control_result`, `call_action_result` | Outcomes, echoing `request_id` |
| ← Mac | `get_sms_threads`, `get_sms_messages`, `sms_search`, `sms_send` | SMS reads and sends |
| → Mac | `sms_thread_list`, `sms_thread_messages`, `sms_search_result`, `sms_send_result` | Answers |
| ← Mac | `contacts_list_request` → `contacts_list_response` | Address book |
| ← Mac | `media_action` | Play/pause/next/seek/volume on the phone's active media session |
| → Mac | `media_state` | Now playing, with artwork |
| ← Mac | `media_list_request`, `media_search_request`, `media_thumbnail_request`, `media_file_request` | Browse the phone's shared storage. Every path is relative to shared-storage root and resolved canonically; anything outside it is refused |
| → Mac | `media_list_response`, `media_search_response`, `media_thumbnail_response` | Answers |
| ← Mac | `mac_directory_list_push` | Listing of the Mac's shared folder (sent on every connect) |
| → Mac | `mac_directory_file_request` | Ask for a file from that listing by `file_id` (never a path) |
| ← Mac | `get_app_filter_list`, `app_filter_update` | Which apps' notifications to mirror |
| → Mac | `app_filter_list` | Installed apps and their filter state |
| ← Mac | `find_phone` → `find_phone_state` | Ring the phone |
| both | `file_transfer_*` | §4 |
| both | `unpair_request`, `unpaired` | §3.3, §3.4 |
| ← Mac | `ping`, `heartbeat_ack`, `disconnect` | §2 |
| → Mac | `keepalive` | §2 |

Field-level details live with each handler; search either codebase for the `type` string.
