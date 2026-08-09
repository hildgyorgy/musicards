import Foundation

nonisolated struct SyncConfigurationValidator: Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case localDestinationUnavailable(String)
        case sameSourceAndDestination
        case destinationInsideSource
        case sourceInsideDestination

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
        guard configuration.destination.kind == .local else { return }

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
