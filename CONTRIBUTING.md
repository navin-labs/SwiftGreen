# Contributing

Thanks for helping. SwiftGreen has one maintainer, so small, focused pull requests with tests are the easiest to review and merge.

## Before you start

- **Bug?** Open an issue first (unless it's a one-line fix), with your phone, Android version and macOS version.
- **Feature?** Open an issue to discuss it before writing code. SwiftGreen stays local-only: no accounts, servers or cloud relays.
- **Security issue?** See [SECURITY.md](SECURITY.md). Never in a public issue or PR.

## Set up

Everything you need, with the exact commands, is in [docs/BUILDING.md](docs/BUILDING.md). In short: JDK 17+ and the Android SDK (Platform 37) for `android/`, Xcode 16.3+ for `macos/`. You'll want a real Android phone and a Mac on the same network to try changes end to end. The emulator can't see your LAN's mDNS.

## Making a change

1. Fork, then branch from `main`: `fix/short-description` or `feat/short-description`.
2. Keep the change to one thing. Unrelated cleanups go in their own PR.
3. Match the code around you: Kotlin official style on Android, the existing SwiftUI patterns on the Mac. Comments explain *why*, not what.
4. **Changing a message on the wire?** Change both apps in the same PR and update [docs/protocol/PROTOCOL.md](docs/protocol/PROTOCOL.md). Old builds of the other app must keep working: add fields, don't rename or remove them.
5. **Touching anything a device on the network can send** (parsing, pairing, auth, file names, sizes)? Add a regression test for the hostile case, not just the happy path.
6. Don't log message content, keys, PINs or proofs. Types and sizes are fine. On Android log only through the app's `Log` object (`Log.kt`): release builds drop all message text. On the Mac, `print` is a no-op in Release; don't use `NSLog`, `Logger` or `os_log` with `%{public}`. `scripts/check-hygiene.sh` fails on both.
7. Add a line to `CHANGELOG.md` under *Unreleased* if users would notice.

## Tests

Run both before you push. CI runs the same:

```bash
cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug
```

```bash
xcodebuild test -project macos/SwiftGreen/SwiftGreen.xcodeproj -scheme SwiftGreen -destination 'platform=macOS'
```

```bash
scripts/check-hygiene.sh
```

More on what's covered, and the most useful manual checks: [docs/TESTING.md](docs/TESTING.md). In the PR, say what you tested on, including the devices.

## Pull requests

- Fill in the template. Link the issue.
- CI must pass. A failing check is never fixed by weakening a test or suppressing a lint error.
- By submitting a PR you agree your contribution is licensed under the project's [Apache-2.0 license](LICENSE).

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
