import SwiftUI

// MARK: - Unified Event
//
// ponytail: no ActivityStore. The four source stores are already ObservableObjects
// with @Published arrays, so merging them in a computed property gives correct
// live updates for free. A separate store would need Combine plumbing to stay in
// sync and could only ever drift from the originals.

struct ActivityEvent: Identifiable {
    enum Kind {
        case clipboard, notification, fileReceived, fileSent, fileFailed, call, missedCall

        /// The whole vocabulary of the timeline. State is glyph, never colour.
        var glyph: String {
            switch self {
            case .clipboard:    return "doc.on.clipboard"
            case .notification: return "bell"
            case .fileReceived: return "arrow.down.doc"
            case .fileSent:     return "arrow.up.doc"
            case .fileFailed:   return "xmark.circle"
            case .call:         return "phone"
            case .missedCall:   return "phone.down"
            }
        }

        var filter: ActivityFilter {
            switch self {
            case .clipboard:                          return .clipboard
            case .notification:                       return .notifications
            case .fileReceived, .fileSent, .fileFailed: return .files
            case .call, .missedCall:                  return .calls
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let timestampMs: Int64
    /// The whole text behind a one-line row: a clipping, a notification body.
    var full = ""
    var number: String? = nil
    var path: String? = nil
    var clipId: String? = nil
    var pinned = false
    /// base64 launcher icon of the app that posted a notification.
    var icon: String? = nil

    var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1000) }

    func matches(_ q: String) -> Bool {
        title.lowercased().contains(q) || detail.lowercased().contains(q) || full.lowercased().contains(q)
    }
}

enum ActivityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case clipboard = "Clipboard"
    case notifications = "Notifications"
    case files = "Files"
    case calls = "Calls"

    var id: String { rawValue }

    /// Chart stacking order, bottom up. The rarer, more personal events sit on
    /// the baseline where they can't be lost under a pile of notifications.
    static let stackOrder: [ActivityFilter] = [.calls, .files, .clipboard, .notifications]

    /// Monochrome: categories are told apart by brightness, never hue.
    var shade: Double {
        switch self {
        case .calls: return 1
        case .files: return 0.72
        case .clipboard: return 0.48
        case .notifications, .all: return 0.26
        }
    }

    var noun: String {
        switch self {
        case .all: return "events"
        case .clipboard: return "clippings"
        case .notifications: return "notifications"
        case .files: return "files"
        case .calls: return "calls"
        }
    }
}

// MARK: - Activity View

/// Shared event merge, used by both the Activity pane and the Dashboard's
/// recent-activity widget so the two can never disagree.
enum ActivityFeed {
    static func merge(
        clipboard: [ClipboardRecord],
        notifications: [NotificationHistoryManager.NotificationRecord],
        transfers: [FileTransferReceiver.TransferRecord],
        calls: [CallLogRecord]
    ) -> [ActivityEvent] {
        var out: [ActivityEvent] = []

        out += clipboard.map {
            ActivityEvent(id: "clip-\($0.id)", kind: .clipboard, title: $0.text,
                          detail: $0.source == "mac" ? "Copied on Mac" : "Copied on Android",
                          timestampMs: $0.timestampMs,
                          full: $0.text, clipId: $0.id, pinned: $0.pinned)
        }
        out += notifications.map {
            ActivityEvent(id: "notif-\($0.key)", kind: .notification, title: $0.appName,
                          detail: $0.title.isEmpty ? $0.body : $0.title,
                          timestampMs: $0.timestampMs,
                          full: $0.body, icon: $0.appIcon)
        }
        out += transfers.map { record in
            let kind: ActivityEvent.Kind
            let detail: String
            switch record.state {
            case "sent":
                kind = .fileSent
                detail = "Sent · \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))"
            case "complete":
                kind = .fileReceived
                detail = "Received · \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))"
            case "cancelled":
                kind = .fileFailed
                detail = "Cancelled"
            default:
                kind = .fileFailed
                detail = "Failed — transfer did not complete"
            }
            return ActivityEvent(id: "file-\(record.id)", kind: kind, title: record.filename,
                                 detail: detail,
                                 timestampMs: Int64(record.date.timeIntervalSince1970 * 1000),
                                 path: record.path.isEmpty ? nil : record.path)
        }
        out += calls.map { record in
            let type = record.callType.lowercased()
            let missed = type.contains("miss")
            var detail = missed ? "Missed call" : type == "outgoing" ? "Outgoing" : type == "incoming" ? "Incoming" : "Call"
            if !missed, record.durationSeconds > 0 {
                detail += " · " + Duration.seconds(record.durationSeconds)
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
            }
            return ActivityEvent(id: "call-\(record.id)",
                                 kind: missed ? .missedCall : .call,
                                 title: record.contactName ?? record.phoneNumber,
                                 detail: detail,
                                 timestampMs: record.timestamp,
                                 number: record.phoneNumber)
        }
        return out.sorted { $0.timestampMs > $1.timestampMs }
    }
}

