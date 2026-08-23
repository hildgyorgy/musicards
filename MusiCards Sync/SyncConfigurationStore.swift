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

        if containsLegacyRsyncPath(data) {
            save(configuration)
        }

        return configuration
    }

    func save(_ configuration: SyncConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }

        userDefaults.set(data, forKey: key)
    }

    private func containsLegacyRsyncPath(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return false
        }

        return dictionary["rsyncPath"] != nil
    }
}
