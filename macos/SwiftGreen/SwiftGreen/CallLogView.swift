import SwiftUI
import AppKit

/// Display-only grouping. Nothing here reaches the dialler, the wire, `matchKey` or
/// UserDefaults — the raw string stays the identity, this only decides what the eye
/// sees. A number the rules below don't confidently cover comes back untouched.
///
/// ponytail: two country codes, no library. Real E.164 formatting is a megabyte of
/// per-country metadata; add a case here if a third country actually shows up.
private func formatNumber(_ raw: String) -> String {
    guard raw.hasPrefix("+") else { return raw }
    let d = Array(raw.filter(\.isNumber))
    if d.count == 11, d[0] == "1" {
        return "+1 \(String(d[1...3])) \(String(d[4...6])) \(String(d[7...10]))"
    }
    if d.count == 12, d[0] == "9", d[1] == "1" {
        return "+91 \(String(d[2...6])) \(String(d[7...11]))"
    }
    return raw
}

/// History and contacts on the left, a keypad on the right that turns into the
/// in-call screen while a call is live.
struct CallLogView: View {
    @ObservedObject var store: CallLogStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var simStore = SimStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @State private var dialNumber = ""
    @State private var query = ""
    /// request_id of the dial awaiting a result, so a result can be matched to the dial
    /// that caused it rather than to whichever dial was most recent.
    @State private var pendingDialId: String?
    @State private var callStatus: String? = nil
    @State private var selectedSubscriptionId: Int?
    /// ponytail: deliberately not persisted. Resets to Recent when the tab is left,
    /// which is the right default to come back to.
    @State private var section: Section = .recent
    /// When the current call went off-hook, for the in-call timer. Mac-side: the
    /// phone doesn't send a start time, and off-hook is the closest signal we get.
    @State private var callStartedAt: Date?
    /// Keypad hidden gives the list the whole width; remembered across launches.
    @AppStorage("calls_keypad_shown") private var showKeypad = true
    /// The number field keeps focus so typed digits and Backspace always land in it.
    @FocusState private var dialFocused: Bool
    @FocusState private var searchFocused: Bool
    @Namespace private var segment
    /// Search shows the top few contacts so call matches aren't buried; this expands.
    @State private var showAllPeople = false

    enum Section: String, CaseIterable {
        case favorites = "Favorites", recent = "Recent", missed = "Missed", contacts = "Contacts"
    }

    /// Newest missed call the user has looked at, remembered across launches — the
    /// same "seen" idea as Messages. The badge counts only what's newer.
    @AppStorage("calls_missed_seen_ms") private var missedSeenMs = 0
    /// What was unseen when the Missed tab opened, so those rows stay bold for this
    /// visit instead of flattening the instant you look.
    @State private var boldAfterMs: Int?

    // MARK: Derived

    private var dialContactName: String? { contacts.name(for: dialNumber) }

    /// Phone-dialer style: after a few digits, offer the contact whose number contains
    /// them, so "98765" becomes one click to the full number.
    private var dialSuggestion: (name: String, number: String)? {
        let digits = dialNumber.filter(\.isNumber)
        guard digits.count >= 3, dialContactName == nil else { return nil }
        for c in contacts.contacts {
            if let n = c.phoneNumbers.first(where: { $0.filter(\.isNumber).contains(digits) }) { return (c.displayName, n) }
        }
        return nil
    }

    private var liveCallTitle: String {
        if store.hangupPending { return "Ending call…" }
        switch store.liveCallState {
        case "ringing": return store.liveCallApp.map { "\($0) call" } ?? "Incoming call"
        // PHONE_STATE cannot tell us the callee picked up, so an outgoing call stays
        // "Calling" for its whole duration rather than claiming a connection we
        // cannot actually observe.
        case "dialing": return "Calling…"
        default:        return store.liveCallApp.map { "On \($0) call" } ?? "On call"
        }
    }

    /// Read straight from FavoritesStore rather than filtered out of the call log, so a
    /// contact starred in Contacts shows here before it has ever been rung. Sorted by
    /// label because a Set has no order and the strip would reshuffle on every redraw.
    private var favoriteNumbers: [String] {
        favorites.numbers.sorted {
            favoriteLabel($0).localizedCaseInsensitiveCompare(favoriteLabel($1)) == .orderedAscending
        }
    }

    /// Address book first, then whatever name the call log cached, then the number.
    private func favoriteLabel(_ number: String) -> String {
        if let name = contacts.name(for: number) { return name }
        let id = ContactsStore.matchKey(number)
        let cached = store.calls.first { ContactsStore.matchKey($0.phoneNumber) == id }?.contactName
        if let cached, !cached.isEmpty { return cached }
        return formatNumber(number)
    }

