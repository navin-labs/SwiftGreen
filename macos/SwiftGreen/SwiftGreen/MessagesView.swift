import SwiftUI
import Combine

/// Threads on the left, conversation on the right, divider draggable. Inbox holds
/// people and one-time codes, Updates holds alerts; promotions aren't listed at all
/// (phone search still finds them).
struct MessagesView: View {
    @ObservedObject private var store = SmsStore.shared
    @ObservedObject private var simStore = SimStore.shared
    @ObservedObject private var contacts = ContactsStore.shared

    @State private var selectedThread: SmsThread?
    @State private var draft = ""
    @State private var searchQuery = ""
    @State private var selectedSubscriptionId: Int?
    @State private var filter: Filter = .inbox
    @State private var copiedCode: String?
    @State private var composing = false
    @State private var recipient = ""
    /// Number just messaged from compose; its thread opens once the phone lists it.
    @State private var pendingNumber: String?

    enum Filter: String, CaseIterable { case inbox = "Inbox", updates = "Updates" }

    /// There's no push for new SMS, so poll while this pane is on screen —
    /// otherwise an OTP only showed up after leaving and re-opening the tab.
    private let refresh = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    // MARK: Derived

    private var filteredThreads: [SmsThread] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return store.threads.filter { t in
            let inFilter = filter == .inbox ? t.isInbox : t.kind == .alert
            return inFilter && (q.isEmpty
                || t.displayName.lowercased().contains(q)
                || t.phoneNumber.lowercased().contains(q)
                || t.snippet.lowercased().contains(q))
        }
    }

    private func unreadCount(_ f: Filter) -> Int {
        store.threads.filter { store.isUnread($0) && (f == .inbox ? $0.isInbox : $0.kind == .alert) }.count
    }

    /// The open thread, refreshed from the latest poll so name/unread stay current.
    private var currentThread: SmsThread? {
        guard let sel = selectedThread else { return nil }
        return store.threads.first { $0.threadId == sel.threadId } ?? sel
    }

    private var conversation: [SmsMessage] {
        guard let thread = currentThread else { return [] }
        return (store.messages[thread.threadId] ?? []).sorted { $0.timestampMs < $1.timestampMs }
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.sgCanvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: SG.Space.lg) {
                SGScreenHeader(title: "Messages", subtitle: "Texts and one-time codes from your Android phone")

                // Native split: drag the divider to give the list or the text more room.
                HSplitView {
                    sidebar
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 600)
                        .padding(.trailing, SG.Space.md)
                    conversationPane
                        .frame(minWidth: 360)
                        .padding(.leading, SG.Space.md)
                }
            }
            .padding(.horizontal, SG.Space.xxl)
            .padding(.bottom, SG.Space.xxl)
        }
        // The SIM list can arrive after this view appears, or change (a SIM removed): keep
        // the pick on a SIM the phone has, so the picker shows it and sends use it.
        .onReceive(simStore.$sims) { sims in
            selectedSubscriptionId = simStore.selection(keeping: selectedSubscriptionId, for: .sms, in: sims)
        }
        .onAppear {
            if selectedSubscriptionId == nil {
                selectedSubscriptionId = simStore.lastUsedSubscriptionId(for: .sms)
                    ?? simStore.sims.first?.subscriptionId
            }
            requestThreads()
            takeComposeRequest()
        }
        .onChange(of: store.composeTo) { _, _ in takeComposeRequest() }
        .onReceive(refresh) { _ in
            requestThreads()
            if let t = currentThread, t.threadId >= 0 { requestMessages(t.threadId) }
        }
        .onChange(of: store.threads.first?.threadId) { _, _ in openPendingThread() }
        // A message that lands in the thread you're reading is already seen.
        .onChange(of: currentThread?.timestampMs) { _, _ in if let t = currentThread { store.markSeen(t) } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SG.Space.md) {
            HStack(spacing: SG.Space.sm) {
                searchField
                Button { startCompose() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous).fill(Color.sgSurfaceHigh))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .help("New message (⌘N)")
                .accessibilityLabel("New message")
            }
            filterChips

            if store.isSearching {
                skeletons
            } else if !store.searchResults.isEmpty {
                searchResults
            } else if store.threads.isEmpty {
                skeletons
            } else if filteredThreads.isEmpty {
                EmptyStateText(emptyText, glyph: "tray")
                    .frame(maxWidth: .infinity)
                    .padding(.top, SG.Space.xxl)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredThreads) { thread in
                            ThreadRow(thread: thread,
                                      selected: thread.threadId == currentThread?.threadId,
                                      copied: copiedCode) { copy($0) }
                                .contentShape(Rectangle())
                                .onTapGesture { open(thread) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyText: String {
        switch filter {
        case .inbox: "No messages from people yet"
        case .updates: "No updates"
        }
    }

    private var skeletons: some View {
        VStack(spacing: SG.Space.sm) { ForEach(0..<6, id: \.self) { _ in SGSkeleton(height: 56) } }
    }

    private var searchField: some View {
        HStack(spacing: SG.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.sgTextSecondary)
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(SG.Font.body)
                .onSubmit(runRemoteSearch)
                .onChange(of: searchQuery) { _, newValue in
                    if newValue.isEmpty { store.searchResults = [] }
                }
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.sgTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Color.sgSurfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous))
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases, id: \.self) { f in
                let active = filter == f
                Button {
                    withAnimation(SG.Motion.quick) { filter = f }
                } label: {
                    HStack(spacing: 4) {
                        Text(f.rawValue)
                        if unreadCount(f) > 0 {
                            Text("\(unreadCount(f))").foregroundColor(active ? .black.opacity(0.5) : .sgTextSecondary)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? .black : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background { if active { Capsule().fill(Color.white) } }
                    .sgGlassCapsule(interactive: true)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: SG.Space.sm) {
            Text("\(store.searchResults.count) results on phone")
                .font(SG.Font.caption)
                .foregroundColor(.sgTextSecondary)
                .padding(.horizontal, SG.Space.sm)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.searchResults) { message in
                        SearchResultRow(message: message)
                            .contentShape(Rectangle())
                            .onTapGesture { openSearchResult(message) }
                    }
                }
            }
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversationPane: some View {
        VStack(spacing: 0) {
            if composing {
                composeView
            } else if let thread = currentThread {
                conversationHeader(thread)
                Divider().overlay(Color.sgHairline)

                if conversation.isEmpty {
                    Spacer()
                    if thread.threadId < 0 {
                        EmptyStateText("New conversation", glyph: "bubble.left")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: SG.Space.sm) {
                                if store.hasOlder[thread.threadId] == true {
                                    Button("Load earlier messages") { requestOlder(thread.threadId) }
                                        .buttonStyle(.plain)
                                        .font(SG.Font.caption)
                                        .foregroundColor(.sgTextSecondary)
                                        .padding(.top, SG.Space.sm)
                                }
                                ForEach(Array(conversation.enumerated()), id: \.element.id) { i, message in
                                    if i == 0 || !Calendar.current.isDate(message.date, inSameDayAs: conversation[i - 1].date) {
                                        Text(SmsTime.day(message.date))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.sgTextSecondary)
                                            .padding(.top, SG.Space.md)
                                    }
                                    MessageBubble(message: message, showTime: endsRun(i),
                                                  copied: copiedCode) { copy($0) }
                                        .id(message.id)
                                        // Runs from one side sit tight; a new speaker gets air.
                                        .padding(.top, i > 0 && !startsRun(i) ? -4 : 0)
                                }
                            }
                            .padding(SG.Space.lg)
                        }
                        // Land on the newest message when a thread opens or a new one arrives.
                        .onAppear { scrollToEnd(proxy) }
                        .onChange(of: conversation.last?.id) { _, _ in scrollToEnd(proxy) }
                    }
                }

                sendResultBanner(for: thread)
                if thread.acceptsReplies {
                    composer(thread)
                } else {
                    Text("This sender doesn't accept replies")
                        .font(SG.Font.caption)
                        .foregroundColor(.sgTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(SG.Space.md)
                }
            } else {
                Spacer()
                EmptyStateText(store.threads.isEmpty ? "Waiting for conversations from your phone"
                                                     : "Select a conversation",
                               glyph: "message")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sgGlass()
    }

    // MARK: Compose

    /// Contacts matching what's typed in To:, by name or number.
    private var suggestions: [(name: String, number: String)] {
        let q = recipient.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let digits = q.filter(\.isNumber)
        return contacts.contacts.flatMap { c in c.phoneNumbers.map { (c.displayName, $0) } }
            // Start of any word, like Messages: "ra" finds Rahul and Ajay Rana, not Antra.
            .filter { c in
                c.0.lowercased().split(separator: " ").contains { $0.hasPrefix(q) } || c.0.lowercased().hasPrefix(q)
                    || (!digits.isEmpty && digits.count == q.count && c.1.filter(\.isNumber).contains(digits))
            }
            .prefix(8).map { $0 }
    }

    private var typedNumber: String? {
        let t = recipient.trimmingCharacters(in: .whitespaces)
        return SmsClassifier.isPhoneNumber(t) ? t : nil
    }

    private var composeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: SG.Space.sm) {
                Text("To")
                    .font(SG.Font.rowTitle)
                    .foregroundColor(.sgTextSecondary)
                TextField("Name or number", text: $recipient)
                    .textFieldStyle(.plain)
                    .font(SG.Font.body)
                    .onSubmit { if let n = typedNumber ?? suggestions.first?.number { pick(n) } }
                Button { composing = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundColor(.sgTextSecondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel new message")
            }
            .padding(SG.Space.lg)
            Divider().overlay(Color.sgHairline)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if let n = typedNumber {
                        suggestionRow(name: n, number: "Send to this number")  { pick(n) }
                    }
                    ForEach(suggestions, id: \.number) { s in
                        suggestionRow(name: s.name, number: s.number) { pick(s.number) }
                    }
                }
                .padding(SG.Space.sm)
            }
            if contacts.contacts.isEmpty {
                Text("Contacts appear once your phone shares them — you can still type a number.")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .padding(SG.Space.md)
            }
        }
    }

    private func suggestionRow(name: String, number: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SG.Space.md) {
                Monogram(name: name, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(SG.Font.rowTitle).foregroundColor(.white)
                    Text(number).font(SG.Font.caption).foregroundColor(.sgTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, SG.Space.md)
            .padding(.vertical, SG.Space.sm)
            .contentShape(Rectangle())
            .sgHoverRow(base: .clear, hovered: .sgSurfaceHigh)
        }
        .buttonStyle(.plain)
    }

    private func conversationHeader(_ thread: SmsThread) -> some View {
        HStack(spacing: SG.Space.md) {
            Monogram(name: thread.displayName, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.displayName)
                    .font(SG.Font.rowTitle)
                    .foregroundColor(.white)
                Text(thread.acceptsReplies ? thread.phoneNumber : "Business sender · \(thread.phoneNumber)")
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(SG.Space.lg)
    }

    @ViewBuilder
    private func sendResultBanner(for thread: SmsThread) -> some View {
        if let result = store.lastSendResult, result.threadId == thread.threadId {
            HStack(spacing: SG.Space.sm) {
                Image(systemName: result.success ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundColor(result.success ? .sgSuccess : .sgDanger)
                Text(result.success ? "Sent" : "Not sent — \(result.failureReason ?? "unknown error")")
                Spacer()
                Button { store.clearSendResult() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
            }
            .font(SG.Font.caption)
            .foregroundColor(.white)
            .padding(.horizontal, SG.Space.lg)
            .padding(.vertical, SG.Space.sm)
            .background(Color.sgSurfaceHigh)
            .task(id: result.at) {
                // Success needs no lingering; failures stay until dismissed.
                guard result.success else { return }
                try? await Task.sleep(for: .seconds(3))
                if store.lastSendResult == result { store.clearSendResult() }
            }
        }
    }

    private func composer(_ thread: SmsThread) -> some View {
        HStack(alignment: .bottom, spacing: SG.Space.sm) {
            if simStore.sims.count > 1 {
                Picker("SIM", selection: $selectedSubscriptionId) {
                    ForEach(simStore.sims) { sim in
                        Text(sim.displayName.isEmpty ? sim.carrierName : sim.displayName)
                            .tag(Optional(sim.subscriptionId))
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            TextField("Text message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(SG.Font.body)
                .lineLimit(1...5)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .sgGlassCapsule()

            let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .opacity(empty ? 0.35 : 1)
            .help("Send (Return)")
            .accessibilityLabel("Send message")
        }
        .padding(SG.Space.md)
    }

    // MARK: Actions

    private func takeComposeRequest() {
        guard let n = store.composeTo else { return }
        store.composeTo = nil
        pick(n)
    }

    private func startCompose() {
        recipient = ""
        composing = true
    }

    /// Existing conversation with that number → open it; otherwise a blank one
    /// (thread id -1) that becomes the real thread after the first send.
    private func pick(_ number: String) {
        composing = false
        if let t = thread(for: number) { open(t); return }
        let name = contacts.contacts.first { $0.phoneNumbers.contains(number) }?.displayName
        selectedThread = SmsThread(threadId: -1, contactName: name, phoneNumber: number,
                                   snippet: "", timestampMs: 0, unreadCount: 0)
    }

    /// Numbers are stored in many shapes (+91 98…, 098…); compare the last 10 digits.
    private func thread(for number: String) -> SmsThread? {
        let key = String(number.filter(\.isNumber).suffix(10))
        return store.threads.first { String($0.phoneNumber.filter(\.isNumber).suffix(10)) == key }
    }

    private func openPendingThread() {
        guard let n = pendingNumber, let t = thread(for: n) else { return }
        pendingNumber = nil
        open(t)
    }

    /// Same direction and within 5 minutes of the neighbour = same run.
    private func sameRun(_ a: SmsMessage, _ b: SmsMessage) -> Bool {
        (a.type == "sent") == (b.type == "sent") && abs(a.timestampMs - b.timestampMs) < 300_000
    }
    private func startsRun(_ i: Int) -> Bool { i == 0 || !sameRun(conversation[i - 1], conversation[i]) }
    private func endsRun(_ i: Int) -> Bool { i == conversation.count - 1 || !sameRun(conversation[i], conversation[i + 1]) }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = conversation.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(SG.Motion.quick) { copiedCode = code }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedCode == code { withAnimation(SG.Motion.quick) { copiedCode = nil } }
        }
    }

    private func requestThreads() {
        mDNSQuicServer.activeServer?.sendMessage("{\"type\":\"get_sms_threads\",\"page\":0}\n")
    }

    private func requestMessages(_ threadId: Int64) {
        sendJSON(["type": "get_sms_messages", "thread_id": threadId, "page": 0])
    }

    /// The page just older than the oldest message shown (a time cursor, so new
    /// arrivals can't shift it).
    private func requestOlder(_ threadId: Int64) {
        let loaded = (store.messages[threadId] ?? []).filter { $0.messageId >= 0 }
        guard let oldest = loaded.map(\.timestampMs).min() else { return }
        sendJSON(["type": "get_sms_messages", "thread_id": threadId, "before_ms": oldest])
    }

    private func open(_ thread: SmsThread) {
        selectedThread = thread
        store.markSeen(thread)
        requestMessages(thread.threadId)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let thread = currentThread, thread.acceptsReplies else { return }
        store.clearSendResult()
        if let sub = selectedSubscriptionId { simStore.setLastUsed(sub, for: .sms) }
        var payload: [String: Any] = [
            "type": "sms_send",
            "to_number": thread.phoneNumber,
            "body": text,
            "thread_id": thread.threadId
        ]
        // Only a SIM the phone reported. This used to fall back to a made-up 1, which
        // fails the send on any phone whose SIM isn't subscription 1.
        if let sub = simStore.reported(selectedSubscriptionId) { payload["subscription_id"] = sub }
        sendJSON(payload)
        store.appendPending(threadId: thread.threadId, to: thread.phoneNumber, body: text)
        draft = ""
        if thread.threadId < 0 { pendingNumber = thread.phoneNumber }
        // The sent message only exists once the phone writes it; fetch it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if thread.threadId < 0 { requestThreads() } else { requestMessages(thread.threadId) }
        }
    }

    private func runRemoteSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        store.isSearching = true
        sendJSON(["type": "sms_search", "query": q, "page": 0])
    }

    private func openSearchResult(_ message: SmsMessage) {
        guard let threadId = message.threadId else { return }
        // Prefer the real thread — it carries the correct contact name and unread count.
        if let known = store.threads.first(where: { $0.threadId == threadId }) {
            open(known)
            return
        }
        open(SmsThread(threadId: threadId, contactName: message.contactName, phoneNumber: message.address,
                       snippet: message.body, timestampMs: message.timestampMs, unreadCount: 0))
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        mDNSQuicServer.activeServer?.sendMessage(json + "\n")
    }
}

// MARK: - Time

private enum SmsTime {
    private static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    private static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()
    private static let fullDate: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; return f }()

    /// Row timestamp: 14:32 · Yesterday · Mon · 12 Sep.
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return weekday.string(from: d) }
        return date.string(from: d)
    }

    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return fullDate.string(from: d)
    }

    static func clock(_ d: Date) -> String { time.string(from: d) }
}

