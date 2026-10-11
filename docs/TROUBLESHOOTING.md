# Troubleshooting

## The phone can't find the Mac

1. Both on the **same network**? Not a guest network: guest Wi-Fi usually isolates clients from each other.
2. The Mac app is **running**. While it is unpaired, **Settings** shows "Server broadcasting on your network" under the pairing code.
3. Some routers drop mDNS (Bonjour) between Wi-Fi devices. Pairing still works, because the QR code carries the Mac's address. If the Mac's address changed since pairing, the phone also probes its local /24 subnet. On a larger subnet, or after the Mac moved networks, unpair and pair again.
4. A VPN on either device can route local traffic away. Turn it off to test.
5. macOS firewall (System Settings → Network → Firewall): allow incoming connections for SwiftGreen.

## Connected, but nothing syncs

- **Notifications:** on the phone, Settings → Notifications → Device & app notifications → SwiftGreen must have access. In SwiftGreen's filter list, check the app isn't switched off. On the Mac, System Settings → Notifications → SwiftGreen must allow alerts.
- **SMS and calls:** the phone permissions for SMS, phone and call log must be granted. SwiftGreen asks when you open each feature.
- **Files from the Mac:** on Android 8–9, allow SwiftGreen's storage permission. Android 10+ needs no permission for this.

## It keeps disconnecting

- **Battery optimisation** is the usual cause. In SwiftGreen, open the battery screen and follow it. On Xiaomi, Oppo, Vivo and Samsung also allow autostart / "unrestricted" background use. [dontkillmyapp.com](https://dontkillmyapp.com) has per-vendor steps.
- A dead link is noticed within 100 s at most. A clean Mac quit or sleep is noticed at once.
- If the phone shows **"Your Mac isn't paired with this phone"**, the Mac lost its pairing (e.g. it was reset). Unpair on the phone and pair again.

## macOS says the app can't be opened

The Mac build is ad-hoc signed and not notarized. On macOS 15 and later right-click → Open no longer works. Open **SwiftGreen.app** once, choose **Done**, then go to System Settings → Privacy & Security and click **Open Anyway**.

## macOS asks to let SwiftGreen use its Keychain

After installing a new version, macOS asks whether SwiftGreen may use the "SwiftGreen" item in your Keychain: the pairing key, saved by the earlier version. The app is ad-hoc signed, so the Keychain treats each build as a different app. Choose **Always Allow**, which stops the prompt until the next update. Plain **Allow** doesn't let SwiftGreen connect (seen on the reference Mac). **Deny** leaves the Mac unable to check the phone, and it won't connect until you allow it or pair again.

## The phone won't allow SMS, Notification access or Answer calls from Mac

Android treats these as restricted settings for an app installed from a downloaded APK; **Allow** is greyed out, or Android says **App was denied access**. On the reference phone (Android 15) SMS, Notification access and Display over other apps (which **Answer calls from Mac** turns on) were blocked; the phone and call-log permissions were not.

1. Tap one of the blocked permissions once, so Android shows **App was denied access**. Close it.
2. Close App info completely, then open it again: Settings → Apps → SwiftGreen. A screen that was already open doesn't show the new menu item.
3. Tap ⋮ (top right) → **Allow restricted settings**, and confirm with your PIN or fingerprint.
4. Grant the permissions again.

## A file transfer failed

- **Checksum mismatch** means the data was corrupted or cut off in transit. Nothing was saved. Try again.
- **Mac → phone** on Android 8–9 needs the storage permission (above); without it the phone refuses the file and says so.
- An existing file is never overwritten: new copies get `_1`, `_2`, … up to `_99`, and after that the transfer fails.

## Pairing says "This isn't the Mac whose code you scanned"

The Mac that answered presented a different TLS certificate from the one in the QR code. Usually the phone reached another device at the Mac's old address, or there is something in the middle of your network. Check both are on the same Wi-Fi and scan a fresh code. If it keeps happening on a network you trust, open an issue.

## The phone asks you to pair again by itself

If the phone can't open its stored pairing key (for example after a backup was restored onto a new phone), it deletes the key and shows a message on the pairing screen. Unpair on the Mac and pair again.

## Collecting logs for a bug report

Release builds log almost nothing: no message text on either platform. For a useful log, build the debug app (`./gradlew installDebug`). Debug logs can contain phone numbers, contact names and file names, so read them and redact before posting.

```bash
adb logcat -d | grep -i -E "swiftgreen|MdnsSslClient|FileTransfer"
```

On the Mac, release builds don't log. Run the app from Xcode (⌘R) to see the debug log in Xcode's console.
