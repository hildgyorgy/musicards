import Foundation
import Darwin

nonisolated struct OnlineOnlyFileMetadata: Equatable, Sendable {
    let isRegularFile: Bool
    let isDataless: Bool
}

/// Metadata-only evidence for a File Provider placeholder. The public macOS
/// `SF_DATALESS` filesystem flag is the authoritative signal; allocation
/// size is intentionally not used because sparse files are valid sync inputs.
nonisolated struct OnlineOnlyFileDetector: Sendable {
    private let metadataReader: @Sendable (String) -> OnlineOnlyFileMetadata?

    init(
        metadataReader: @escaping @Sendable (String) -> OnlineOnlyFileMetadata?
            = OnlineOnlyFileDetector.readMetadata
    ) {
        self.metadataReader = metadataReader
    }

    func isOnlineOnly(path: String) -> Bool {
        guard let metadata = metadataReader(path) else { return false }
        return metadata.isRegularFile &&
            metadata.isDataless
    }

    func countOnlineOnlyFiles(
        modifiedPaths: [String],
        sourceDirectory: String
    ) -> Int {
        let sourceURL = URL(fileURLWithPath: sourceDirectory, isDirectory: true)
        return modifiedPaths.reduce(into: 0) { count, path in
            let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fileURL = sourceURL.appendingPathComponent(relativePath)
            if isOnlineOnly(path: fileURL.path) {
                count += 1
            }
        }
    }

    private static func readMetadata(path: String) -> OnlineOnlyFileMetadata? {
        var fileStat = Darwin.stat()
        guard Darwin.lstat(path, &fileStat) == 0 else { return nil }

        let fileType = fileStat.st_mode & S_IFMT
        return OnlineOnlyFileMetadata(
            isRegularFile: fileType == S_IFREG,
            isDataless: (fileStat.st_flags & UInt32(bitPattern: SF_DATALESS)) != 0
        )
    }
}

nonisolated struct SyncPreview: Sendable {
    var newFiles: [String] = []
    var modifiedFiles: [String] = []
    var newFolders: [String] = []
    var deletedFiles: [String] = []
    var deletedFolders: [String] = []
    var systemCleanup: [String] = []

    var affectedFilePaths: Set<String> {
        Set(newFiles + modifiedFiles + deletedFiles + systemCleanup)
    }

    var affectedFileCount: Int {
        affectedFilePaths.count
    }

    var hasChanges: Bool {
        !newFiles.isEmpty ||
        !modifiedFiles.isEmpty ||
        !newFolders.isEmpty ||
        !deletedFiles.isEmpty ||
        !deletedFolders.isEmpty ||
        !systemCleanup.isEmpty
    }
}

nonisolated struct SyncSummary: Equatable, Sendable {
    var newFiles = 0
    var modifiedFiles = 0
    var newFolders = 0
    var deletedFiles = 0
    var deletedFolders = 0
    var systemCleanup = 0

    init() {}

    init(
        newFiles: Int,
        modifiedFiles: Int,
        newFolders: Int,
        deletedFiles: Int,
        deletedFolders: Int,
        systemCleanup: Int
    ) {
        self.newFiles = newFiles
        self.modifiedFiles = modifiedFiles
        self.newFolders = newFolders
        self.deletedFiles = deletedFiles
        self.deletedFolders = deletedFolders
        self.systemCleanup = systemCleanup
    }

    init(preview: SyncPreview) {
        newFiles = preview.newFiles.count
        modifiedFiles = preview.modifiedFiles.count
        newFolders = preview.newFolders.count
        deletedFiles = preview.deletedFiles.count
        deletedFolders = preview.deletedFolders.count
        systemCleanup = preview.systemCleanup.count
    }

    var affectedFileCount: Int {
        newFiles + modifiedFiles + deletedFiles + systemCleanup
    }
}

nonisolated struct LibraryIndexSyncSummary: Equatable, Sendable {
    var indexGenerated: Bool
    var previousIndexRemoved: Bool
    var newIndexPublished: Bool
    var musicBrainzReadyAlbumCount: Int?
    var totalAlbumCount: Int?

    init(
        indexGenerated: Bool = false,
        previousIndexRemoved: Bool = false,
        newIndexPublished: Bool = false,
        musicBrainzReadyAlbumCount: Int? = nil,
        totalAlbumCount: Int? = nil
    ) {
        self.indexGenerated = indexGenerated
        self.previousIndexRemoved = previousIndexRemoved
        self.newIndexPublished = newIndexPublished
        self.musicBrainzReadyAlbumCount = musicBrainzReadyAlbumCount
        self.totalAlbumCount = totalAlbumCount
    }
}
