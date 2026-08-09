import Foundation

final class SyncConfigurationStore {

    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "MusiCardsSync.Configuration"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> SyncConfiguration {
        guard
            let data = userDefaults.data(forKey: key),
            let configuration = try? JSONDecoder().decode(
                SyncConfiguration.self,
                from: data
            )
        else {
            return .defaultConfiguration
        }

        return configuration
    }

    func save(_ configuration: SyncConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }

        userDefaults.set(data, forKey: key)
    }
}
