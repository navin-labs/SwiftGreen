import Foundation
import Combine

struct SimInfo: Identifiable, Codable {
    var id: Int { subscriptionId }
    let subscriptionId: Int
    let simSlotIndex: Int
    let displayName: String
    let carrierName: String
}

enum SimAction: String {
    case sms
    case dial
}

class SimStore: ObservableObject {
    static let shared = SimStore()

    @Published var sims: [SimInfo] = []

    // No seeded SIMs, in any build configuration. Fabricated subscription ids used to
    // leak into the dial path here: they match no real PhoneAccountHandle on the phone,
    // so Android silently fell back to the default SIM while the Mac reported success —
    // which made every SIM-routing test on a Debug build meaningless.
    private init() {}

    func update(from json: [[String: Any]]) {
        sims = json.compactMap { entry in
            guard let subscriptionId = entry["subscription_id"] as? Int else { return nil }
            return SimInfo(
                subscriptionId: subscriptionId,
                simSlotIndex: entry["sim_slot_index"] as? Int ?? -1,
                displayName: entry["display_name"] as? String ?? "",
                carrierName: entry["carrier_name"] as? String ?? ""
            )
        }
    }

    /// `id` if it's one of the SIMs the phone last reported, else nil. An id with no SIM
    /// behind it fails the SMS on the phone (RESULT_USER_NOT_ALLOWED): a stale last-used
    /// pick, or a made-up default. Without an id the phone sends from its default SIM.
    func reported(_ id: Int?) -> Int? {
        guard let id, sims.contains(where: { $0.subscriptionId == id }) else { return nil }
        return id
    }

    /// The SIM to have selected for `action` once the phone reports `sims`: the current pick
    /// if the phone still has it, else the last one used for this action if it still has
    /// that, else its first SIM. Unchanged until the phone has reported any SIMs. Takes the
    /// list explicitly because `$sims` publishes before `sims` itself changes.
    func selection(keeping current: Int?, for action: SimAction, in sims: [SimInfo]) -> Int? {
        let ids = sims.map(\.subscriptionId)
        guard !ids.isEmpty else { return current }
        if let current, ids.contains(current) { return current }
        if let last = lastUsedSubscriptionId(for: action), ids.contains(last) { return last }
        return ids.first
    }

    func lastUsedSubscriptionId(for action: SimAction) -> Int? {
        let key = "lastUsedSim.\(action.rawValue)"
        let value = UserDefaults.standard.integer(forKey: key)
        return value == 0 ? nil : value
    }

    func setLastUsed(_ subscriptionId: Int, for action: SimAction) {
        UserDefaults.standard.set(subscriptionId, forKey: "lastUsedSim.\(action.rawValue)")
    }
}
