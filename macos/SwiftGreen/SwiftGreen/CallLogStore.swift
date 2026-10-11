import AppKit
import Foundation
import Combine

struct CallLogRecord: Codable, Identifiable {
    var id: String { "\(phoneNumber)-\(timestamp)" }
    let phoneNumber: String
    let contactName: String?
    let callType: String
    let timestamp: Int64
    let durationSeconds: Int
    let source: String

    enum CodingKeys: String, CodingKey {
        case phoneNumber     = "phone_number"
        case contactName     = "contact_name"
        case callType        = "call_type"
        case timestamp
        case durationSeconds = "duration_seconds"
        case source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phoneNumber = try c.decode(String.self, forKey: .phoneNumber)
        contactName = try c.decodeIfPresent(String.self, forKey: .contactName)
        callType = try c.decode(String.self, forKey: .callType)
        timestamp = try c.decode(Int64.self, forKey: .timestamp)
        durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "cellular"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phoneNumber, forKey: .phoneNumber)
        try c.encodeIfPresent(contactName, forKey: .contactName)
        try c.encode(callType, forKey: .callType)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        if source != "cellular" { try c.encode(source, forKey: .source) }
    }
}

class CallLogStore: ObservableObject {
    static let shared = CallLogStore()

    @Published var calls: [CallLogRecord] = []

    /// Live call pushed from Android — "ringing", "dialing" or "offhook"; nil when idle.
    /// Deliberately not persisted: a stale call banner after a restart would be a lie.
    @Published var liveCallState: String? {
        // Every path that clears the banner (idle, hangup timeout, disconnect) also
        // drops the WhatsApp tag, so a later cellular call never inherits it.
        didSet { if liveCallState == nil { liveCallApp = nil; liveCallKey = nil; liveCallPhoto = nil } }
    }
    @Published var liveCallNumber = ""
    @Published var liveCallName: String?
    /// "WhatsApp" for a WhatsApp call mirrored off the phone's notification; nil for a
    /// cellular call. Its controls press the notification's own buttons on the phone.
    @Published var liveCallApp: String?
    var liveCallKey: String?
    /// The caller's picture from the app's call notification, when it has one.
    @Published var liveCallPhoto: NSImage?
    /// A number another tab wants on the keypad. Consumed (and cleared) by the Calls tab.
    @Published var dialTo: String?
    /// Set by another tab to land the Calls tab on Missed. Consumed on arrival.
    @Published var openMissed = false

