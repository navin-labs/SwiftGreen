import Foundation
import Combine

class AppFilterStore: ObservableObject {
    static let shared = AppFilterStore()

    struct AppEntry: Identifiable, Codable {
        var id: String { packageName }
        let packageName: String
        let appName: String
        let iconBase64: String?
        var blocked: Bool
    }

    @Published var apps: [AppEntry] = []

    private let cacheKey = "appFilterList"

    private init() {
        load()
    }

    func updateFromAndroid(_ list: [[String: Any]]) {
        var entries: [AppEntry] = []
        for item in list {
            guard let pkg = item["package_name"] as? String,
                  let name = item["app_name"] as? String else { continue }
            let icon = item["icon_base64"] as? String
            let blocked = item["blocked"] as? Bool ?? false
            entries.append(AppEntry(
                packageName: pkg,
                appName: name,
                iconBase64: icon,
                blocked: blocked
            ))
        }
        entries.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        apps = entries
        persist()
    }

    func setBlocked(packageName: String, blocked: Bool) {
        if let idx = apps.firstIndex(where: { $0.packageName == packageName }) {
            apps[idx].blocked = blocked
            persist()
        }
        mDNSQuicServer.activeServer?.sendAppFilterUpdate(packageName: packageName, blocked: blocked)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([AppEntry].self, from: data) else { return }
        apps = decoded
    }
}
