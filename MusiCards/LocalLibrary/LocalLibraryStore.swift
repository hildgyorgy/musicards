//
//  LocalLibraryStore.swift
//  MusiCards
//

import Combine
import Foundation
import SwiftData

@MainActor
final class LocalLibraryStore: ObservableObject {
    @Published private(set) var summary = LocalLibrarySummary()
    @Published private(set) var folderNames: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var connectionErrorMessage: String?

    private let container: ModelContainer
    private let context: ModelContext
    private var rootURLs: [String: URL] = [:]
    private var accessedRootIDs = Set<String>()
    private var tracksByReleaseID: [String: [LocalAudioFileSnapshot]] = [:]
    private var tracksByReleaseTrackKey: [String: LocalAudioFileSnapshot] = [:]
    private var legacyTracksByRecordingKey: [String: LocalAudioFileSnapshot] = [:]
    private var normalizedArtistCredits = Set<String>()
    private var normalizedArtistCreditsByAlbumTitle: [String: Set<String>] = [:]

    init() {
        do {
            container = try ModelContainer(
                for: LocalLibraryRootRecord.self,
                LocalAudioFileRecord.self
            )
        } catch {
            let memoryConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(
                for: LocalLibraryRootRecord.self,
                LocalAudioFileRecord.self,
                configurations: memoryConfiguration
            )
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
            isScanning = true
            connectionErrorMessage = nil
            statusMessage = "Connecting music folder…"
            Task {
                await connectMusicFolder(
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
        tracksByReleaseID[normalizedMBID(releaseID)]?.isEmpty == false
    }

    func containsArtist(named artistName: String) -> Bool {
        let needle = normalizedLibraryText(artistName)
        guard !needle.isEmpty else { return false }
        return normalizedArtistCredits.contains(needle)
    }

    func containsReleaseGroup(title: String, artistName: String) -> Bool {
        let artist = normalizedLibraryText(artistName)
        let album = normalizedLibraryText(title)
        guard !artist.isEmpty, !album.isEmpty else { return false }
        return normalizedArtistCreditsByAlbumTitle[album]?.contains {
            artistCredit($0, contains: artist)
        } == true
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
        if let releaseTrackID = nonemptyMBID(releaseTrackID),
           let exactMatch = tracksByReleaseTrackKey[
               releaseTrackKey(
                   releaseID: releaseID,
                   releaseTrackID: releaseTrackID
               )
           ] {
            return exactMatch
        }
        guard allowsRecordingFallback,
              let recordingID = nonemptyMBID(recordingID) else {
            return nil
        }
        return legacyTracksByRecordingKey[
            recordingKey(releaseID: releaseID, recordingID: recordingID)
        ]
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
        didAccess: Bool
    ) async {
        defer { isScanning = false }

        do {
            let manifest = try await LocalLibraryManifestLoader.load(
                from: url
            )
            let existingRoots = try context.fetch(
                FetchDescriptor<LocalLibraryRootRecord>()
            )
            let existingFiles = try context.fetch(
                FetchDescriptor<LocalAudioFileRecord>()
            )

            if let existing = existingRoots.first(where: {
                rootURLs[$0.id]?.standardizedFileURL == url.standardizedFileURL
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
            statusMessage = "Library index connected"
        } catch {
            context.rollback()
            if didAccess { url.stopAccessingSecurityScopedResource() }
            connectionErrorMessage = manifestErrorMessage(error)
        }
    }

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
    }

    private func releaseAccess(for roots: [LocalLibraryRootRecord]) {
        for root in roots {
            if accessedRootIDs.remove(root.id) != nil {
                rootURLs[root.id]?.stopAccessingSecurityScopedResource()
            }
            rootURLs.removeValue(forKey: root.id)
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
            var snapshotsByFileURL: [String: LocalAudioFileSnapshot] = [:]
            for record in records {
                guard let rootURL = rootURLs[record.rootID] else { continue }
                let fileURL = rootURL
                    .appendingPathComponent(record.relativePath)
                    .standardizedFileURL
                snapshotsByFileURL[fileURL.path] = LocalAudioFileSnapshot(record)
            }
            let snapshots = snapshotsByFileURL.values.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath)
                    == .orderedAscending
            }

            tracksByReleaseID = Dictionary(
                grouping: snapshots.compactMap { file -> (String, LocalAudioFileSnapshot)? in
                    guard let releaseID = file.releaseMBID else { return nil }
                    return (normalizedMBID(releaseID), file)
                },
                by: { $0.0 }
            ).mapValues { $0.map(\.1) }

            normalizedArtistCredits = Set(
                snapshots.compactMap { file in
                    let artist = normalizedLibraryText(file.artist)
                    return artist.isEmpty ? nil : artist
                }
            )
            normalizedArtistCreditsByAlbumTitle = [:]
            for file in snapshots {
                let artist = normalizedLibraryText(file.artist)
                let album = normalizedLibraryText(file.albumTitle)
                guard !artist.isEmpty, !album.isEmpty else { continue }
                normalizedArtistCreditsByAlbumTitle[album, default: []].insert(artist)
            }

            tracksByReleaseTrackKey = [:]
            var legacyRecordingCandidates: [String: [LocalAudioFileSnapshot]] = [:]
            for file in snapshots {
                guard let releaseID = file.releaseMBID else { continue }
                if let releaseTrackID = nonemptyMBID(file.releaseTrackMBID) {
                    let key = releaseTrackKey(
                        releaseID: releaseID,
                        releaseTrackID: releaseTrackID
                    )
                    if tracksByReleaseTrackKey[key] == nil {
                        tracksByReleaseTrackKey[key] = file
                    }
                } else if let recordingID = nonemptyMBID(file.recordingMBID) {
                    let key = recordingKey(
                        releaseID: releaseID,
                        recordingID: recordingID
                    )
                    legacyRecordingCandidates[key, default: []].append(file)
                }
            }
            legacyTracksByRecordingKey = legacyRecordingCandidates.compactMapValues {
                $0.count == 1 ? $0[0] : nil
            }

            folderNames = roots
                .filter { rootURLs[$0.id] != nil }
                .map(\.displayName)
                .sorted()
            let activeRoots = roots.filter { rootURLs[$0.id] != nil }
            let hasPersistedIdentifiedCounts = !activeRoots.isEmpty
                && activeRoots.allSatisfy { $0.identifiedAlbumCount != nil }
            let identifiedAlbumCount = hasPersistedIdentifiedCounts
                ? activeRoots.reduce(0) { $0 + ($1.identifiedAlbumCount ?? 0) }
                : tracksByReleaseID.count
            let totalAlbumCount: Int? = !activeRoots.isEmpty
                && activeRoots.allSatisfy({ $0.totalAlbumCount != nil })
                ? activeRoots.reduce(0) { $0 + ($1.totalAlbumCount ?? 0) }
                : nil
            summary = LocalLibrarySummary(
                folderCount: folderNames.count,
                releaseCount: tracksByReleaseID.count,
                trackCount: snapshots.count,
                identifiedAlbumCount: identifiedAlbumCount,
                totalAlbumCount: totalAlbumCount
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func normalizedMBID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedLibraryText(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .joined(separator: " ")
    }

    private func artistCredit(_ credit: String, contains artist: String) -> Bool {
        credit == artist
            || credit.hasPrefix("\(artist) ")
            || credit.hasSuffix(" \(artist)")
            || credit.contains(" \(artist) ")
    }

    private func nonemptyMBID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizedMBID(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func recordingKey(releaseID: String, recordingID: String) -> String {
        "\(normalizedMBID(releaseID))::\(normalizedMBID(recordingID))"
    }

    private func releaseTrackKey(
        releaseID: String,
        releaseTrackID: String
    ) -> String {
        "\(normalizedMBID(releaseID))::\(normalizedMBID(releaseTrackID))"
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
