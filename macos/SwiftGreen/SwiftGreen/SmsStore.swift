import Foundation
import Combine
import AppKit

struct SmsThread: Codable, Identifiable {
    var id: Int64 { threadId }
    let threadId: Int64
    let contactName: String?
    let phoneNumber: String
    let snippet: String
    let timestampMs: Int64
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case threadId    = "thread_id"
        case contactName = "contact_name"
        case phoneNumber = "phone_number"
        case snippet
        case timestampMs = "timestamp_ms"
        case unreadCount = "unread_count"
    }
}

struct SmsMessage: Codable, Identifiable {
    var id: Int64 { messageId }
    let messageId: Int64
    /// Only present on `sms_search_result` rows — `sms_thread_messages` omits it
    /// because the thread id is on the envelope instead.
    let threadId: Int64?
    let address: String
    let contactName: String?
    let body: String
    let timestampMs: Int64
    let type: String // "inbox" | "sent" | "other"

    enum CodingKeys: String, CodingKey {
        case messageId   = "message_id"
        case threadId    = "thread_id"
        case address
        case contactName = "contact_name"
        case body
        case timestampMs = "timestamp_ms"
        case type
    }
}

class SmsStore: ObservableObject {
    static let shared = SmsStore()

    @Published var threads: [SmsThread] = []
    @Published var messages: [Int64: [SmsMessage]] = [:]
    /// Threads with messages older than the oldest one loaded here ("Load earlier").
    @Published var hasOlder: [Int64: Bool] = [:]

    /// Outcome of the most recent send, cleared by the UI once shown.
    /// Was previously dropped on the floor — `sms_send_result` arrived and nothing
    /// consumed it, so a failed send looked identical to a successful one.
    @Published var lastSendResult: SendResult? = nil
    @Published var searchResults: [SmsMessage] = []
    @Published var isSearching: Bool = false
    /// Set by Calls ("Message" on a row); Messages opens a conversation to it.
    @Published var composeTo: String?

    struct SendResult: Equatable {
        let threadId: Int64
        let success: Bool
        let failureReason: String?
        let at: Date
    }

    private init() {
        #if DEBUG
        SmsClassifier.selfCheck()
        #endif
    }

    func recordSendResult(threadId: Int64, success: Bool, failureReason: String?) {
        lastSendResult = SendResult(threadId: threadId, success: success, failureReason: failureReason, at: Date())
        SGSound.play(success ? .sent : .failed)
    }

    func clearSendResult() {
        lastSendResult = nil
    }

    func replaceSearchResults(_ incoming: [SmsMessage]) {
        searchResults = incoming
        isSearching = false
    }

    func replaceThreads(_ incoming: [SmsThread]) {
        threads = incoming.sorted { $0.timestampMs > $1.timestampMs }
    }

    /// The latest page. `hasMore` is nil from phones that predate paging.
    func replaceMessages(threadId: Int64, incoming: [SmsMessage], hasMore: Bool? = nil) {
        let existing = messages[threadId] ?? []
        // Keep an optimistic "Sending…" bubble until the phone's own copy shows up
        // (it can lag the send by a few seconds), or a minute passes.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sentBodies = Set(incoming.filter { $0.type == "sent" }.map(\.body))
        let pending = existing.filter {
            $0.messageId < 0 && !sentBodies.contains($0.body) && now - $0.timestampMs < 60_000
        }
        // Keep what "Load earlier" fetched: everything older than this page. The
        // periodic refresh re-sends only the latest page and would otherwise wipe it.
        let incomingIds = Set(incoming.map(\.messageId))
        let oldestIncoming = incoming.map(\.timestampMs).min() ?? Int64.min
        let older = existing.filter { (m: SmsMessage) -> Bool in
            m.messageId >= 0 && !incomingIds.contains(m.messageId) && m.timestampMs < oldestIncoming
        }
        messages[threadId] = older + incoming + pending
        // Once older pages are loaded, the flag describes the oldest of them instead.
        if older.isEmpty, let hasMore { hasOlder[threadId] = hasMore }
    }

    /// A "Load earlier" page: merged in, never replacing what is already shown.
    func appendOlderMessages(threadId: Int64, incoming: [SmsMessage], hasMore: Bool) {
        let existing = messages[threadId] ?? []
        let known = Set(existing.map(\.messageId))
        messages[threadId] = incoming.filter { !known.contains($0.messageId) } + existing
        hasOlder[threadId] = hasMore
    }

    // MARK: Seen

