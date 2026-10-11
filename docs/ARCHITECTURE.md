# Architecture

Two native apps and one TLS connection between them. What travels on that connection is specified in [PROTOCOL.md](protocol/PROTOCOL.md); why it is built this way is in the ADRs ([transport](adr/ADR-001-Transport-Decision.md), [pairing and authentication](adr/ADR-002-Pairing-and-Authentication.md), [keepalive and reconnect](adr/ADR-003-Keepalive-and-Reconnect.md)). The sequence diagram is in the [README](../README.md#how-it-works).

## Components

The phone connects; the Mac listens. Each side has one class that owns the connection and routes every message to a feature store.

| | Android (`android/app/src/main/java/com/swiftgreen/app/`) | macOS (`macos/SwiftGreen/SwiftGreen/`) |
|---|---|---|
| Connection | `SwiftGreenTunnelService` (foreground service, owns the lifetime), `MdnsQuicClient` (TLS client, reconnect, message routing; the name predates the TCP decision in ADR-001), `MdnsDiscoveryManager` (mDNS) | `mDNSQuicServer` (TLS listener, authentication gate, message routing, keepalive), `mDNSServicePublisher` (Bonjour), `ProximityBeacon` (Bluetooth LE presence) |
| Pairing and keys | `PairingManager`, `PairingKeyVault` (Keystore seal), `MacCertPin` | `PairingManager` (QR, PIN, Keychain) |
| Notifications | `SwiftGreenNotificationListener`, `AppFilterManager` | `NotificationHistoryManager`, `AppFilterStore` |
| Clipboard | `ClipboardSyncManager`, `ClipboardShareActivity` (share target) | `ClipboardSyncManager` |
| Files | `FileTransferManager` (send), `FileTransferReceiver` (receive), `MediaBrowserStore` (phone storage browsing) | `FileTransferSender`, `FileTransferReceiver`, `MediaBrowserStore`, `MacFileBrowserStore` (shared folder) |
| SMS and calls | `SmsThreadStore`, `CallControlManager`, `CallLogHistoryManager`, `ContactsStore` | `SmsStore`, `CallLogStore` (also contacts), `SimStore` |
| Media | `MediaSessionManager` | `MediaControlStore` |
| UI | Jetpack Compose (`MainActivity`, `Screens`, `QRScannerScreen`) | SwiftUI (`ContentView` and one view per pane) |

The Mac never starts a connection, and nothing on either side talks to a server. The only outbound internet requests are listed in [SECURITY.md](../SECURITY.md#data-that-leaves-your-network).

## Persistence

| Data | Mac | Android |
|---|---|---|
| Pairing key | Keychain, after first unlock, not synced | AES-256-GCM sealed under an Android Keystore key, in `swiftgreen_pairing` preferences, excluded from backup and device transfer |
| TLS identity | `~/Library/Application Support/SwiftGreen/identity.p12`, mode 0600, made on first launch | The Mac's certificate fingerprint (the pin), stored with the pairing key |
| Received files | `~/Downloads`, quarantined | MediaStore Downloads (Android 10+), Downloads folder (8–9) |
| Histories and settings | `UserDefaults`. Notification and clipboard history are each saved within 1 MiB (media and the oldest entries are dropped first, see `NotificationHistoryManager.encodedWithinBudget`); call log up to 200 rows per source; contacts, app filter, a day of battery readings, file-transfer history (20) | App-private `SharedPreferences` (notification history up to 50 entries, clipboard, call log, file-transfer state, tunnel state) |
| SMS threads and messages | In memory only, fetched from the phone | Read from the phone's SMS provider; not copied |

## Test strategy

- **Unit tests on both sides** cover what a device on the network can send: the authentication gates, line-length caps, file-name containment, checksum fail-closed, transfer ordering, certificate pinning and the Keystore seal. Persistence limits are tested too.
- **Shared crypto vectors:** the pairing and authentication crypto is computed independently and asserted by both test suites, so a change on one side that breaks pairing fails a test.
- **Repository hygiene** (`scripts/check-hygiene.sh`) fails CI on key material, personal paths and log calls that could carry message content in release builds.
- **Not automated:** the two apps are never run against each other in CI. End-to-end behaviour is checked by hand on the reference setup.

Commands, counts and the manual checks: [TESTING.md](TESTING.md).