    /// Consecutive-only, in list order: someone else calling in between starts a new
    /// group, so the list still reads strictly newest-first. Matched on
    /// `ContactsStore.matchKey` so "+15555550123" folds with "+1 555-555-0123".
    ///
    /// Two guards, both load-bearing: an empty matchKey never groups (WhatsApp records
    /// carry no number and would merge unrelated callers), and source must match, or a
    /// WhatsApp call absorbed into a cellular run would hide its badge.
    private var callGroups: [CallGroup] {
        var groups: [CallGroup] = []
        let q = query.lowercased()
        for record in store.calls {
            // Searching spans every call, whichever tab is showing.
            if section == .missed, query.isEmpty, record.callType.lowercased() != "missed" { continue }
            if !q.isEmpty {
                let name = (record.contactName ?? contacts.name(for: record.phoneNumber) ?? "").lowercased()
                guard name.contains(q) || record.phoneNumber.contains(q) else { continue }
            }
            let key = ContactsStore.matchKey(record.phoneNumber)
            if !key.isEmpty, let last = groups.last,
               last.record.source == record.source,
               ContactsStore.matchKey(last.record.phoneNumber) == key {
                groups[groups.count - 1] = CallGroup(record: last.record, count: last.count + 1)
            } else {
                groups.append(CallGroup(record: record, count: 1))
            }
        }
        return groups
    }

    private var newestMissedMs: Int {
        Int(store.calls.first { $0.callType.lowercased() == "missed" }?.timestamp ?? 0)
    }

