import SwiftUI
import AppKit
import UserNotifications
import Combine

// MARK: - Store

/// Mac-side memory of the phone: a day of battery/latency readings for the trend
/// lines, the low/full battery alerts, and Find My Phone state. Fed by telemetry
/// (roughly once a minute) from mDNSQuicServer.
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    struct Sample: Codable {
        let t: Date
        let battery: Int
        let latency: Int?
    }

    @Published private(set) var samples: [Sample] = []
    /// Last time the phone reported in — what "Last seen" shows while offline.
    @Published private(set) var lastSeen: Date?
    /// Find My Phone is sounding. Cleared by the phone's own report, or after 30s.
    @Published var ringing = false

    static let lowAlertKey = "device_alert_low"
    static let fullAlertKey = "device_alert_full"
    private let samplesKey = "device_samples"
    private var notifiedLow = false
    private var notifiedFull = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: samplesKey),
           let decoded = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = decoded
            lastSeen = decoded.last?.t
        }
        UserDefaults.standard.register(defaults: [Self.lowAlertKey: true, Self.fullAlertKey: true])
    }

    func record(battery: Int, charging: Bool, latency: Int?) {
        let now = Date()
        lastSeen = now
        samples.append(Sample(t: now, battery: battery, latency: latency))
        samples.removeAll { now.timeIntervalSince($0.t) > 86_400 }
        if let data = try? JSONEncoder().encode(samples) { UserDefaults.standard.set(data, forKey: samplesKey) }
        checkAlerts(battery: battery, charging: charging)
    }

    /// Each alert fires once per crossing: low re-arms above 25% or once charging,
    /// full re-arms below 95%. No nagging every minute.
    private func checkAlerts(battery: Int, charging: Bool) {
        let d = UserDefaults.standard
        if battery > 25 || charging { notifiedLow = false }
        if battery < 95 { notifiedFull = false }
        if d.bool(forKey: Self.lowAlertKey), !charging, battery <= 20, !notifiedLow {
            notifiedLow = true
            notify("Phone battery low", "\(battery)% left — time to plug it in.")
        }
        if d.bool(forKey: Self.fullAlertKey), charging, battery >= 100, !notifiedFull {
            notifiedFull = true
            notify("Phone fully charged", "You can unplug it.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "device-\(title)", content: content, trigger: nil))
    }

    /// "Full in 35 min" / "About 6 hr left", from the last hour's slope. Needs 15+
    /// minutes of readings and some movement; otherwise it stays quiet rather than guess.
    func estimate(battery: Int, charging: Bool) -> (text: String, at: Date)? {
        let now = Date()
        let recent = samples.filter { now.timeIntervalSince($0.t) <= 3600 }
        guard let first = recent.first, let last = recent.last else { return nil }
        let minutes = last.t.timeIntervalSince(first.t) / 60
        let delta = Double(last.battery - first.battery)
        guard minutes >= 15, delta != 0 else { return nil }
        let rate = delta / minutes                       // % per minute
        let remaining: Double
        if charging, rate > 0, battery < 100 { remaining = Double(100 - battery) / rate }
        else if !charging, rate < 0 { remaining = Double(battery) / -rate }
        else { return nil }
        let m = Int(remaining.rounded())
        let span = m < 60 ? "\(m) min" : m < 600 ? "\(m / 60) hr \(m % 60) min" : "\(m / 60) hr"
        return (charging ? "Full in \(span)" : "About \(span) left", now.addingTimeInterval(remaining * 60))
    }

    func ring(_ on: Bool) {
        ringing = on
        mDNSQuicServer.activeServer?.sendMessage("{\"type\":\"find_phone\",\"action\":\"\(on ? "start" : "stop")\"}\n")
        // The phone stops itself after 30s and says so; this covers a lost reply.
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 32) { [weak self] in self?.ringing = false }
        }
    }
}

// MARK: - View

/// One glance tells you everything about the phone: who it is, whether it's here,
/// how much battery, how good the link. Then two things you can do with it.
struct DeviceView: View {
    @ObservedObject var server: mDNSQuicServer
    @ObservedObject private var simStore = SimStore.shared
    @ObservedObject private var store = DeviceStore.shared
    @ObservedObject private var media = MediaControlStore.shared
    @AppStorage(DeviceStore.lowAlertKey) private var lowAlert = true
    @AppStorage(DeviceStore.fullAlertKey) private var fullAlert = true
    @State private var copied: String?