/// A row in the timeline: one event, or a run of notifications from the same app
/// collapsed into a stack the way Notification Centre does it.
private struct ActivityItem: Identifiable {
    var events: [ActivityEvent]
    /// Keyed on the oldest event so the id survives new notifications joining the top.
    var id: String { "stack-\(events[events.count - 1].id)" }
}

private enum ActivityTime {
    private static func fmt(_ f: String) -> DateFormatter { let d = DateFormatter(); d.dateFormat = f; return d }
    private static let clockF = fmt("HH:mm")
    private static let weekdayF = fmt("EEEE")
    private static let weekdayShortF = fmt("EEE")
    private static let dayNumberF = fmt("d")
    private static let shortF = fmt("d MMM")
    private static let yearF = fmt("d MMM yyyy")
    private static let longF = fmt("EEEE, d MMMM")

    static func clock(_ d: Date) -> String { clockF.string(from: d) }
    static func long(_ d: Date) -> String { longF.string(from: d) }
    static func weekdayShort(_ d: Date) -> String { weekdayShortF.string(from: d) }
    static func dayNumber(_ d: Date) -> String { dayNumberF.string(from: d) }

    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day,
           days < 7 { return weekdayF.string(from: d) }
        return cal.isDate(d, equalTo: Date(), toGranularity: .year) ? shortF.string(from: d) : yearF.string(from: d)
    }

    static func hourRange(_ h: Int) -> String { String(format: "%02d:00 – %02d:00", h, (h + 1) % 24) }
}

struct ActivityView: View {
    @ObservedObject private var clipboard = ClipboardSyncManager.shared
    @ObservedObject private var notifications = NotificationHistoryManager.shared
    @ObservedObject private var files = FileTransferReceiver.shared
    @ObservedObject private var calls = CallLogStore.shared

    /// Days back from today. Relative, so the view rolls over at midnight by itself.
    @State private var dayOffset = 0
    @State private var hour: Int?
    @State private var hoveredHour: Int?
    @State private var filter: ActivityFilter = .all
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @FocusState private var searchFocused: Bool
    @Namespace private var thumbs

    private let cal = Calendar.current