    /// Missed calls newer than the seen mark. Before anything has been marked seen,
    /// only the last day counts. Shared by the Calls badge and the Overview.
    func unseenMissed(seenMs: Int) -> [CallLogRecord] {
        let cutoff = seenMs > 0 ? seenMs : Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000)
        return calls.filter { $0.callType.lowercased() == "missed" && Int($0.timestamp) > cutoff }
    }

    private let prefsKey = "swiftgreen_call_log"

    private init() { load() }

    /// Applies a confirmed mute result. On failure the toggle stays where it was:
    /// showing "Muted" when the mic is actually live is the worst outcome here.
    func applyAudioResult(action: String, success: Bool, enabled: Bool, error: String?) {
        guard action == "mute" else { return }
        mutePending = false
        guard success else {
            audioNotice = error == "not_applied"
                ? "Your phone wouldn't let SwiftGreen mute this call."
                : "Mute failed (\(error ?? "unknown"))."
            return
        }
        audioNotice = nil
        isMuted = enabled
    }

    /// Called when the toggle is sent, so the UI can show in-flight and recover if the
    /// phone never answers — the same gap that let a failed reply look delivered.
    func markMutePending() {
        mutePending = true
        audioNotice = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.mutePending else { return }
            self.mutePending = false
            self.audioNotice = "No response from your phone for mute."
        }
    }

    /// Mic-mute, as last confirmed by the phone. Never set optimistically — see
    /// `applyAudioResult`.
    @Published var isMuted = false
    /// In-flight toggle, so a tap shows feedback and can't be double-sent.
    @Published var mutePending = false
    /// Why the phone refused the toggle.
    @Published var audioNotice: String?

    /// In-flight hangup/decline, mirrors `mutePending` — set on tap, cleared on the
    /// next call_state (normally "idle") or by the timeout in `markHangupPending`.
    @Published var hangupPending = false
    /// Set only when a hangup timed out with no idle confirmation — the call may
    /// still be connected, so the banner must not silently read as ended.
    @Published var callEndNotice: String?

    /// `state` is the raw wire value; "idle" clears the banner.
    func updateLiveCall(state: String, number: String, name: String?) {
        // Only these two retire a pending hangup. A duplicate "offhook" — routine on
        // dual-SIM handsets, which broadcast PHONE_STATE per subscription — would
        // otherwise kill the 6s timeout early and leave nothing to recover the banner.
        // "ringing" is a different call, so the old hangup no longer applies either.
        if state == "idle" || state == "ringing" { hangupPending = false }
        if state == "idle" {
            liveCallState = nil
            liveCallNumber = ""
            liveCallName = nil
            // The mute toggle belongs to the call that just ended.
            isMuted = false
            mutePending = false
            audioNotice = nil
            callEndNotice = nil
            return
        }
        callEndNotice = nil
        liveCallState = state
        liveCallNumber = number
        // Android resolves the name only on ringing/dialing; keep the one we have
        // rather than blanking the banner when offhook arrives with a null name.
        if let name, !name.isEmpty { liveCallName = name }
    }

    func updateAppCall(app: String, state: String, name: String, key: String, photo: NSImage? = nil) {
        // A real cellular call (it has a number) owns the banner. A numberless one is this
        // same VoIP call as the phone's call state saw it, so WhatsApp takes it over.
        if liveCallApp == nil, liveCallState != nil, !liveCallNumber.isEmpty, state != "idle" { return }
        if state == "idle" {
            guard liveCallKey == key else { return }
            updateLiveCall(state: "idle", number: "", name: nil)
            return
        }
        liveCallApp = app
        liveCallKey = key
        if let photo { liveCallPhoto = photo }
        updateLiveCall(state: state, number: "", name: name.isEmpty ? nil : name)
    }

    /// Called when hangup/decline is sent, so the UI can show "Ending…" and recover if
    /// the phone never confirms — the same gap that could otherwise leave a stale
    /// "Calling" banner forever. Mirrors `markMutePending`'s 6s timeout.
    func markHangupPending() {
        hangupPending = true
        callEndNotice = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.hangupPending else { return }
            self.hangupPending = false
            // No idle arrived — clear the banner rather than leave it stuck, but
            // don't claim the call ended when we don't actually know that.
            self.liveCallState = nil
            self.liveCallNumber = ""
            self.liveCallName = nil
            self.isMuted = false
            self.mutePending = false
            self.audioNotice = nil
            self.callEndNotice = "No response from your phone — the call may still be active."
        }
    }

    /// The tunnel dropped while a call banner was up. The call may well still be
    /// running on the phone — we just can't see it any more — so the banner has to go
    /// (its buttons would silently do nothing) while the notice says what we actually
    /// know. Silently blanking to idle would be a lie in the other direction.
    func clearLiveCallOnDisconnect() {
        guard liveCallState != nil || hangupPending else { return }
        hangupPending = false
        liveCallState = nil
        liveCallNumber = ""
        liveCallName = nil
        isMuted = false
        mutePending = false
        audioNotice = nil
        callEndNotice = "Phone disconnected — call state unknown."
    }

    func replace(_ records: [CallLogRecord]) {
        // Dedup incoming records against themselves by source-specific key
        var incomingDeduped = [String: CallLogRecord]()
        for record in records {
            let key = record.source == "whatsapp"
                ? "whatsapp:\(record.contactName ?? ""):\(record.timestamp)"
                : "cellular:\(record.phoneNumber):\(record.timestamp)"
            incomingDeduped[key] = record
        }

        // Dedup keys of incoming records
        let incomingKeys = Set(incomingDeduped.keys)

        // A cellular sync is the phone's latest rows, contiguous by date. Inside that window
        // an absent row was deleted on the phone, so it goes here too; older rows are kept
        // (they're just outside the 50). WhatsApp-only pushes carry no cellular rows and
        // prune nothing. ponytail: clearing the phone's whole log sends an empty sync,
        // indistinguishable from "nothing new", so that one case isn't mirrored.
        let syncedFrom = records.filter { $0.source != "whatsapp" }.map(\.timestamp).min()

        // Preserve existing records not matching any incoming dedup key
        let preserved = calls.filter { existing in
            let key = existing.source == "whatsapp"
                ? "whatsapp:\(existing.contactName ?? ""):\(existing.timestamp)"
                : "cellular:\(existing.phoneNumber):\(existing.timestamp)"
            if existing.source != "whatsapp", let syncedFrom, existing.timestamp >= syncedFrom { return false }
            return !incomingKeys.contains(key)
        }

        // Merge, cap per-source at 200, sort by timestamp descending
        var merged = preserved + Array(incomingDeduped.values)
        let cellularCount = merged.filter { $0.source == "cellular" }.count
        let whatsappCount = merged.filter { $0.source == "whatsapp" }.count

        if cellularCount > 200 {
            let cellular = merged.filter { $0.source == "cellular" }.sorted { $0.timestamp > $1.timestamp }
            let kept = Set(cellular.prefix(200).map { $0.phoneNumber + String($0.timestamp) })
            merged = merged.filter { r in
                r.source != "cellular" || kept.contains(r.phoneNumber + String(r.timestamp))
            }
        }
        if whatsappCount > 200 {
            let whatsapp = merged.filter { $0.source == "whatsapp" }.sorted { $0.timestamp > $1.timestamp }
            let kept = Set(whatsapp.prefix(200).map { (r: CallLogRecord) -> String in
                (r.contactName ?? "") + String(r.timestamp)
            })
            merged = merged.filter { r in
                r.source != "whatsapp" || kept.contains((r.contactName ?? "") + String(r.timestamp))
            }
        }

        calls = merged.sorted { $0.timestamp > $1.timestamp }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(calls) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let decoded = try? JSONDecoder().decode([CallLogRecord].self, from: data) else { return }
        calls = decoded
    }
}