    /// `serverStatus` is `@Published`; `isTunnelActive` is computed over private
    /// state and never re-rendered a view when the tunnel dropped.
    private var isOnline: Bool { server.serverStatus == mDNSQuicServer.onlineStatus }

    private var phase: ConnectionPhase {
        if isOnline { return .connected }
        return server.isRunning ? .searching : .connecting
    }

    private var battery: Int? { server.androidBatteryLevel >= 0 ? server.androidBatteryLevel : nil }

    var body: some View {
        ZStack {
            Color.sgCanvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: SG.Space.lg) {
                SGScreenHeader(title: "Device", subtitle: "Your phone, at a glance")

                ScrollView {
                    VStack(spacing: SG.Space.lg) {
                        hero
                        if !isOnline {
                            HStack {
                                Text("Open SwiftGreen on your phone to connect.")
                                    .font(SG.Font.body)
                                    .foregroundColor(.sgTextSecondary)
                                Spacer()
                                SGSecondaryButton(title: "Open Pairing") {
                                    NotificationCenter.default.post(name: .sgNavigate, object: Tab.pairing)
                                }
                            }
                        }
                        if isOnline { tiles }
                        HStack(alignment: .top, spacing: SG.Space.lg) {
                            details
                            alerts
                        }
                    }
                    .padding(.bottom, SG.Space.xxl)
                }
            }
            .padding(.horizontal, SG.Space.xxl)
        }
    }

    // MARK: Hero

    private var estimate: (text: String, at: Date)? {
        battery.flatMap { store.estimate(battery: $0, charging: server.androidBatteryCharging) }
    }

    private var hero: some View {
        HStack(spacing: SG.Space.xxl) {
            LivePhone(online: isOnline, battery: battery, charging: server.androidBatteryCharging,
                      ringing: store.ringing, art: media.hasActiveSession ? media.albumArt : nil,
                      track: media.hasActiveSession ? media.trackTitle : nil,
                      artist: media.artist)

            VStack(alignment: .leading, spacing: 6) {
                Text(server.androidDeviceInfo?.name ?? "Your phone")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(subtitleLine)
                    .font(SG.Font.body)
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)

                statusPill.padding(.top, SG.Space.sm)

                Group {
                    if isOnline, let since = server.connectedSince {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text("Connected \(since.formatted(.relative(presentation: .named)))")
                        }
                    } else if let seen = store.lastSeen {
                        Text("Last seen \(seen.formatted(.relative(presentation: .named)))")
                    } else {
                        Text(phase.subtitle)
                    }
                }
                .font(SG.Font.caption)
                .foregroundColor(.sgTextSecondary)

                findButton.padding(.top, SG.Space.lg)
            }

            Spacer(minLength: SG.Space.md)

            if isOnline, let battery {
                VStack(spacing: SG.Space.sm) {
                    SGRing(value: Double(battery) / 100, label: "\(battery)%",
                           caption: server.androidBatteryCharging ? "CHARGING" : "BATTERY", size: 112,
                           tint: Color.sgBattery(battery, charging: server.androidBatteryCharging) ?? .white)
                    if let e = estimate {
                        Text(e.text)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                        Text("\(server.androidBatteryCharging ? "Charged by" : "Until") \(e.at.formatted(date: .omitted, time: .shortened))")
                            .font(SG.Font.caption)
                            .foregroundColor(.sgTextSecondary)
                    }
                }
            }
        }
        .padding(SG.Space.xl)
        .sgGlass()
    }

    /// The one action that belongs here: make the phone tell you where it is.
    private var findButton: some View {
        Button { store.ring(!store.ringing) } label: {
            Label(store.ringing ? "Stop ringing" : "Find my phone",
                  systemImage: store.ringing ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(store.ringing ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(Capsule().fill(store.ringing ? Color.white : Color.sgSurfaceHigh))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!isOnline)
        .opacity(isOnline ? 1 : 0.4)
        .help(store.ringing ? "Press the phone's power button to silence it"
                            : "Rings at full volume, even on silent · stops after 30s")
        .animation(SG.Motion.standard, value: store.ringing)
    }

    private var subtitleLine: String {
        let info = server.androidDeviceInfo
        return [info?.model, info?.osVersion.map { "Android \($0)" }].compactMap { $0 }.joined(separator: " · ")
            .ifEmpty("Android")
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOnline ? Color.sgSuccess : Color.sgDanger)
                .frame(width: 7, height: 7)
            Text(isOnline ? "Connected" : phase.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .sgGlassCapsule()
    }

    // MARK: Live tiles

    private var tiles: some View {
        let hasStorage = (server.androidDeviceInfo?.storageTotalBytes ?? 0) > 0
        // Equal columns that always fill the row — no orphaned gap on the right.
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SG.Space.md, alignment: .top),
                                        count: hasStorage ? 3 : 2), spacing: SG.Space.md) {
            Tile(label: "Battery",
                 value: battery.map { "\($0)" } ?? "—", unit: "%",
                 caption: batteryCaption) {
                // A level bar, like Storage. A trend line of a battery that sat at 100%
                // all day drew a flat line over the baseline and read as two lines; the
                // caption already carries the trend ("−3% this hour", "Full in 35 min").
                SGMeter(value: Double(battery ?? 0) / 100,
                        tint: battery.flatMap { Color.sgBattery($0, charging: server.androidBatteryCharging) } ?? .white)
                    .frame(height: 28, alignment: .bottom)
            }
            Tile(label: "Connection",
                 value: server.androidLatencyMs.map { "\($0)" } ?? "—", unit: "ms",
                 caption: latencyBand) {
                SGSparkline(samples: store.samples.compactMap { $0.latency.map(Double.init) }).frame(height: 28)
            }
            if let total = server.androidDeviceInfo?.storageTotalBytes, total > 0 {
                let free = server.androidDeviceInfo?.storageFreeBytes ?? 0
                Tile(label: "Storage",
                     value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file), unit: "free",
                     caption: "of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))") {
                    SGMeter(value: Double(total - free) / Double(total)).frame(height: 28, alignment: .bottom)
                }
            }
        }
    }

    private var batteryCaption: String {
        if server.androidBatteryCharging, battery == 100 { return "Fully charged" }
        if let e = estimate { return e.text }
        guard let battery, let first = store.samples.first(where: { Date().timeIntervalSince($0.t) < 3600 }) else {
            return server.androidBatteryCharging ? "Charging" : "On battery"
        }
        // The last hour's change says more than "on battery".
        let delta = battery - first.battery
        let trend = delta == 0 ? "steady" : "\(delta > 0 ? "+" : "")\(delta)% this hour"
        return (server.androidBatteryCharging ? "Charging · " : "") + trend
    }

    private var latencyBand: String {
        guard let ms = server.androidLatencyMs else { return "Measuring…" }
        return ms < 100 ? "Excellent" : ms <= 300 ? "Good" : "Slow"
    }

    // MARK: Details & alerts

    private var details: some View {
        var rows: [(String, String?)] = [
            ("Model", server.androidDeviceInfo?.model),
            ("Android", server.androidDeviceInfo?.osVersion),
            ("SwiftGreen", server.androidDeviceInfo?.appVersion),
        ]
        // The label the user gave each SIM beats the raw network string.
        for (i, sim) in simStore.sims.enumerated() {
            let value = sim.displayName.isEmpty ? sim.carrierName : sim.displayName
            rows.append((simStore.sims.count == 1 ? "SIM" : "SIM \(i + 1)", value.isEmpty ? nil : value))
        }
        rows.append(("IP address", server.phoneIP))

        return Card(title: "About") {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider().overlay(Color.sgHairline) }
                HStack {
                    Text(row.0).foregroundColor(.sgTextSecondary)
                    Spacer()
                    Text(row.1 ?? "—")
                        .foregroundColor(row.1 == nil ? .sgTextSecondary : .white)
                        .textSelection(.enabled)
                    if let v = row.1, row.0 == "IP address" {
                        Button { copy(v) } label: {
                            Image(systemName: copied == v ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(.sgTextSecondary)
                                .frame(width: 16)
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                        .accessibilityLabel("Copy \(row.0)")
                    }
                }
                .font(.system(size: 12))
                .padding(.vertical, 9)
            }
        }
    }

    private var alerts: some View {
        Card(title: "Alerts") {
            alertRow("Battery low", "Notify at 20%", isOn: $lowAlert)
            Divider().overlay(Color.sgHairline)
            alertRow("Fully charged", "Notify at 100%", isOn: $fullAlert)
        }
        .frame(maxWidth: 320)
    }

    private func alertRow(_ title: String, _ caption: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                Text(caption).font(SG.Font.caption).foregroundColor(.sgTextSecondary)
            }
            Spacer()
            // Pinned to the trailing edge so every switch lines up.
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.white)
        }
        .padding(.vertical, 8)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == value { copied = nil } }
    }
}

