//
//  SwiftGreenApp.swift
//  SwiftGreen
//
//  Created by Navin Rana on 27/05/26.
//

import SwiftUI
import UserNotifications

/// True when this process is hosting the unit tests (Xcode and xcodebuild set this variable
/// only there). The tests run inside the app, so the app must then leave the user's pairing
/// key, identity file, network and other running copies alone.
nonisolated enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

#if !DEBUG
/// Release builds print nothing. The debug log traces every line of the tunnel —
/// clipboard text, notification and SMS bodies, the pairing PIN — and a user who
/// starts the app from a terminal would otherwise see all of it there.
nonisolated func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}   // callable from any thread, like Swift.print
#endif

// MARK: - Foreground Notification Delegate
// Must be set on UNUserNotificationCenter BEFORE requestAuthorization is called.
// Without this delegate, macOS suppresses banners when the app is in the foreground.
class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Called when a notification is about to be presented while the app is in the foreground.
    /// Return .banner + .sound to force it to show even when the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("🔔 [NotificationDelegate] willPresent fired — notification id: \(notification.request.identifier)")
        print("🔔 [NotificationDelegate] Title: \(notification.request.content.title), Body: \(notification.request.content.body)")
        print("🔔 [NotificationDelegate] Returning .banner + .sound to force foreground display")
        completionHandler([.banner, .sound, .list])
    }

    /// Called when the user taps or replies to a delivered notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        print("🔔 [NotificationDelegate] didReceive — id: \(response.notification.request.identifier), action: \(response.actionIdentifier)")

        let userInfo = response.notification.request.content.userInfo
        let server = mDNSQuicServer.activeServer

        // Step 15.3 — incoming-call Answer/Decline. Handled before the notification_key
        // guard below, since the call banner carries no notification_key.
        if userInfo["call_action_request"] as? Bool == true {
            if response.actionIdentifier != UNNotificationDefaultActionIdentifier { CallRinger.stop() }
            switch response.actionIdentifier {
            case "swiftgreen_call_answer": server?.sendCallControl(action: "answer")
            case "swiftgreen_call_decline": server?.sendCallControl(action: "decline")
            default: break
            }
            return
        }

        guard let notificationKey = userInfo["notification_key"] as? String else { return }
        let sbnKey = userInfo["sbn_key"] as? String

        if let textResponse = response as? UNTextInputNotificationResponse,
           response.actionIdentifier == "swiftgreen_reply" {
            print("🔔 [NotificationDelegate] Inline reply submitted for key: \(notificationKey)")
            server?.sendNotificationAction(
                notificationKey: notificationKey,
                sbnKey: sbnKey,
                actionType: "reply",
                replyText: textResponse.userText,
                actionId: nil
            )
        } else if response.actionIdentifier.hasPrefix("btn_") {
            let actionId = String(response.actionIdentifier.dropFirst(4))
            print("🔔 [NotificationDelegate] Button '\(actionId)' tapped for key: \(notificationKey)")
            server?.sendNotificationAction(
                notificationKey: notificationKey,
                sbnKey: sbnKey,
                actionType: "button",
                replyText: nil,
                actionId: actionId
            )
        }
    }
}

@main
struct SwiftGreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // Hold delegate strongly — if this is released, delegate becomes nil and banners stop.
    // Do NOT use a local variable inside init().
    private let notificationDelegate = AppNotificationDelegate()

    init() {
        print("🚀 [App] SwiftGreenApp init() called")
        guard !TestHost.isActive else { return }

        // STEP 1 — Set delegate FIRST, before requestAuthorization.
        // This ensures that when the system delivers the authorization prompt
        // and any subsequent notifications, the delegate is already in place.
        UNUserNotificationCenter.current().delegate = notificationDelegate
        print("✅ [App] UNUserNotificationCenter delegate set to AppNotificationDelegate")

        // STEP 2 — Request authorization
        print("🔐 [App] Requesting UNUserNotificationCenter authorization (.alert, .sound, .badge)...")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("❌ [App] Authorization request FAILED with error: \(error.localizedDescription)")
                return
            }
            if granted {
                print("✅ [App] Notification authorization GRANTED by user/system")
                // Verify current settings after grant
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    print("📋 [App] authorizationStatus: \(settings.authorizationStatus.rawValue)")
                    print("📋 [App] alertSetting: \(settings.alertSetting.rawValue)")
                    print("📋 [App] soundSetting: \(settings.soundSetting.rawValue)")
                    print("📋 [App] notificationCenterSetting: \(settings.notificationCenterSetting.rawValue)")
                }
            } else {
                print("⚠️ [App] Notification authorization DENIED by user — banners will NOT appear")
                print("⚠️ [App] Go to System Settings > Notifications > SwiftGreen and enable banners manually")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // Under the tests: no UI, so no pairing screen starts the server or advertises.
            if TestHost.isActive {
                EmptyView()
            } else {
                ContentView(publisher: appDelegate.publisher, quicServer: appDelegate.quicServer, pairingManager: appDelegate.pairingManager)
            }
        }
    }
}