    /// Before anything has been marked seen, only the last day counts — otherwise the
    /// first launch greets you with every missed call in history.
    private var seenCutoff: Int {
        missedSeenMs > 0 ? missedSeenMs : Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000)
    }

    /// Missed calls not yet seen — the badge on the Missed tab.
    private var recentMissed: Int {
        store.unseenMissed(seenMs: missedSeenMs).count
    }

    private func markMissedSeen() {
        if boldAfterMs == nil { boldAfterMs = seenCutoff }
        missedSeenMs = max(missedSeenMs, newestMissedMs)
    }

    private func isUnseen(_ r: CallLogRecord) -> Bool {
        r.callType.lowercased() == "missed" && Int(r.timestamp) > (boldAfterMs ?? seenCutoff)
    }

    private func dayBuckets(_ groups: [CallGroup]) -> [(title: String, groups: [CallGroup])] {
        let cal = Calendar.current
        var out: [(title: String, groups: [CallGroup])] = []
        for g in groups {
            let d = Date(timeIntervalSince1970: TimeInterval(g.record.timestamp) / 1000)
            let title = cal.isDateInToday(d) ? "Today"
                : cal.isDateInYesterday(d) ? "Yesterday"
                : (cal.dateComponents([.day], from: d, to: Date()).day ?? 99) < 7 ? "This Week" : "Earlier"
            if out.last?.title == title { out[out.count - 1].groups.append(g) } else { out.append((title, [g])) }
        }
        return out
    }

    private func letterBuckets(_ list: [MacContact]) -> [(letter: String, contacts: [MacContact])] {
        let sorted = list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        var out: [(letter: String, contacts: [MacContact])] = []
        for c in sorted {
            let first = c.displayName.first.map { String($0).uppercased() } ?? "#"
            let letter = first.first?.isLetter == true ? first : "#"
            if out.last?.letter == letter { out[out.count - 1].contacts.append(c) } else { out.append((letter, [c])) }
        }
        // Numbers and symbols go last, as in Contacts.
        return out.filter { $0.letter != "#" } + out.filter { $0.letter == "#" }
    }

    private var contactMatches: [MacContact] {
        query.isEmpty ? contacts.contacts : contacts.search(query)
    }

    /// "Never synced" and "synced, genuinely empty" both leave `contacts` empty but
    /// mean opposite things about whether the user needs to go and fix something.
    private var contactsEmptyMessage: String {
        if !contacts.contacts.isEmpty { return "No contacts match “\(query)”" }
        return contacts.hasSyncedOnce ? "Your phone's address book is empty" : "Contacts appear once your phone connects"
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.sgCanvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: SG.Space.lg) {
                SGScreenHeader(title: "Calls", subtitle: "Call from your Mac through your Android phone")

                HStack(alignment: .top, spacing: SG.Space.lg) {
                    listPane
                    // Sized to its content, not the window: a compact card beside the
                    // list rather than a panel that eats the right side.
                    if store.liveCallState != nil || showKeypad {
                        Group {
                            if store.liveCallState != nil { inCallPane } else { keypadPane }
                        }
                        .frame(width: 280)
                        .padding(.vertical, SG.Space.xl)
                        .sgGlass()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(SG.Motion.standard, value: store.liveCallState)
                .animation(SG.Motion.standard, value: showKeypad)
            }
            .padding(.horizontal, SG.Space.xxl)
            .padding(.bottom, SG.Space.xxl)
        }
        // Same as Messages: keep the pick on a SIM the phone actually has.
        .onReceive(simStore.$sims) { sims in
            selectedSubscriptionId = simStore.selection(keeping: selectedSubscriptionId, for: .dial, in: sims)
        }
        .onAppear {
            if selectedSubscriptionId == nil {
                selectedSubscriptionId = simStore.lastUsedSubscriptionId(for: .dial) ?? simStore.sims.first?.subscriptionId
            }
            // Refresh every visit so a contact added on the phone shows without a
            // reconnect. Only claim "loading" when a live tunnel can answer — a request
            // into a dead one is dropped silently.
            if mDNSQuicServer.activeServer?.isTunnelActive == true { contacts.markLoading() }
            mDNSQuicServer.activeServer?.requestContacts()
            // Opening this tab is when a stale call banner would be seen; re-check it.
            mDNSQuicServer.activeServer?.requestCallState()
            takeDialRequest()
        }
        .onChange(of: store.dialTo) { _, _ in takeDialRequest() }
        .onChange(of: store.openMissed) { _, _ in takeDialRequest() }
        // `callStatus` only ever holds a rejected dial; any movement in call state means
        // the phone has moved on, so the message is stale.
        .onChange(of: query) { _, _ in showAllPeople = false }
        .onChange(of: section) { _, s in
            if s == .missed { markMissedSeen() } else { boldAfterMs = nil }
        }
        // A missed call landing while you're on Missed is seen as it arrives.
        .onChange(of: newestMissedMs) { _, _ in if section == .missed { markMissedSeen() } }
        .onChange(of: store.liveCallState) { _, state in
            callStatus = nil
            if state == "offhook" { if callStartedAt == nil { callStartedAt = Date() } }
            else if state == nil { callStartedAt = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .callActionResult)) { notif in
            // Settle only on the result for the dial still outstanding here, so two rapid
            // dials can't render the first result against the second number.
            guard let id = notif.userInfo?["request_id"] as? String, id == pendingDialId else { return }
            let success = notif.userInfo?["success"] as? Bool ?? false
            let error = notif.userInfo?["error"] as? String
            // Only a rejected dial leaves a mark; on success the call screen says it.
            callStatus = success ? nil : dialErrorMessage(error)
            pendingDialId = nil
        }
    }

    // MARK: List

    private var listPane: some View {
        VStack(alignment: .leading, spacing: SG.Space.md) {

            HStack(spacing: SG.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.sgTextSecondary)
                TextField("Search calls and contacts", text: $query)
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
            .background { Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0) }

            HStack(spacing: SG.Space.md) {
                // One track, one sliding thumb — the segmented control, Apple-style.
                HStack(spacing: 0) {
                    ForEach(Section.allCases, id: \.self) { s in
                        let active = section == s
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { section = s }
                        } label: {
                            HStack(spacing: 5) {
                                Text(s.rawValue)
                                if s == .missed, recentMissed > 0 {
                                    Text("\(recentMissed)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(active ? .white : .black)
                                        .padding(.horizontal, 5)
                                        .background(Capsule().fill(active ? Color.black : Color.white))
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(active ? .black : .white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background {
                                if active {
                                    Capsule().fill(Color.white)
                                        .matchedGeometryEffect(id: "thumb", in: segment)
                                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .frame(maxWidth: 340)
                .sgGlassCapsule()
                Spacer()
                Button { showKeypad.toggle() } label: {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.system(size: 13))
                        .foregroundColor(showKeypad ? .black : .white)
                        .frame(width: 30, height: 26)
                        .background { if showKeypad { Capsule().fill(Color.white) } }
                        .sgGlassCapsule(interactive: true)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .help(showKeypad ? "Hide keypad (⌘K)" : "Show keypad (⌘K)")
                .accessibilityLabel(showKeypad ? "Hide keypad" : "Show keypad")
            }

            if !query.isEmpty {
                searchResults
            } else {
                switch section {
                case .favorites: favoritesGrid
                case .contacts: contactsList
                case .recent, .missed: recentList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Typing searches the whole tab — contacts (favourites included) and every call —
    /// not just whichever segment happens to be selected.
    @ViewBuilder
    private var searchResults: some View {
        let people = contactMatches
        let calls = callGroups
        if people.isEmpty && calls.isEmpty {
            EmptyStateText("No results for “\(query)”", glyph: "magnifyingglass")
                .frame(maxWidth: .infinity)
                .padding(.top, SG.Space.xxl)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if !people.isEmpty {
                        SwiftUI.Section {
                            ForEach(showAllPeople ? people : Array(people.prefix(5))) { contact in
                                ContactResultRow(contact: contact,
                                                 onDial: { dialNumber = $0; dial($0) },
                                                 onFill: fill)
                            }
                            if people.count > 5 {
                                Button {
                                    withAnimation(SG.Motion.standard) { showAllPeople.toggle() }
                                } label: {
                                    Text(showAllPeople ? "Show fewer" : "Show all \(people.count) contacts")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.sgTextSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, SG.Space.md)
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: { SectionHeader(title: "Contacts") }
                    }
                    if !calls.isEmpty {
                        SwiftUI.Section {
                            ForEach(calls) { group in
                                CallRow(record: group.record, count: group.count,
                                        unseen: isUnseen(group.record),
                                        onDial: { dialNumber = $0; dial($0) },
                                        onFill: fill)
                            }
                        } header: { SectionHeader(title: "Recent Calls") }
                    }
                }
            }
        }
    }

    /// People you call often who aren't starred yet — up to three, most calls first.
    /// Grouped on matchKey so "+91…" and "0…" count as one person.
    private var suggestedFavorites: [(number: String, count: Int)] {
        let byPerson = Dictionary(grouping: store.calls.filter { !$0.phoneNumber.isEmpty }) {
            ContactsStore.matchKey($0.phoneNumber)
        }
        return byPerson.values
            .filter { $0.count >= 3 && !favorites.isFavorite($0[0].phoneNumber) }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { ($0[0].phoneNumber, $0.count) }
    }

    @ViewBuilder
    private var favoritesGrid: some View {
        let q = query.lowercased()
        let list = favoriteNumbers.filter { q.isEmpty || favoriteLabel($0).lowercased().contains(q) || $0.contains(q) }
        let suggested = q.isEmpty ? suggestedFavorites : []
        if list.isEmpty && suggested.isEmpty {
            EmptyStateText(query.isEmpty ? "Star anyone in Recent or Contacts to keep them here" : "No matches",
                           glyph: "star")
                .frame(maxWidth: .infinity)
                .padding(.top, SG.Space.xxl)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SG.Space.lg) {
                    if list.isEmpty {
                        Text("Star anyone in Recent or Contacts to keep them here")
                            .font(SG.Font.body)
                            .foregroundColor(.sgTextSecondary)
                            .padding(.horizontal, SG.Space.md)
                            .padding(.top, SG.Space.sm)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: SG.Space.md, alignment: .top)], alignment: .leading, spacing: SG.Space.md) {
                            ForEach(list, id: \.self) { number in
                                FavoriteCard(name: favoriteLabel(number), number: number,
                                             onDial: { dialNumber = $0; dial($0) }, onFill: fill)
                            }
                        }
                    }

                    if !suggested.isEmpty {
                        VStack(spacing: 2) {
                            SectionHeader(title: "Suggested")
                            ForEach(suggested, id: \.number) { s in
                                let name = favoriteLabel(s.number)
                                HoverRow { _ in
                                    Monogram(name: name, size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text("\(s.count) calls")
                                            .font(SG.Font.caption)
                                            .foregroundColor(.sgTextSecondary)
                                    }
                                    Spacer()
                                    Button {
                                        withAnimation(SG.Motion.standard) { favorites.toggle(s.number) }
                                    } label: {
                                        Label("Add to Favorites", systemImage: "star")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 10)
                                            .frame(height: 26)
                                            .sgGlassCapsule(interactive: true)
                                    }
                                    .buttonStyle(PressScale())
                                    .help("Keep \(name) in Favorites")
                                }
                                .onTapGesture { fill(s.number) }
                            }
                        }
                    }
                }
                .padding(.vertical, SG.Space.sm)
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        let groups = callGroups
        if groups.isEmpty {
            EmptyStateText(section == .missed ? "No missed calls" : (query.isEmpty ? "No calls yet" : "No matches"),
                           glyph: "phone")
                .frame(maxWidth: .infinity)
                .padding(.top, SG.Space.xxl)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(dayBuckets(groups), id: \.title) { bucket in
                        SwiftUI.Section {
                            ForEach(bucket.groups) { group in
                                CallRow(record: group.record, count: group.count,
                                        unseen: isUnseen(group.record),
                                        onDial: { dialNumber = $0; dial($0) },
                                        onFill: fill)
                            }
                        } header: { SectionHeader(title: bucket.title) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contactsList: some View {
        if contacts.contacts.isEmpty && contacts.isLoading {
            // Skeletons, not a spinner: the row shape is known, so the data lands
            // without a layout jump. Gated on empty so a per-visit refresh never
            // blanks contacts already on screen.
            VStack(spacing: SG.Space.sm) { ForEach(0..<6, id: \.self) { _ in SGSkeleton(height: 52) } }
            Spacer()
        } else if contactMatches.isEmpty {
            EmptyStateText(contactsEmptyMessage, glyph: "person.crop.circle")
                .frame(maxWidth: .infinity)
                .padding(.top, SG.Space.xxl)
            Spacer()
        } else {
            ScrollView {
                // A–Z with pinned letters, like Contacts.
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(letterBuckets(contactMatches), id: \.letter) { bucket in
                        SwiftUI.Section {
                            ForEach(bucket.contacts) { contact in
                                ContactResultRow(contact: contact,
                                                 onDial: { dialNumber = $0; dial($0) },
                                                 onFill: fill)
                            }
                        } header: { SectionHeader(title: bucket.letter) }
                    }
                }
            }
        }
    }

    // MARK: Keypad

    private var keypadPane: some View {
        VStack(spacing: SG.Space.md) {
            // The number itself is the text field: type, paste, or use the keys.
            TextField("", text: $dialNumber)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .light, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .focused($dialFocused)
                // macOS left-aligns a TextField prompt whatever the alignment, so the
                // placeholder is drawn here, centred, and never takes clicks.
                .overlay {
                    if dialNumber.isEmpty {
                        Text("Enter number")
                            .font(.system(size: 24, weight: .light, design: .rounded))
                            .foregroundColor(.white.opacity(0.25))
                            .allowsHitTesting(false)
                    }
                }
                .onSubmit { if canDial { dial(dialNumber) } }
                .onChange(of: dialNumber) { _, v in
                    // Keep only what a dialler can use; pasted "(630) 709-4133" stays callable.
                    let clean = v.filter { $0.isNumber || "+*#".contains($0) }
                    if clean != v { dialNumber = clean }
                }
                .padding(.horizontal, SG.Space.lg)

            Group {
                if let s = dialSuggestion {
                    Button { dialNumber = s.number } label: {
                        Text("\(s.name) · \(formatNumber(s.number))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .sgGlassCapsule(interactive: true)
                    }
                    .buttonStyle(.plain)
                    .help("Use this number")
                } else {
                    Text(dialContactName ?? callStatus ?? " ")
                        .font(.system(size: 12, weight: dialContactName != nil ? .medium : .regular))
                        .foregroundColor(dialContactName != nil ? .white.opacity(0.8) : .sgTextSecondary)
                }
            }
            .lineLimit(1)
            .frame(height: 22)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(60), spacing: 16), count: 3), spacing: 10) {
                ForEach(Self.keys, id: \.digit) { key in
                    KeypadKey(digit: key.digit, letters: key.letters) {
                        dialNumber.append(key.digit)
                        SGSound.play(.key(key.digit))
                        dialFocused = true   // so the next keystroke or Backspace lands here
                    } onLongPress: {
                        // Long-press 0 for "+", like every phone.
                        if key.digit == "0" { dialNumber.append("+") }
                    }
                }
            }

            HStack(spacing: 16) {
                simPicker.frame(width: 60)

                Button { dial(dialNumber) } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.sgSuccess))
                }
                .buttonStyle(PressScale())
                // Full green even before a number is typed, as on iPhone; the 35%
                // dimming made it read as a dull, disabled grey-green.
                .disabled(!canDial)
                .help("Call (Return)")
                .accessibilityLabel("Call \(dialContactName ?? dialNumber)")

                Button { if !dialNumber.isEmpty { dialNumber.removeLast() } } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 20))
                        .foregroundColor(.sgTextSecondary)
                        .frame(width: 60, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(dialNumber.isEmpty ? 0 : 1)
                .simultaneousGesture(LongPressGesture().onEnded { _ in dialNumber = "" })
                .help("Delete (hold to clear)")
                .accessibilityLabel("Delete digit")
            }

            if let notice = store.callEndNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .padding(.horizontal, SG.Space.lg)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { dialFocused = true }
        // Backspace deletes one digit even when a key click took focus elsewhere.
        .onKeyPress(.delete) {
            guard !dialFocused, !dialNumber.isEmpty else { return .ignored }
            dialNumber.removeLast()
            return .handled
        }
        .onKeyPress(.escape) {
            guard !dialNumber.isEmpty else { return .ignored }
            dialNumber = ""
            return .handled
        }
    }

    @ViewBuilder
    private var simPicker: some View {
        if simStore.sims.count > 1 {
            Picker("SIM", selection: $selectedSubscriptionId) {
                ForEach(simStore.sims) { sim in
                    Text(sim.displayName.isEmpty ? sim.carrierName : sim.displayName)
                        .tag(Optional(sim.subscriptionId))
                }
            }
            .labelsHidden()
            .help("SIM to call from")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private static let keys: [(digit: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"), ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"), ("*", ""), ("0", "+"), ("#", "")
    ]

    // MARK: In call

    private var inCallPane: some View {
        let name = store.liveCallName ?? (store.liveCallNumber.isEmpty ? "Unknown" : formatNumber(store.liveCallNumber))
        let ringing = store.liveCallState == "ringing"
        return VStack(spacing: SG.Space.lg) {
            Group {
                if let photo = store.liveCallPhoto {
                    Image(nsImage: photo).resizable().scaledToFill().frame(width: 80, height: 80).clipShape(Circle())
                } else {
                    Monogram(name: name, size: 80)
                }
            }
                .overlay(Circle().stroke(Color.white.opacity(ringing ? 0.5 : 0), lineWidth: 2)
                    .scaleEffect(ringing && !reduceMotion ? 1.25 : 1)
                    .animation(ringing && !reduceMotion ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default, value: ringing))
            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if store.liveCallName != nil, !store.liveCallNumber.isEmpty {
                    Text(formatNumber(store.liveCallNumber))
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                }
                if let start = callStartedAt, store.liveCallState == "offhook", !store.hangupPending {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Duration.seconds(ctx.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                            .font(SG.Font.mono(13))
                            .foregroundColor(.sgTextSecondary)
                    }
                } else {
                    Text(liveCallTitle)
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                }
            }

            HStack(spacing: 28) {
                // Mute is meaningless while ringing — there is no audio path yet.
                if !ringing, store.liveCallApp == nil {
                    CallButton(glyph: store.isMuted ? "mic.slash.fill" : "mic.fill",
                               label: store.isMuted ? "Unmute" : "Mute",
                               inverted: store.isMuted, pending: store.mutePending) {
                        store.markMutePending()
                        mDNSQuicServer.activeServer?.sendCallControl(action: "mute", enabled: !store.isMuted)
                    }
                }
                CallButton(glyph: "phone.down.fill", label: ringing ? "Decline" : "End",
                           inverted: true, pending: store.hangupPending, tint: .sgDanger, action: hangUp)
                if ringing {
                    CallButton(glyph: "phone.fill", label: "Answer", inverted: true, pending: false, tint: .sgSuccess) {
                        mDNSQuicServer.activeServer?.sendCallControl(action: "answer")
                    }
                }
            }

            // Shown only when the phone refused a toggle, so a mute that never took
            // effect can't read as active.
            if let notice = store.audioNotice {
                Text(notice)
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SG.Space.lg)
            }

            // Decline with a text, like iPhone: one click hangs up and sends it.
            if ringing, !store.liveCallNumber.isEmpty, !store.hangupPending {
                VStack(spacing: 6) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button { declineWithMessage(reply) } label: {
                            Text(reply)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .sgGlassCapsule(interactive: true)
                        }
                        .buttonStyle(PressScale())
                        .help("Decline and text this")
                    }
                }
                .padding(.horizontal, SG.Space.lg)
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
        // Space answers a ringing call; Escape declines it.
        .background {
            Group {
                Button("") { mDNSQuicServer.activeServer?.sendCallControl(action: "answer") }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!ringing)
                // Ringing only: Escape to clear a search mid-call must never hang up.
                Button("", action: hangUp).keyboardShortcut(.escape, modifiers: []).disabled(!ringing)
            }
            .opacity(0)
        }
    }

    private static let quickReplies = ["Can't talk now. I'll call you back.", "In a meeting — text me?", "On my way."]

    // MARK: Actions

    private func takeDialRequest() {
        if store.openMissed {
            store.openMissed = false
            query = ""
            section = .missed
        }
        guard let n = store.dialTo else { return }
        store.dialTo = nil
        fill(n)
    }

    private func fill(_ number: String) {
        dialNumber = number
        showKeypad = true
        dialFocused = true
    }

    private func declineWithMessage(_ text: String) {
        let number = store.liveCallNumber
        hangUp()
        PhoneActions.sendSms(to: number, body: text, subscriptionId: selectedSubscriptionId)
    }

    private var canDial: Bool { !dialNumber.trimmingCharacters(in: .whitespaces).isEmpty }

    private func hangUp() {
        store.markHangupPending()
        mDNSQuicServer.activeServer?.sendCallControl(action: "hangup")
    }

    private func dial(_ number: String) {
        guard !number.isEmpty else { return }
        callStatus = nil
        if let subId = selectedSubscriptionId { simStore.setLastUsed(subId, for: .dial) }
        if let id = mDNSQuicServer.activeServer?.sendCallDial(number: number, subscriptionId: selectedSubscriptionId) {
            pendingDialId = id
            // sendCallDial mints an id even when the message never reached the phone, so
            // a dial into a dead tunnel used to produce nothing at all. Harmless once
            // the result has landed, since that clears pendingDialId.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard pendingDialId == id else { return }
                pendingDialId = nil
                callStatus = "No response from your phone"
            }
        }
    }

    /// Wire errors are identifiers, not sentences. These three are the only values the
    /// dial path sends; anything else gets the generic line.
    private func dialErrorMessage(_ code: String?) -> String {
        switch code {
        case "invalid_number":    return "That number can't be dialled"
        case "permission_denied": return "Your phone wouldn't let SwiftGreen call"
        default:                  return "Couldn't place the call"
        }
    }
}

// MARK: - Pieces

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct KeypadKey: View {
    let digit: String
    let letters: String
    let action: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: {
            action()
        }) {
            VStack(spacing: 0) {
                Text(digit)
                    .font(.system(size: 22, weight: .regular, design: .rounded))
                    .foregroundColor(.white)
                Text(letters)
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(1.5)
                    .foregroundColor(.sgTextSecondary)
                    .frame(height: 10)
            }
            .frame(width: 56, height: 56)
            .sgGlassCircle()
        }
        .buttonStyle(PressScale())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() })
        .accessibilityLabel(digit)
    }
}

