import Foundation

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
