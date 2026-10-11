//
//  ContentView.swift
//  SwiftGreen
//
//  Created by Navin Rana on 27/05/26.
//

import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import UserNotifications
import Combine
import Darwin
import ServiceManagement

// MARK: - Tab Definition
enum Tab: String, CaseIterable, Identifiable {
    case dashboard = "Overview"
    case activity = "Activity"
    case device = "Device"
    case calls = "Calls"
    case messages = "Messages"
    case media = "Media"
    /// Files both ways: browse the phone, and one Mac folder the phone can open.
    case files = "Bridge"
    case pairing = "Pairing"
    case filters = "Filters"
    case settings = "Settings"

    var id: String { self.rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "house"
        case .activity: return "clock"
        case .device: return "smartphone"
        case .calls: return "phone"
        case .messages: return "message"
        case .media: return "play.circle"
        case .files: return "folder"
        case .pairing: return "qrcode"
        case .filters: return "line.3.horizontal.decrease"
        case .settings: return "gearshape"
        }
    }

    /// ⌘1…⌘8 for the eight top-level panes, numbered in sidebar order. Displayed in
    /// the command palette; bound by the zero-opacity buttons in `ContentView.body`
    /// (there is no `Commands` block — `SwiftGreenApp` is a bare `WindowGroup`).
    var shortcutKey: Character? {
        switch self {
        case .dashboard:   return "1"
        case .activity:    return "2"
        case .device:      return "3"
        case .calls:       return "4"
        case .messages:    return "5"
        case .media:       return "6"
        case .files:       return "7"
        case .settings:    return "8"
        default:           return nil
        }
    }

    var shortcutHint: String? {
        shortcutKey.map { "⌘\($0)" }
    }
}

// MARK: - Sidebar Device Row

/// The "Device" row: a plain labelled sidebar row, with the phone's live state as a
/// trailing accessory (status dot, battery %, a bolt while charging).
/// Reads the same `serverStatus` every pane reads, so it can't disagree with them.
private struct DeviceRow: View {
    @ObservedObject var quicServer: mDNSQuicServer
    let isPaired: Bool

    private var isOnline: Bool { isPaired && quicServer.serverStatus == mDNSQuicServer.onlineStatus }

    private var name: String {
        let n = quicServer.androidDeviceInfo?.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? (quicServer.androidDeviceInfo?.model ?? "Android phone") : n
    }

    private var level: Int? {
        isOnline && quicServer.androidBatteryLevel >= 0 ? quicServer.androidBatteryLevel : nil
    }

    /// A bolt after the percentage, as the menu-bar battery shows it.
    private var isCharging: Bool { level != nil && quicServer.androidBatteryCharging }

    /// The row spelled out for VoiceOver.
    private var spokenState: String {
        guard isPaired else { return "not paired" }
        guard isOnline else { return "\(name), not connected" }
        guard let level else { return "\(name), connected" }
        return "\(name), connected, \(level) percent" + (isCharging ? ", charging" : "")
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Label(Tab.device.rawValue, systemImage: Tab.device.icon)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let level {
                HStack(spacing: 1) {
                    Text("\(level)%")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(level)))
                        .animation(reduceMotion ? nil : SG.Motion.standard, value: level)
                    if isCharging {
                        // bolt.fill, the bolt of the Device pane's battery.100.bolt.
                        Image(systemName: "bolt.fill")
                            .imageScale(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.sgBattery(level, charging: isCharging).map { AnyShapeStyle($0) }
                                 ?? AnyShapeStyle(.secondary))
            }
            // Colour is the connection state's sanctioned exception; VoiceOver and the
            // Device pane carry it in words too, for colour-blind users.
            Circle()
                .fill(isOnline ? Color.sgSuccess : Color.sgDanger)
                .frame(width: 6, height: 6)
        }
        // Never wider than the column: the label truncates before anything overflows.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .help(isPaired ? name : "Not paired")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Device, \(spokenState)")
        .accessibilityHint("Shows your phone's details")
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @ObservedObject var publisher: mDNSServicePublisher
    @ObservedObject var quicServer: mDNSQuicServer
    @ObservedObject var pairingManager: PairingManager
    @ObservedObject private var notificationHistory = NotificationHistoryManager.shared
    @ObservedObject private var callLogStore = CallLogStore.shared
    @ObservedObject private var smsStore = SmsStore.shared
    @State private var selectedTab: Tab? = .dashboard
    /// Same mark the Calls pane and Overview use, so the sidebar badge clears with them.
    @AppStorage("calls_missed_seen_ms") private var missedSeenMs = 0
    
    // Heartbeat timer to detect zombie connections
    @State private var heartbeatTimer: DispatchSourceTimer?
    @State private var lastServerStatus: String = ""
    @State private var hasNavigatedOnPairing: Bool = false
    @State private var showPalette = false
    @State private var showSearch = false
    @State private var settingsFocus: SettingsSection? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        splitViewWithEvents
            .overlay {
                if showPalette {
                    CommandPalette(
                        isPresented: $showPalette,
                        selectedTab: Binding(
                            get: { selectedTab ?? .dashboard },
                            set: { selectedTab = $0 }
                        ),
                        pairingManager: pairingManager,
                        quicServer: quicServer,
                        onOpenSearch: {
                            // Deferred: presenting the popover in the same update
                            // that tears down the palette overlay gets swallowed.
                            DispatchQueue.main.async { showSearch = true }
                        }
                    )
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                MilestoneBanner()
                    .padding(.top, SG.Space.xl)
            }
            .animation(SG.Motion.spring, value: MilestoneTracker.shared.current)
            .animation(SG.Motion.quick, value: showPalette)
            // ⌘K opens the palette, ⌘F universal search; ⌘1…⌘8 jump straight to a
            // pane. Zero-opacity buttons are the only reliable key binding inside
            // a NavigationSplitView.
            .background {
                VStack {
                    Button("") { showPalette.toggle() }
                        .keyboardShortcut("k", modifiers: .command)
                    Button("") { showSearch.toggle() }
                        .keyboardShortcut("f", modifiers: .command)
                    ForEach(Tab.allCases.filter { $0.shortcutKey != nil }) { tab in
                        Button("") { selectedTab = tab }
                            .keyboardShortcut(KeyEquivalent(tab.shortcutKey!), modifiers: .command)
                    }
                }
                .opacity(0)
            }
    }

    /// One sidebar row. Outline symbols, as macOS sidebars use them; the list tints them
    /// with the accent colour and sizes them to the row. A zero badge draws nothing.
    private func sidebarRow(_ tab: Tab, badge: Int = 0) -> some View {
        Label(tab.rawValue, systemImage: tab.icon)
            .badge(badge)
            .tag(tab)
    }

