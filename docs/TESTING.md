# Testing SwiftGreen

## Automated

| Suite | Command | What it covers |
|---|---|---|
| Android unit tests (JVM) | `cd android && ./gradlew testDebugUnitTest` | 57 tests: bounded line reader, share-target URI scheme, file-name sanitising, storage-path containment, crypto vectors (HKDF, unpair proof), certificate pinning (`MacCertPinTest`), Keystore seal/migration/failure (`PairingKeyVaultTest`, with a software key standing in for the Keystore), receive order/checksum/cleanup and free-name selection (`IncomingFileTest`), SMS part tally, request dedup, caller-number parsing, media helpers |
| Android lint | `cd android && ./gradlew lintDebug` | Errors fail. 0 warnings on the current tree; the few deliberate suppressions are narrow and commented beside the code |
| macOS unit tests | `xcodebuild test -project macos/SwiftGreen/SwiftGreen.xcodeproj -scheme SwiftGreen -destination 'platform=macOS'` | 29 tests: unpaired gate, pre-auth buffer cap, stale-connection bytes, byte-safe bounded framing, per-install TLS identity (generation, mode 0600, uniqueness, importable, stable fingerprint), `challenge-ok` certificate claim (same vector as Android), streamed SHA-256, checksum fail-closed, `../` file names kept in Downloads, in-order transfer routing, back-to-back transfer saved, Mac → phone transfer complete only on the phone's confirmed result, test isolation from the real Keychain, identity and Downloads, crypto vectors identical to Android's, notification and clipboard history kept within their storage budget (media dropped before text, oversized saved history repaired on load), SMS classifier self-check |
| Repo hygiene | `scripts/check-hygiene.sh` | Key material, credential patterns, tool metadata, `website/`, junk, build output, home paths, release-unsafe logging, licence, tracked-but-ignored files |
| Mac smoke | `scripts/macos-smoke.sh <path to SwiftGreen.app>` | App launches, stays up, creates its TLS identity, listens. Uses your real SwiftGreen state (Keychain pairing key, identity file); don't run it while your own copy is running |

CI runs the Android suite, lint and both build types, the macOS tests and Release build, and the hygiene check on every push to `main` and every pull request.

The cross-platform crypto vectors (`HkdfTest`, `UnpairProofTest`, `MacCertPinTest` ↔ `ProtocolVectorTests`, `testChallengeOKCarriesTheProvenCertificateFingerprint`) were computed independently (Python `hmac`/`hashlib`) and are asserted on both platforms. If either side drifts, pairing breaks, and these tests say why.

## What automation doesn't cover

There are no end-to-end tests: the two apps are never run against each other in CI. There are no instrumented Android tests (`connectedAndroidTest`).

The features marked *Working* in the README have been checked by hand on the maintainer's reference setup (Motorola Edge 40 on Android 15, Apple Silicon Mac). If you test on something else, say what in your issue or pull request; the most useful manual checks are:

- Pair from scratch, then reconnect after the Mac sleeps and after a Wi-Fi change.
- Mirror a notification and reply to it from the Mac.
- Clipboard text and an image, both directions.
- A file each way, including one that already exists in Downloads (it must get a new name).
- Send an SMS; place, answer and decline a call from the Mac.
- Unpair from each side and confirm the other side notices.
