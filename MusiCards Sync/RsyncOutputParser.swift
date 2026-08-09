import Foundation

nonisolated struct RsyncPreviewParser: Sendable {
    func parse(_ output: String) -> SyncPreview {
        var preview = SyncPreview()

        let systemNames = [
            ".DS_Store",
            ".Spotlight-V100",
            ".Trashes"
        ]

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)

            if line.hasPrefix(">f+++++++++|") || line.hasPrefix("<f+++++++++|") {
                if let separator = line.firstIndex(of: "|") {
                    let path = String(line[line.index(after: separator)...])
                    preview.newFiles.append(path)
                }
                continue
            }

            if line.hasPrefix(">f") || line.hasPrefix("<f") {
                if let separator = line.firstIndex(of: "|") {
                    let path = String(line[line.index(after: separator)...])
                    preview.modifiedFiles.append(path)
                }
                continue
            }

            if line.hasPrefix("cd+++++++++|") {
                let path = String(line.dropFirst("cd+++++++++|".count))
                preview.newFolders.append(path)
                continue
            }

            if line.hasPrefix("*deleting") {
                var path = line
                    .replacingOccurrences(of: "*deleting", with: "")
                    .trimmingCharacters(in: .whitespaces)

                if path.hasPrefix("|") {
                    path.removeFirst()
                }

                let basename = URL(fileURLWithPath: path).lastPathComponent
                let isSystemFile =
                    systemNames.contains(basename) ||
                    basename.hasPrefix("._")

                if isSystemFile {
                    preview.systemCleanup.append(path)
                } else if path.hasSuffix("/") {
                    preview.deletedFolders.append(path)
                } else {
                    preview.deletedFiles.append(path)
                }
            }
        }

        return preview
    }
}

nonisolated struct RsyncCompletedItemRecord: Equatable, Sendable {
    let path: String
    let displayLine: String
}

nonisolated struct RsyncCompletedItemParser: Sendable {
    func parse(_ line: String) -> RsyncCompletedItemRecord? {
        guard let firstSeparator = line.firstIndex(of: "|"),
              let lastSeparator = line.lastIndex(of: "|"),
              firstSeparator != lastSeparator else {
            return nil
        }

        let byteCountStart = line.index(after: lastSeparator)
        let byteCount = line[byteCountStart...]
        guard !byteCount.isEmpty,
              byteCount.allSatisfy(\.isNumber) else {
            return nil
        }

        let pathStart = line.index(after: firstSeparator)
        let path = String(line[pathStart..<lastSeparator])
        guard !path.isEmpty else { return nil }

        return RsyncCompletedItemRecord(
            path: path,
            displayLine: String(line[..<lastSeparator])
        )
    }
}

nonisolated struct RsyncProgressTracker: Sendable {
    private let expectedNewFiles: Set<String>
    private let expectedModifiedFiles: Set<String>
    private let expectedNewFolders: Set<String>
    private let expectedDeletedFiles: Set<String>
    private let expectedDeletedFolders: Set<String>
    private let expectedSystemCleanup: Set<String>

    private var completedNewFiles: Set<String> = []
    private var completedModifiedFiles: Set<String> = []
    private var completedNewFolders: Set<String> = []
    private var completedDeletedFiles: Set<String> = []
    private var completedDeletedFolders: Set<String> = []
    private var completedSystemCleanup: Set<String> = []

    init(preview: SyncPreview = SyncPreview()) {
        expectedNewFiles = Set(preview.newFiles)
        expectedModifiedFiles = Set(preview.modifiedFiles)
        expectedNewFolders = Set(preview.newFolders)
        expectedDeletedFiles = Set(preview.deletedFiles)
        expectedDeletedFolders = Set(preview.deletedFolders)
        expectedSystemCleanup = Set(preview.systemCleanup)
    }

    var totalCount: Int {
        plannedSummary.affectedFileCount
    }

    var completedCount: Int {
        completedSummary.affectedFileCount
    }

    var progress: Double? {
        guard totalCount > 0 else { return nil }
        return Double(completedCount) / Double(totalCount)
    }

    mutating func recordCompletion(for path: String) -> Bool {
        if expectedNewFiles.contains(path) {
            return completedNewFiles.insert(path).inserted
        }
        if expectedModifiedFiles.contains(path) {
            return completedModifiedFiles.insert(path).inserted
        }
        if expectedNewFolders.contains(path) {
            return completedNewFolders.insert(path).inserted
        }
        if expectedDeletedFiles.contains(path) {
            return completedDeletedFiles.insert(path).inserted
        }
        if expectedDeletedFolders.contains(path) {
            return completedDeletedFolders.insert(path).inserted
        }
        if expectedSystemCleanup.contains(path) {
            return completedSystemCleanup.insert(path).inserted
        }
        return false
    }

    mutating func markAllCompleted() {
        completedNewFiles = expectedNewFiles
        completedModifiedFiles = expectedModifiedFiles
        completedNewFolders = expectedNewFolders
        completedDeletedFiles = expectedDeletedFiles
        completedDeletedFolders = expectedDeletedFolders
        completedSystemCleanup = expectedSystemCleanup
    }

    var plannedSummary: SyncSummary {
        SyncSummary(
            newFiles: expectedNewFiles.count,
            modifiedFiles: expectedModifiedFiles.count,
            newFolders: expectedNewFolders.count,
            deletedFiles: expectedDeletedFiles.count,
            deletedFolders: expectedDeletedFolders.count,
            systemCleanup: expectedSystemCleanup.count
        )
    }

    var completedSummary: SyncSummary {
        SyncSummary(
            newFiles: completedNewFiles.count,
            modifiedFiles: completedModifiedFiles.count,
            newFolders: completedNewFolders.count,
            deletedFiles: completedDeletedFiles.count,
            deletedFolders: completedDeletedFolders.count,
            systemCleanup: completedSystemCleanup.count
        )
    }
}
