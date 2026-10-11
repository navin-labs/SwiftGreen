## What and why

<!-- One or two sentences. Link the issue: Fixes #123 -->

## How it was tested

<!-- Commands you ran and on what. "Builds" is not a test. -->
- [ ] `cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug`
- [ ] `xcodebuild test -project macos/SwiftGreen/SwiftGreen.xcodeproj -scheme SwiftGreen -destination 'platform=macOS'`
- [ ] On devices (say which phone / Android version and which Mac / macOS version):

## Checklist

- [ ] Touches the wire protocol? Both apps changed together, and `docs/protocol/PROTOCOL.md` updated.
- [ ] Touches pairing, auth, file paths or anything a LAN peer can send? A regression test covers the case.
- [ ] No new log line prints message content, keys, PINs or proofs.
- [ ] `CHANGELOG.md` updated under *Unreleased* for anything a user would notice.
