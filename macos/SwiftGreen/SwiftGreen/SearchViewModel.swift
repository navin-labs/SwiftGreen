import Foundation
import Combine

class SearchViewModel: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var searchResults: SearchResults = .empty

    struct SearchResults {
        var notifications: [NotificationHistoryManager.NotificationRecord] = []
        var clipboardEntries: [ClipboardRecord] = []
        var fileTransfers: [FileTransferReceiver.TransferRecord] = []
        static let empty = SearchResults()
    }

    private var cancellable: AnyCancellable?

    init() {
        cancellable = $searchQuery
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] query in self?.performSearch(query) }
    }

    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            searchResults = .empty
            return
        }
        let q = query.lowercased()
        let notifications = NotificationHistoryManager.shared.history
        let clipboard = ClipboardSyncManager.shared.history
        let transfers = FileTransferReceiver.shared.transferHistory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let filteredNotifications = notifications
                .filter {
                    $0.appName.lowercased().contains(q) ||
                    $0.title.lowercased().contains(q) ||
                    $0.body.lowercased().contains(q)
                }
                .sorted { $0.timestampMs > $1.timestampMs }

            let filteredClipboard = clipboard
                .filter { $0.text.lowercased().contains(q) }
                .sorted { $0.timestampMs > $1.timestampMs }

            let filteredTransfers = transfers
                .filter { $0.filename.lowercased().contains(q) }
                .sorted { $0.date > $1.date }

            DispatchQueue.main.async {
                self?.searchResults = SearchResults(
                    notifications: filteredNotifications,
                    clipboardEntries: filteredClipboard,
                    fileTransfers: filteredTransfers
                )
            }
        }
    }
}