    private var splitView: some View {
        NavigationSplitView {
            // Native sidebar: system material, selection and section headers, in light
            // and dark alike. Plain tagged rows, not NavigationLinks: the detail pane
            // already switches on `selectedTab`, and a NavigationLink inside a
            // List(selection:) draws its own highlight on top of the list's, which left
            // two rows looking selected at once.
            List(selection: $selectedTab) {
                // .tag() must stay the OUTERMOST modifier. Applying .badge() after it
                // wraps the tagged view, the tag trait stops reaching the row, and List
                // silently treats the row as unselectable.

                Section {
                    sidebarRow(.dashboard, badge: notificationHistory.unreadCount)
                    sidebarRow(.activity)
                    DeviceRow(quicServer: quicServer, isPaired: pairingManager.isPaired)
                        .tag(Tab.device)
                }
                Section("Communication") {
                    sidebarRow(.calls, badge: callLogStore.unseenMissed(seenMs: missedSeenMs).count)
                    sidebarRow(.messages, badge: smsStore.threads.filter { smsStore.isUnread($0) && $0.isInbox }.count)
                }
                Section("Media & Files") {
                    sidebarRow(.media)
                    sidebarRow(.files)
                }
                Section {
                    sidebarRow(.settings)
                }
            }
            .listStyle(.sidebar)
            // macOS 26 floats the sidebar with an inset; at a 200pt minimum its rows
            // were laid out wider than the visible column and SwiftUI centred the
            // overflow, cutting the leading edge ("ommunication").
            .navigationSplitViewColumnWidth(min: 230, ideal: 240, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Tab changes cross-fade on the app's spring; none with Reduce Motion.
                .sgAnimation(selectedTab, reduceMotion: reduceMotion)
        }
        .frame(minWidth: 800, minHeight: 600)
        // Matte charcoal backdrop with its glow. The sidebar keeps its own native
        // material above this; nothing paints over it.
        .background { SGBackdrop().ignoresSafeArea() }
        .background(SGTranslucentWindow())
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search (⌘F)")
                .accessibilityLabel("Search notifications, clipboard and files")
                .popover(isPresented: $showSearch, arrowEdge: .bottom) {
                    SearchPopover()
                }
                // No toolbar gear: Settings already has its sidebar row and ⌘8.
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
            if let selectedTab {
                switch selectedTab {
                case .dashboard:
                    DashboardView(
                        publisher: publisher,
                        quicServer: quicServer,
                        onFireTestNotification: {
                            fireTestNotification()
                        }
                    )
                    .id(Tab.dashboard)
                case .activity:
                    ActivityView()
                case .device:
                    DeviceView(server: quicServer)
                case .calls:
                    CallLogView(store: callLogStore)
                case .messages:
                    MessagesView()
                case .media:
                    MediaControlView(quicServer: quicServer)
                case .files:
                    BridgeView(server: quicServer)
                case .settings, .pairing, .filters:
                    SettingsView(quicServer: quicServer,
                        pairingManager: pairingManager,
                        focus: $settingsFocus)
                }
            } else {
                Text("Select an option from the sidebar")
                    .font(.system(size: 15))
                    .foregroundColor(.sgTextSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.sgCanvas)
            }
    }

    private var splitViewWithEvents: some View {
        splitView
        .onAppear {
            if pairingManager.isPaired {
                selectedTab = .dashboard
            }

            addLog("Console initialized. SwiftGreen ready.")
            addLog("Server Status: \(quicServer.serverStatus)")
            addLog("mDNS Status: \(publisher.statusMessage)")
            lastServerStatus = quicServer.serverStatus
        }
        .onReceive(quicServer.$serverStatus.removeDuplicates()) { newStatus in
            guard newStatus != lastServerStatus else { return }
            lastServerStatus = newStatus
            addLog("Server: \(newStatus)")
            
            if newStatus == mDNSQuicServer.onlineStatus {
                startHeartbeatTimer()
            } else {
                cancelHeartbeatTimer()
            }
        }
        .onReceive(quicServer.$receivedMessage) { newMessage in
            if !newMessage.isEmpty {
                resetHeartbeatTimer()
            }
        }
        .onReceive(publisher.$statusMessage) { newStatus in
            addLog("mDNS: \(newStatus)")
        }
        .onReceive(pairingManager.$isPaired.removeDuplicates()) { isPaired in
            guard isPaired, !hasNavigatedOnPairing else { return }
            hasNavigatedOnPairing = true
            selectedTab = .dashboard
            SGSound.play(.connected)
        }
        // Sending a file: Hero when it lands, Basso when it fails. Receiving plays its
        // own sounds in FileTransferReceiver, where each outcome is recorded once.
        .onReceive(FileTransferSender.shared.$transferState.removeDuplicates()) { state in
            switch state {
            case .complete: SGSound.play(.transfer)
            case .error:    SGSound.play(.failed)
            default:        break
            }
        }
        .onReceive(FileTransferReceiver.shared.$transferHistory) { history in
            guard let latest = history.first else { return }
            if latest.state == "complete" || latest.state == "sent" {
                MilestoneTracker.shared.recordTransfer()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            // Pairing and Filters live inside Settings. Deep links (Device pane, ⌘K,
            // suggestions) still target the old tabs; land them on the right section
            // with the Settings row highlighted.
            if newTab == .pairing || newTab == .filters {
                settingsFocus = newTab == .pairing ? .pairing : .filters
                selectedTab = .settings
                return
            }
            if newTab == nil {
                DispatchQueue.main.async {
                    if selectedTab == nil { selectedTab = .dashboard }
                }
            }
            if newTab == .dashboard {
                // Deferred: markAllRead publishes into the same sidebar row that
                // is being selected right now, and mutating it inline fights the
                // selection commit.
                DispatchQueue.main.async {
                    NotificationHistoryManager.shared.markAllRead()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sgNavigate)) { note in
            if let tab = note.object as? Tab { selectedTab = tab }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if selectedTab == nil {
                selectedTab = .dashboard
            }
        }
        .onDisappear {
            cancelHeartbeatTimer()
        }
    }
    
    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 120.0)
        timer.setEventHandler { [self] in
            DispatchQueue.main.async {
                addLog("Heartbeat: 120s timeout — force-disconnecting zombie connection")
                quicServer.closeActiveConnection()
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }
    
    private func resetHeartbeatTimer() {
        guard quicServer.serverStatus == mDNSQuicServer.onlineStatus else { return }
        startHeartbeatTimer()
    }
    
    private func cancelHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
    
    // The in-app Terminal is gone; diagnostics go to the Xcode console only.
    private func addLog(_ message: String) {
        print("[SwiftGreen] \(message)")
    }
    
    private func fireTestNotification() {
        addLog("Debugger: Triggered direct test notification")
        
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    addLog("Debugger: ERROR - Notifications NOT authorized in System Settings!")
                }
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = "SwiftGreen Test 🟢"
            content.subtitle = "Notification Debugger"
            content.body = "Direct test at \(Date().formatted(date: .omitted, time: .standard)) — no tunnel involved"
            content.sound = UNNotificationSound.default
            
            let identifier = "swiftgreen-test-\(UUID().uuidString)"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2.0, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        addLog("Debugger: Failed to schedule - \(error.localizedDescription)")
                    } else {
                        addLog("Debugger: Notification scheduled successfully - id: \(identifier)")
                    }
                }
            }
        }
    }
}