    var body: some View {
        let all = ActivityFeed.merge(clipboard: clipboard.history, notifications: notifications.history,
                                     transfers: files.transferHistory, calls: calls.calls)
        let today = cal.startOfDay(for: Date())
        let day = cal.date(byAdding: .day, value: -dayOffset, to: today) ?? today
        // Sorted newest first, so the last event bounds how far back there is to go.
        let maxOffset = all.last.flatMap { cal.dateComponents([.day], from: cal.startOfDay(for: $0.date), to: today).day } ?? 0
        let perDay = Dictionary(grouping: all) { cal.startOfDay(for: $0.date) }.mapValues(\.count)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let dayEvents = all.filter { cal.isDate($0.date, inSameDayAs: day) }
        let categorised = dayEvents.filter { filter == .all || $0.kind.filter == filter }
        let shown = q.isEmpty
            ? categorised.filter { hour == nil || cal.component(.hour, from: $0.date) == hour }
            : all.filter { (filter == .all || $0.kind.filter == filter) && $0.matches(q) }

        ZStack {
            Color.sgCanvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: SG.Space.lg) {
                HStack(alignment: .center) {
                    SGScreenHeader(title: "Activity", subtitle: "Everything that happened across your devices")
                    Spacer()
                    if !all.isEmpty {
                        searchField.frame(width: 260).padding(.top, SG.Space.xl)
                    }
                }

                if all.isEmpty {
                    Spacer()
                    EmptyStateText("Nothing has happened yet", glyph: "clock.arrow.circlepath")
                    Spacer()
                } else {
                    ScrollView {
                        // Lazy: the timeline merges four unbounded histories.
                        LazyVStack(alignment: .leading, spacing: SG.Space.lg) {
                            if q.isEmpty {
                                dayCard(day: day, today: today, dayEvents: dayEvents, categorised: categorised,
                                        count: shown.count, maxOffset: maxOffset, perDay: perDay)
                                SuggestionsStrip(suggestions: SuggestionEngine.suggestions(
                                    clipboard: clipboard.history,
                                    notifications: notifications.history,
                                    calls: calls.calls,
                                    transfers: files.transferHistory,
                                    onNavigate: { NotificationCenter.default.post(name: .sgNavigate, object: $0) }
                                ))
                            } else {
                                Text(shown.count == 1 ? "1 result" : "\(shown.count) results")
                                    .font(SG.Font.caption)
                                    .foregroundColor(.sgTextSecondary)
                            }

                            if shown.isEmpty {
                                EmptyStateText(emptyMessage(q: q, day: day), glyph: q.isEmpty ? "moon.zzz" : "magnifyingglass")
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, SG.Space.xxl)
                            } else {
                                ForEach(groups(shown, byHour: q.isEmpty), id: \.label) { group in
                                    timelineGroup(group)
                                }
                            }
                        }
                        .padding(.bottom, SG.Space.lg)
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(.horizontal, SG.Space.xxl)
            .padding(.bottom, SG.Space.xxl)
        }
        // Every visit opens on today, everything shown — never on a view left behind.
        .onAppear {
            dayOffset = 0; hour = nil; filter = .all
        }
        // Zero-opacity buttons: the only reliable key binding inside the split view.
        .background {
            VStack {
                Button("") { searchFocused = true }.keyboardShortcut("f")
                Button("") { if dayOffset < maxOffset { go(dayOffset + 1) } }.keyboardShortcut("[")
                Button("") { if dayOffset > 0 { go(dayOffset - 1) } }.keyboardShortcut("]")
                Button("") { clearOne() }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: SG.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.sgTextSecondary)
            TextField("Search all activity", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.sgTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘F").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .sgGlass(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(searchFocused ? 0.25 : 0)))
    }

    // MARK: Day card

    private func dayCard(day: Date, today: Date, dayEvents: [ActivityEvent], categorised: [ActivityEvent],
                         count: Int, maxOffset: Int, perDay: [Date: Int]) -> some View {
        VStack(alignment: .leading, spacing: SG.Space.lg) {
            weekStrip(today: today, maxOffset: maxOffset, perDay: perDay)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActivityTime.day(day))
                        .font(SG.Font.section)
                        .foregroundColor(.white)
                    Text(ActivityTime.long(day))
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(count)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                    Text(noun(count))
                        .font(SG.Font.body)
                        .foregroundColor(.sgTextSecondary)
                }
            }

            DayChart(events: categorised, isToday: dayOffset == 0, hour: $hour, hovered: $hoveredHour)

            HStack(spacing: SG.Space.md) {
                filterControl(dayEvents)
                Spacer(minLength: 0)
                insight(categorised)
            }
        }
        .sgCard()
        .animation(SG.Motion.standard, value: count)
        .animation(SG.Motion.quick, value: hour)
    }

