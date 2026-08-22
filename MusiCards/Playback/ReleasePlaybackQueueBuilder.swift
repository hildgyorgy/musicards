import Foundation

struct ReleasePlaybackSelection: Equatable, Sendable {
    let releaseTrackID: String?
    let recordingID: String?
}

struct ReleasePlaybackQueue: Equatable, Sendable {
    let items: [PlaybackQueueItem]
    let selectedIndex: Int
}

/// Maps one MusicBrainz release onto playable items supplied by the active
/// library provider. Provider-specific asset locations stay opaque here.
@MainActor
final class ReleasePlaybackQueueBuilder {
    private let libraryManager: LibraryManager

    init(libraryManager: LibraryManager) {
        self.libraryManager = libraryManager
    }

    func canBuildQueue(
        for release: MBRelease,
        selection: ReleasePlaybackSelection
    ) -> Bool {
        playbackSource(for: release, selection: selection) != nil
    }

    func playbackSource(
        for release: MBRelease,
        selection: ReleasePlaybackSelection
    ) -> LibrarySource? {
        libraryManager.playableTrack(
            for: identity(
                release: release,
                releaseTrackID: selection.releaseTrackID,
                recordingID: selection.recordingID
            )
        )?.assetReference.source
    }

    func firstPlayableSelection(
        in release: MBRelease,
        source: LibrarySource? = nil
    ) -> ReleasePlaybackSelection? {
        for medium in release.media ?? [] {
            for track in medium.tracks ?? [] {
                let selection = ReleasePlaybackSelection(
                    releaseTrackID: track.id,
                    recordingID: track.recording?.id
                )
                let identity = identity(
                    release: release,
                    releaseTrackID: selection.releaseTrackID,
                    recordingID: selection.recordingID
                )
                let playableTrack = source.map {
                    libraryManager.playableTrack(for: identity, from: $0)
                } ?? libraryManager.playableTrack(for: identity)
                if playableTrack != nil {
                    return selection
                }
            }
        }
        return nil
    }

    func buildQueue(
        for release: MBRelease,
        selection: ReleasePlaybackSelection,
        source: LibrarySource? = nil,
        artworkData: Data? = nil
    ) async -> ReleasePlaybackQueue? {
        let source = source ?? libraryManager.source
        await libraryManager.prepareTrackAvailability(
            forRelease: release.id,
            from: source
        )
        guard !Task.isCancelled else { return nil }
        guard libraryManager.playableTrack(
            for: identity(
                release: release,
                releaseTrackID: selection.releaseTrackID,
                recordingID: selection.recordingID
            ),
            from: source
        ) != nil else {
            return nil
        }

        let releaseArtist = MBTextFormatter.artistLine(
            from: release.artistCredit
        )
        var items = [PlaybackQueueItem]()
        var selectedIndex = 0

        for (mediumIndex, medium) in (release.media ?? []).enumerated() {
            for track in medium.tracks ?? [] {
                guard let playableTrack = libraryManager.playableTrack(
                    for: identity(
                        release: release,
                        releaseTrackID: track.id,
                        recordingID: track.recording?.id
                    ),
                    from: source
                ) else {
                    continue
                }

                if trackMatches(
                    track,
                    selection: selection
                ) {
                    selectedIndex = items.count
                }

                let playbackTrack = PlaybackTrack(
                    id: playableTrack.id,
                    releaseTrackID: playableTrack.releaseTrackID ?? track.id,
                    recordingID: playableTrack.recordingID,
                    releaseID: playableTrack.releaseID,
                    title: track.title,
                    artist: releaseArtist.isEmpty
                        ? playableTrack.fallbackArtist
                        : releaseArtist,
                    albumTitle: release.title,
                    duration: playableTrack.duration ?? track.length.map {
                        Double($0) / 1_000
                    },
                    artworkData: artworkData,
                    mediumFormat: medium.format,
                    discNumber: medium.position ?? mediumIndex + 1,
                    trackNumber: track.position,
                    audioFormat: playableTrack.audioFormat
                )
                items.append(
                    PlaybackQueueItem(
                        track: playbackTrack,
                        source: .libraryAsset(
                            playableTrack.assetReference
                        )
                    )
                )
            }
        }

        guard !items.isEmpty else { return nil }
        return ReleasePlaybackQueue(
            items: items,
            selectedIndex: selectedIndex
        )
    }

    private func identity(
        release: MBRelease,
        releaseTrackID: String?,
        recordingID: String?
    ) -> LibraryTrackIdentity {
        LibraryTrackIdentity(
            releaseID: release.id,
            releaseTrackID: releaseTrackID,
            recordingID: recordingID,
            allowsRecordingFallback: release.hasUniqueOccurrence(
                ofRecordingID: recordingID
            )
        )
    }

    private func trackMatches(
        _ track: MBTrack,
        selection: ReleasePlaybackSelection
    ) -> Bool {
        if let releaseTrackID = selection.releaseTrackID {
            return track.id == releaseTrackID
        }
        return track.recording?.id == selection.recordingID
    }
}