// MARK: - Dashboard Tab View
//
// The Overview is the page you leave open while working on something else. Read
// top to bottom it is in order of priority: what needs you, the one thing you most
// often do (send a file), then what just happened — quiet lists, no chrome, every
// row one click or one drag from being used.
struct DashboardView: View {
    @ObservedObject var publisher: mDNSServicePublisher
    @ObservedObject var quicServer: mDNSQuicServer
    var onFireTestNotification: () -> Void
    @ObservedObject var notificationHistory = NotificationHistoryManager.shared
    @ObservedObject var clipboardHistory = ClipboardSyncManager.shared
    @ObservedObject private var sms = SmsStore.shared
    @ObservedObject private var calls = CallLogStore.shared
    @ObservedObject private var receiver = FileTransferReceiver.shared
    @ObservedObject private var sender = FileTransferSender.shared
    @AppStorage("calls_missed_seen_ms") private var missedSeenMs = 0
    @State private var copiedCode: String? = nil
    @State private var previewURL: URL?
    @State private var dropTargeted = false
    @State private var sentBounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Files sitting on the pasteboard from a ⌘C in Finder, waiting to be sent.
    @State private var copiedFiles: [URL] = []
    /// The pasteboard state they came from, so a dismissed copy stays dismissed.
    @State private var copiedChange = -1
    @State private var dismissedChange = -1
    private let pasteboardTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isOnline: Bool { quicServer.serverStatus == mDNSQuicServer.onlineStatus }

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        ZStack {
            Color.sgCanvas.ignoresSafeArea()

            // Re-evaluated every 30s so a code ages out and the greeting keeps time.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let code = freshCode
                let unread = unreadThreads
                let missed = calls.unseenMissed(seenMs: missedSeenMs)
                let attention = isOnline && (code != nil || !unread.isEmpty || !missed.isEmpty)

                VStack(alignment: .leading, spacing: SG.Space.lg) {
                    HStack(alignment: .center) {
                        // Shared header: every tab's title sits at the same size and place.
                        SGScreenHeader(title: "Overview", subtitle: subtitle(caughtUp: !attention))
                        Spacer()
                        if isOnline, quicServer.androidBatteryLevel >= 0 {
                            batteryPill.padding(.top, SG.Space.xl)   // centre on the header, which carries this inset
                        }
                    }

                    // The page fills the window: the lists take whatever height is left,
                    // and only below their floor does the page itself scroll.
                    GeometryReader { geo in
                        ScrollView {
                            VStack(alignment: .leading, spacing: SG.Space.lg) {
                                if attention {
                                    attentionStrip(code: code, unread: unread, missed: missed)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }

                                sendHero

                                HStack(alignment: .top, spacing: SG.Space.lg) {
                                    notificationsList
                                    VStack(spacing: SG.Space.lg) {
                                        clipboardList
                                        filesList
                                    }
                                }
                                .frame(maxHeight: .infinity)
                            }
                            .padding(.bottom, SG.Space.xxl)
                            // An exact height, not a minimum: inside a ScrollView a minimum
                            // lets the lazy lists grow to their full length.
                            .frame(height: max(geo.size.height, attention ? 700 : 580), alignment: .top)
                            .animation(SG.Motion.standard, value: attention)
                        }
                        .scrollIndicators(.never)
                    }
                }
                .padding(.horizontal, SG.Space.xxl)
            }
        }
        // The whole page takes a drop; the send strip is where it shows.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard isOnline, let server = mDNSQuicServer.activeServer else { return false }
            // Multi-file drop: the first starts immediately, the rest queue.
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { sender.enqueue([url], via: server) } }
                }
            }
            return true
        }
        .quickLookPreview($previewURL)
        .onAppear { readPasteboard() }
        .onReceive(pasteboardTick) { _ in readPasteboard() }
        .background {
            Button("", action: paste).keyboardShortcut("v").opacity(0)
        }
        .onReceive(NotificationHistoryManager.shared.$history) { _ in
            if NotificationHistoryManager.shared.unreadCount > 0 {
                NotificationHistoryManager.shared.markAllRead()
            }
        }
    }

    private func subtitle(caughtUp: Bool) -> String {
        guard isOnline else { return "Open SwiftGreen on Android to connect" }
        let name = quicServer.androidDeviceInfo?.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let phone = name.isEmpty ? "Your phone" : name
        return "\(greeting). \(phone) is connected" + (caughtUp ? " · You're all caught up" : "")
    }

    private var batteryPill: some View {
        let level = quicServer.androidBatteryLevel
        let charging = quicServer.androidBatteryCharging
        return Button {
            NotificationCenter.default.post(name: .sgNavigate, object: Tab.device)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: charging ? "battery.100.bolt" :
                        level > 50 ? "battery.75" : level > 20 ? "battery.25" : "battery.0")
                Text("\(level)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .sgGlassCapsule()
        }
        .buttonStyle(.plain)
        .help("Open Device")
        .accessibilityLabel("Phone battery \(level) percent\(charging ? ", charging" : ""). Open Device")
    }

    // MARK: 1 · Needs you

    /// A verification code that arrived in the last ten minutes.
    private var freshCode: (code: String, from: String, at: Int64)? {
        let cutoff = Int64(Date().addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let codes: [(String, SmsThread)] = sms.threads.compactMap { t in
            if case .code(let c) = t.kind, t.timestampMs > cutoff { return (c, t) }
            return nil
        }
        guard let (code, t) = codes.max(by: { $0.1.timestampMs < $1.1.timestampMs }) else { return nil }
        return (code, t.displayName, t.timestampMs)
    }

    /// People, not businesses: the same threads the Messages inbox shows as unread.
    private var unreadThreads: [SmsThread] {
        sms.threads.filter { $0.kind == .personal && sms.isUnread($0) }
            .sorted { $0.timestampMs > $1.timestampMs }
    }

    private func attentionStrip(code: (code: String, from: String, at: Int64)?, unread: [SmsThread],
                                missed: [CallLogRecord]) -> some View {
        HStack(alignment: .top, spacing: SG.Space.lg) {
            if let code {
                let copied = copiedCode == code.code
                AttentionCard(glyph: copied ? "checkmark" : "lock.shield",
                              label: "Verification code",
                              value: code.code, mono: true,
                              detail: copied ? "Copied to clipboard" : "\(code.from) · \(relativeTime(code.at)) · Click to copy",
                              help: "Copy \(code.code)") {
                    clipboardHistory.writeLocalOnly(code.code)
                    withAnimation(SG.Motion.quick) { copiedCode = code.code }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(SG.Motion.quick) { if copiedCode == code.code { copiedCode = nil } }
                    }
                }
            }
            if let first = unread.first {
                AttentionCard(glyph: "message",
                              label: unread.count == 1 ? "New message" : "New messages",
                              value: "\(unread.count)",
                              detail: "\(first.displayName): \(first.snippet)",
                              help: "Open \(first.displayName) in Messages") {
                    sms.composeTo = first.phoneNumber
                    NotificationCenter.default.post(name: .sgNavigate, object: Tab.messages)
                }
            }
            if let last = missed.first {
                let people = Set(missed.map { ContactsStore.matchKey($0.phoneNumber) }).count
                let name = last.contactName ?? last.phoneNumber
                let time = timeFormatter.string(from: Date(timeIntervalSince1970: Double(last.timestamp) / 1000))
                AttentionCard(glyph: "phone.arrow.down.left",
                              label: missed.count == 1 ? "Missed call" : "Missed calls",
                              value: "\(missed.count)",
                              detail: people > 1 ? "\(name) and \(people - 1) more · \(time)" : "\(name) · \(time)",
                              help: "Open missed calls") {
                    calls.openMissed = true
                    NotificationCenter.default.post(name: .sgNavigate, object: Tab.calls)
                }
            }
        }
    }

    // MARK: 2 · Send to phone

    /// The one action on the page, in one place, in whichever state it's in: moving
    /// a file, holding a file you copied in Finder, catching a drop, or waiting.
    @ViewBuilder
    private var sendHero: some View {
        Group {
            if case .sending = sender.transferState {
                transferProgress(glyph: "arrow.up", name: sender.currentFilename, progress: sender.progress,
                                 detail: sender.finishingOnPhone ? "Finishing on phone…"
                                    : sender.bytesPerSecond > 0
                                    ? "Sending to your phone · \(ByteCountFormatter.string(fromByteCount: Int64(sender.bytesPerSecond), countStyle: .file))/s"
                                      + (sender.etaSeconds.map { " · \($0)s left" } ?? "")
                                    : "Sending to your phone…",
                                 queued: sender.queue.count) {
                    if let server = mDNSQuicServer.activeServer { sender.cancelTransfer(via: server) }
                }
            } else if receiver.isReceiving {
                transferProgress(glyph: "arrow.down", name: receiver.receiveFilename, progress: receiver.receiveProgress,
                                 detail: "Arriving from your phone", queued: 0) {
                    receiver.cancelReceive()
                    mDNSQuicServer.activeServer?.sendMessage(#"{"type":"file_transfer_cancel","transfer_id":""}"#)
                }
            } else if !copiedFiles.isEmpty && !dropTargeted {
                copiedCard
            } else {
                dropTarget
            }
        }
        .animation(SG.Motion.standard, value: copiedFiles)
        .animation(SG.Motion.quick, value: dropTargeted)
        .onChange(of: sender.transferState) { _, state in
            // After the send card has swapped back to the drop target, so the arrow
            // is on screen to see the change.
            guard state == .complete else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { sentBounce += 1 }
        }
    }

    private var dropTarget: some View {
        let failed: String? = { if case .error(let m) = sender.transferState { return m }; return nil }()
        return HStack(spacing: SG.Space.lg) {
            Image(systemName: dropTargeted ? "arrow.down" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(isOnline ? .sgBackground : .sgTextSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(isOnline ? Color.white : Color.sgSurfaceHigh))
                .contentTransition(.symbolEffect(.replace))
                // One bounce each time a file lands on the phone.
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : sentBounce)
            VStack(alignment: .leading, spacing: 3) {
                Text(!isOnline ? "Connect your phone to send files"
                     : dropTargeted ? "Release to send to your phone" : "Send to your phone")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(!isOnline ? "Then drop files here, or copy one in Finder and press ⌘V"
                     : failed.map { "Last send failed: \($0)" }
                     ?? "Drop files anywhere on this page — or copy one in Finder and press ⌘V")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SG.Space.sm)
            if isOnline && !dropTargeted {
                SGPrimaryButton(title: "Choose Files", action: chooseFiles)
            }
        }
        .padding(.horizontal, SG.Space.lg)
        .frame(height: 72)
        .sgGlass(highlighted: dropTargeted)
        // A solid light ring only while a file hovers over the page; no dashes at rest.
        .overlay(RoundedRectangle(cornerRadius: SG.Radius.card, style: .continuous)
            .strokeBorder(Color.white.opacity(dropTargeted ? 0.6 : 0), lineWidth: 1.5))
    }

    /// A file copied in Finder, one click (or ⌘V) from the phone.
    private var copiedCard: some View {
        let first = copiedFiles[0]
        let bytes = copiedFiles.reduce(Int64(0)) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0)
        }
        return HStack(spacing: SG.Space.lg) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(copiedFiles.count == 1 ? first.lastPathComponent : "\(copiedFiles.count) files")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.sgBackground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Copied in Finder · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgBackground.opacity(0.6))
            }
            Spacer(minLength: SG.Space.sm)
            Button(action: sendCopied) {
                HStack(spacing: 8) {
                    Text(isOnline ? "Send to phone" : "Phone offline")
                    if isOnline { Text("⌘V").opacity(0.5) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Color.sgBackground))
            }
            .buttonStyle(.plain)
            .disabled(!isOnline)
            Button {
                withAnimation(SG.Motion.quick) { dismissedChange = copiedChange; copiedFiles = [] }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.sgBackground.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Not now")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, SG.Space.lg)
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: SG.Radius.card, style: .continuous).fill(Color.white))
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    private func transferProgress(glyph: String, name: String, progress: Double, detail: String,
                                  queued: Int, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: SG.Space.lg) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(SG.Motion.quick, value: progress)
                Image(systemName: glyph).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(queued > 0 ? "\(detail) · \(queued) more waiting" : detail)
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SG.Space.sm)
            Text("\(Int(progress * 100))%")
                .font(SG.Font.mono(13, weight: .semibold))
                .foregroundColor(.white)
                .contentTransition(.numericText())
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.sgTextSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel transfer")
        }
        .padding(.horizontal, SG.Space.lg)
        .frame(height: 72)
        .sgGlass()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let server = mDNSQuicServer.activeServer {
            sender.enqueue(panel.urls, via: server)
        }
    }

    /// Files (not folders) a Finder ⌘C left on the pasteboard. Re-read only when the
    /// pasteboard changes, so a dismissal holds until the next copy.
    private func readPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != copiedChange else { return }
        copiedChange = pb.changeCount
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            }
        copiedFiles = pb.changeCount == dismissedChange ? [] : urls
    }

    private func sendCopied() {
        guard !copiedFiles.isEmpty, let server = mDNSQuicServer.activeServer, isOnline else { return }
        sender.enqueue(copiedFiles, via: server)
        dismissedChange = copiedChange
        copiedFiles = []
    }

    /// ⌘V on this page: typing in a field (a notification reply) pastes as usual;
    /// otherwise it sends the file waiting from Finder.
    private func paste() {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } else {
            sendCopied()
        }
    }

    // MARK: 3 · What just happened

    private var notificationsList: some View {
        let accessOff = quicServer.androidNotificationAccess == false
        return VStack(alignment: .leading, spacing: SG.Space.sm) {
            listHeader("Notifications", note: accessOff ? "Access is off on your phone" : nil,
                       clear: notificationHistory.history.isEmpty ? nil : { NotificationHistoryManager.shared.clearAll() })
            if notificationHistory.history.isEmpty {
                quietEmpty("Notifications from your phone appear here")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(notificationHistory.history) { NotificationRow(record: $0) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .panel()
    }

    private var clipboardList: some View {
        let items = clipboardHistory.history.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.timestampMs > b.timestampMs
        }
        return VStack(alignment: .leading, spacing: SG.Space.sm) {
            listHeader("Clipboard", note: nil,
                       clear: items.isEmpty ? nil : { clipboardHistory.clearAll() })
            if items.isEmpty {
                quietEmpty("Copy on either device and it lands here")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { ClipRow(record: $0) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .panel()
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: SG.Space.sm) {
            listHeader("Files", note: nil,
                       clear: receiver.transferHistory.isEmpty ? nil : { receiver.clearHistory() })
            if receiver.transferHistory.isEmpty {
                quietEmpty("Files you send and receive appear here")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(receiver.transferHistory) { FileRow(record: $0, preview: $previewURL) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .panel()
    }

    // MARK: Shared pieces

    private func listHeader(_ title: String, note: String?, clear: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SG.Space.sm) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            if let note {
                Text(note)
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let clear {
                Button("Clear", action: clear)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.sgTextSecondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SG.Space.sm)
        .padding(.bottom, SG.Space.xs)
    }

    private func quietEmpty(_ text: String) -> some View {
        Text(text)
            .font(SG.Font.caption)
            .foregroundColor(.sgTextSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    /// The Overview's list shell: one surface, one radius, content pinned top-left.
    func panel() -> some View {
        self
            .padding(SG.Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sgGlass()
    }
}

/// A clipping. Quiet at rest; the pointer brings out pin and copy.
private struct ClipRow: View {
    let record: ClipboardRecord
    @State private var hovering = false
    @State private var copied = false

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        HStack(spacing: SG.Space.md) {
            Image(systemName: record.source == "mac" ? "laptopcomputer" : "iphone")
                .font(.system(size: 12))
                .foregroundColor(.sgTextSecondary)
                .frame(width: 20)
                .help(record.source == "mac" ? "Copied on Mac" : "Copied on your phone")
            Text(record.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: SG.Space.sm)
            if hovering || copied {
                action(record.pinned ? "bookmark.fill" : "bookmark", record.pinned ? "Unpin" : "Pin to the top") {
                    ClipboardSyncManager.shared.togglePin(id: record.id)
                }
                action(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy") {
                    ClipboardSyncManager.shared.writeLocalOnly(record.text)
                    withAnimation(SG.Motion.quick) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(SG.Motion.quick) { copied = false } }
                }
            } else {
                if record.pinned {
                    Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundColor(.sgTextSecondary)
                }
                Text(Self.clock.string(from: Date(timeIntervalSince1970: Double(record.timestampMs) / 1000)))
                    .font(SG.Font.mono(11))
                    .foregroundColor(.sgTextSecondary)
            }
        }
        .padding(.horizontal, SG.Space.sm)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous)
            .fill(hovering ? Color.sgSurfaceHigh : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
        .onTapGesture(count: 2) { ClipboardSyncManager.shared.writeLocalOnly(record.text); copied = true }
        .help("Double-click to copy")
        .contextMenu {
            Button("Copy") { ClipboardSyncManager.shared.writeLocalOnly(record.text) }
            Button(record.pinned ? "Unpin" : "Pin") { ClipboardSyncManager.shared.togglePin(id: record.id) }
        }
    }

    private func action(_ glyph: String, _ help: String, run: @escaping () -> Void) -> some View {
        Button {
            run()
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One transfer. Click to Quick Look, drag into any app, right-click for the rest.
private struct FileRow: View {
    let record: FileTransferReceiver.TransferRecord
    @Binding var preview: URL?
    @State private var hovering = false
    /// Bumped once when a just-landed transfer's row appears, to bounce its arrow.
    @State private var landed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()

    var body: some View {
        let url = record.path.isEmpty ? nil : URL(fileURLWithPath: record.path)
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let sent = record.state == "sent"
        let ok = sent || record.state == "complete"

        HStack(spacing: SG.Space.md) {
            Group {
                if exists, let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: ok ? "doc" : "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.sgTextSecondary)
                }
            }
            .frame(width: 20, height: 20)

            Text(record.filename)
                .font(.system(size: 13))
                .foregroundColor(ok && exists ? .white : .sgTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: sent ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.sgTextSecondary)
                .symbolEffect(.bounce, options: .nonRepeating, value: landed)
                .onAppear {
                    // Only a transfer that just landed, not the history at launch.
                    if !reduceMotion, Date().timeIntervalSince(record.date) < 5 { landed += 1 }
                }
                .help(sent ? "Sent to your phone" : "From your phone")
            Spacer(minLength: SG.Space.sm)

            if hovering, exists, let url {
                button("eye", "Quick Look") { preview = url }
                button("folder", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else {
                Text(detail(ok: ok, exists: exists))
                    .font(SG.Font.mono(11))
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, SG.Space.sm)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous)
            .fill(hovering ? Color.sgSurfaceHigh : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
        .onTapGesture { if exists { preview = url } }
        .onDrag {
            guard exists, let url, let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
            return provider
        }
        .help(exists ? "Click to preview · drag into any app" : ok ? "No longer on this Mac" : "Didn't finish")
        .accessibilityAction { if exists { preview = url } }
        .contextMenu {
            if exists, let url {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Quick Look") { preview = url }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                // A file on the pasteboard pastes as the file itself — into Mail, Slack, Finder.
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                }
            }
        }
    }

    /// Size and time when the file is usable; otherwise why it isn't.
    private func detail(ok: Bool, exists: Bool) -> String {
        guard ok else { return record.state == "cancelled" ? "Cancelled" : "Failed" }
        let when = Calendar.current.isDateInToday(record.date) ? Self.clock.string(from: record.date)
                                                                 : Self.day.string(from: record.date)
        return exists ? "\(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)) · \(when)" : "Moved · \(when)"
    }

    private func button(_ glyph: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One thing that wants you, as a single big click: the number or code large, the
/// who and when underneath.
private struct AttentionCard: View {
    let glyph: String
    let label: String
    let value: String
    var mono = false
    let detail: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: SG.Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: glyph)
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.6)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.sgTextSecondary)

                Text(value)
                    .font(mono ? .system(size: 28, weight: .bold, design: .monospaced)
                               : .system(size: 28, weight: .bold, design: .rounded))
                    .kerning(mono ? 4 : 0)
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .contentTransition(.numericText())

                Text(detail)
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
            }
            .padding(SG.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sgHoverRow()
            .contentShape(RoundedRectangle(cornerRadius: SG.Radius.card))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(label): \(value). \(detail)")
    }
}

// MARK: - Notification History Helpers

private func relativeTime(_ timestampMs: Int64) -> String {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let diff = now - timestampMs
    if diff < 60_000 { return "Just now" }
    if diff < 3_600_000 { return "\(diff / 60_000)m ago" }
    if diff < 86_400_000 { return "\(diff / 3_600_000)h ago" }
    let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM dd"
    return fmt.string(from: date)
}

private func decodeImage(_ base64: String?) -> NSImage? {
    NSImage(base64: base64)
}

// MARK: - Notification Row (with inline reply)

/// Reply is offered only when Android told us the notification has a reply action.
/// Firing a reply at a notification that has none would silently do nothing, which
/// is worse than not showing the affordance.
private struct NotificationRow: View {
    let record: NotificationHistoryManager.NotificationRecord

    @State private var replying = false
    @State private var draft = ""
    /// Reply outcome. Only `.sent` on a confirmed success from the device — a
    /// send that is still in flight, or that failed, must not look delivered.
    @State private var replyState: ReplyState = .idle

    /// Held so a failed reply can be restored into the field for a retry.
    @State private var lastAttempt = ""

    private enum ReplyState { case idle, sending, sent, failed }
    @FocusState private var replyFocused: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let img = decodeImage(record.senderPhoto) ?? decodeImage(record.appIcon) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: SG.Radius.tile))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: SG.Radius.tile)
                            .fill(Color.sgSurface)
                            .frame(width: 32, height: 32)
                        Image(systemName: "bell")
                            .font(.system(size: 13))
                            .foregroundColor(.sgTextSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(record.appName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(relativeTime(record.timestampMs))
                            .font(.system(size: 11))
                            .foregroundColor(.sgTextSecondary)
                    }
                    Text(record.title)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                    Text(record.body)
                        .font(.system(size: 12))
                        .foregroundColor(.sgTextSecondary)
                        .lineLimit(1)
                }

                if record.canReply {
                    Button {
                        replying.toggle()
                        replyFocused = replying
                    } label: {
                        Image(systemName: replyGlyph)
                            .font(.system(size: 12))
                            .foregroundColor(replyState == .sent ? .sgSuccess
                                             : replyState == .failed ? .sgDanger : .sgTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(replyHelp)
                    .accessibilityLabel(replyHelp)
                }
            }

            if replying {
                HStack(spacing: SG.Space.sm) {
                    TextField(record.replyLabel ?? "Reply", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($replyFocused)
                        .onSubmit(send)
                        .padding(8)
                        .background(Color.sgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: SG.Radius.card))

                    Button(action: send) {
                        Image(systemName: "paperplane")
                            .font(.system(size: 12))
                            .foregroundColor(.sgBackground)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(sendDisabled)
                    .opacity(sendDisabled ? 0.4 : 1)
                    .accessibilityLabel("Send reply")
                }
                .transition(.opacity)

                if replyState == .failed {
                    Text("Not delivered — the notification may no longer be active on your phone.")
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                }
            }
        }
        .padding(.horizontal, SG.Space.sm)
        .padding(.vertical, SG.Space.sm)
        // Quiet list row: no box at rest, a soft lift under the pointer.
        .background(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous)
            .fill(hovering || replying ? Color.sgSurfaceHigh : .clear))
        .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
        .animation(SG.Motion.quick, value: replying)
        .animation(SG.Motion.quick, value: replyState)
        .onReceive(NotificationCenter.default.publisher(for: .notificationActionResult),
                   perform: applyResult)
        .contextMenu {
            Button("Copy body") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.body, forType: .string)
            }
            if record.canReply {
                Button(record.replyLabel ?? "Reply") {
                    replying = true
                    replyFocused = true
                }
            }
        }
    }

    private var sendDisabled: Bool {
        draft.trimmingCharacters(in: .whitespaces).isEmpty || replyState == .sending
    }

    private var replyGlyph: String {
        switch replyState {
        case .idle:    return "arrowshape.turn.up.left"
        case .sending: return "ellipsis"
        case .sent:    return "checkmark"
        case .failed:  return "exclamationmark.triangle"
        }
    }

    private var replyHelp: String {
        switch replyState {
        case .failed:  return "Reply failed — try again"
        case .sending: return "Sending…"
        case .sent:    return "Reply sent"
        case .idle:    return record.replyLabel ?? "Reply"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let androidKey = record.androidKey else { return }
        // Keep the text until the device confirms: on failure the user still has
        // their draft and can retry without retyping it.
        lastAttempt = text
        replyState = .sending
        mDNSQuicServer.activeServer?.sendNotificationAction(
            notificationKey: androidKey,
            sbnKey: record.sbnKey,
            actionType: "reply",
            replyText: text,
            actionId: nil
        )
        // The phone always answers; if the link dies mid-way nothing will, so don't
        // leave the row on "Sending…" for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard replyState == .sending else { return }
            replyState = .failed
            draft = lastAttempt
            replying = true
        }
    }

    /// Applies the device's verdict. The failure banner itself is already raised
    /// by mDNSQuicServer; this only settles the row's own state.
    private func applyResult(_ note: Notification) {
        guard let key = note.userInfo?["notification_key"] as? String,
              key == record.androidKey,
              let success = note.userInfo?["success"] as? Bool else { return }
        if success {
            replyState = .sent
            draft = ""
            replying = false
            lastAttempt = ""
        } else {
            replyState = .failed
            draft = lastAttempt
            replying = true
        }
    }
}

// MARK: - Settings Tab View
/// Scroll anchors on the one-page Settings, so deep links (Device pane, ⌘K,
/// suggestions) that used to open the Pairing/Filters tabs land on their section.
enum SettingsSection: Hashable { case pairing, filters }

/// System Settings grammar: your phone on top, then short grouped lists. Filters and
/// Help open as their own pages so nothing long sits inline.
struct SettingsView: View {
    @ObservedObject var quicServer: mDNSQuicServer
    @ObservedObject var pairingManager: PairingManager
    @Binding var focus: SettingsSection?
    @ObservedObject private var filters = AppFilterStore.shared
    @State private var showFilters = false
    @State private var showHelp = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var sounds = SGSound.isEnabled
    @State private var ringtone = CallRinger.selected

    var body: some View {
        Group {
            if showFilters {
                subpage("Notification Filters",
                        "Choose which apps can send notifications to your Mac · \(filterSummary)",
                        back: { showFilters = false }) { AppFilterView() }
            } else if showHelp {
                subpage("Help", "Answers to common questions",
                        back: { showHelp = false }) { HelpView() }
            } else {
                mainPage
            }
        }
        // A pairing deep link while a subpage is open goes back to the main page,
        // whose onAppear then scrolls to the phone card.
        .onChange(of: focus) { _, new in
            if new == .pairing { showFilters = false; showHelp = false }
        }
    }

    private var mainPage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SG.Space.xl) {
                    SGScreenHeader(title: "Settings",
                                   subtitle: "Your phone, how SwiftGreen behaves, and help")

                    PairingQRView(pairingManager: pairingManager, quicServer: quicServer)
                        .id(SettingsSection.pairing)

                    group("General") {
                        row("power", "Open at Login", loginDetail) {
                            toggle(loginStatus == .enabled) { setLogin($0) }
                        }
                        hairline
                        row("speaker.wave.2", "Sounds", "A distinct sound for sent, received, file transfers, connecting and failures, plus keypad tones") {
                            toggle(sounds) { on in
                                SGSound.isEnabled = on; sounds = on
                            }
                        }
                        hairline
                        row("phone.arrow.down.left", "Ringtone", "Rings on your Mac until you answer or the call ends") {
                            Picker("", selection: Binding(get: { ringtone }, set: { name in
                                ringtone = name; CallRinger.selected = name; CallRinger.preview(name)
                            })) {
                                Text("None").tag(CallRinger.none)
                                Divider()
                                ForEach(CallRinger.available, id: \.self) { Text(CallRinger.displayName($0)).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }

                    group("Notifications") {
                        navRow("bell.badge", "Notification Filters", filterSummary) { showFilters = true }
                    }

                    group("Support") {
                        navRow("questionmark.circle", "Help", "Pairing, connection, messages, files and more") {
                            showHelp = true
                        }
                        hairline
                        row("info.circle", "Version", nil) {
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                                .font(SG.Font.mono(13))
                                .foregroundColor(.sgTextSecondary)
                        }
                    }
                }
                .padding(.horizontal, SG.Space.xxl)
                .padding(.bottom, SG.Space.xxl)
            }
            .onAppear { loginStatus = SMAppService.mainApp.status; scroll(proxy) }
            .onChange(of: focus) { _, _ in scroll(proxy) }
        }
        .background(Color.sgCanvas)
    }

    private var loginDetail: String {
        loginStatus == .requiresApproval
            ? "Allow SwiftGreen in System Settings → General → Login Items"
            : "Start SwiftGreen when you log in, so your phone stays connected"
    }

    private func setLogin(_ on: Bool) {
        let app = SMAppService.mainApp
        do { if on { try app.register() } else { try app.unregister() } } catch {}
        loginStatus = app.status
        if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private var filterSummary: String {
        let total = filters.apps.count
        guard total > 0 else { return "Apps appear once your phone connects" }
        let allowed = filters.apps.filter { !$0.blocked }.count
        return allowed == total ? "All \(total) apps allowed" : "\(allowed) of \(total) apps allowed"
    }

    /// A page opened from a Settings row: back row, title, then its content.
    private func subpage<Content: View>(_ title: String, _ subtitle: String,
                                        back: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SG.Space.lg) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Settings")
                        Spacer()
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.sgTextSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back to Settings")

                VStack(alignment: .leading, spacing: SG.Space.xs) {
                    Text(title)
                        .font(SG.Font.screenTitle)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.sgTextSecondary)
                }

                content()
            }
            .padding(.horizontal, SG.Space.xxl)
            .padding(.vertical, SG.Space.xl)
        }
        .background(Color.sgCanvas)
    }

    /// A titled inset group: rows share one card, split by hairlines.
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SG.Space.sm) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.sgTextSecondary)
                .padding(.leading, SG.Space.xs)
            VStack(spacing: 0) { content() }
                .sgGlass()
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.sgHairline).frame(height: 1)
            .padding(.leading, SG.Space.lg + 28 + SG.Space.md)
    }

    private func row<Trailing: View>(_ icon: String, _ title: String, _ detail: String?,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: SG.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.sgSurfaceHigh))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SG.Font.rowTitle)
                    .foregroundColor(.white)
                if let detail {
                    Text(detail)
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                }
            }
            Spacer(minLength: SG.Space.md)
            trailing()
        }
        .padding(.horizontal, SG.Space.lg)
        .padding(.vertical, SG.Space.md)
        .frame(minHeight: 56)
    }

    private func toggle(_ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { on }, set: set))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(.white)
    }

    /// A row that opens a subpage.
    private func navRow(_ icon: String, _ title: String, _ detail: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            row(icon, title, detail) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.sgTextSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sgHoverRow(base: .clear)
        .accessibilityLabel("\(title), \(detail)")
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        // Filters is a page, not a scroll target: open it directly.
        if focus == .filters {
            showFilters = true
            DispatchQueue.main.async { self.focus = nil }
            return
        }
        guard let focus else { return }
        withAnimation(SG.Motion.spring) { proxy.scrollTo(focus, anchor: .top) }
        DispatchQueue.main.async { self.focus = nil }
    }
}