// MARK: - Pieces

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(.sgTextSecondary)
                .padding(.bottom, 4)
            content
        }
        .padding(SG.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sgGlass()
    }
}

/// Big number, small unit, a caption and a trend underneath.
private struct Tile<Chart: View>: View {
    let label: String
    let value: String
    let unit: String
    let caption: String
    @ViewBuilder let chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(.sgTextSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(value == "—" ? .white.opacity(0.25) : .white)
                    .contentTransition(.numericText())
                if value != "—" {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.sgTextSecondary)
                }
            }
            Text(caption)
                .font(SG.Font.caption)
                .foregroundColor(.sgTextSecondary)
                .lineLimit(1)
            chart.padding(.top, 6)
        }
        .padding(SG.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sgGlass()
        .accessibilityElement(children: .combine)
    }
}

/// The phone itself, alive: a lock screen with the time, what's playing as the
/// wallpaper, battery up top and a status island. Dims when the phone is away,
/// and shakes with ripples while Find My Phone is ringing.
private struct LivePhone: View {
    let online: Bool
    let battery: Int?
    let charging: Bool
    let ringing: Bool
    let art: NSImage?
    let track: String?
    let artist: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 150
    private let height: CGFloat = 300

    var body: some View {
        // Shake and ripples are computed from the clock while ringing — not
        // repeatForever animations, which SwiftUI keeps running after the state flips
        // back (the phone went on shaking after Stop). No ringing, no timeline: still.
        TimelineView(.animation(paused: !ringing || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let live = ringing && !reduceMotion
            phone(angle: live ? sin(t * 38) * 2.5 : 0, rippleTime: live ? t : nil)
        }
        .frame(width: width + 20, height: height + 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(online ? "Phone connected\(battery.map { ", battery \($0) percent" } ?? "")" : "Phone not connected")
    }

    private func phone(angle: Double, rippleTime: Double?) -> some View {
        ZStack {
            // Find My Phone: rings spreading out from the device, 0.5s apart.
            if let t = rippleTime {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 1.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .stroke(Color.white.opacity(0.35 * (1 - p)), lineWidth: 1.5)
                        .frame(width: width, height: height)
                        .scaleEffect(1 + 0.35 * p)
                }
            }

            screen
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 35, style: .continuous).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 35, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .rotationEffect(.degrees(angle))
        }
    }

