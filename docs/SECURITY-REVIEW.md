# Security review

Before the first public release the project reviewed its own code against the threat model in [SECURITY.md](../SECURITY.md): a hostile device on the same network that can connect to the Mac, advertise a fake Mac, sit in the middle, and send malformed, oversized, reordered or replayed data. Other apps on the phone and anything that ends up in logs were also in scope. This is the project's own review, **not a third-party audit**.

Every fix below has a regression test unless the row says otherwise. The tests run in CI; see [TESTING.md](TESTING.md).

**Severity:** P0 critical · P1 high · P2 medium · P3 low.

## Fixed

| ID | Sev | Component | Issue | Fix | Test |
|---|---|---|---|---|---|
| SG-01 | P0 | Mac server | An unpaired Mac acted on any line containing `"publicKey"`, so a device on the network could set the clipboard or post notifications | While unpaired, only a parsed JSON object whose `type` is exactly `pairing` is admitted | `testUnpairedMacAdmitsOnlyPairingRequests` |
| SG-04 | P1 | Mac TLS | The TLS identity was read from one developer's machine, so other builds had none and working builds shared one key | Per-install self-signed identity generated on first launch (mode 0600), imported memory-only | `testGeneratesImportablePrivatePerInstallIdentity`, `testInstallIdentityHasAStableFingerprint` |
| SG-19 | P1 | Mac file receive | Phone → Mac files were saved without checking the SHA-256 | Missing or mismatched checksum deletes the file; hashing is streamed | `testAndroidStyleTransferWithWrongChecksumIsNotSaved`, `testStreamedSha256` |
| SG-02 | P2 | Mac server | Unbounded receive buffer before authentication | 64 KiB line cap before the challenge, 64 MiB after | `testPreAuthBufferIsSmall` |
| SG-03 | P2 | Mac file receive | Transfer messages ran on two queues, so a small file's first chunk could overtake `begin` and the transfer stalled | All transfer messages run in stream order on one serial queue | `testFileTransferLinesAreRoutedInline`, `testBackToBackAndroidStyleTransferIsSaved` |
| SG-05 | P2 | Android client | Unbounded `readLine()` before the Mac proved the key | `LineReader`: 64 KiB per line before authentication, 64 MiB after | `LineReaderTest` |
| SG-06 | P2 | Android share target | Another app could make SwiftGreen send its own private files (including the pairing key) to the Mac via a `file://` URI | Only `content://` URIs are accepted | `ShareableSchemeTest` |
| SG-07 | P2 | Android storage | Pairing key stored in plaintext preferences | AES-256-GCM seal under a non-exportable Android Keystore key; a plaintext key is re-sealed on first read; an unreadable one is deleted and the user is asked to pair again | `PairingKeyVaultTest` (software key stands in for the Keystore) |
| SG-08 | P2 | Mac server | Any device connecting to the Mac knocked the paired phone off | A newcomer must answer its own challenge before it can replace the connection; at most 4 pending | Structure- and compile-checked; no unit test |
| SG-09 | P2 | Authentication | No relay protection on Android 8–11 (no TLS channel binding below API 31) | The phone pins the Mac's certificate: its SHA-256 is in the QR and checked before anything is sent | `MacCertPinTest`, `testChallengeOKCarriesTheProvenCertificateFingerprint` |
| SG-15 | P2 | Android file receive | Mac → phone transfers failed below Android 11 or without "All files access" | MediaStore Downloads on Android 10+; legacy storage with the storage permission on 8–9; hash as bytes arrive, discard on every failure | `IncomingFileTest` |
| SG-23 | P2 | Mac framing | A UTF-8 character split across two reads dropped the whole read | Byte-level line framing, decode per complete line | `testLineFramerIsByteSafeAndBounded` |
| SG-24 | P2 | Logging | Logs carried the QR payload, addresses, file names and message text | Android: one `Log` wrapper; release builds log no message text. Mac: `print` is a no-op in Release | Enforced by `scripts/check-hygiene.sh` |
| SG-12 | P3 | Mac server | Connection state touched from two queues | Confined to the main queue; a replaced connection's late bytes are ignored | `testStaleConnectionBytesNeverReachTheNewConnection` |
| SG-13 | P3 | Protocol | Android ignored the Mac's `file_transfer_cancel` | Handled: partial file and progress notification removed | — |
| SG-14 | P3 | Android file receive | Receiving could truncate or overwrite an existing file in Downloads | Unique temp file, atomic free-name reservation, fail if no free name | `IncomingFileTest` |
| SG-16 | P3 | Android config | Network security config trusted user-installed CAs | System CAs only, no cleartext | — |
| SG-25 | P3 | Android boot | Crash at boot before first unlock | Boot receiver waits for the user unlock | — |
| SG-26 | P3 | Android file receive | Receive state shared between threads without a lock | Entry points synchronised | — |
| SG-27 | P3 | Build | Gradle distribution not checksum-pinned | `distributionSha256Sum` in the wrapper properties | — |

## Accepted (availability only)

| ID | Issue | Why accepted |
|---|---|---|
| SG-22 | A device on the network can burn the 3 PIN tries and make the Mac rotate its pairing code | It can't pair; the user scans the new code |
| SG-30 | A device can hold the 4 pending-connection slots, delaying a reconnecting phone | Each slot closes after 5 s; no data exposure |
| SG-31 | The fallback /24 probe takes the first host that answers on the Mac's port | A pinned phone refuses the wrong host before sending anything |
| SG-32 | `QUICKBOOT_POWERON` isn't a protected broadcast | It can only start the sync service when the user left sync on |

Residual risks (pre-pinning pairings on Android 8–11, local access to the Mac's TLS identity file, code running as the app) are listed in [SECURITY.md](../SECURITY.md#what-is-and-isnt-protected).

## Not covered by this review

- No relay or hostile-network attack has been staged against a phone; the pinning and authentication checks are verified by unit tests and cross-platform test vectors.
- Behaviour has been checked on one reference setup only (see the README).