    /// Newest message time the user has seen, per thread. Mac-side because only the
    /// default SMS app may mark messages read on Android; this keeps a thread you
    /// opened here from showing as unread until something newer arrives.
    @Published private var seen: [String: Int64] = UserDefaults.standard.dictionary(forKey: "sms_seen") as? [String: Int64] ?? [:]

    func isUnread(_ t: SmsThread) -> Bool {
        t.unreadCount > 0 && t.timestampMs > (seen[String(t.threadId)] ?? 0)
    }

    func markSeen(_ t: SmsThread) {
        guard t.threadId >= 0, isUnread(t) else { return }
        seen[String(t.threadId)] = t.timestampMs
        UserDefaults.standard.set(seen, forKey: "sms_seen")
    }

    /// Shown immediately on send; the next fetch replaces it with the phone's copy.
    func appendPending(threadId: Int64, to number: String, body: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        messages[threadId, default: []].append(SmsMessage(
            messageId: -now, threadId: threadId, address: number, contactName: nil,
            body: body, timestampMs: now, type: "sent"))
    }
}

// MARK: - Classification

/// What a thread is, judged from its sender and latest message. Promotions are
/// hidden by default so bank alerts and codes aren't buried under marketing.
enum SmsKind: Equatable {
    case personal
    case code(String)   // one-time password, extracted
    case alert          // bank, delivery, bills: transactional but not a code
    case promotion
}