private extension SmsMessage {
    var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1000) }
}

private extension SmsThread {
    var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1000) }
}

// MARK: - Pieces

/// Initials on a quiet disc — the same for people and business senders.
struct Monogram: View {
    let name: String
    var size: CGFloat = 38

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count >= 2 ? [words[0].first, words[1].first] : [name.first(where: \.isLetter), nil]
        let s = String(letters.compactMap { $0 }).uppercased()
        return s.isEmpty ? "#" : s
    }

    var body: some View {
        Group {
            // A bare number has no initials worth showing — "99" reads as a count.
            if name.contains(where: \.isLetter) {
                Text(initials).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.38))
            }
        }
        .foregroundColor(.white)
        .frame(width: size, height: size)
        // Soft top-lit grey, the Contacts monogram look.
        .background(Circle().fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.24)],
                                                 startPoint: .top, endPoint: .bottom)))
    }
}

/// The code itself as a button: tap copies. Shows "Copied" briefly.
private struct CodeChip: View {
    let code: String
    let copied: Bool
    var large = false
    let onCopy: (String) -> Void

    var body: some View {
        Button { onCopy(code) } label: {
            HStack(spacing: 6) {
                Text(copied ? "Copied" : code)
                    .font(SG.Font.mono(large ? 22 : 12, weight: .semibold))
                    .kerning(copied ? 0 : (large ? 4 : 1.5))
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: large ? 13 : 10, weight: .semibold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, large ? 14 : 8)
            .padding(.vertical, large ? 8 : 3)
            .background(Capsule().fill(Color.white))
            .contentTransition(.opacity)
            .fixedSize()   // a code must never wrap mid-digits in a narrow list
        }
        .buttonStyle(.plain)
        .help("Copy code")
        .accessibilityLabel("Copy code \(code)")
    }
}