    private var screen: some View {
        VStack(spacing: 0) {
                // Status island + battery.
                HStack {
                    Spacer()
                    Capsule().fill(Color.black)
                        .frame(width: ringing ? 84 : 52, height: 16)
                        .overlay {
                            if ringing {
                                Image(systemName: "bell.fill").font(.system(size: 8)).foregroundColor(.white)
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: ringing)
                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    if let battery {
                        HStack(spacing: 2) {
                            if charging { Image(systemName: "bolt.fill").font(.system(size: 6)) }
                            Text("\(battery)").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.trailing, 12)
                    }
                }
                .padding(.top, 9)

                TimelineView(.everyMinute) { ctx in
                    VStack(spacing: 2) {
                        Text(ctx.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.system(size: 9, weight: .medium))
                        // Lock-screen style: no AM/PM, never wraps.
                        Text(ctx.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundColor(.white)
                }
                .padding(.top, 22)

                Spacer()

                if let track, !track.isEmpty {
                    HStack(spacing: 6) {
                        if let art {
                            Image(nsImage: art).resizable().scaledToFill()
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track).font(.system(size: 8, weight: .semibold)).lineLimit(1)
                            Text(artist).font(.system(size: 7)).opacity(0.7).lineLimit(1)
                        }
                        .foregroundColor(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 10)
                }

                HStack(spacing: 4) {
                    Circle().fill(online ? Color.sgSuccess : Color.sgDanger).frame(width: 5, height: 5)
                    Text(online ? "Linked to Mac" : "Not connected")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.vertical, 12)

                Capsule().fill(Color.white.opacity(0.6)).frame(width: 44, height: 3).padding(.bottom, 7)
        }
        .frame(width: width - 10, height: height - 10)
        // Wallpaper as a background, never a sibling: a fill-scaled image beside the
        // content sizes the stack to the image and warps the phone.
        .background {
            if let art {
                Image(nsImage: art).resizable().scaledToFill()
                    .blur(radius: 18).saturation(1.2)
                    .overlay(Color.black.opacity(0.35))
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            }
        }
        // Away: the screen sleeps.
        .overlay(Color.black.opacity(online ? 0 : 0.55))
        .animation(SG.Motion.standard, value: online)
    }
}
