import Foundation

nonisolated struct SyncConfigurationValidator: Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case localDestinationUnavailable(String)
        case sameSourceAndDestination
        case destinationInsideSource
        case sourceInsideDestination
        case incompleteRemoteDestination
        case invalidRemotePort
        case invalidRemotePath
        case invalidRemoteUsername
        case invalidRemoteHostname
        case invalidSSHKeyPath

        var errorDescription: String? {
            switch self {
            case .localDestinationUnavailable(let path):
                return "The local destination folder is not available: \(path) Connect the external drive or choose another destination."
            case .sameSourceAndDestination:
                return "Source and local destination must be different folders."
            case .destinationInsideSource:
                return "The local destination cannot be inside the source folder."
            case .sourceInsideDestination:
                return "The source cannot be inside the local destination because synchronization could delete unrelated destination files."
            case .incompleteRemoteDestination:
                return "Remote destination requires a name, hostname, username, and folder path."
            case .invalidRemotePort:
                return "SSH port must be between 1 and 65535."
            case .invalidRemotePath:
                return "Remote destination folder must be an absolute path beginning with /."
            case .invalidRemoteUsername:
                return "Remote username contains unsupported characters."
            case .invalidRemoteHostname:
                return "Remote hostname is invalid. Use a DNS name, .local name, or IPv4 address."
            case .invalidSSHKeyPath:
                return "SSH private-key path is invalid."
            }
        }
    }

    private let directoryExists: @Sendable (String) -> Bool

    init(
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(
                atPath: path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    ) {
        self.directoryExists = directoryExists
    }

    func validate(_ configuration: SyncConfiguration) throws {
        if configuration.destination.kind == .remote {
            let destination = configuration.destination
            guard !destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let host = destination.host,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let user = destination.user,
                  !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !destination.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.incompleteRemoteDestination
            }
            guard (1...65_535).contains(destination.sshPort) else {
                throw ValidationError.invalidRemotePort
            }
            guard destination.path.hasPrefix("/") else {
                throw ValidationError.invalidRemotePath
            }
            do {
                try SSHInvocation.validate(username: user, hostname: host)
                _ = try SSHInvocation.rsyncRemoteShell(
                    keyPath: configuration.sshKeyPath,
                    port: destination.sshPort
                )
            } catch SSHInvocation.ValidationError.invalidUsername {
                throw ValidationError.invalidRemoteUsername
            } catch SSHInvocation.ValidationError.invalidHostname {
                throw ValidationError.invalidRemoteHostname
            } catch SSHInvocation.ValidationError.invalidKeyPath {
                throw ValidationError.invalidSSHKeyPath
            }
            return
        }

        guard !configuration.destination.path.isEmpty else {
            throw ValidationError.localDestinationUnavailable(
                configuration.destination.path
            )
        }

        let sourceComponents = canonicalPathComponents(
            configuration.sourcePath
        )
        let destinationComponents = canonicalPathComponents(
            configuration.destination.path
        )

        if componentsEqual(sourceComponents, destinationComponents) {
            throw ValidationError.sameSourceAndDestination
        }

        if isAncestor(sourceComponents, of: destinationComponents) {
            throw ValidationError.destinationInsideSource
        }

        if isAncestor(destinationComponents, of: sourceComponents) {
            throw ValidationError.sourceInsideDestination
        }

        guard isLocalDestinationAvailable(configuration.destination) else {
            throw ValidationError.localDestinationUnavailable(
                configuration.destination.path
            )
        }
    }

    func isLocalDestinationAvailable(
        _ destination: DestinationProfile
    ) -> Bool {
        destination.kind != .local ||
            (!destination.path.isEmpty && directoryExists(destination.path))
    }

    private func canonicalPathComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
    }

    private func isAncestor(
        _ possibleAncestor: [String],
        of path: [String]
    ) -> Bool {
        possibleAncestor.count < path.count &&
            componentsEqual(possibleAncestor, Array(path.prefix(possibleAncestor.count)))
    }

    private func componentsEqual(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        return zip(lhs, rhs).allSatisfy { left, right in
            left.compare(right, options: .caseInsensitive) == .orderedSame
        }
    }
}
