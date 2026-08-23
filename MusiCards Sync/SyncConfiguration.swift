import Foundation

nonisolated struct SyncConfiguration: Codable, Equatable, Sendable {

    var sourcePath: String

    var destination: DestinationProfile

    var sshKeyPath: String

    static let defaultConfiguration = SyncConfiguration(
        sourcePath: "",

        destination: .unconfigured,

        sshKeyPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/musicards_sync")
            .path
    )
}