/// Glass for a round control that has no solid fill of its own.
private struct GlassUnlessFilled: ViewModifier {
    let filled: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if filled { content } else { content.sgGlassCircle() }
    }
}

/// Round control with its label underneath. Inverted = white fill, the "active" look
/// in a palette that has no colour to say on/off with.
private struct CallButton: View {
    let glyph: String
    let label: String
    let inverted: Bool
    let pending: Bool
    /// Green for Answer, red for Decline/End; nil keeps the white/grey look.
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: pending ? "ellipsis" : glyph)
                    .font(.system(size: 22))
                    .foregroundColor(tint != nil ? .white : inverted ? .black : .white)
                    .frame(width: 64, height: 64)
                    .background {
                        if let fill = tint ?? (inverted ? Color.white : nil) { Circle().fill(fill) }
                    }
                    .modifier(GlassUnlessFilled(filled: tint != nil || inverted))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.sgTextSecondary)
            }
            .opacity(pending ? 0.5 : 1)
        }
        .buttonStyle(PressScale())
        .disabled(pending)
        .accessibilityLabel(label)
    }
}

/// One row per number, not per contact — a contact commonly has several and picking
/// the wrong one places a real call.
private struct ContactResultRow: View {
    let contact: MacContact
    let onDial: (String) -> Void
    let onFill: (String) -> Void
    @ObservedObject private var favorites = FavoritesStore.shared