private struct ThreadRow: View {
    let thread: SmsThread
    let selected: Bool
    let copied: String?
    let onCopy: (String) -> Void

    var body: some View {
        let unread = SmsStore.shared.isUnread(thread)
        HStack(spacing: SG.Space.md) {
            Monogram(name: thread.displayName)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SG.Space.sm) {
                    Text(thread.displayName)
                        .font(.system(size: 13, weight: unread ? .bold : .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SmsTime.short(thread.date))
                        .font(.system(size: 11))
                        .foregroundColor(unread ? .white : .sgTextSecondary)
                }
                HStack(spacing: SG.Space.sm) {
                    Text(thread.snippet)
                        .font(SG.Font.caption)
                        .foregroundColor(unread ? .white.opacity(0.85) : .sgTextSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if case .code(let c) = thread.kind {
                        CodeChip(code: c, copied: copied == c, onCopy: onCopy)
                    } else if unread {
                        Circle().fill(Color.white).frame(width: 8, height: 8)
                            .accessibilityLabel("\(thread.unreadCount) unread")
                    }
                }
            }
        }
        .padding(.horizontal, SG.Space.md)
        .padding(.vertical, 10)
        .sgHoverRow(base: selected ? .sgSurfaceHigh : .clear, hovered: selected ? .sgSurfaceHigh : .sgSurface)
        .accessibilityElement(children: .combine)
    }
}

