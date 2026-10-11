import SwiftUI
import AppKit
import Combine

// MARK: - Suggestion

struct Suggestion: Identifiable {
    let id: String
    let glyph: String
    let title: String
    let detail: String
    let actionLabel: String
    let run: () -> Void
}

// MARK: - Suggestion Engine

/// Rule-based suggestions over real usage data.
///
/// ponytail: explicit rules, not a model. Every suggestion here can be traced to a
/// count the user could verify themselves, and each one has a concrete action
/// attached. A suggestion the user can't act on is just a notification with extra
/// steps, so anything that would only *describe* usage lives in Insights instead.
enum SuggestionEngine {

    static func suggestions(
        clipboard: [ClipboardRecord],
        notifications: [NotificationHistoryManager.NotificationRecord],
        calls: [CallLogRecord],
        transfers: [FileTransferReceiver.TransferRecord],
        onNavigate: @escaping (Tab) -> Void
    ) -> [Suggestion] {
        var out: [Suggestion] = []

        // A missed call in the last two days that hasn't been returned: no call either
        // way with that person since. Favourites belong to the Calls tab, not here.
        let since = Int64(Date().addingTimeInterval(-48 * 3600).timeIntervalSince1970 * 1000)
        let byPerson = Dictionary(grouping: calls.filter { !$0.phoneNumber.isEmpty }) {
            ContactsStore.matchKey($0.phoneNumber)
        }
        let unreturned = byPerson.compactMap { key, records -> (key: String, missed: [CallLogRecord])? in
            let missed = records.filter { $0.callType.lowercased() == "missed" && $0.timestamp > since }
            guard let last = missed.map(\.timestamp).max(),
                  !records.contains(where: { $0.callType.lowercased() != "missed" && $0.timestamp > last })
            else { return nil }
            return (key, missed.sorted { $0.timestamp > $1.timestamp })
        }
        if let latest = unreturned.max(by: { $0.missed[0].timestamp < $1.missed[0].timestamp }) {
            let record = latest.missed[0]
            let name = record.contactName ?? record.phoneNumber
            let date = Date(timeIntervalSince1970: TimeInterval(record.timestamp) / 1000)
            // 24-hour, like every other time in the app.
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            let clock = f.string(from: date)
            let when = Calendar.current.isDateInToday(date) ? "today at \(clock)" : "yesterday at \(clock)"
            out.append(Suggestion(
                id: "callback-\(latest.key)-\(record.timestamp)",
                glyph: "phone.arrow.down.left",
                title: "Call back \(name)",
                detail: latest.missed.count > 1
                    ? "Tried you \(latest.missed.count) times, last \(when). Not returned yet."
                    : "Missed \(when). Not returned yet.",
                actionLabel: "Call back"
            ) {
                // Fills the keypad; the call itself is still one deliberate press.
                CallLogStore.shared.dialTo = record.phoneNumber
                onNavigate(.calls)
            })
        }

        // An app producing more than a third of all notifications.
        let appTally = Dictionary(grouping: notifications, by: \.appName).mapValues(\.count)
        if notifications.count >= 12,
           let (app, count) = appTally.max(by: { $0.value < $1.value }),
           Double(count) / Double(notifications.count) > 0.34 {
            out.append(Suggestion(
                id: "mute-\(app)",
                glyph: "line.3.horizontal.decrease",
                title: "Filter \(app) notifications",
                detail: "\(app) is \(Int(Double(count) / Double(notifications.count) * 100))% of everything mirrored.",
                actionLabel: "Open filters"
            ) {
                onNavigate(.filters)
            })
        }

        // Unpinned clipboard entry that keeps coming back.
        let textTally = Dictionary(grouping: clipboard, by: \.text).mapValues(\.count)
        if let (text, count) = textTally
            .filter({ $0.value >= 3 && !($0.key.isEmpty) })
            .max(by: { $0.value < $1.value }),
           !clipboard.contains(where: { $0.text == text && $0.pinned }),
           let record = clipboard.first(where: { $0.text == text }) {
            out.append(Suggestion(
                id: "pin-\(record.id)",
                glyph: "bookmark",
                title: "Pin a repeated clipping",
                detail: "You've copied this \(count) times.",
                actionLabel: "Pin"
            ) {
                ClipboardSyncManager.shared.togglePin(id: record.id)
            })
        }

        // Most recent transfer failed and the file is still on disk.
        if let failed = transfers.first, failed.state != "complete", failed.state != "sent",
           !failed.path.isEmpty,
           FileManager.default.fileExists(atPath: failed.path) {
            out.append(Suggestion(
                id: "retry-\(failed.id)",
                glyph: "arrow.clockwise",
                title: "Retry \(failed.filename)",
                detail: "The last transfer didn't finish.",
                actionLabel: "Retry"
            ) {
                if let server = mDNSQuicServer.activeServer {
                    FileTransferSender.shared.sendFile(
                        at: URL(fileURLWithPath: failed.path), via: server)
                }
            })
        }

        return out
    }
}