    /// Monday-to-Sunday week holding the selected day; each day carries a bar for how
    /// busy it was. Days after today show but stay disabled. Chevrons step a week.
    private func weekStrip(today: Date, maxOffset: Int, perDay: [Date: Int]) -> some View {
        let day = cal.date(byAdding: .day, value: -dayOffset, to: today) ?? today
        let monday = dayOffset + (cal.component(.weekday, from: day) + 5) % 7   // offset of that week's Monday
        let offsets = (0..<7).map { monday - $0 }   // Mon → Sun, left → right
        let dates = offsets.map { cal.date(byAdding: .day, value: -$0, to: today) ?? today }
        let peak = max(dates.map { perDay[$0] ?? 0 }.max() ?? 0, 1)

        return HStack(spacing: SG.Space.xs) {
            stepButton("chevron.left", label: "Earlier week", enabled: maxOffset > monday) {
                go(min(dayOffset + 7, maxOffset))
            }
            ForEach(Array(zip(offsets, dates)), id: \.0) { offset, date in
                dayChip(offset: offset, date: date, count: perDay[date] ?? 0, peak: peak,
                        enabled: offset >= 0 && offset <= maxOffset)
            }
            stepButton("chevron.right", label: "Later week", enabled: monday - 6 > 0) {
                go(max(dayOffset - 7, 0))
            }
        }
    }

