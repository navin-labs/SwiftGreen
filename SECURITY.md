# Security policy

## Reporting a vulnerability

**Please don't open a public issue.** Report privately through GitHub: [**Report a vulnerability**](https://github.com/navin-labs/SwiftGreen/security/advisories/new) (Security tab → Advisories). Include what you found, how to reproduce it, and which versions or commits you tested.

What happens next. SwiftGreen has one maintainer, so these are the commitments one person can keep:

| Step | Within |
|---|---|
| Acknowledge your report | 7 days |
| Confirm or rule out the issue, with reasoning | 21 days |
| Fix released, for a confirmed issue that a device on the same network can exploit | 90 days, usually much sooner |

You'll be credited in the advisory and the changelog unless you'd rather not be. Please give us the 90 days (or until a fix ships, if sooner) before publishing details.

## Supported versions

Only the latest release gets security fixes. Older builds should update.

## What is and isn't protected

SwiftGreen assumes your local network is **not** trusted: any device on it may connect to the Mac, advertise a fake Mac, or sit in the middle. Design: [ADR-002](docs/adr/ADR-002-Pairing-and-Authentication.md). Wire details: [PROTOCOL.md §3](docs/protocol/PROTOCOL.md#3-pairing-and-authentication).

**Protected** (implemented, and covered by the tests listed in [docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md)):

- A device without the pairing key can't make the Mac act on anything. While unpaired, the Mac accepts only a pairing request; while paired, only the challenge response, until the challenge succeeds.
- Pairing needs both the QR code (the Mac's public key) and the PIN shown on screen. Three wrong PINs, or three minutes, retire the code.
- Both sides prove the pairing key on every connection, so a phone won't talk to a fake Mac and the Mac won't accept a fake phone.
- **The phone pins the Mac's TLS certificate.** The QR carries its SHA-256; the phone checks the pairing connection against it before sending the PIN proof, and every later connection before sending anything. A relay presenting its own certificate gets nothing from the phone, on every Android version (unit-tested, see below).
- On Android 12+, the authentication proofs are also bound to the TLS session, so a relay can't forward them even apart from the pin.
- Traffic between the two is encrypted with TLS.
- A device connecting to the Mac can't knock the paired phone off: while the phone is connected, a newcomer must answer its own challenge before it can replace the connection.
- **The phone's pairing key is sealed** with AES-256-GCM under a non-exportable Android Keystore key, so a copy of the app's preferences file alone doesn't reveal it. It is also excluded from backups and device transfer.
- Received files can't be written outside the Downloads folder, can't overwrite existing files, and are kept only if their SHA-256 matches.
- Oversized lines before authentication can't exhaust memory on either side.
- The phone's share target only sends content you shared from another app, never SwiftGreen's own private files.

**Not protected, or not yet:**

- **Not attack-tested on a device.** Pinning, channel binding and the Keystore seal are covered by unit tests and cross-platform test vectors, and the app is in daily use on one reference phone, but no relay or hostile-network attack has been staged against a real phone.
- **Upgrading a pairing made before pinning.** Such a phone has no pin yet and learns it on its first reconnect, from a claim the Mac proves with the pairing key. On Android 12+ that connection is protected by channel binding. **On Android 8–11 it isn't**: a relay present at exactly that moment could forward the authentication; the phone then refuses the relay before sending any data, but the Mac will already have sent the relay its opening messages, including its shared-folder file listing. Re-pairing after upgrading removes this case.
- **Code running as SwiftGreen, or a rooted phone**, can use the Keystore key and so recover the pairing key. The seal protects a copied file, not a compromised phone.
- **The Mac's TLS identity** is generated on first launch by the system `/usr/bin/openssl` and kept as a PKCS#12 file (mode 0600) in `~/Library/Application Support/SwiftGreen/`, with a fixed passphrase, so the file mode is its only protection; it is **not** in the Keychain. Other software running as you can read it and could impersonate the Mac's certificate, though not prove the pairing key. If generation fails (no `openssl`, unwritable folder), the Mac has no TLS identity and no phone can connect.
- **Availability.** A device on the network can still hold up to 4 pending connections to the Mac's port, and can disrupt pairing while no phone is connected.
- **A compromised Mac or phone** sees everything synced. SwiftGreen is not a defence against malware on either end.
- **No security audit by a third party** has been done. The review in [docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md) was done by the project.

## Data that leaves your network

Only from the phone, and none of it is your messages, notifications, clipboard or files:

- Album artwork for what's playing, from the URL your music app supplies, or looked up by track and artist on Apple's iTunes Search API.
- Google ML Kit, which scans the pairing QR code; its terms allow it to send usage metrics to Google.

From the Mac, only when you click it: **Open in WhatsApp** on a call or contact opens a `wa.me` link containing that phone number in your browser.

SwiftGreen does not read the phone's accounts. It recognises your own outgoing WhatsApp messages from the notification's metadata (a message with no sender is yours) and skips them.
