# ADR-002 — Pairing and authentication: QR + typed PIN, pairing-key mutual challenge, pinned Mac certificate

| Field | Value |
|---|---|
| ID | ADR-002 |
| Status | **ACCEPTED** (records the design as built) |
| Date | 2026-10-10 |
| Supersedes | An earlier Ed25519 identity design (never built; removed from the public docs) |
| Wire details | [`docs/protocol/PROTOCOL.md`](../protocol/PROTOCOL.md) §3 |

## Context

Two devices with no account, no server and no shared CA have to recognise each other on a LAN that we treat as hostile: any host on it can connect to the Mac's port, advertise a fake `_swiftgreen._tcp` service, or sit in the middle. We need:

1. A first introduction that a LAN attacker can't hijack, even if they photograph the QR code.
2. Authentication on every reconnect, fast enough that a phone coming back from sleep is syncing within seconds.
3. Both directions authenticated: the phone must not send SMS, notifications or files to a host that merely answers on the right port.
4. A way to unpair that still works when the other device is off.

Constraints: CryptoKit on the Mac, JCA/BouncyCastle on Android (X25519 on API < 31), and no paid Apple Developer identity to sign anything.

## Decision

- **Pairing:** the Mac shows an ephemeral X25519 public key in a QR code and a 6-digit PIN *as text beside it*. The phone scans, the user types the PIN, and both derive `K = HKDF-SHA256(X25519, info "SwiftGreen-v1")`. The phone proves the PIN with `HMAC(K, "SwiftGreen-pin|" ‖ PIN)`. The Mac allows 3 tries and 3 minutes, then rotates both the key and the PIN.
- **Every connection:** a mutual HMAC challenge. The Mac proves `K` too (`challenge-ok` proof), and both proofs cover the TLS session's RFC 5705 exporter value, so a relay can't pass them through.
- **TLS** gives confidentiality and the exporter binding. The Mac's certificate is self-signed per install; **the QR carries its SHA-256**, and the phone checks the pairing connection against it before sending the PIN proof, then pins it. On every later connection the phone checks the certificate before it sends anything (SG-09). A phone paired before the QR carried the hash pins it from `challenge-ok`'s `tls_id`, which the Mac proves with `K`.
- **Unpair:** live `unpair_request`, or a one-way "tombstone" `HMAC(K, "SwiftGreen-unpaired")` presented later.

## Why it holds

- A LAN host without the QR doesn't have the Mac's public key, so it can't compute `K` and can't produce a PIN proof. It can only spend the 3 tries, which rotates the code (a nuisance, not a takeover).
- A LAN host *with* a photo of the QR still lacks the PIN for the Mac side, and for the phone side it lacks the Mac's private key, so it can't learn `K` either way. The PIN is guessable only online, at 3 tries per code.
- A relay between a paired phone and Mac presents its own certificate, which isn't the pinned one, so the phone sends it nothing. On Android 12+ the exporter binding stops it independently: each TLS leg has a different exporter value.

## Alternatives considered

| Option | Why not (now) |
|---|---|
| PIN inside the QR (the original design) | Anyone who sees the QR can pair. Moved the PIN out of the QR. |
| PIN only, no QR key | A 6-digit secret as the only input to the key exchange can be brute-forced offline from one observed handshake. The QR's public key makes the PIN an online-only check. |
| Trust-on-first-use TLS pinning instead of the pairing key | TOFU trusts whoever answers first. A first connection on a hostile LAN is exactly the risky case. |
| A PAKE (SPAKE2, OPAQUE) | The right primitive for "short secret → strong key", but neither CryptoKit nor the Android platform ships one. A hand-rolled or less-reviewed dependency is a worse trade than QR key + online PIN check. |
| Ed25519 long-term identity keys | More moving parts (key storage, rotation, revocation) for no property the shared `K` doesn't already give two devices. |
| Pinning without the QR (trust on first use) | Trusts whoever answers first. The QR's hash makes the first connection checkable too. |

## Consequences

- **Android 8–11 (API < 31) has no TLS exporter API**, so it runs the challenge with an empty binding (`v:1`). There the pinned certificate is what stops a relay. One residual case: a phone paired by a build from before the QR carried the hash learns the pin on its first reconnect after upgrading, and on that one connection (Android 8–11 only) a relay could forward the proofs; the phone then rejects it before sending any application data, because the proven `tls_id` isn't the relay's certificate, but the Mac has by then sent the relay its opening messages, including the listing of its shared folder (file names). Re-pairing removes the case.
- The Mac can't tell an old phone from a downgrade, so it accepts `v:1` from anyone who holds `K`. That is safe only because `K` is required either way.
- The phone stores `K` sealed with AES-256-GCM under a non-exportable Android Keystore key (`swiftgreen_pairing_wrap`), in app-private SharedPreferences excluded from cloud backup and device transfer (SG-07). A key stored in plaintext by an older build is re-sealed the first time it's read. If the seal can't be opened (a restored or moved phone), the phone deletes it and asks to pair again. Code running as the app, or a rooted phone using the Keystore key, can still recover `K`.
- Losing either device means re-pairing. There is no recovery path, by design.
