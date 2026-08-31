//
//  LocalLibraryLookup.swift
//  MusiCards
//

import Foundation

/// Immutable, in-memory view of the connected library.
///
/// Keeping matching here makes the MusicBrainz identity policy independently
/// testable while the SwiftData store remains responsible only for persistence.
nonisolated struct LocalLibraryLookup {
    private let tracksByReleaseID: [String: [LocalAudioFileSnapshot]]
    private let tracksByID: [String: LocalAudioFileSnapshot]
    private let tracksByReleaseTrackKey: [String: LocalAudioFileSnapshot]
    private let legacyTracksByRecordingKey: [String: LocalAudioFileSnapshot]
    private let normalizedArtistCredits: Set<String>
    private let normalizedArtistCreditsByAlbumTitle: [String: Set<String>]
    private let catalogReleases: [LibraryCatalogRelease]

    init(files: [LocalAudioFileSnapshot] = []) {
        let files = files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }

        let groupedTracksByReleaseID = Dictionary(
            grouping: files.compactMap {
                file -> (String, LocalAudioFileSnapshot)? in
                guard let releaseID = Self.nonemptyMBID(file.releaseMBID) else {
                    return nil
                }
                return (releaseID, file)
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }
        tracksByReleaseID = groupedTracksByReleaseID

        tracksByID = Dictionary(
            files.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        normalizedArtistCredits = Set(
            files.compactMap { file in
                // An artist tag on an untagged/unidentified file is not a
                // playable MusicBrainz artist result. Only count artists
                // attached to a release that can actually be resolved.
                guard Self.nonemptyMBID(file.releaseMBID) != nil else {
                    return nil
                }
                let artist = Self.normalizedLibraryText(file.artist)
                return artist.isEmpty ? nil : artist
            }
        )

        var artistsByAlbum: [String: Set<String>] = [:]
        var exactTracks: [String: LocalAudioFileSnapshot] = [:]
        var legacyCandidates: [String: [LocalAudioFileSnapshot]] = [:]

        for file in files {
            let artist = Self.normalizedLibraryText(file.artist)
            let album = Self.normalizedLibraryText(file.albumTitle)
            if !artist.isEmpty, !album.isEmpty {
                artistsByAlbum[album, default: []].insert(artist)
            }

            guard let releaseID = Self.nonemptyMBID(file.releaseMBID) else {
                continue
            }
            if let releaseTrackID = Self.nonemptyMBID(file.releaseTrackMBID) {
                let key = Self.releaseTrackKey(
                    releaseID: releaseID,
                    releaseTrackID: releaseTrackID
                )
                if exactTracks[key] == nil {
                    exactTracks[key] = file
                }
            } else if let recordingID = Self.nonemptyMBID(file.recordingMBID) {
                let key = Self.recordingKey(
                    releaseID: releaseID,
                    recordingID: recordingID
                )
                legacyCandidates[key, default: []].append(file)
            }
        }

        normalizedArtistCreditsByAlbumTitle = artistsByAlbum
        tracksByReleaseTrackKey = exactTracks
        legacyTracksByRecordingKey = legacyCandidates.compactMapValues {
            $0.count == 1 ? $0[0] : nil
        }
        catalogReleases = groupedTracksByReleaseID.keys.sorted().compactMap {
            releaseID in
            guard let releaseFiles = groupedTracksByReleaseID[releaseID],
                  let first = releaseFiles.first else {
                return nil
            }
            return LibraryCatalogRelease(
                releaseID: releaseID,
                title: first.albumTitle,
                artistName: first.artist,
                format: first.codec.isEmpty ? nil : first.codec,
                trackTitles: releaseFiles.map(\.title)
            )
        }
    }

    var releaseCount: Int {
        tracksByReleaseID.count
    }

    func containsRelease(_ releaseID: String) -> Bool {
        tracksByReleaseID[Self.normalizedMBID(releaseID)]?.isEmpty == false
    }

    func searchCatalog(
        query: String,
        limit: Int = 50
    ) -> [LibraryCatalogRelease] {
        LibraryCatalogSearch.search(
            catalogReleases,
            query: query,
            limit: limit
        )
    }

    func audioFile(id: String) -> LocalAudioFileSnapshot? {
        tracksByID[id]
    }

    func containsArtist(named artistName: String) -> Bool {
        let needle = Self.normalizedLibraryText(artistName)
        guard !needle.isEmpty else { return false }
        return normalizedArtistCredits.contains(needle)
    }

    func containsReleaseGroup(title: String, artistName: String) -> Bool {
        let artist = Self.normalizedLibraryText(artistName)
        let album = Self.normalizedLibraryText(title)
        guard !artist.isEmpty, !album.isEmpty else { return false }
        return normalizedArtistCreditsByAlbumTitle[album]?.contains {
            Self.artistCredit($0, contains: artist)
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
        if let releaseTrackID = Self.nonemptyMBID(releaseTrackID),
           let exactMatch = tracksByReleaseTrackKey[
               Self.releaseTrackKey(
                   releaseID: releaseID,
                   releaseTrackID: releaseTrackID
               )
           ] {
            return exactMatch
        }
        guard allowsRecordingFallback,
              let recordingID = Self.nonemptyMBID(recordingID) else {
            return nil
        }
        return legacyTracksByRecordingKey[
            Self.recordingKey(
                releaseID: releaseID,
                recordingID: recordingID
            )
        ]
    }

    private static func normalizedMBID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedLibraryText(_ value: String) -> String {
        LibraryCatalogSearch.normalizedText(value)
    }

    private static func artistCredit(
        _ credit: String,
        contains artist: String
    ) -> Bool {
        credit == artist
            || credit.hasPrefix("\(artist) ")
            || credit.hasSuffix(" \(artist)")
            || credit.contains(" \(artist) ")
    }

    private static func nonemptyMBID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizedMBID(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func recordingKey(
        releaseID: String,
        recordingID: String
    ) -> String {
        "\(normalizedMBID(releaseID))::\(normalizedMBID(recordingID))"
    }

    private static func releaseTrackKey(
        releaseID: String,
        releaseTrackID: String
    ) -> String {
        "\(normalizedMBID(releaseID))::\(normalizedMBID(releaseTrackID))"
    }
}