    private var displayName: String { contact.displayName.isEmpty ? "No name" : contact.displayName }

    var body: some View {
        ForEach(contact.phoneNumbers, id: \.self) { number in
            let isFavorite = favorites.isFavorite(number)
            HoverRow {
                hovering in
                Monogram(name: displayName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(SG.Font.rowTitle)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(formatNumber(number))
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                }
                Spacer()
                RowActions(number: number, name: displayName, isFavorite: isFavorite,
                           expanded: hovering, onDial: onDial)
            }
            // Row click fills the keypad; only the phone glyph rings anyone.
            .onTapGesture { onFill(number) }
            .contextMenu { RowMenu(number: number, isFavorite: isFavorite) }
        }
    }
}

/// A run of consecutive calls from one number, folded into one row.
private struct CallGroup: Identifiable {
    /// Newest of the run — `store.calls` is newest-first.
    let record: CallLogRecord
    let count: Int
    var id: String { record.id }
}

private struct CallRow: View {
    let record: CallLogRecord
    let count: Int
    /// A missed call you haven't looked at yet — bold until you open Missed.
    let unseen: Bool
    let onDial: (String) -> Void
    /// Puts the number in the keypad without ringing it, so the row can be clickable
    /// without a stray click placing a call.
    let onFill: (String) -> Void
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var contacts = ContactsStore.shared

