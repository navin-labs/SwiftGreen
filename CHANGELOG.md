# Changelog

All notable changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

First public release, planned as v0.1.0, a beta tested on one reference phone and Mac.

### Added
- Open-source release under Apache-2.0: README, SECURITY, CONTRIBUTING, code of conduct, issue and PR templates.
- CI for both apps (unit tests, Android lint, debug and release builds) and a repo-hygiene check (`scripts/check-hygiene.sh`).
- `docs/protocol/PROTOCOL.md`: the protocol as built, the single authoritative spec. ADR-002 (pairing and authentication) and ADR-003 (keepalive and reconnect).
- Regression tests for every security fix below, plus cross-platform crypto test vectors run on both platforms.

### Security
- Mac: while unpaired, only a pairing request is accepted. Previously any message containing the text `"publicKey"` was acted on, so a device on the same network could set the clipboard or post notifications.
- Mac: unterminated lines are capped at 64 KiB before authentication (64 MiB after). Previously unbounded.
- Mac: each install generates its own TLS identity. Previously the identity came from one developer's machine, so builds elsewhere had none.
- Mac: phone → Mac files are saved only when their SHA-256 matches; a missing checksum is a failure. Saved files get the quarantine flag.
- Android: the socket reader is capped at 64 KiB per line before authentication. Previously a host answering on the Mac's port could exhaust the phone's memory.
- Android: the share target accepts only `content://` URIs. Previously another app could make SwiftGreen send its own private files (including the pairing key) to the Mac.
- Android: network security config no longer trusts user-installed CAs or lists (ineffective) cleartext exceptions.
- Release builds of the Mac app no longer print anything; Android release builds log no message text at all (only tags and exception class names), enforced by `scripts/check-hygiene.sh`.
- Android: the phone pins the Mac's per-install TLS certificate. The QR carries its SHA-256 and the phone checks it before sending a PIN proof, an authentication proof or any data; a phone paired earlier pins it from a key-proven `tls_id` in `challenge-ok`. Closes the relay gap on Android 8–11 for new pairings.
- Android: the pairing key is sealed with AES-256-GCM under an Android Keystore key; a plaintext key from an earlier build is re-sealed on first read; an unreadable one is deleted with a re-pair message.
- Mac: a new connection can no longer knock the paired phone off; it must authenticate before it replaces the tunnel.
- Mac: connection, challenge and buffer state is confined to the main queue, and a replaced connection's late bytes can't reach the new one.
- Android: own outgoing WhatsApp messages are recognised from the notification's metadata. The app no longer looks up the phone's Google account name or SIM display name for this.

### Fixed
- Mac: notification history could outgrow the ~4 MiB `UserDefaults` limit (base64 icons and photos), so saving it failed. It is now saved within a 1 MiB budget: photos are dropped first, oldest first, then the oldest notifications; an oversized history from an earlier build is shrunk on launch.
- Mac: clipboard history had the same problem (20 clippings of up to 1 MiB each). It is saved within the same budget: a clipping too big to fit is left out, then the oldest unpinned clippings go first.
- Mac: copied text containing a control character other than tab, newline or carriage return was sent to the phone as invalid JSON.
- Mac: a small file from the phone could stall in "Receiving" forever: its first chunk overtook the `begin` message and was dropped. All transfer messages now run in stream order on one queue.
- Mac: a checksum mismatch now clears the "Receiving" state and records the failure.
- Android: a cancel from the Mac is now honoured (the partial file and progress notification were left behind).
- Android: receiving a file can no longer truncate or overwrite an existing file in Downloads.
- Mac: a file sent to the phone showed complete as soon as its last chunk was sent, a few seconds before the phone had saved and verified it, and even if the phone then discarded it. The phone now answers with `file_transfer_result`, and the Mac shows complete only on success; until then it says "Finishing on phone…".
- Android: tapping the "File Received" notification now opens the file.
- Mac: the pairing key is read from the Keychain once per launch instead of on every connection check, so a new build's Keychain prompt appears once.
- Android: a call dialed on the phone itself showed as "Unknown" on the Mac, because Android gives no number for it. The name now comes from the dialer's ongoing-call notification.
- Android: the TLS-exporter check now gates on API 31, where the API exists (it gated on API 29 and failed silently on 29–30).
- Android: Mac → phone files now work on Android 8–9 (storage permission) and 10+ (MediaStore Downloads, no "All files access"), hashing as they arrive and deleting the partial file on every failure.
- Mac: a UTF-8 character split across two TCP reads no longer drops that whole read.
- Android: no crash at boot before the first unlock (`LOCKED_BOOT_COMPLETED` read credential-encrypted preferences).

### Changed
- New app icon on both platforms: the SwiftGreen swift (`design/icon/swiftgreen-mark.svg`, the same mark as the website), replacing the earlier bird and green trail. `design/icon/build.sh` regenerates every packaged icon from it.
- Android: compileSdk and targetSdk 37; Gradle 9.8.1 (checksum-pinned), AGP 9.4.1, Kotlin 2.4.21 and current AndroidX, CameraX and Bouncy Castle. Dependencies are declared in the version catalog.
- Both apps build with zero warnings: Android lint, the Kotlin compiler and Xcode.
- Android: mDNS resolution uses `registerServiceInfoCallback` on Android 14+ (`resolveService` below that). The QR camera uses `ResolutionSelector`, and permission prompts use the Activity Result API.
- Mac: the TLS identity is generated and imported off the main thread at launch, so the first launch no longer stalls the UI.
- Mac: the unit tests use their own Keychain item, a temporary TLS identity and a temporary Downloads folder, and the app does nothing else while hosting them (no quitting other copies, no port, no mDNS).

### Removed
- Android: the unused photo, video and audio permissions (`READ_MEDIA_*`); the Files pane uses "All files access". The WorkManager dependency; a watchdog an earlier build scheduled is cancelled through `JobScheduler`.
- Paid tiers, licence keys, billing and relay code. Every feature is free.
