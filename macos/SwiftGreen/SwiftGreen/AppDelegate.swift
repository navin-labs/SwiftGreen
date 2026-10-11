import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let quicServer = mDNSQuicServer()
    let publisher = mDNSServicePublisher()
    let pairingManager = PairingManager()
    @AppStorage("swiftgreen_service_type") private var serviceType: String = "_swiftgreen._tcp"
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var mainWindow: NSWindow?
    private var sigtermSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One appearance, the smoky dark one, whatever System Settings says: set before
        // the first window exists so nothing ever draws light. Covers the menu-bar
        // popover, alerts and sheets too.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting the unit tests: only prepare the test-only TLS identity, off the main thread.
        // Nothing else runs, so the tests never quit a running SwiftGreen, open the port or advertise.
        if TestHost.isActive {
            DispatchQueue.global(qos: .userInitiated).async { _ = mDNSQuicServer.tlsIdentity() }
            return
        }
        // One daemon per Mac. Two copies each advertise the same mDNS service and run
        // their own TLS server, so the phone can pair with one and connect to the
        // other (key mismatch → never connects). Newest wins, so an Xcode ⌘R always
        // becomes the live instance; terminate() lets the old one deregister cleanly.
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other != NSRunningApplication.current {
            other.terminate()
        }

        mDNSQuicServer.activeServer = quicServer

        quicServer.onReady = { [weak self] port in
            guard let self else { return }
            let serviceTypeWithDot = self.serviceType.hasSuffix(".") ? self.serviceType : "\(self.serviceType)."
            self.publisher.startAdvertising(serviceType: serviceTypeWithDot, port: Int32(port))
        }
        quicServer.onStop = { [weak self] in
            self?.publisher.stopAdvertising()
        }
        quicServer.pairingManager = pairingManager
        pairingManager.quicServer = quicServer

        // The TLS identity can take an openssl run (first launch) and a PKCS#12 import, so
        // prepare it off the main thread; the listener and the pairing QR then read the cache.
        // Also while an unpair proof is pending: a phone that was away when this Mac
        // unpaired can only learn it by connecting (PROTOCOL.md §3.4).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = mDNSQuicServer.tlsIdentity()
            DispatchQueue.main.async {
                guard let self, self.pairingManager.isPaired || PairingManager.unpairTombstone != nil else { return }
                self.quicServer.startServer()
            }
        }

        // A plain SIGTERM (`kill`, a logout, Activity Monitor's Quit) ends an AppKit app
        // without applicationWillTerminate, so the phone was never told and the mDNS
        // record stayed up. Route it through a normal quit.
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { NSApp.terminate(nil) }
        sigterm.resume()
        sigtermSource = sigterm
        ProximityBeacon.shared.start(server: quicServer)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            img?.isTemplate = true
            button.image = img
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 320, height: 150)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: MiniPlayerView(server: quicServer))
        popover = pop

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        // Grab the main WindowGroup window so we can intercept its close (hide-not-destroy for
        // accessory mode) and reopen it later from the status item menu.
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow = NSApp.windows.first
            self?.mainWindow?.delegate = self
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Deregister now. stopServer() only reaches stopAdvertising() through the
        // listener's .cancelled handler, which is dispatched async to main and may
        // never run before the process exits — leaving the stale record the phone
        // then waits out (PROTOCOL.md §2).
        publisher.stopAdvertising()
        mDNSQuicServer.activeServer?.sayGoodbye(reason: "quit")
        mDNSQuicServer.activeServer?.stopServer()
        // stopServer's close is asynchronous and the process exits as soon as this returns;
        // a moment lets the goodbye and the TCP close actually leave the Mac.
        Thread.sleep(forTimeInterval: 0.25)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - NSWindowDelegate (accessory-mode close interception)

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        sender.orderOut(nil)
        return false
    }

    @objc private func macWillSleep() {
        print("💤 [App] Mac going to sleep — tearing down server")
        mDNSQuicServer.activeServer?.sayGoodbye(reason: "going_to_sleep")
        mDNSQuicServer.activeServer?.stopServer()
    }

    @objc private func macDidWake() {
        print("☀️ [App] Mac woke — restarting server")
        mDNSQuicServer.activeServer?.startServer()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            // A transient popover from an app that isn't active closes the moment
            // another app is frontmost — the "popover sometimes fails to open" bug.
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Status item click routing

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open SwiftGreen", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