    private func dayChip(offset: Int, date: Date, count: Int, peak: Int, enabled: Bool) -> some View {
        let selected = offset == dayOffset
        return Button { go(offset) } label: {
            VStack(spacing: 5) {
                Text(offset == 0 ? "Today" : ActivityTime.weekdayShort(date))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(selected ? .black.opacity(0.55) : .sgTextSecondary)
                Text(ActivityTime.dayNumber(date))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(selected ? .black : .white)
                // How busy the day was, relative to the busiest day in view.
                Capsule()
                    .fill(selected ? Color.black.opacity(count > 0 ? 0.5 : 0.12)
                                   : Color.white.opacity(count > 0 ? 0.55 : 0.1))
                    .frame(width: 18, height: count > 0 ? max(3, 12 * CGFloat(count) / CGFloat(peak)) : 2)
                    .frame(height: 12, alignment: .bottom)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SG.Space.sm)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                        .matchedGeometryEffect(id: "day", in: thumbs)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help("\(ActivityTime.long(date)) · \(count) \(count == 1 ? "event" : "events")")
        .accessibilityLabel("\(ActivityTime.long(date)), \(count) events")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepButton(_ glyph: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(enabled ? 1 : 0.25))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.sgSurfaceHigh))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    /// All · Clipboard · Notifications · Files · Calls — one track, one sliding thumb,
    /// the same control as the Calls tab. Each swatch is that category's bar shade.
    private func filterControl(_ dayEvents: [ActivityEvent]) -> some View {
        HStack(spacing: 0) {
            ForEach(ActivityFilter.allCases) { f in
                let active = filter == f
                let n = f == .all ? dayEvents.count : dayEvents.filter { $0.kind.filter == f }.count
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { filter = f; hour = nil }
                } label: {
                    HStack(spacing: 6) {
                        if f != .all {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(active ? Color.black.opacity(max(f.shade, 0.35)) : Color.white.opacity(f.shade))
                                .frame(width: 8, height: 8)
                        }
                        Text(f.rawValue)
                        Text("\(n)")
                            .font(SG.Font.mono(10, weight: .medium))
                            .opacity(0.6)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? .black : .white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if active {
                            Capsule().fill(Color.white)
                                .matchedGeometryEffect(id: "filter", in: thumbs)
                                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(f.rawValue), \(n)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .sgGlassCapsule()
        .fixedSize()
    }

    /// One slot, most specific first: the bar under the pointer, then the hour you
    /// picked, then the day's busiest hour.
    @ViewBuilder
    private func insight(_ categorised: [ActivityEvent]) -> some View {
        let perHour = Dictionary(grouping: categorised) { cal.component(.hour, from: $0.date) }.mapValues(\.count)
        if let h = hoveredHour, let n = perHour[h] {
            Text("\(ActivityTime.hourRange(h)) · \(n) \(noun(n))")
                .font(SG.Font.mono(11, weight: .medium))
                .foregroundColor(.white)
        } else if let hour {
            Button { withAnimation(SG.Motion.quick) { self.hour = nil } } label: {
                HStack(spacing: 6) {
                    Text(ActivityTime.hourRange(hour)).font(SG.Font.mono(11, weight: .medium))
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.sgBackground)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .help("Show the whole day")
            .accessibilityLabel("Clear hour \(ActivityTime.hourRange(hour))")
            .transition(.scale.combined(with: .opacity))
        } else if !categorised.isEmpty {
            let top = perHour.values.max() ?? 0
            // Only a clear winner is "busiest"; a tie would name one hour arbitrarily.
            if categorised.count >= 3, perHour.filter({ $0.value == top }).count == 1,
               let busiest = perHour.first(where: { $0.value == top }) {
                Text("Busiest \(ActivityTime.hourRange(busiest.key))")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
            } else {
                Text("Click a bar to see that hour")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
            }
        }
    }

    private func noun(_ n: Int) -> String { n == 1 ? String(filter.noun.dropLast()) : filter.noun }

    // MARK: Timeline

    private func groups(_ events: [ActivityEvent], byHour: Bool) -> [(label: String, items: [ActivityItem])] {
        var out: [(label: String, items: [ActivityItem])] = []
        for e in events {
            let label = byHour ? String(format: "%02d:00", cal.component(.hour, from: e.date)) : ActivityTime.day(e.date)
            if out.last?.label != label { out.append((label, [])) }
            let i = out.count - 1
            if e.kind == .notification, let last = out[i].items.last?.events.first,
               last.kind == .notification, last.title == e.title {
                out[i].items[out[i].items.count - 1].events.append(e)
            } else {
                out[i].items.append(ActivityItem(events: [e]))
            }
        }
        return out
    }

    @ViewBuilder
    private func timelineGroup(_ group: (label: String, items: [ActivityItem])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, SG.Space.lg)
                .padding(.bottom, 2)

            ForEach(group.items) { item in
                if item.events.count > 1 {
                    let open = expanded.contains(item.id)
                    StackRow(events: item.events, open: open) { toggle(item.id) }
                    if open {
                        ForEach(item.events) { event in
                            ActivityRow(event: event, expanded: expanded.contains(event.id)) { toggle(event.id) }
                        }
                    }
                } else if let event = item.events.first {
                    ActivityRow(event: event, expanded: expanded.contains(event.id)) { toggle(event.id) }
                }
            }
        }
    }

    private func emptyMessage(q: String, day: Date) -> String {
        if !q.isEmpty { return "No results for “\(query.trimmingCharacters(in: .whitespaces))”" }
        if let hour { return "Nothing between \(ActivityTime.hourRange(hour).replacingOccurrences(of: " – ", with: " and "))" }
        let when = ActivityTime.day(day)
        let on = ["Today", "Yesterday"].contains(when) ? when.lowercased() : "on \(when)"
        return filter == .all ? "Nothing happened \(on)" : "No \(filter.noun) \(on)"
    }

    // MARK: Actions

    private func toggle(_ id: String) {
        withAnimation(SG.Motion.quick) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func go(_ offset: Int) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            dayOffset = offset
            hour = nil
        }
    }

    /// Esc peels back one layer at a time: search, then hour, then category.
    private func clearOne() {
        withAnimation(SG.Motion.quick) {
            if !query.isEmpty || searchFocused { query = ""; searchFocused = false }
            else if hour != nil { hour = nil }
            else if filter != .all { filter = .all }
        }
    }
}

// MARK: - Day Chart

/// 24 hourly bars, stacked by category. Tap a bar to narrow the timeline to it.
private struct DayChart: View {
    let events: [ActivityEvent]
    let isToday: Bool
    @Binding var hour: Int?
    @Binding var hovered: Int?

    private let height: CGFloat = 96

    /// [hour][stackOrder index] → count.
    private var counts: [[Int]] {
        var c = Array(repeating: Array(repeating: 0, count: ActivityFilter.stackOrder.count), count: 24)
        let cal = Calendar.current
        for e in events {
            if let i = ActivityFilter.stackOrder.firstIndex(of: e.kind.filter) {
                c[cal.component(.hour, from: e.date)][i] += 1
            }
        }
        return c
    }

    var body: some View {
        let counts = counts
        let peak = max(counts.map { $0.reduce(0, +) }.max() ?? 0, 1)
        let now = Calendar.current.component(.hour, from: Date())

        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    bar(h, segments: counts[h], peak: peak, future: isToday && h > now)
                }
            }
            .frame(height: height)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.sgHairline).frame(height: 1).offset(y: 1)
            }

            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                        .overlay(alignment: .leading) {
                            if h % 6 == 0 {
                                Text(String(format: "%02d", h))
                                    .font(SG.Font.mono(10))
                                    .foregroundColor(.sgTextSecondary)
                                    .fixedSize()
                            }
                        }
                }
            }
        }
        .animation(SG.Motion.standard, value: counts)
    }

    private func bar(_ h: Int, segments: [Int], peak: Int, future: Bool) -> some View {
        let total = segments.reduce(0, +)
        let dim = hour != nil && hour != h

        return Button {
            withAnimation(SG.Motion.quick) { hour = hour == h ? nil : h }
        } label: {
            VStack(spacing: 1) {
                Spacer(minLength: 0)
                if total == 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(future ? 0.04 : 0.1))
                        .frame(height: 2)
                } else {
                    ForEach((0..<ActivityFilter.stackOrder.count).reversed(), id: \.self) { i in
                        if segments[i] > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(ActivityFilter.stackOrder[i].shade))
                                .frame(height: max(2, height * CGFloat(segments[i]) / CGFloat(peak) - 1))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(dim ? 0.3 : 1)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(hovered == h && total > 0 ? 0.06 : 0))
                .padding(.horizontal, -2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(total == 0)
        .onHover { inside in
            if inside { hovered = total > 0 ? h : nil } else if hovered == h { hovered = nil }
        }
        .accessibilityLabel("\(ActivityTime.hourRange(h)), \(total) events")
        .accessibilityAddTraits(hour == h ? .isSelected : [])
    }
}

