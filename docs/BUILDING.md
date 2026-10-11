# Building SwiftGreen

Every command here was run on 2026-10-11 against this repository (Apple Silicon Mac, Xcode 27.0, Android Studio's bundled JDK 21, Android SDK Platform 37). Run them from the repository root unless a step says otherwise.

## Android

### Toolchain

| | Version | Why |
|---|---|---|
| JDK | 17 or later (tested 21) | Required by Android Gradle Plugin 9 |
| Gradle | 9.8.1 | Pinned by the wrapper, with its SHA-256; nothing to install |
| Android Gradle Plugin | 9.4.1 | `android/gradle/libs.versions.toml` |
| Kotlin | 2.4.21 | Same file |
| compileSdk / targetSdk | 37 / 37 | Latest API level, so the app runs under current background and permission rules. Install **Android SDK Platform 37** (Android Studio → SDK Manager); current AndroidX releases require it |
| minSdk | 26 (Android 8.0) | Project choice, not forced by one API. X25519 comes from Bouncy Castle on every version. Below 31, TLS channel binding is unavailable (see SECURITY.md); on 26–28, Mac → phone file transfer needs the storage permission |

Point Gradle at the SDK with either `ANDROID_HOME`, or a `android/local.properties` containing `sdk.dir=…` (Android Studio writes it; it's git-ignored). No JDK on your PATH? Use Android Studio's:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

### Build, test, lint

```bash
cd android
./gradlew assembleDebug
```

```bash
./gradlew testDebugUnitTest lintDebug
```

```bash
./gradlew assembleRelease
```

Outputs:

- `android/app/build/outputs/apk/debug/app-debug.apk`: installable, signed with the local debug key.
- `android/app/build/outputs/apk/release/app-release-unsigned.apk`: release build, **unsigned**. Android won't install it until you sign it. With the signing properties below set, the build writes a signed `app-release.apk` instead.
- `android/app/build/reports/lint-results-debug.html`: lint report. Errors fail the build. The tree has 0 warnings; keep it that way (lint's version checks start warning again whenever a newer library is published).

### Install on a phone

Turn on USB debugging, connect, then:

```bash
./gradlew installDebug
```

### Signing a release APK

Signing keys never go in the repository (`*.jks` and `*.keystore` are git-ignored, and CI never signs). With your own keystore:

```bash
keytool -genkeypair -v -keystore ~/swiftgreen-release.jks -alias swiftgreen -keyalg RSA -keysize 4096 -validity 10000
```

```bash
$ANDROID_HOME/build-tools/<version>/apksigner sign --ks ~/swiftgreen-release.jks --out app-release.apk app/build/outputs/apk/release/app-release-unsigned.apk
```

Or let the build sign it: put these in `~/.gradle/gradle.properties` (outside the repository), and `assembleRelease` produces a signed `app-release.apk`. Without them the build stays unsigned, as in CI.

```properties
swiftgreen.storeFile=/absolute/path/to/swiftgreen-release.jks
swiftgreen.storePassword=…
swiftgreen.keyAlias=swiftgreen
swiftgreen.keyPassword=…
```

Keep that keystore safe. Updates must be signed with the same key, or Android refuses to install them over the old version.

## macOS

### Toolchain

| | Version | Why |
|---|---|---|
| Xcode | 16.3 or later (built and tested with 27.0) | The sources use `nonisolated` on type declarations, a Swift 6.1 feature (Xcode 16.3). The project's default-main-actor and approachable-concurrency settings only exist in Xcode 26+; an older Xcode ignores them, and the project builds without them (checked by turning both off). Only Xcode 27.0 has actually been used |
| Deployment target | macOS 15.0 | `kSecImportToMemoryOnly` and `toolbarBackgroundVisibility` are macOS 15 APIs. Builds at 14.0 fail on both (checked by lowering the target and building) |
| Architectures | arm64 + x86_64 | Universal Release build |
| Signing | Ad-hoc ("Sign to Run Locally") | No Apple Developer team is configured. The app is not notarized |
| App Sandbox | Off | The app writes to `~/Downloads`, runs a TCP listener and reads the user-chosen shared folder |

### Build and test

```bash
xcodebuild -project macos/SwiftGreen/SwiftGreen.xcodeproj -scheme SwiftGreen -configuration Release -destination 'generic/platform=macOS' -derivedDataPath macos/DerivedData build
```

```bash
xcodebuild test -project macos/SwiftGreen/SwiftGreen.xcodeproj -scheme SwiftGreen -destination 'platform=macOS' -derivedDataPath macos/DerivedData
```

The app is at `macos/DerivedData/Build/Products/Release/SwiftGreen.app` (`macos/DerivedData/` is git-ignored). Or open `macos/SwiftGreen/SwiftGreen.xcodeproj` and press ⌘R.

The test run launches the app as its test host. Under tests the app does nothing else (no listener, no mDNS) and uses its own Keychain item, a temporary TLS identity and a temporary Downloads folder, so your real pairing and files are untouched.

Smoke-test a built app (it stays up, creates its TLS identity, opens its listener):

```bash
scripts/macos-smoke.sh macos/DerivedData/Build/Products/Release/SwiftGreen.app
```

### First launch of a downloaded build

Ad-hoc signed apps from the internet are blocked by Gatekeeper. On macOS 15 and later, open it once, choose **Done**, then click **Open Anyway** in System Settings → Privacy & Security. This project has no Apple Developer ID and does not notarize; an app you build yourself isn't quarantined and opens without the prompt.

## Repository checks

```bash
scripts/check-hygiene.sh
```

It checks what `git add -A` would publish (tracked plus untracked, non-ignored files) and fails on: key material and local config; local AI/tool metadata (`.project-intelligence/`, `.claude/`, `graphify-out/`, …); anything under `website/` (kept outside this repository); editor/OS junk; build output (APKs, `build/`, `DerivedData/`, …); credential-shaped strings; developer home paths; `android.util.Log` outside `Log.kt` and Swift loggers that bypass the Release no-op `print`; a missing licence; and files that are tracked although `.gitignore` excludes them. It works by pattern matching, so a pass catches the common shapes and proves nothing more. It needs bash.