// MARK: - Help (page inside Settings)
/// Apple Support grammar: one search field, topic tiles, then questions that open in
/// place. Every answer names a real control, so it can be checked against the app.
struct HelpView: View {
    private struct Topic: Identifiable {
        let id: String
        let icon: String
        let items: [(q: String, a: String)]
    }

    private static let topics: [Topic] = [
        Topic(id: "Getting Started", icon: "sparkles", items: [
            ("What does SwiftGreen do?",
             "It links your Android phone to your Mac. Notifications, texts, calls, the clipboard and files move between them over your own Wi‑Fi, with no cloud account."),
            ("How do I pair my phone?",
             "Install SwiftGreen on your phone and open it. On your Mac, open Settings and scan the code with your phone, then type the PIN your Mac shows. Your Mac and phone need to be on the same Wi‑Fi network."),
            ("Are there keyboard shortcuts?",
             "Press ⌘1 to ⌘8 to jump between sections, ⌘K to open the command palette, and ⌘F to search."),
        ]),
        Topic(id: "Connection", icon: "wifi", items: [
            ("Why does my phone show as not connected?",
             "Keep SwiftGreen open on your Mac and make sure both devices are on the same Wi‑Fi network. On your phone, open SwiftGreen Settings → Essentials and turn on Unrestricted battery, otherwise Android can stop the connection when the screen turns off."),
            ("Does my data go through the cloud?",
             "No. Your phone and Mac talk directly over an encrypted connection on your local network, and the pairing keys stay on your devices."),
            ("How does my phone reconnect by itself?",
             "While your phone isn't connected, your Mac sends a small Bluetooth signal. The phone's Bluetooth chip listens for it without waking the app, so SwiftGreen reconnects within seconds when you're back in range. Both need Bluetooth on, and the phone needs Nearby devices allowed (Android 12 and later). Without Bluetooth, it reconnects when Wi‑Fi comes back or within 15 minutes."),
            ("Do I need Bluetooth on?",
             "No. Everything works over Wi‑Fi. Bluetooth on both devices only makes the phone reconnect instantly when you come back to your Mac. You never need to pair them in Bluetooth settings."),
            ("Why is my phone still not connected?",
             "Sync on the phone stays off after you tap Turn Off on its SwiftGreen notification or Disconnect in the app, or force stop it in Android settings. Open SwiftGreen on the phone to turn it back on. Swiping it away from Recent apps doesn't stop it."),
            ("How do I unpair or switch phones?",
             "Click Unpair at the top of Settings, on either device. Both forget each other, and your Mac shows a new code to pair again."),
        ]),
        Topic(id: "Notifications", icon: "bell", items: [
            ("Notifications aren't arriving on my Mac.",
             "On your phone, open SwiftGreen Settings → Essentials and turn on Notification access. On your Mac, check Settings → Notification Filters in case that app is turned off."),
            ("Can I reply from my Mac?",
             "Yes, when the app allows it. Message notifications in Overview show a Reply button, and your phone sends the reply from that app."),
            ("How do I stop an app from sending notifications?",
             "Open Settings → Notification Filters and turn the app off. Its notifications stay on your phone."),
        ]),
        Topic(id: "Messages & Calls", icon: "message", items: [
            ("How do I send a text?",
             "Open Messages and choose a conversation, or press ⌘N to write to any contact or number. Your phone sends it with its own SIM. SwiftGreen needs the SMS permission on your phone."),
            ("Why don't I see promotional texts?",
             "Messages keeps your inbox to people and one-time codes, and puts alerts under Updates. Promotions aren't listed."),
            ("How do calls work?",
             "Click Call anywhere, or type a number on the keypad in Calls. Your phone places the call and the audio stays on your phone. When a call comes in, press Space to answer or Esc to decline."),
        ]),
        Topic(id: "Clipboard & Files", icon: "doc.on.doc", items: [
            ("How does the shared clipboard work?",
             "Copy text or an image on one device and paste it on the other. Recent copies are listed in Overview."),
            ("How do I send a file to my phone?",
             "Drop files onto Overview. You can also copy files in Finder, then press ⌘V in SwiftGreen."),
            ("Where do files from my phone go?",
             "Into the Downloads folder on your Mac."),
            ("How do I browse my phone's files?",
             "Open Bridge → Phone. To see every folder, turn on All files access in SwiftGreen Settings → Feature permissions on your phone."),
            ("How do I share a Mac folder with my phone?",
             "Open Bridge → Mac Folder and choose a folder. Its files appear on your phone under Files → From your Mac. Files inside subfolders aren't shared."),
        ]),
        Topic(id: "Your Phone", icon: "smartphone", items: [
            ("Where do I see my phone's battery and details?",
             "Click Device in the sidebar, under Overview and Activity, or press ⌘3. The row itself shows a dot while your phone is connected, its battery level, and a bolt while it charges."),
            ("How do I find my phone?",
             "Click Device in the sidebar and click Find my phone. It rings at full volume, even on silent, and stops after 30 seconds."),
        ]),
    ]

