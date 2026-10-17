//
//  LocalLibraryStore.swift
//  MusiCards
//

import Combine
import Foundation
import OSLog
import SwiftData

@MainActor
final class LocalLibraryStore: ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "LocalLibrary"
    )

    @Published private(set) var summary = LocalLibrarySummary()
    @Published private(set) var folderNames: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var connectionErrorMessage: String?
    /// A readable label only; file access continues to use the original URL and bookmark.
    @Published private(set) var selectedFolderDisplayPath: String?

    private let container: ModelContainer
    private let context: ModelContext
    private var rootURLs: [String: URL] = [:]
    private var accessedRootIDs = Set<String>()
    private var lookup = LocalLibraryLookup()
    private var pendingFolderConnectionID: UUID?
    private var pendingFolderConnectionTask: Task<Void, Never>?

    init() {
        do {
            container = try ModelContainer(
                for: LocalLibraryRootRecord.self,
                LocalAudioFileRecord.self
            )
        } catch let persistentStoreError {
            let nsError = persistentStoreError as NSError
            Self.logger.error(
                "Persistent library store initialization failed; falling back to an in-memory store domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) detail=\(nsError.localizedDescription, privacy: .private)"
            )
            let memoryConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                container = try ModelContainer(
                    for: LocalLibraryRootRecord.self,
                    LocalAudioFileRecord.self,
                    configurations: memoryConfiguration
                )
            } catch {
                let fallbackError = error as NSError
                Self.logger.critical(
                    "In-memory library store initialization failed domain=\(fallbackError.domain, privacy: .public) code=\(fallbackError.code, privacy: .public) detail=\(fallbackError.localizedDescription, privacy: .private)"
                )
                fatalError(
                    "Could not initialize the in-memory LocalLibraryStore fallback."
                )
            }
            statusMessage = "The library index could not be opened; using a temporary index."
        }
        context = ModelContext(container)
        restoreRoots()
        rebuildLookup()
    }

    deinit {
        for rootID in accessedRootIDs {
            rootURLs[rootID]?.stopAccessingSecurityScopedResource()
        }
    }

    func startAutomaticRefresh() {
        guard !rootURLs.isEmpty else { return }
        Task { await refreshAll() }
    }

    func refreshIfNeeded(minimumInterval: TimeInterval = 60) {
        guard !isScanning, !rootURLs.isEmpty else { return }
        let roots = (try? context.fetch(
            FetchDescriptor<LocalLibraryRootRecord>()
        )) ?? []
        let needsRefresh = roots.contains { root in
            guard let lastScanDate = root.lastScanDate else { return true }
            return Date().timeIntervalSince(lastScanDate) >= minimumInterval
        }
        guard needsRefresh else { return }
        Task { await refreshAll() }
    }

    func selectMusicFolder(_ url: URL) {
        guard !isScanning else { return }
        // A document picker grants access only for the duration of its callback.
        // Claim that access synchronously, before this method starts any Task.
        let didAccess = url.startAccessingSecurityScopedResource()

        do {
            let bookmark = try makeBookmark(for: url)
            let connectionID = UUID()
            pendingFolderConnectionID = connectionID
            isScanning = true
            connectionErrorMessage = nil
            statusMessage = "Connecting music folder…"
            pendingFolderConnectionTask = Task {
                await connectMusicFolder(
                    url,
                    bookmark: bookmark,
                    didAccess: didAccess,
                    connectionID: connectionID
                )
            }
        } catch {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            connectionErrorMessage = error.localizedDescription
        }
    }

    /// Leaves an in-flight file-provider read alone, but prevents its result from connecting.
    func cancelPendingFolderConnection() {
        guard pendingFolderConnectionID != nil else { return }
        pendingFolderConnectionID = nil
        pendingFolderConnectionTask?.cancel()
        pendingFolderConnectionTask = nil
        isScanning = false
        statusMessage = nil
        connectionErrorMessage = nil
    }

    #if os(macOS)
    func createOrUpdateLibraryIndex(in url: URL) {
        guard !isScanning else { return }
        // The picker grant must be claimed before the asynchronous scan starts.
        let didAccess = url.startAccessingSecurityScopedResource()

        do {
            let bookmark = try makeBookmark(for: url)
            isScanning = true
            connectionErrorMessage = nil
            statusMessage = "Preparing music library…"
            Task {
                await createIndexAndConnect(
                    url,
                    bookmark: bookmark,
                    didAccess: didAccess
                )
            }
        } catch {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            connectionErrorMessage = error.localizedDescription
        }
    }
    #endif

    func disconnectLibrary() {
        guard !isScanning else { return }

        do {
            let roots = try context.fetch(
                FetchDescriptor<LocalLibraryRootRecord>()
            )
            let files = try context.fetch(
                FetchDescriptor<LocalAudioFileRecord>()
            )
            for file in files { context.delete(file) }
            for root in roots { context.delete(root) }
            try context.save()
            releaseAccess(for: roots)
            connectionErrorMessage = nil
            statusMessage = "Music library disconnected"
            rebuildLookup()
        } catch {
            context.rollback()
            connectionErrorMessage = "Could not disconnect the music library: \(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        guard !isScanning else { return }
        isScanning = true
        connectionErrorMessage = nil
        statusMessage = "Reading library.json…"
        defer { isScanning = false }

        let rootIDs = Array(rootURLs.keys)
        var succeeded = true
        for rootID in rootIDs {
            if !(await refreshRoot(rootID: rootID)) { succeeded = false }
        }
        rebuildLookup()
        if succeeded {
            statusMessage = summary.trackCount == 0
                ? "No Picard-tagged playable releases found"
                : "Library index updated"
        }
    }

    func containsRelease(_ releaseID: String) -> Bool {
        lookup.containsRelease(releaseID)
    }

    func searchCatalog(
        query: LibraryCatalogQuery,
        limit: Int
    ) -> [LibraryCatalogRelease] {
        lookup.searchCatalog(query: query, limit: limit)
    }

    func containsArtist(named artistName: String) -> Bool {
        lookup.containsArtist(named: artistName)
    }

    func containsReleaseGroup(title: String, artistName: String) -> Bool {
        lookup.containsReleaseGroup(title: title, artistName: artistName)
    }

    func containsTrack(
        releaseID: String,
        releaseTrackID: String?,
        recordingID: String?,
        allowsRecordingFallback: Bool
    ) -> Bool {
        audioFile(
            releaseID: releaseID,
            releaseTrackID: releaseTrackID,
            recordingID: recordingID,
            allowsRecordingFallback: allowsRecordingFallback
        ) != nil
    }

    func audioFile(
        releaseID: String,
        releaseTrackID: String?,
        recordingID: String?,
        allowsRecordingFallback: Bool
    ) -> LocalAudioFileSnapshot? {
        lookup.audioFile(
            releaseID: releaseID,
            releaseTrackID: releaseTrackID,
            recordingID: recordingID,
            allowsRecordingFallback: allowsRecordingFallback
        )
    }

    func audioFile(id: String) -> LocalAudioFileSnapshot? {
        lookup.audioFile(id: id)
    }

    func url(for file: LocalAudioFileSnapshot) -> URL? {
        rootURLs[file.rootID]?.appendingPathComponent(file.relativePath)
    }

    private func refresh(rootID: String) async {
        guard !isScanning else {
            _ = await refreshRoot(rootID: rootID)
            rebuildLookup()
            return
        }
        isScanning = true
        connectionErrorMessage = nil
        statusMessage = "Reading library.json…"
        defer { isScanning = false }
        let succeeded = await refreshRoot(rootID: rootID)
        rebuildLookup()
        if succeeded { statusMessage = "Library index updated" }
    }

    private func refreshRoot(rootID: String) async -> Bool {
        guard let rootURL = rootURLs[rootID] else { return false }

        do {
            statusMessage = "Reading library.json…"
            let manifest = try await LocalLibraryManifestLoader.load(
                from: rootURL
            )

            let allRecords = try context.fetch(
                FetchDescriptor<LocalAudioFileRecord>()
            )
            let existing = allRecords.filter { $0.rootID == rootID }
            apply(manifest.files, to: rootID, replacing: existing)

            if let root = try context.fetch(
                FetchDescriptor<LocalLibraryRootRecord>()
            ).first(where: { $0.id == rootID }) {
                root.lastScanDate = Date()
                root.identifiedAlbumCount = manifest.identifiedAlbumCount
                root.totalAlbumCount = manifest.totalAlbumCount
            }
            try context.save()
            return true
        } catch {
            context.rollback()
            connectionErrorMessage = manifestErrorMessage(error)
            return false
        }
    }

    private func connectMusicFolder(
        _ url: URL,
        bookmark: Data,
        didAccess: Bool,
        successMessage: String = "Library index connected",
        connectionID: UUID? = nil
    ) async {
        defer {
            if let connectionID {
                if pendingFolderConnectionID == connectionID {
                    pendingFolderConnectionID = nil
                    pendingFolderConnectionTask = nil
                    isScanning = false
                }
            } else {
                isScanning = false
            }
        }

        if let connectionID,
           pendingFolderConnectionID != connectionID || Task.isCancelled {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            return
        }

        do {
            let manifest = try await LocalLibraryManifestLoader.load(
                from: url
            )
            if let connectionID,
               pendingFolderConnectionID != connectionID || Task.isCancelled {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                return
            }
            let existingRoots = try context.fetch(
                FetchDescriptor<LocalLibraryRootRecord>()
            )
            let existingFiles = try context.fetch(
                FetchDescriptor<LocalAudioFileRecord>()
            )

            if let existing = existingRoots.first(where: {
                // Comparing paths is enough here; standardizing a File Provider
                // URL can synchronously wait for Dropbox on the main actor.
                rootURLs[$0.id]?.path == url.path
            }) {
                guard didAccess || accessedRootIDs.contains(existing.id) else {
                    throw NativePlaybackEngineError(
                        "The selected music folder could not be accessed."
                    )
                }

                existing.displayName = url.lastPathComponent
                existing.bookmarkData = bookmark
                let obsoleteRoots = existingRoots.filter { $0.id != existing.id }
                let obsoleteRootIDs = Set(obsoleteRoots.map(\.id))
                for file in existingFiles where obsoleteRootIDs.contains(file.rootID) {
                    context.delete(file)
                }
                for root in obsoleteRoots { context.delete(root) }

                let currentFiles = existingFiles.filter { $0.rootID == existing.id }
                apply(manifest.files, to: existing.id, replacing: currentFiles)
                existing.lastScanDate = Date()
                existing.identifiedAlbumCount = manifest.identifiedAlbumCount
                existing.totalAlbumCount = manifest.totalAlbumCount
                try context.save()
                releaseAccess(for: obsoleteRoots)

                if accessedRootIDs.contains(existing.id) {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                } else {
                    retain(url: url, for: existing.id, didAccess: didAccess)
                }
            } else {
                guard didAccess else {
                    throw NativePlaybackEngineError(
                        "The selected music folder could not be accessed."
                    )
                }

                let root = LocalLibraryRootRecord(
                    displayName: url.lastPathComponent,
                    bookmarkData: bookmark,
                    lastScanDate: Date(),
                    identifiedAlbumCount: manifest.identifiedAlbumCount,
                    totalAlbumCount: manifest.totalAlbumCount
                )
                context.insert(root)
                for file in existingFiles { context.delete(file) }
                for existingRoot in existingRoots { context.delete(existingRoot) }
                apply(manifest.files, to: root.id, replacing: [])
                try context.save()
                releaseAccess(for: existingRoots)
                retain(url: url, for: root.id, didAccess: didAccess)
            }

            rebuildLookup()
            statusMessage = successMessage
        } catch {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            if let connectionID,
               pendingFolderConnectionID != connectionID || Task.isCancelled {
                return
            }
            context.rollback()
            connectionErrorMessage = manifestErrorMessage(error)
        }
    }

    #if os(macOS)
    private func createIndexAndConnect(
        _ url: URL,
        bookmark: Data,
        didAccess: Bool
    ) async {
        do {
            let generation = try await LocalLibraryManifestGenerator.generate(
                in: url
            ) { [weak self] message in
                self?.statusMessage = message
            }
            var message = generation.indexWasUpdated
                ? "Library index updated"
                : "Library index is up to date"
            message += " · \(generation.indexedAlbumCount) releases"
            if let warning = generation.warningMessage {
                message += " · \(warning)"
            }
            await connectMusicFolder(
                url,
                bookmark: bookmark,
                didAccess: didAccess,
                successMessage: message
            )
        } catch {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            isScanning = false
            connectionErrorMessage = "Could not create library.json: \(error.localizedDescription)"
        }
    }
    #endif

    private func apply(
        _ scannedFiles: [ScannedAudioFile],
        to rootID: String,
        replacing existingFiles: [LocalAudioFileRecord]
    ) {
        let existingByPath = Dictionary(
            uniqueKeysWithValues: existingFiles.map { ($0.relativePath, $0) }
        )
        let importedPaths = Set(scannedFiles.map(\.relativePath))

        for record in existingFiles where !importedPaths.contains(record.relativePath) {
            context.delete(record)
        }
        for scanned in scannedFiles {
            if let record = existingByPath[scanned.relativePath] {
                record.update(from: scanned)
            } else {
                context.insert(
                    LocalAudioFileRecord(rootID: rootID, scanned: scanned)
                )
            }
        }
    }

    private func manifestErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        if (error as NSError).domain == NSCocoaErrorDomain,
           (error as NSError).code == NSFileReadNoSuchFileError {
            #if os(macOS)
            return "No library.json found. Create it in MusiCards or run the Python indexer."
            #else
            return "No library.json found. Create it with MusiCards for Mac or the Python indexer."
            #endif
        }
        return "Could not connect library.json: \(message)"
    }

    private func restoreRoots() {
        do {
            let roots = try context.fetch(
                FetchDescriptor<LocalLibraryRootRecord>()
            )
            for root in roots {
                var isStale = false
                let url = try resolveBookmark(root.bookmarkData, isStale: &isStale)
                activate(url: url, for: root.id)
                if isStale {
                    root.bookmarkData = try makeBookmark(for: url)
                }
            }
            try context.save()
        } catch {
            statusMessage = "A saved music folder needs to be selected again."
        }
    }

    private func activate(url: URL, for rootID: String) {
        retain(
            url: url,
            for: rootID,
            didAccess: url.startAccessingSecurityScopedResource()
        )
    }

    private func retain(url: URL, for rootID: String, didAccess: Bool) {
        rootURLs[rootID] = url
        if didAccess { accessedRootIDs.insert(rootID) }
        updateDisplayPath(for: url, rootID: rootID)
    }

    private func releaseAccess(for roots: [LocalLibraryRootRecord]) {
        for root in roots {
            if accessedRootIDs.remove(root.id) != nil {
                rootURLs[root.id]?.stopAccessingSecurityScopedResource()
            }
            rootURLs.removeValue(forKey: root.id)
        }
        if let (rootID, url) = rootURLs.first {
            updateDisplayPath(for: url, rootID: rootID)
        } else {
            selectedFolderDisplayPath = nil
        }
    }

    private func updateDisplayPath(for url: URL, rootID: String) {
        // The file provider may block while answering volume metadata requests.
        // Show a path-only label immediately and resolve the fuller label off-main.
        selectedFolderDisplayPath = MusicFolderDisplayPath.label(
            for: url,
            volumeURL: nil,
            volumeName: nil,
            isExternalVolume: false
        )
        let labelTask = Task.detached(priority: .utility) {
            MusicFolderDisplayPath.label(for: url)
        }
        Task { [weak self] in
            let label = await labelTask.value
            guard let self, self.rootURLs[rootID] == url else { return }
            self.selectedFolderDisplayPath = label
        }
    }

    private func rebuildLookup() {
        do {
            let roots = try context.fetch(
                FetchDescriptor<LocalLibraryRootRecord>()
            )
            let records = try context.fetch(
                FetchDescriptor<LocalAudioFileRecord>()
            )
            // The records already have stable root/path IDs. Standardizing each
            // URL here performs a filesystem stat, which can wait on Dropbox's
            // file provider and block the main thread during scene creation.
            let snapshots = records
                .filter { rootURLs[$0.rootID] != nil }
                .map(LocalAudioFileSnapshot.init)

            lookup = LocalLibraryLookup(files: snapshots)

            folderNames = roots
                .filter { rootURLs[$0.id] != nil }
                .map(\.displayName)
                .sorted()
            let activeRoots = roots.filter { rootURLs[$0.id] != nil }
            let hasPersistedIdentifiedCounts = !activeRoots.isEmpty
                && activeRoots.allSatisfy { $0.identifiedAlbumCount != nil }
            let identifiedAlbumCount = hasPersistedIdentifiedCounts
                ? activeRoots.reduce(0) { $0 + ($1.identifiedAlbumCount ?? 0) }
                : lookup.releaseCount
            let totalAlbumCount: Int? = !activeRoots.isEmpty
                && activeRoots.allSatisfy({ $0.totalAlbumCount != nil })
                ? activeRoots.reduce(0) { $0 + ($1.totalAlbumCount ?? 0) }
                : nil
            summary = LocalLibrarySummary(
                folderCount: folderNames.count,
                releaseCount: lookup.releaseCount,
                trackCount: snapshots.count,
                identifiedAlbumCount: identifiedAlbumCount,
                totalAlbumCount: totalAlbumCount
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        return try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
    }

    private func resolveBookmark(
        _ data: Data,
        isStale: inout Bool
    ) throws -> URL {
        #if os(macOS)
        return try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        return try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #endif
    }
}

enum MusicFolderDisplayPath {
    nonisolated static func label(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [
            .volumeURLKey,
            .volumeLocalizedNameKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey
        ])
        return label(
            for: url,
            volumeURL: values?.volume,
            volumeName: values?.volumeLocalizedName,
            isExternalVolume: values?.volumeIsInternal == false
                || values?.volumeIsEjectable == true
                || values?.volumeIsRemovable == true
        )
    }

    nonisolated static func label(
        for url: URL,
        volumeURL: URL?,
        volumeName: String?,
        isExternalVolume: Bool
    ) -> String {
        let components = url.pathComponents
        if let cloudStorageIndex = components.indices.first(where: { index in
            index > components.startIndex
                && components[index - 1].caseInsensitiveCompare("Library") == .orderedSame
                && components[index].caseInsensitiveCompare("CloudStorage") == .orderedSame
        }) {
            var relativeComponents = Array(components.dropFirst(cloudStorageIndex + 1))
            if let firstComponent = relativeComponents.first,
               UUID(uuidString: firstComponent) != nil {
                relativeComponents.removeFirst()
                return relativeComponents.isEmpty
                    ? "Cloud storage"
                    : "Cloud storage/" + relativeComponents.joined(separator: "/")
            }
            if !relativeComponents.isEmpty {
                return relativeComponents.joined(separator: "/")
            }
            return "Cloud storage"
        }

        if let iCloudIndex = components.firstIndex(of: "com~apple~CloudDocs"),
           iCloudIndex > components.startIndex,
           components[iCloudIndex - 1] == "Mobile Documents" {
            let relativeComponents = components.dropFirst(iCloudIndex + 1)
            return (["iCloud Drive"] + relativeComponents).joined(separator: "/")
        }

        let readableTail = readableTail(of: components)
        let name = volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExternalVolume, let name, !name.isEmpty,
           UUID(uuidString: name) == nil {
            let relativeComponents: [String]
            if let volumeURL {
                let volumeComponents = volumeURL.standardizedFileURL.pathComponents
                let selectedComponents = url.standardizedFileURL.pathComponents
                let belongsToVolume = volumeComponents.count > 1
                    && selectedComponents.count >= volumeComponents.count
                    && zip(selectedComponents, volumeComponents).allSatisfy { pair in
                        pair.0.caseInsensitiveCompare(pair.1) == .orderedSame
                    }
                relativeComponents = belongsToVolume
                    ? Array(selectedComponents.dropFirst(volumeComponents.count))
                    : readableTail
            } else {
                relativeComponents = readableTail
            }
            if relativeComponents.first?.caseInsensitiveCompare(name) == .orderedSame {
                return relativeComponents.joined(separator: "/")
            }
            return ([name] + relativeComponents).joined(separator: "/")
        }

        return readableTail.joined(separator: "/")
    }

    nonisolated private static func readableTail(of components: [String]) -> [String] {
        let systemComponents: Set<String> = [
            "Library", "CloudStorage", "Mobile Documents", "Application Support",
            "File Provider Storage", "Containers", "AppGroup", "Shared",
            "Volumes", "private", "var", "mobile", "Users", "System"
        ]
        var tail: [String] = []
        for component in components.reversed() {
            if component == "/" || UUID(uuidString: component) != nil
                || systemComponents.contains(component) {
                break
            }
            tail.insert(component, at: 0)
            if tail.count == 2 { break }
        }
        return tail.isEmpty ? ["Music folder"] : tail
    }
}