// MARK: - Suggestions Strip

struct SuggestionsStrip: View {
    let suggestions: [Suggestion]
    /// Newline-joined ids. Persisted: a dismissed suggestion that returns on the next
    /// visit isn't dismissed, it's nagging. New events mint new ids, so a fresh
    /// missed call or failed transfer still comes through.
    @AppStorage("activity_dismissed_suggestions") private var dismissedRaw = ""

    private var dismissed: Set<String> { Set(dismissedRaw.split(separator: "\n").map(String.init)) }

    private var visible: [Suggestion] {
        suggestions.filter { !dismissed.contains($0.id) }
    }

    private func dismiss(_ id: String) {
        withAnimation(SG.Motion.quick) { dismissedRaw = (dismissed.union([id])).sorted().joined(separator: "\n") }
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: SG.Space.sm) {
                Text("Suggestions")
                    .font(SG.Font.section)
                    .foregroundColor(.white)

                ForEach(visible) { suggestion in
                    HStack(spacing: SG.Space.md) {
                        Image(systemName: suggestion.glyph)
                            .font(.system(size: 14))
                            .foregroundColor(.sgTextSecondary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(SG.Font.rowTitle)
                                .foregroundColor(.white)
                            Text(suggestion.detail)
                                .font(SG.Font.caption)
                                .foregroundColor(.sgTextSecondary)
                        }

                        Spacer()

                        SGSecondaryButton(title: suggestion.actionLabel) {
                            suggestion.run()
                            dismiss(suggestion.id)
                        }

                        Button {
                            dismiss(suggestion.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                                .foregroundColor(.sgTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss suggestion")
                    }
                    .padding(.horizontal, SG.Space.md)
                    .padding(.vertical, SG.Space.md)
                    .sgHoverRow(base: .sgSurfaceHigh, hovered: .sgSurfaceHigh)
                }
            }
            .sgCard()
        }
    }
}

// MARK: - Milestones

/// Subtle celebration at round numbers. Deliberately restrained: a one-line
/// banner that auto-dismisses, no confetti, no sound. This is a background sync
/// daemon — a milestone should feel like a nod, not an interruption.
final class MilestoneTracker: ObservableObject {
    static let shared = MilestoneTracker()

    @Published var current: String? = nil

    private let countKey = "swiftgreen_transfer_count"
    private let firedKey = "swiftgreen_fired_milestones"
    private let thresholds = [1, 10, 50, 100, 500, 1000]

    private init() {}

    func recordTransfer() {
        let count = UserDefaults.standard.integer(forKey: countKey) + 1
        UserDefaults.standard.set(count, forKey: countKey)

        guard thresholds.contains(count) else { return }
        var fired = Set(UserDefaults.standard.stringArray(forKey: firedKey) ?? [])
        guard !fired.contains("\(count)") else { return }
        fired.insert("\(count)")
        UserDefaults.standard.set(Array(fired), forKey: firedKey)

        current = count == 1
            ? "First file transferred"
            : "\(count) files transferred"

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.current != nil { self?.current = nil }
        }
    }
}

struct MilestoneBanner: View {
    @ObservedObject private var tracker = MilestoneTracker.shared

    var body: some View {
        if let message = tracker.current {
            HStack(spacing: SG.Space.sm) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 14))
                    .foregroundColor(.sgBackground)
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sgBackground)
            }
            .padding(.horizontal, SG.Space.lg)
            .padding(.vertical, SG.Space.md)
            .background(Color.white)
            .clipShape(Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(message)
        }
    }
}