    @State private var query = ""
    @State private var topic: String?
    @State private var open: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = Self.topics.compactMap { t -> Topic? in
            if q.isEmpty { return topic == nil || topic == t.id ? t : nil }
            let hits = t.items.filter { $0.q.lowercased().contains(q) || $0.a.lowercased().contains(q) }
            return hits.isEmpty ? nil : Topic(id: t.id, icon: t.icon, items: hits)
        }

        VStack(alignment: .leading, spacing: SG.Space.xl) {
            searchField
            if q.isEmpty { tiles }
            if shown.isEmpty {
                EmptyStateText("No answers for “\(query.trimmingCharacters(in: .whitespaces))”",
                               glyph: "magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding(.top, SG.Space.xl)
            }
            ForEach(shown) { t in
                VStack(alignment: .leading, spacing: SG.Space.sm) {
                    Text(t.id)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.sgTextSecondary)
                        .padding(.leading, SG.Space.xs)
                    VStack(spacing: 0) {
                        ForEach(Array(t.items.enumerated()), id: \.element.q) { i, item in
                            if i > 0 { Rectangle().fill(Color.sgHairline).frame(height: 1).padding(.leading, SG.Space.lg) }
                            // A search opens every match, so the answer is right there.
                            question(item.q, item.a, isOpen: !q.isEmpty || open.contains(item.q))
                        }
                    }
                    .sgGlass()
                }
            }
        }
        .animation(SG.Motion.standard, value: topic)
        .animation(SG.Motion.quick, value: open)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0)
        }
    }

    private var searchField: some View {
        HStack(spacing: SG.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.sgTextSecondary)
            TextField("Search Help", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.sgTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, SG.Space.lg)
        .frame(height: 40)
        .sgGlassCapsule()
    }

    /// One tile per topic; clicking narrows the page to it, clicking again shows all.
    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SG.Space.sm), count: 3), spacing: SG.Space.sm) {
            ForEach(Self.topics) { t in
                let selected = topic == t.id
                Button {
                    topic = selected ? nil : t.id
                } label: {
                    VStack(alignment: .leading, spacing: SG.Space.md) {
                        Image(systemName: t.icon)
                            .font(.system(size: 18, weight: .medium))
                            .frame(height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.id)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(t.items.count) \(t.items.count == 1 ? "answer" : "answers")")
                                .font(SG.Font.caption)
                                .opacity(0.6)
                        }
                    }
                    .foregroundColor(selected ? .black : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SG.Space.lg)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: SG.Radius.card, style: .continuous).fill(Color.white)
                        }
                    }
                    .sgGlass()
                    .contentShape(RoundedRectangle(cornerRadius: SG.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func question(_ q: String, _ a: String, isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: SG.Space.sm) {
            Button {
                if open.contains(q) { open.remove(q) } else { open.insert(q) }
            } label: {
                HStack(spacing: SG.Space.md) {
                    Text(q)
                        .font(SG.Font.rowTitle)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: SG.Space.md)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.sgTextSecondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(q)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                Text(a)
                    .font(SG.Font.body)
                    .foregroundColor(.sgTextSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, SG.Space.lg)
        .padding(.vertical, SG.Space.md + 2)
    }
}

// MARK: - Media Control View
struct MediaControlView: View {
    @ObservedObject var quicServer: mDNSQuicServer
    @ObservedObject var store = MediaControlStore.shared
    @State private var volumeSlider: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            // Offline shows "Not connected" rather than a cached track whose
            // controls can't reach the phone.
            if store.hasActiveSession && quicServer.isTunnelActive { player } else { emptyState }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A background, never a ZStack sibling: a scaledToFill image as a sibling
        // sizes the stack beyond the window and knocks the layout off-centre
        // (worst in half-screen and split view).
        .background { backdrop }
        .background { shortcuts }
    }

    // MARK: Ambient backdrop

    /// The artwork itself, blurred across the whole pane, so every track tints the
    /// room. Full colour on purpose — the zero-colour rule governs chrome, and this
    /// is the user's own music. Crossfades on track change.
    private var backdrop: some View {
        ZStack {
            Color.sgCanvas
            if store.hasActiveSession, quicServer.isTunnelActive, let art = store.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 90)
                    .saturation(1.3)
                    .opacity(0.6)
                    .id(store.trackTitle)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: store.trackTitle)
    }

    private var header: some View {
        SGScreenHeader(title: "Now Playing",
                       subtitle: store.hasActiveSession && quicServer.isTunnelActive && !store.appName.isEmpty
                           ? "On your Android phone · \(store.appName)"
                           : "Control what's playing on your Android phone")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SG.Space.xxl)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            if quicServer.isTunnelActive {
                EmptyStateText("Play music or a video on your phone — controls appear here",
                               glyph: "play.circle")
            } else {
                EmptyStateText("Not connected", glyph: "wifi.slash")
            }
            Spacer()
        }
    }

    // MARK: Player

    private var player: some View {
        GeometryReader { geo in
            // Up next needs its own column; below this width it would squeeze the
            // controls, so it steps aside rather than break the layout.
            let showQueue = !store.queue.isEmpty && geo.size.width >= 780
            let columnWidth = geo.size.width - (showQueue ? 280 : 0)
            // Art follows the window: full 300pt when there's room, smaller in
            // half-screen / split view so everything stays on screen and centred.
            let artSize = max(140, min(300, geo.size.height * 0.42, columnWidth - 64))

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        artwork(size: artSize)
                        titleBlock
                        scrubber
                        transport
                        volume
                    }
                    .frame(maxWidth: 540)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    // minHeight = the visible height, so the block sits dead centre
                    // and only scrolls when the window is genuinely too short.
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollIndicators(.never)

                // Up next. Hidden entirely when the player exposes no queue, which
                // most streaming apps don't.
                if showQueue { upNext }
            }
        }
    }

    /// Eases down when paused and back up when playing, so state reads at a glance.
    private func artwork(size: CGFloat) -> some View {
        ZStack {
            if let img = store.albumArt {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .id(store.trackTitle)
                    .transition(.opacity)
            } else {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .light))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.075, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
        .scaleEffect(store.isPlaying ? 1 : 0.88)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72), value: store.isPlaying)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: store.trackTitle)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(store.trackTitle.isEmpty ? "Unknown track" : store.trackTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            Text([store.artist, store.album].filter { !$0.isEmpty }.joined(separator: " — "))
                .font(.system(.title3, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var scrubber: some View {
        if store.isLive {
            // No length to scrub against: say so instead of a bar stuck at zero.
            HStack(spacing: 8) {
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                Text(formatDuration(store.positionMs))
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundColor(.white.opacity(0.7))
            .frame(height: 44)
        } else {
            VStack(spacing: 6) {
                MediaScrubber(positionMs: store.positionMs,
                              durationMs: store.durationMs,
                              trackKey: store.trackTitle) { seek(to: $0) }
                    .allowsHitTesting(store.canSeek)
                    .help(store.canSeek ? "" : "This app doesn't allow seeking")
                HStack {
                    Text(formatDuration(store.positionMs))
                    Spacer()
                    Text("-" + formatDuration(max(0, store.durationMs - store.positionMs)))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var canSkip15: Bool { store.canSeek && !store.isLive }

    private var transport: some View {
        HStack(spacing: 30) {
            transportButton("gobackward.15", size: 20, label: "Back 15 seconds") {
                seek(to: max(0, store.positionMs - 15_000))
            }
            .disabled(!canSkip15).opacity(canSkip15 ? 1 : 0.3)
            transportButton("backward.fill", size: 26, label: "Previous track", hint: "⌘←") {
                send("previous")
            }
            Button { send("play_pause") } label: {
                ZStack {
                    Circle().fill(Color.white)
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.black)
                        .offset(x: store.isPlaying ? 0 : 2)   // optical centre of ▶
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(PressScaleStyle())
            .help(store.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
            transportButton("forward.fill", size: 26, label: "Next track", hint: "⌘→") {
                send("next")
            }
            transportButton("goforward.15", size: 20, label: "Forward 15 seconds") {
                seek(to: min(store.durationMs, store.positionMs + 15_000))
            }
            .disabled(!canSkip15).opacity(canSkip15 ? 1 : 0.3)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, label: String,
                                 hint: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(hint.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
            Slider(value: $volumeSlider, in: 0...100, step: 1) { editing in
                if !editing {
                    mDNSQuicServer.activeServer?.sendMediaAction(action: "volume_set",
                                                                 volume: Int(volumeSlider))
                }
            }
            .tint(.white)
            .accessibilityLabel("Phone volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
            Text("\(Int(volumeSlider))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 36, alignment: .trailing)
        }
        .onAppear { volumeSlider = Double(store.volume) }
        .onChange(of: store.volume) { _, newVal in volumeSlider = Double(newVal) }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: SG.Space.sm) {
            Text("Up Next")
                .font(SG.Font.section)
                .foregroundColor(.white)
                .padding(.horizontal, SG.Space.md)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.queue) { item in
                        Button {
                            mDNSQuicServer.activeServer?.sendMediaAction(
                                action: "play_queue_item", queueId: item.queueId)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.55))
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SG.Space.md)
                            .padding(.vertical, SG.Space.sm)
                            .contentShape(Rectangle())
                            .sgHoverRow(base: .clear, hovered: .white.opacity(0.08))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 24)
        .frame(width: 280)
        .background(.black.opacity(0.25))
    }

    /// Space / ⌘← / ⌘→ while this pane is on screen. Zero-opacity buttons, the
    /// same binding trick ContentView uses for ⌘1…⌘8.
    private var shortcuts: some View {
        VStack {
            Button("") { send("play_pause") }.keyboardShortcut(.space, modifiers: [])
            Button("") { send("previous") }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("") { send("next") }.keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .opacity(0)
        .disabled(!store.hasActiveSession)
    }

    private func send(_ action: String) {
        mDNSQuicServer.activeServer?.sendMediaAction(action: action)
    }

    private func seek(to positionMs: Int64) {
        store.positionMs = positionMs   // move the scrubber now; the next poll confirms
        mDNSQuicServer.activeServer?.sendMediaAction(action: "seek", positionMs: positionMs)
    }

    private func formatDuration(_ ms: Int64) -> String {
        let s = Int(max(0, ms) / 1000)
        // Long videos and podcasts: 1:05:03, not 65:03.
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Transport buttons sink slightly under the pointer — physical, not decorative.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - App Filter View
struct AppFilterView: View {
    @ObservedObject var store = AppFilterStore.shared

    /// Inline section content for Settings — no title or scroll view of its own.
    var body: some View {
        if store.apps.isEmpty {
            Text("Your phone's apps appear here once it connects.")
                .font(.system(size: 13))
                .foregroundColor(.sgTextSecondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sgGlass()
        } else {
                    LazyVStack(spacing: 8) {
                        ForEach(store.apps) { app in
                            HStack(spacing: 12) {
                                if let img = decodeFilterIcon(app.iconBase64) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 36, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.sgSurfaceHigh)
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "app.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.sgTextSecondary)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.appName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(app.packageName)
                                        .font(.system(size: 11))
                                        .foregroundColor(.sgTextSecondary)
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { !app.blocked },
                                    set: { enabled in
                                        store.setBlocked(packageName: app.packageName, blocked: !enabled)
                                    }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(Color.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .sgGlass()
                        }
                    }
        }
    }
}

// MARK: - Notification Filter Chip
private func decodeFilterIcon(_ base64: String?) -> NSImage? {
    guard let str = base64, !str.isEmpty,
          let data = Data(base64Encoded: str) else { return nil }
    return NSImage(data: data)
}


// Colour tokens now live in DesignSystem.swift.


// MARK: - Preview Provider
#Preview {
    ContentView(publisher: mDNSServicePublisher(), quicServer: mDNSQuicServer(), pairingManager: PairingManager())
}
