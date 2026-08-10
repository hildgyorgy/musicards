import Foundation

nonisolated final class RemoteDestinationStore {
    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "MusiCardsSync.RemoteDestinations"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> [DestinationProfile] {
        guard let data = userDefaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode(
                [DestinationProfile].self,
                from: data
              ) else {
            return []
        }

        return profiles.filter { $0.kind == .remote }
    }

    func save(_ profiles: [DestinationProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        userDefaults.set(data, forKey: key)
    }
}