// MARK: - Rows

private struct RowAction: Identifiable {
    let title: String
    let glyph: String
    var help: String? = nil
    /// Copy-style actions confirm in place; the rest take you somewhere.
    var confirms = false
    /// The white circle, like the call button on the Calls tab.
    var prominent = false
    /// Right-click only; keeps the hover row to the actions people reach for.
    var menuOnly = false
    let run: () -> Void
    var id: String { title }
}

extension ActivityEvent {
    /// Only what can really be done from here. A file that's gone from disk gets
    /// no Open; a failed send can only be retried if the file is still on this Mac.
    fileprivate var actions: [RowAction] {
        let copy = { (text: String) in ClipboardSyncManager.shared.writeLocalOnly(text) }
        let onDisk = path.map { FileManager.default.fileExists(atPath: $0) } ?? false

        switch kind {
        case .clipboard:
            var out = [RowAction(title: "Copy", glyph: "doc.on.doc", help: "Copy to the clipboard", confirms: true) { copy(full) }]
            if let clipId {
                out.append(RowAction(title: pinned ? "Unpin" : "Pin", glyph: pinned ? "bookmark.slash" : "bookmark",
                                     help: pinned ? "Unpin from clipboard history" : "Keep at the top of clipboard history") {
                    ClipboardSyncManager.shared.togglePin(id: clipId)
                })
            }
            return out
        case .notification:
            let text = [detail, full].filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return [RowAction(title: "Copy", glyph: "doc.on.doc", help: "Copy the notification text", confirms: true) {
                copy(text.joined(separator: "\n"))
            }]
        case .fileReceived, .fileSent:
            guard onDisk, let path else { return [] }
            let url = URL(fileURLWithPath: path)
            var out = [RowAction(title: "Show in Finder", glyph: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }]
            if kind == .fileReceived {
                out.insert(RowAction(title: "Open", glyph: "arrow.up.forward.square") { NSWorkspace.shared.open(url) }, at: 0)
            }
            return out
        case .fileFailed:
            guard onDisk, let path, mDNSQuicServer.activeServer != nil else { return [] }
            return [RowAction(title: "Retry", glyph: "arrow.clockwise", help: "Send it to your phone again") {
                if let server = mDNSQuicServer.activeServer {
                    FileTransferSender.shared.sendFile(at: URL(fileURLWithPath: path), via: server)
                }
            }]
        case .call, .missedCall:
            guard let number else { return [] }
            return [
                RowAction(title: "Message", glyph: "message.fill", help: "Text \(title) from Messages") {
                    PhoneActions.message(number)
                },
                RowAction(title: "WhatsApp", glyph: "arrow.up.forward.app.fill", help: "Open \(title)'s chat in WhatsApp") {
                    PhoneActions.whatsApp(number)
                },
                // Fills the keypad rather than dialling: a call is never one stray click away.
                RowAction(title: "Call", glyph: "phone.fill", help: "Call \(title)", prominent: true) {
                    CallLogStore.shared.dialTo = number
                    NotificationCenter.default.post(name: .sgNavigate, object: Tab.calls)
                },
                RowAction(title: "Copy Number", glyph: "doc.on.doc", menuOnly: true) { copy(number) },
            ]
        }
    }

