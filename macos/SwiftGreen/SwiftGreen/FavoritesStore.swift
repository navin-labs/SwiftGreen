import Foundation
import Combine

/// Starred phone numbers, kept local to the Mac.
///
/// ponytail: a Set<String> in UserDefaults. Favourites are a handful of numbers
/// that never need querying, ordering or syncing — a store with its own schema
/// and a sync message type would be pure ceremony.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var numbers: Set<String> = []

    private let key = "swiftgreen_favorite_numbers"

    private init() {
        numbers = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// Compared on `ContactsStore.matchKey`, not on the raw string: the call log
    /// hands us "+15555550123" where the address book hands us "+1 555-555-0123",
    /// so an exact match had the same person starred in Recent and unstarred in
    /// Contacts. What gets *stored* is still the number as it was starred, so it
    /// stays dialable — only membership is normalised.
    ///
    /// ponytail: a linear scan. Favourites are a handful of numbers; an index
    /// keyed by matchKey would be a second copy to keep in sync for no gain.
    func isFavorite(_ number: String) -> Bool {
        let id = ContactsStore.matchKey(number)
        return numbers.contains { ContactsStore.matchKey($0) == id }
    }

    func toggle(_ number: String) {
        let id = ContactsStore.matchKey(number)
        if let existing = numbers.first(where: { ContactsStore.matchKey($0) == id }) {
            numbers.remove(existing)
        } else {
            numbers.insert(number)
        }
        UserDefaults.standard.set(Array(numbers), forKey: key)
    }
}
