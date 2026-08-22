//
//  LocalLibraryManifestGenerator.swift
//  MusiCards Shared
//

#if os(macOS)
import Foundation

nonisolated struct LocalLibraryManifestGenerationSummary: Sendable {
    let indexedAlbumCount: Int
    let indexedTrackCount: Int
    let skippedFolderCount: Int
    let indexWasUpdated: Bool

    var warningMessage: String? {
        guard skippedFolderCount > 0 else { return nil }
        let noun = skippedFolderCount == 1 ? "folder" : "folders"
        return "\(skippedFolderCount) \(noun) skipped · missing Release MBID"
    }
}

enum LocalLibraryManifestGenerator {
    nonisolated static let currentIndexVersion = 2

    nonisolated static func generate(
        in rootURL: URL,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> LocalLibraryManifestGenerationSummary {
        await progress("Finding audio files…")
        let candidates = try await Task.detached(priority: .utility) {
            try LocalLibraryScanner.enumerateAudioFiles(in: rootURL)
        }.value

        let existingAlbums = loadExistingManifest(from: rootURL)
        let existingByFolder = Dictionary(
            uniqueKeysWithValues: existingAlbums.map { ($0.folderPath, $0) }
        )
        let groupedCandidates = Dictionary(grouping: candidates, by: folderPath)
        let folders = groupedCandidates.keys.sorted()
        var albums: [LocalLibraryManifestAlbum] = []
        var skippedFolderCount = 0

        for (index, folder) in folders.enumerated() {
            try Task.checkCancellation()
            let folderCandidates = (groupedCandidates[folder] ?? [])
                .sorted { $0.relativePath < $1.relativePath }
            await progress("Indexing album \(index + 1) / \(folders.count)…")

            if let existing = existingByFolder[folder],
               isUnchanged(existing, candidates: folderCandidates) {
                albums.append(existing)
                continue
            }

            if let album = try await scanAlbum(
                folderPath: folder,
                candidates: folderCandidates
            ) {
                albums.append(album)
            } else {
                skippedFolderCount += 1
            }
        }

        // Keep the compatibility report inside library.json so every client
        // can present the same identified/total album count without rescanning.
        for index in albums.indices {
            albums[index].libraryAlbumCount = folders.count
        }

        await progress("Writing library.json…")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(albums)
        let manifestURL = rootURL.appendingPathComponent(
            LocalLibraryManifestLoader.fileName
        )
        let existingData = try? Data(contentsOf: manifestURL)
        let indexWasUpdated = existingData != data
        if indexWasUpdated {
            try data.write(to: manifestURL, options: .atomic)
        }
        return LocalLibraryManifestGenerationSummary(
            indexedAlbumCount: albums.count,
            indexedTrackCount: albums.reduce(0) { $0 + $1.tracks.count },
            skippedFolderCount: skippedFolderCount,
            indexWasUpdated: indexWasUpdated
        )
    }

    private nonisolated static func loadExistingManifest(
        from rootURL: URL
    ) -> [LocalLibraryManifestAlbum] {
        let url = rootURL.appendingPathComponent(LocalLibraryManifestLoader.fileName)
        guard let data = try? Data(contentsOf: url),
              let albums = try? JSONDecoder().decode(
                [LocalLibraryManifestAlbum].self,
                from: data
              ) else {
            return []
        }
        return albums
    }

    private nonisolated static func folderPath(
        for candidate: LocalAudioFileCandidate
    ) -> String {
        let folder = (candidate.relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "." : folder
    }

    private nonisolated static func isUnchanged(
        _ album: LocalLibraryManifestAlbum,
        candidates: [LocalAudioFileCandidate]
    ) -> Bool {
        guard album.indexVersion == currentIndexVersion else { return false }
        guard album.tracks.count == candidates.count else { return false }
        let tracksByFilename = Dictionary(
            uniqueKeysWithValues: album.tracks.map { ($0.filename, $0) }
        )

        for candidate in candidates {
            let filename = (candidate.relativePath as NSString).lastPathComponent
            guard let track = tracksByFilename[filename],
                  track.fileSize == candidate.fileSize,
                  let oldNanoseconds = track.modifiedNS else {
                return false
            }
            let newNanoseconds = modificationNanoseconds(candidate.modificationDate)
            // File-provider timestamps can lose sub-millisecond precision when
            // they cross the JSON/Date boundary.
            if abs(oldNanoseconds - newNanoseconds) > 1_000_000 {
                return false
            }
        }
        return true
    }

    private nonisolated static func scanAlbum(
        folderPath: String,
        candidates: [LocalAudioFileCandidate]
    ) async throws -> LocalLibraryManifestAlbum? {
        let scannedFiles = try await scanFiles(candidates, maximumConcurrent: 4)
        guard let albumMetadata = scannedFiles.first,
              let albumMBID = albumMetadata.releaseMBID,
              !albumMBID.isEmpty else {
            return nil
        }

        let matchingFiles = scannedFiles.filter { file in
            guard let releaseMBID = file.releaseMBID, !releaseMBID.isEmpty else {
                return true
            }
            return releaseMBID.caseInsensitiveCompare(albumMBID) == .orderedSame
        }
        let fallbackFolderName = folderPath == "."
            ? "Music"
            : (folderPath as NSString).lastPathComponent
        let fallbackArtist = folderPath == "."
            ? ""
            : ((folderPath as NSString).deletingLastPathComponent as NSString)
                .lastPathComponent

        return LocalLibraryManifestAlbum(
            indexVersion: currentIndexVersion,
            libraryAlbumCount: nil,
            albumName: albumMetadata.albumTitle.isEmpty
                ? fallbackFolderName
                : albumMetadata.albumTitle,
            artistName: albumMetadata.artist.isEmpty
                ? fallbackArtist
                : albumMetadata.artist,
            albumMBID: albumMBID,
            releaseYear: albumMetadata.releaseYear,
            country: albumMetadata.country,
            label: albumMetadata.label,
            mediaFormat: albumMetadata.mediaFormat,
            folderPath: folderPath,
            tracks: matchingFiles.map { file in
                LocalLibraryManifestTrack(
                    filename: (file.relativePath as NSString).lastPathComponent,
                    title: file.title,
                    trackMBID: file.recordingMBID,
                    releaseTrackMBID: file.releaseTrackMBID,
                    codec: file.codec,
                    bitDepth: file.bitDepth,
                    sampleRate: file.sampleRate,
                    bitrate: file.bitrate,
                    channels: file.channelCount,
                    fileSize: file.fileSize,
                    modifiedNS: modificationNanoseconds(file.modificationDate),
                    modifiedAt: file.modificationDate.ISO8601Format()
                )
            }
        )
    }

    private nonisolated static func scanFiles(
        _ candidates: [LocalAudioFileCandidate],
        maximumConcurrent: Int
    ) async throws -> [ScannedAudioFile] {
        guard !candidates.isEmpty else { return [] }
        return try await withThrowingTaskGroup(
            of: (Int, ScannedAudioFile).self,
            returning: [ScannedAudioFile].self
        ) { group in
            var nextIndex = 0
            var results = Array<ScannedAudioFile?>(
                repeating: nil,
                count: candidates.count
            )

            func addNext() {
                guard nextIndex < candidates.count else { return }
                let index = nextIndex
                let candidate = candidates[index]
                nextIndex += 1
                group.addTask {
                    (index, try await LocalLibraryScanner.readMetadata(from: candidate))
                }
            }

            for _ in 0..<min(maximumConcurrent, candidates.count) { addNext() }
            while let (index, file) = try await group.next() {
                results[index] = file
                addNext()
            }
            return results.compactMap { $0 }
        }
    }

    private nonisolated static func modificationNanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}
#endif