    /// The expanded body, when it adds something the collapsed row doesn't show.
    fileprivate var extraText: String? {
        guard !full.isEmpty, full != detail else { return nil }
        if full == title, full.count < 60, !full.contains("\n") { return nil }
        return full
    }
}

private enum IconCache {
    static let cache = NSCache<NSString, NSImage>()

    static func image(_ id: String, _ base64: String?) -> NSImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        guard let base64, let data = Data(base64Encoded: base64), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: id as NSString)
        return img
    }
}

private struct EventIcon: View {
    let event: ActivityEvent
    private let size: CGFloat = 32

    var body: some View {
        switch event.kind {
        case .call, .missedCall:
            Monogram(name: event.title, size: size)
                .overlay(alignment: .bottomTrailing) {
                    if event.kind == .missedCall {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.sgBackground)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.white))
                            .overlay(Circle().stroke(Color.sgSurface, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                }
        case .notification:
            if let img = IconCache.image(event.id, event.icon) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                glyph
            }
        default:
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: event.kind.glyph)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(event.kind == .fileFailed ? .sgDanger : .white.opacity(0.8))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.sgSurfaceHigh))
    }
}

/// Quiet at rest; the pointer brings out what can be done, labelled — the same
/// hover-to-act pattern as a Calls row. Clicking unfolds text that was cut short.
private struct ActivityRow: View {
    let event: ActivityEvent
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @State private var confirmed: String?