    /// Call-log name first — it's what the phone itself showed — then the address
    /// book, then the number.
    private var displayName: String {
        if let cached = record.contactName, !cached.isEmpty { return cached }
        if let name = contacts.name(for: record.phoneNumber) { return name }
        return formatNumber(record.phoneNumber)
    }

    private var missed: Bool { record.callType.lowercased() == "missed" }

    /// Direction by glyph shape — the monochrome palette has no red for missed, so a
    /// missed call is marked by weight instead. Unknown values stay neutral.
    private var direction: (glyph: String, label: String) {
        switch record.callType.lowercased() {
        case "missed":   return ("phone.arrow.down.left", "Missed")
        case "outgoing": return ("phone.arrow.up.right", "Outgoing")
        case "incoming": return ("phone.arrow.down.left", "Incoming")
        default:         return ("phone", "Call")
        }
    }

    private var detail: String {
        var parts = [direction.label]
        if count > 1 { parts.append("×\(count)") }
        if record.durationSeconds > 0, !missed {
            parts.append(Duration.seconds(record.durationSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HoverRow { hovering in
            Monogram(name: displayName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 13, weight: unseen ? .bold : .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if record.source == "whatsapp" {
                        Text("WhatsApp")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.sgTextSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.sgSurfaceHigh))
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: direction.glyph).font(.system(size: 9))
                    Text(detail)
                }
                .font(SG.Font.caption)
                .foregroundColor(unseen ? .white : .sgTextSecondary)
            }
            Spacer()
            Text(CallTime.short(record.timestamp))
                .font(.system(size: 11))
                .foregroundColor(.sgTextSecondary)
            if !record.phoneNumber.isEmpty {
                RowActions(number: record.phoneNumber, name: displayName,
                           isFavorite: favorites.isFavorite(record.phoneNumber),
                           expanded: hovering, onDial: onDial)
            }
        }
        // A gesture, not a Button wrapping the row: nested Buttons break hit-testing on
        // macOS. Skipped for rows with no number (a WhatsApp caller the phone couldn't
        // pin to one number).
        .onTapGesture {
            guard !record.phoneNumber.isEmpty else { return }
            onFill(record.phoneNumber)
        }
        .contextMenu {
            if !record.phoneNumber.isEmpty {
                RowMenu(number: record.phoneNumber, isFavorite: favorites.isFavorite(record.phoneNumber))
            }
        }
    }
}