// MARK: - Contacts
// Lives here rather than in its own file because contacts exist on the Mac purely to
// serve the dialer — searching for someone and putting a name on a number.

struct MacContact: Codable, Identifiable {
    let id: Int64
    let displayName: String
    let phoneNumbers: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName  = "display_name"
        case phoneNumbers = "phone_numbers"
    }
}

class ContactsStore: ObservableObject {
    static let shared = ContactsStore()

    @Published var contacts: [MacContact] = []

    /// A contacts request is outstanding. Callers should pair this with "and the list is
    /// still empty" before showing anything: the Calls tab re-requests on every
    /// appearance by design, and a refresh over contacts already on screen should be
    /// silent rather than blanking them behind a placeholder.
    @Published private(set) var isLoading = false

    /// Tells one request's timeout from the next. Without it, an earlier visit's timer
    /// fires six seconds later and clears the flag out from under a request that has
    /// only just gone out — easy to hit, since every tab visit starts another.
    private var loadToken = 0

    /// A contacts response has landed at least once, ever. "Never synced" and "synced,
    /// and the address book really is empty" both leave `contacts` empty, but they mean
    /// opposite things about whether anything is wrong — this is what tells them apart.
    /// Persisted, because the distinction has to survive a relaunch to be worth making.
    @Published private(set) var hasSyncedOnce = false

    private var nameByNumber: [String: String] = [:]
    private let prefsKey = "swiftgreen_contacts"
    private let syncedKey = "swiftgreen_contacts_synced"

    private init() { load() }

    /// Called where the request is *sent*, not where it is answered — the send is the
    /// only moment that knows a request now exists.
    ///
    /// ponytail: 6s, mirroring CallLogStore.markMutePending rather than inventing a
    /// second convention. A timeout is needed at all because sendMessage drops silently
    /// when no connection is up, so "no answer ever" is a real outcome here, not merely
    /// a slow one — without this the placeholder would sit there forever.
    func markLoading() {
        isLoading = true
        loadToken += 1
        let token = loadToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.isLoading, self.loadToken == token else { return }
            self.isLoading = false
        }
    }

    /// Last 10 digits, ignoring spaces, dashes and country code. Enough to match
    /// "+91 98765 43210" against "9876543210" without pulling in a phone-number
    /// library. Short codes (bank OTP senders, 121) keep whatever digits they have.
    static func matchKey(_ number: String) -> String {
        String(number.filter(\.isNumber).suffix(10))
    }

    func replace(_ incoming: [MacContact]) {
        // Cleared on any response, including an empty one — the phone answering with no
        // contacts is an answer, and continuing to claim "loading" would be a lie.
        isLoading = false
        // Same reasoning, same moment: replace() running at all means a response landed,
        // so the address book has been seen whether or not it had anything in it.
        hasSyncedOnce = true
        contacts = incoming.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        reindex()
        persist()
    }

    /// Contact name for a dialled or incoming number, nil if not in the address book.
    func name(for number: String) -> String? {
        let key = Self.matchKey(number)
        guard !key.isEmpty else { return nil }
        return nameByNumber[key]
    }

    /// Name-or-number, for display anywhere a raw number would otherwise show.
    func label(for number: String) -> String {
        name(for: number) ?? number
    }

    /// Matches on name or on digits, so "priya" and "98765" both work.
    func search(_ query: String) -> [MacContact] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let digits = trimmed.filter(\.isNumber)
        return contacts.filter { contact in
            if contact.displayName.localizedCaseInsensitiveContains(trimmed) { return true }
            guard !digits.isEmpty else { return false }
            return contact.phoneNumbers.contains { $0.filter(\.isNumber).contains(digits) }
        }
    }

    private func reindex() {
        nameByNumber = [:]
        for contact in contacts where !contact.displayName.isEmpty {
            for number in contact.phoneNumbers {
                let key = Self.matchKey(number)
                // First writer wins: contacts are sorted by name, so collisions
                // between two people sharing a landline resolve stably.
                if !key.isEmpty, nameByNumber[key] == nil {
                    nameByNumber[key] = contact.displayName
                }
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(hasSyncedOnce, forKey: syncedKey)
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }

    private func load() {
        // Read before the guard below, deliberately: it is independent of whether any
        // contact data decoded, and the case it exists to describe — a phone that
        // answered with an empty address book — is one where there is nothing to decode.
        hasSyncedOnce = UserDefaults.standard.bool(forKey: syncedKey)
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let decoded = try? JSONDecoder().decode([MacContact].self, from: data) else { return }
        contacts = decoded
        reindex()
    }
}