    var body: some View {
        let actions = event.actions
        let extra = event.extraText
        let titleIsFull = extra == event.title

        HStack(alignment: .top, spacing: SG.Space.md) {
            summary(extra: extra, titleIsFull: titleIsFull)

            HStack(spacing: 6) {
                if hovering || expanded {
                    ForEach(actions.filter { !$0.menuOnly }) { action in
                        button(action)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Text(ActivityTime.clock(event.date))
                    .font(SG.Font.mono(11))
                    .foregroundColor(.sgTextSecondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .frame(height: 32)
        }
        .padding(.horizontal, SG.Space.lg)
        .padding(.vertical, SG.Space.md)
        .sgHoverRow()
        .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
        .contextMenu {
            ForEach(actions) { action in Button(action.title, action: action.run) }
        }
    }

    /// Icon and text. A Button only when there is more to unfold — a row that does
    /// nothing on click shouldn't pretend to be clickable.
    @ViewBuilder
    private func summary(extra: String?, titleIsFull: Bool) -> some View {
        let content = HStack(alignment: .top, spacing: SG.Space.md) {
            EventIcon(event: event)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // A clipping's title *is* its text: unfold it in place rather
                    // than repeating it underneath.
                    Text(event.title)
                        .font(SG.Font.rowTitle)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(expanded && titleIsFull ? 12 : 1)
                        .fixedSize(horizontal: false, vertical: expanded && titleIsFull)
                    if event.pinned {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.sgTextSecondary)
                            .accessibilityLabel("Pinned")
                    }
                }
                HStack(spacing: 4) {
                    Text(event.detail)
                        .lineLimit(1)
                    if extra != nil {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .font(SG.Font.caption)
                .foregroundColor(.sgTextSecondary)

                if expanded, !titleIsFull, let extra {
                    Text(extra)
                        .font(SG.Font.body)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SG.Space.xs)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())

        if extra != nil {
            Button(action: toggle) { content }
                .buttonStyle(.plain)
                .help(expanded ? "Show less" : "Show all")
                .accessibilityLabel("\(event.title), \(event.detail)")
                .accessibilityHint(expanded ? "Collapses" : "Shows the full text")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func button(_ action: RowAction) -> some View {
        let done = confirmed == action.id
        Button {
            action.run()
            guard action.confirms else { return }
            withAnimation(SG.Motion.quick) { confirmed = action.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(SG.Motion.quick) { if confirmed == action.id { confirmed = nil } }
            }
        } label: {
            if action.prominent {
                // The one prominent row action is Call: green, as everywhere a call starts.
                Image(systemName: action.glyph)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.sgSuccess))
            } else {
                Label(done ? "Copied" : action.title, systemImage: done ? "checkmark" : action.glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(action.help ?? action.title)
        .accessibilityLabel(action.help ?? action.title)
    }
}

/// A run of notifications from one app, drawn as a deck: the next card peeks out
/// underneath until it's opened.
private struct StackRow: View {
    let events: [ActivityEvent]
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let first = events[0]

        Button(action: toggle) {
            HStack(alignment: .top, spacing: SG.Space.md) {
                EventIcon(event: first)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: SG.Space.sm) {
                        Text(first.title)
                            .font(SG.Font.rowTitle)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("\(events.count)")
                            .font(SG.Font.mono(10, weight: .semibold))
                            .foregroundColor(.sgBackground)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().fill(Color.white.opacity(0.85)))
                    }
                    HStack(spacing: 4) {
                        Text(open ? "\(events.count) notifications" : first.detail)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                }
                Spacer(minLength: SG.Space.sm)
                Text(ActivityTime.clock(first.date))
                    .font(SG.Font.mono(11))
                    .foregroundColor(.sgTextSecondary)
                    .frame(height: 32)
            }
            .padding(.horizontal, SG.Space.lg)
            .padding(.vertical, SG.Space.md)
            .sgHoverRow()
            .background(alignment: .bottom) {
                if !open {
                    RoundedRectangle(cornerRadius: SG.Radius.card)
                        .fill(Color.sgSurface.opacity(0.55))
                        .frame(height: 24)
                        .padding(.horizontal, SG.Space.md)
                        .offset(y: 6)
                }
            }
            .padding(.bottom, open ? 0 : 6)
            .contentShape(RoundedRectangle(cornerRadius: SG.Radius.card))
        }
        .buttonStyle(.plain)
        .help(open ? "Collapse" : "Show all \(events.count)")
        .accessibilityLabel("\(first.title), \(events.count) notifications")
    }
}