/// Contact-card tile. Clicking the card only fills the keypad; calling is its own
/// labelled button, like the action row on an Apple contact card.
private struct FavoriteCard: View {
    let name: String
    let number: String
    let onDial: (String) -> Void
    let onFill: (String) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: SG.Space.sm) {
            Monogram(name: name, size: 56)
            VStack(spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                // No name → the title already is the number; don't say it twice.
                Text(name == formatNumber(number) ? " " : formatNumber(number))
                    .font(.system(size: 11))
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
            }
            // Equal columns, top-aligned: every circle on one line, every caption on one.
            HStack(alignment: .top, spacing: 4) {
                action("phone.fill", "Call", filled: true) { onDial(number) }
                action("message.fill", "Message") { PhoneActions.message(number) }
                action("arrow.up.forward.app.fill", "WhatsApp") { PhoneActions.whatsApp(number) }
            }
            .padding(.top, 2)
        }
        .padding(SG.Space.md)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(hovering ? Color.sgSurfaceHigh : Color.sgSurface))
        .contentShape(Rectangle())
        .onTapGesture { onFill(number) }
        .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
        .contextMenu {
            RowMenu(number: number, isFavorite: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    /// Circle + caption, the Apple contact-card action.
    private func action(_ glyph: String, _ title: String, filled: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: glyph)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background { if filled { Circle().fill(Color.sgSuccess) } }
                    .modifier(GlassUnlessFilled(filled: filled))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 58)
        }
        .buttonStyle(PressScale())
        .help(title == "Call" ? "Call \(name)" : title == "Message" ? "Text \(name)" : "Open \(name)'s chat in WhatsApp")
        .accessibilityLabel("\(title) \(name)")
    }
}

