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

    private let container: ModelContainer
    private let context: ModelContext
    private var rootURLs: [String: URL] = [:]
    private var accessedRootIDs = Set<String>()
    private var tracksByReleaseID: [String: [LocalAudioFileSnapshot]] = [:]
    private var tracksByRecordingKey: [String: LocalAudioFileSnapshot] = [:]

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
        // A document picker grants access only for the duration of its callback.
        // Claim that access synchronously, before this method starts any Task.
        let didAccess = url.startAccessingSecurityScopedResource()

        do {
            let bookmark = try makeBookmark(for: url)
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
                try context.save()
                releaseAccess(for: obsoleteRoots)

                if accessedRootIDs.contains(existing.id) {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                } else {
                    retain(url: url, for: existing.id, didAccess: didAccess)
                }
                rebuildLookup()
                Task { await refresh(rootID: existing.id) }
                return
            }

            guard didAccess else {
                throw NativePlaybackEngineError(
                    "The selected music folder could not be accessed."
                )
            }

            let root = LocalLibraryRootRecord(
                displayName: url.lastPathComponent,
                bookmarkData: bookmark
            )
            context.insert(root)
            for file in existingFiles { context.delete(file) }
            for existingRoot in existingRoots { context.delete(existingRoot) }
            try context.save()
            releaseAccess(for: existingRoots)
            retain(url: url, for: root.id, didAccess: didAccess)
            rebuildLookup()
            Task { await refresh(rootID: root.id) }
        } catch {
            context.rollback()
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            statusMessage = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = "Scanning music folder…"
        defer { isScanning = false }

        let rootIDs = Array(rootURLs.keys)
        for rootID in rootIDs {
            await refreshRoot(rootID: rootID)
        }
        rebuildLookup()
        statusMessage = summary.trackCount == 0
            ? "No Picard-tagged playable releases found"
            : "Library updated"
    }

    func containsRelease(_ releaseID: String) -> Bool {
        tracksByReleaseID[normalizedMBID(releaseID)]?.isEmpty == false
    }

    func containsRecording(
        releaseID: String,
        recordingID: String?
    ) -> Bool {
        audioFile(releaseID: releaseID, recordingID: recordingID) != nil
    }

    func audioFile(
        releaseID: String,
        recordingID: String?
    ) -> LocalAudioFileSnapshot? {
        guard let recordingID else { return nil }
        return tracksByRecordingKey[
            recordingKey(releaseID: releaseID, recordingID: recordingID)
        ]
    }

    func url(for file: LocalAudioFileSnapshot) -> URL? {
        rootURLs[file.rootID]?.appendingPathComponent(file.relativePath)
    }

    private func refresh(rootID: String) async {
        guard !isScanning else {
            await refreshRoot(rootID: rootID)
            rebuildLookup()
            return
        }
        isScanning = true
        statusMessage = "Scanning music folder…"
        defer { isScanning = false }
        await refreshRoot(rootID: rootID)
        rebuildLookup()
        statusMessage = "Library updated"
    }

    private func refreshRoot(rootID: String) async {
        guard let rootURL = rootURLs[rootID] else { return }

        do {
            statusMessage = "Finding audio files…"
            let candidates = try await Task.detached(priority: .utility) {
                try LocalLibraryScanner.enumerateAudioFiles(in: rootURL)
            }.value

            let allRecords = try context.fetch(
                FetchDescriptor<LocalAudioFileRecord>()
            )
            let existing = allRecords.filter { $0.rootID == rootID }
            let existingByPath = Dictionary(
                uniqueKeysWithValues: existing.map { ($0.relativePath, $0) }
            )
            let candidatePaths = Set(candidates.map(\.relativePath))

            for record in existing where !candidatePaths.contains(record.relativePath) {
                context.delete(record)
            }

            let changed = candidates.filter { candidate in
                guard let record = existingByPath[candidate.relativePath] else {
                    return true
                }
                return record.fileSize != candidate.fileSize
                    || record.modificationDate != candidate.modificationDate
            }
            let scannedFiles = await scanMetadata(for: changed)

            for scanned in scannedFiles {
                if let record = existingByPath[scanned.relativePath] {
                    record.update(from: scanned)
                } else {
                    context.insert(
                        LocalAudioFileRecord(rootID: rootID, scanned: scanned)
                    )
                }
            }

            if let root = try context.fetch(
                FetchDescriptor<LocalLibraryRootRecord>()
            ).first(where: { $0.id == rootID }) {
                root.lastScanDate = Date()
            }
            try context.save()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func scanMetadata(
        for candidates: [LocalAudioFileCandidate]
    ) async -> [ScannedAudioFile] {
        let maxConcurrent = 4
        var iterator = candidates.makeIterator()
        var scanned: [ScannedAudioFile] = []
        var completed = 0

        guard !candidates.isEmpty else { return [] }
        statusMessage = "Reading metadata 0 / \(candidates.count)…"

        await withTaskGroup(of: ScannedAudioFile?.self) { group in
            for _ in 0..<min(maxConcurrent, candidates.count) {
                guard let candidate = iterator.next() else { break }
                group.addTask {
                    try? await LocalLibraryScanner.readMetadata(from: candidate)
                }
            }

            while let result = await group.next() {
                completed += 1
                if let result { scanned.append(result) }
                statusMessage = "Reading metadata \(completed) / \(candidates.count)…"
                if let candidate = iterator.next() {
                    group.addTask {
                        try? await LocalLibraryScanner.readMetadata(from: candidate)
                    }
                }
            }
        }
        return scanned
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
            let snapshots = Array(snapshotsByFileURL.values)

            tracksByReleaseID = Dictionary(
                grouping: snapshots.compactMap { file -> (String, LocalAudioFileSnapshot)? in
                    guard let releaseID = file.releaseMBID else { return nil }
                    return (normalizedMBID(releaseID), file)
                },
                by: { $0.0 }
            ).mapValues { $0.map(\.1) }

            tracksByRecordingKey = [:]
            for file in snapshots {
                guard let releaseID = file.releaseMBID,
                      let recordingID = file.recordingMBID else {
                    continue
                }
                let key = recordingKey(
                    releaseID: releaseID,
                    recordingID: recordingID
                )
                if tracksByRecordingKey[key] == nil {
                    tracksByRecordingKey[key] = file
                }
            }

            folderNames = roots
                .filter { rootURLs[$0.id] != nil }
                .map(\.displayName)
                .sorted()
            summary = LocalLibrarySummary(
                folderCount: folderNames.count,
                releaseCount: tracksByReleaseID.count,
                trackCount: snapshots.count
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func normalizedMBID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func recordingKey(releaseID: String, recordingID: String) -> String {
        "\(normalizedMBID(releaseID))::\(normalizedMBID(recordingID))"
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