enum SmsClassifier {
    /// Indian DLT sender headers: "VM-HDFCBK-S". The TRAI suffix says what the
    /// sender registered as: P promotional, S service, T transactional, G government.
    private static let header = try! NSRegularExpression(pattern: #"^[A-Z]{2}-([A-Za-z0-9]{3,})(?:-([PSTG]))?$"#)
    private static let otpWords = try! NSRegularExpression(
        pattern: #"\b(otp|one[- ]?time|verification|verify|passcode|pass code|code|two[- ]factor|2fa|authenticat\w*|log ?in|sign[- ]?in)\b"#,
        options: .caseInsensitive)
    /// Digits touching - / : . , are dates, times, amounts or phone fragments, not codes.
    private static let digits = try! NSRegularExpression(pattern: #"(?<![\d.,\-/:]|\d )\d{4,8}(?![\d.,\-/:]| \d)"#)
    /// "spent … without using OTP/PIN" names OTP without containing one.
    private static let negatedOtp = try! NSRegularExpression(
        pattern: #"without (using )?(an? )?otp"#, options: .caseInsensitive)
    private static let moneyOrCard = try! NSRegularExpression(
        pattern: #"(rs\.?|inr|₹|x{2,}|\*{2,}|a/c|ac no\.?|card)\s*$"#, options: .caseInsensitive)
    private static let alertWords = try! NSRegularExpression(
        pattern: #"\b(debited|credited|a/c|acct|txn|transaction|balance|due|paid|payment|received|order|delivered|shipped|dispatched|booking|booked|pnr|ticket|bill|refund|emi|statement|appointment)\b"#,
        options: .caseInsensitive)
    private static let promoWords = try! NSRegularExpression(
        pattern: #"(\d+\s?% off|\boffer|\bsale\b|discount|cashback|coupon|\bdeal|\bwin\b|\bfree\b|hurry|limited (time|period)|shop now|buy now|apply now|pre-?approved|exclusive|unsubscribe|opt[- ]out|lowest|\bflat \d|up ?to \d+%|click|recharge now|\bt&c|\bloan\b|credit limit (increase|enhance)|\bupgrade\b)"#,
        options: .caseInsensitive)

    static func isPhoneNumber(_ sender: String) -> Bool {
        sender.filter(\.isNumber).count >= 10 && sender.allSatisfy { $0.isNumber || "+ -()".contains($0) }
    }

    /// "VM-HDFCBK-S" → "HDFCBK". Anything else is returned as-is.
    static func senderName(_ sender: String) -> String {
        let r = NSRange(sender.startIndex..., in: sender)
        guard let m = header.firstMatch(in: sender, range: r),
              let brand = Range(m.range(at: 1), in: sender) else { return sender }
        return String(sender[brand])
    }

    /// The code in an OTP message, or nil. Skips amounts ("Rs 5000") and masked
    /// card/account numbers ("XX1234"), which are also 4–8 digits.
    static func code(in body: String) -> String? {
        let text = negatedOtp.stringByReplacingMatches(
            in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
        let r = NSRange(text.startIndex..., in: text)
        let keywords = otpWords.matches(in: text, range: r).map(\.range)
        guard !keywords.isEmpty else { return nil }
        // The code nearest a keyword, and near it at all: a long alert can say
        // "OTP" in one sentence and carry an unrelated number three sentences on.
        var best: (code: String, distance: Int)?
        for m in digits.matches(in: text, range: r) {
            guard let range = Range(m.range, in: text) else { continue }
            let before = String(text[..<range.lowerBound].suffix(8))
            if moneyOrCard.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil { continue }
            let distance = keywords.map { k in
                max(0, max(k.location - NSMaxRange(m.range), m.range.location - NSMaxRange(k)))
            }.min() ?? .max
            if distance <= 60, distance < (best?.distance ?? .max) { best = (String(text[range]), distance) }
        }
        return best?.code
    }

    static func classify(sender: String, body: String, isContact: Bool) -> SmsKind {
        if let otp = code(in: body) { return .code(otp) }
        let r = NSRange(sender.startIndex..., in: sender)
        let b = NSRange(body.startIndex..., in: body)
        if isContact { return .personal }
        if isPhoneNumber(sender) {
            // Spam also comes from ordinary mobile numbers. A stranger's text with a
            // link *and* sales words is marketing; a friend's "are you free?" isn't.
            let hasLink = body.range(of: #"https?://|www\.|bit\.ly"#, options: [.regularExpression, .caseInsensitive]) != nil
            return hasLink && promoWords.firstMatch(in: body, range: b) != nil ? .promotion : .personal
        }
        if let m = header.firstMatch(in: sender, range: r), let suffix = Range(m.range(at: 2), in: sender) {
            switch sender[suffix] {
            case "P": return .promotion
            case "T", "G": return .alert
            default: break   // "S" (service) is where banks send loan offers too: let the text decide
            }
        }
        if alertWords.firstMatch(in: body, range: b) != nil { return .alert }
        if promoWords.firstMatch(in: body, range: b) != nil { return .promotion }
        return .alert   // unknown business sender: show it rather than risk hiding something real
    }

    #if DEBUG
    /// Runs once at launch in Debug builds, and in the unit tests (SelfCheckTests).
    static func selfCheck() {
        assert(code(in: "123456 is your OTP for login. Do not share.") == "123456")
        assert(code(in: "Rs 5000 debited from A/c XX1234. OTP 4821 to confirm") == "4821")
        assert(code(in: "Your a/c XX1234 credited with Rs 2500") == nil)
        assert(classify(sender: "VM-AMAZON-P", body: "Flat 50% off today", isContact: false) == .promotion)
        assert(classify(sender: "AX-HDFCBK-S", body: "Rs 250 debited", isContact: false) == .alert)
        assert(classify(sender: "JIOMKT", body: "Hurry! Get 2GB free, click here", isContact: false) == .promotion)
        assert(classify(sender: "+919876543210", body: "See you at 8?", isContact: false) == .personal)
        assert(classify(sender: "+919876543210", body: "Are you free tonight?", isContact: false) == .personal)
        assert(classify(sender: "+919812345678", body: "Get 90% off, click https://x.co/a", isContact: false) == .promotion)
        assert(senderName("VM-HDFCBK-S") == "HDFCBK")
        assert(senderName("JX-aCMEco-S") == "aCMEco")
        assert(code(in: "Log in to the app or call 1800 425 3800 for help") == nil)
        assert(code(in: "Use 494095 for two-factor authentication on your Meta account.") == "494095")
        assert(classify(sender: "VM-HDFCBN-S", body: "A Personal Loan facility has been enabled for you", isContact: false) == .promotion)
        assert(classify(sender: "VM-HDFCBN-S", body: "Loan EMI of Rs 5000 debited from a/c", isContact: false) == .alert)
        // Real alert that named OTP and carried a date: not a code.
        assert(code(in: "ALERT: You have spent USD 23.60 at X using your card (xx1234) on 13-09-2026 without using OTP/PIN. Limit INR 50,000.00. Call 02200000000") == nil)
        assert(code(in: "682598 is OTP for txn of INR 206.00 at ZEPTO") == "682598")
    }
    #endif
}

extension SmsThread {
    var kind: SmsKind { SmsClassifier.classify(sender: phoneNumber, body: snippet, isContact: contactName != nil) }
    var displayName: String { contactName ?? SmsClassifier.senderName(phoneNumber) }
    /// Inbox = people and one-time codes.
    var isInbox: Bool {
        switch kind {
        case .personal, .code: true
        case .alert, .promotion: false
        }
    }
    /// Business senders (alphanumeric IDs, short codes) can't receive replies.
    var acceptsReplies: Bool { contactName != nil || SmsClassifier.isPhoneNumber(phoneNumber) }
}