private struct SearchResultRow: View {
    let message: SmsMessage

    var body: some View {
        let name = message.contactName ?? SmsClassifier.senderName(message.address)
        HStack(spacing: SG.Space.md) {
            Monogram(name: name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name)
                        .font(SG.Font.rowTitle)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(SmsTime.short(message.date))
                        .font(.system(size: 11))
                        .foregroundColor(.sgTextSecondary)
                }
                Text(message.body)
                    .font(SG.Font.caption)
                    .foregroundColor(.sgTextSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, SG.Space.md)
        .padding(.vertical, 10)
        .sgHoverRow(base: .clear, hovered: .sgSurface)
        .accessibilityElement(children: .combine)
    }
}

private struct MessageBubble: View {
    let message: SmsMessage
    let showTime: Bool
    let copied: String?
    let onCopy: (String) -> Void

    private var outgoing: Bool { message.type == "sent" }

    var body: some View {
        let code = outgoing ? nil : SmsClassifier.code(in: message.body)
        HStack {
            if outgoing { Spacer(minLength: 80) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 6) {
                Text(message.body)
                    .font(SG.Font.body)
                    // Outgoing is a white fill with dark text, incoming a recessed
                    // grey — direction reads from value, not hue.
                    .foregroundColor(outgoing ? .black : .white)
                    .textSelection(.enabled)
                if let code {
                    CodeChip(code: code, copied: copied == code, onCopy: onCopy)
                }
                if showTime {
                    // Negative id = not yet confirmed by the phone.
                    Text(message.messageId < 0 ? "Sending…" : SmsTime.clock(message.date))
                        .font(.system(size: 10))
                        .foregroundColor(outgoing ? .black.opacity(0.5) : .sgTextSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(outgoing ? Color.white : Color.sgSurfaceHigh)
            )
            if !outgoing { Spacer(minLength: 80) }
        }
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.body, forType: .string)
            }
            if let code { Button("Copy Code") { onCopy(code) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(outgoing ? "Sent" : "Received"): \(message.body)")
    }
}