/// Small caps over the bar material so pinned headers read cleanly over scrolling rows.
private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundColor(.sgTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SG.Space.md)
            .padding(.top, SG.Space.md)
            .padding(.bottom, 6)
            .background(.bar)
    }
}

/// Row with hover state and the shared row chrome.
private struct HoverRow<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: SG.Space.md) { content(hovering) }
            .padding(.horizontal, SG.Space.md)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous)
                .fill(hovering ? Color.sgSurface : .clear))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(SG.Motion.quick) { hovering = h } }
    }
}

/// Message · WhatsApp · star appear on hover; call is always there. Quiet rows,
/// everything one move away.
private struct RowActions: View {
    let number: String
    let name: String
    let isFavorite: Bool
    let expanded: Bool
    let onDial: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Labelled, not bare glyphs: "WhatsApp" has to say so, not make you guess.
            if expanded {
                pill("message.fill", "Message", help: "Text \(name) from Messages") { PhoneActions.message(number) }
                pill("arrow.up.forward.app.fill", "WhatsApp", help: "Open \(name)'s chat in WhatsApp") { PhoneActions.whatsApp(number) }
            }
            if expanded || isFavorite {
            Button { FavoritesStore.shared.toggle(number) } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundColor(isFavorite ? .white : .sgTextSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            }

            Button { onDial(number) } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.sgSuccess))
            }
            .buttonStyle(PressScale())
            .help("Call \(formatNumber(number))")
            .accessibilityLabel("Call \(name)")
        }
    }

    private func pill(_ glyph: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .sgGlassCapsule(interactive: true)
                .padding(.trailing, 4)
        }
        .buttonStyle(PressScale())
        .help(help)
        .accessibilityLabel(help)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

/// Cross-app actions on a number: text it here, or hand it to WhatsApp.
enum PhoneActions {
    /// Jump to Messages with a new conversation to this number.
    static func message(_ number: String) {
        SmsStore.shared.composeTo = number
        NotificationCenter.default.post(name: .sgNavigate, object: Tab.messages)
    }

    /// wa.me needs the full international number. A bare local number gets the Mac's
    /// region code. ponytail: India only — add a region→code entry when needed.
    static func whatsApp(_ number: String) {
        var digits = number.filter(\.isNumber)
        if !number.hasPrefix("+"), digits.count == 10, Locale.current.region?.identifier == "IN" { digits = "91" + digits }
        if let url = URL(string: "https://wa.me/\(digits)") { NSWorkspace.shared.open(url) }
    }

    static func sendSms(to number: String, body: String, subscriptionId: Int?) {
        var payload: [String: Any] = ["type": "sms_send", "to_number": number, "body": body, "thread_id": -1]
        // Same rule as Messages: only a SIM the phone reported, else its default SIM.
        if let sub = SimStore.shared.reported(subscriptionId) { payload["subscription_id"] = sub }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        mDNSQuicServer.activeServer?.sendMessage(json + "\n")
    }
}

private struct RowMenu: View {
    let number: String
    let isFavorite: Bool

    var body: some View {
        Button("Copy Number") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(number, forType: .string)
        }
        Button("Message") { PhoneActions.message(number) }
        Button("Open in WhatsApp") { PhoneActions.whatsApp(number) }
        Divider()
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { FavoritesStore.shared.toggle(number) }
    }
}

private enum CallTime {
    private static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    private static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()

    /// Rows sit under Today / Yesterday / This Week headers, so the row adds what the
    /// header doesn't: the clock for the last two days, then weekday, then date.
    static func short(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) || cal.isDateInYesterday(d) { return time.string(from: d) }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return weekday.string(from: d) }
        return date.string(from: d)
    }
}
