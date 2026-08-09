import Foundation

nonisolated struct SyncConfiguration: Codable, Equatable, Sendable {

    var rsyncPath: String
    var sourcePath: String

    var destination: DestinationProfile

    var sshKeyPath: String

    static let defaultConfiguration = SyncConfiguration(
        rsyncPath: "/opt/homebrew/bin/rsync",

        sourcePath: "",

        destination: .umbrelRPi5,

        sshKeyPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/musicards_sync")
            .path
    )
}
