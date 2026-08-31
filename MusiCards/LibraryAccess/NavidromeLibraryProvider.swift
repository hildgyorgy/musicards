import Combine
import Foundation

@MainActor
protocol NavidromeCatalogConnectionProviding: AnyObject {
    func catalogCredentials() throws -> NavidromeCatalogCredentials
}

nonisolated protocol OpenSubsonicCatalogClientProtocol: Sendable {
    func albumListPage(
        profile: NavidromeServerProfile,
        password: String,
        offset: Int,
        size: Int
    ) async throws -> [OpenSubsonicAlbum]

    func album(
        profile: NavidromeServerProfile,
        password: String,
        id: String
    ) async throws -> OpenSubsonicAlbum
}

extension OpenSubsonicClient: OpenSubsonicCatalogClientProtocol {}

nonisolated private struct NavidromeMatchedSong: Sendable {
    let song: OpenSubsonicSong
    let fallbackArtist: String
}

/// Cached Navidrome availability keyed by MusicBrainz release and recording IDs.
@MainActor
final class NavidromeLibraryProvider: ObservableObject, LibraryProvider {
    let source: LibrarySource = .navidrome
    @Published private(set) var catalogState: LibraryCatalogState = .unknown
    @Published private(set) var catalogSummary = LibraryCatalogSummary()

    private let connection: any NavidromeCatalogConnectionProviding
    private let client: any OpenSubsonicCatalogClientProtocol
    private let pageSize: Int
    private let foregroundRefreshInterval: TimeInterval
    private let now: () -> Date
    private var releaseIDs = Set<String>()
    private var albumIDsByReleaseID = [String: Set<String>]()
    private var catalogReleasesByID = [String: LibraryCatalogRelease]()
    private var recordingIDsByReleaseID = [String: Set<String>]()
    private var matchedSongsByReleaseID =
        [String: [String: NavidromeMatchedSong]]()
    private var normalizedArtistCredits = Set<String>()
    private var normalizedArtistCreditsByAlbumTitle = [String: Set<String>]()
    private var catalogRefreshTask: Task<Void, Never>?
    private var detailLoadTasks = [String: Task<Void, Never>]()
    private var catalogGeneration = 0
    private var lastSuccessfulCatalogRefresh: Date?
    private var connectionObservation: AnyCancellable?

    init(
        connectionStore: NavidromeConnectionStore,
        client: any OpenSubsonicCatalogClientProtocol = OpenSubsonicClient(),
        pageSize: Int = 500,
        foregroundRefreshInterval: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.connection = connectionStore
        self.client = client
        self.pageSize = min(max(pageSize, 1), 500)
        self.foregroundRefreshInterval = max(foregroundRefreshInterval, 0)
        self.now = now
        connectionObservation = connectionStore.$savedProfile
            .removeDuplicates()
            .dropFirst()
            .sink { @MainActor [weak self] _ in
                self?.invalidateCatalog()
            }
    }

    init(
        connection: any NavidromeCatalogConnectionProviding,
        client: any OpenSubsonicCatalogClientProtocol,
        pageSize: Int = 500,
        foregroundRefreshInterval: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.connection = connection
        self.client = client
        self.pageSize = min(max(pageSize, 1), 500)
        self.foregroundRefreshInterval = max(foregroundRefreshInterval, 0)
        self.now = now
    }

    var availabilityChanges: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    func refreshCatalog() async {
        if let catalogRefreshTask {
            await catalogRefreshTask.value
            return
        }

        let refreshGeneration = catalogGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCatalogRefresh(generation: refreshGeneration)
        }
        catalogRefreshTask = task
        await task.value
        if refreshGeneration == catalogGeneration {
            catalogRefreshTask = nil
        }
    }

    func refreshCatalogIfNeeded() async {
        if let lastSuccessfulCatalogRefresh {
            let age = now().timeIntervalSince(lastSuccessfulCatalogRefresh)
            if age >= 0, age < foregroundRefreshInterval {
                return
            }
        }
        await refreshCatalog()
    }

    private func performCatalogRefresh(generation refreshGeneration: Int) async {
        catalogState = .loading

        do {
            let credentials = try connection.catalogCredentials()
            var refreshedReleaseIDs = Set<String>()
            var refreshedAlbumIDsByReleaseID = [String: Set<String>]()
            var refreshedCatalogReleasesByID =
                [String: LibraryCatalogRelease]()
            var refreshedArtistCredits = Set<String>()
            var refreshedArtistCreditsByAlbumTitle = [String: Set<String>]()
            var seenAlbumIDs = Set<String>()
            var offset = 0

            while true {
                try Task.checkCancellation()
                let albums = try await client.albumListPage(
                    profile: credentials.profile,
                    password: credentials.password,
                    offset: offset,
                    size: pageSize
                )

                let pageAlbumIDs = Set(albums.map(\.id))
                if !albums.isEmpty,
                   pageAlbumIDs.isSubset(of: seenAlbumIDs) {
                    throw NavidromeConnectionError.invalidResponse
                }
                seenAlbumIDs.formUnion(pageAlbumIDs)

                for album in albums {
                    let artistCredits = Self.normalizedArtistCredits(
                        in: album
                    )
                    guard let releaseID = Self.releaseID(
                        from: album.musicBrainzID
                    ) else {
                        continue
                    }
                    // Only identified albums are playable MusicBrainz
                    // results. Artist credits from untagged Navidrome albums
                    // must not paint unrelated MB artist rows as playable.
                    refreshedArtistCredits.formUnion(artistCredits)
                    refreshedReleaseIDs.insert(releaseID)
                    refreshedAlbumIDsByReleaseID[releaseID, default: []]
                        .insert(album.id)
                    if refreshedCatalogReleasesByID[releaseID] == nil {
                        refreshedCatalogReleasesByID[releaseID] =
                            Self.catalogRelease(
                                releaseID: releaseID,
                                album: album
                            )
                    }
                    let albumTitle = Self.normalizedLibraryText(
                        album.name
                    )
                    if !albumTitle.isEmpty {
                        refreshedArtistCreditsByAlbumTitle[
                            albumTitle,
                            default: []
                        ].formUnion(artistCredits)
                    }
                }

                offset += albums.count
                if albums.count < pageSize {
                    break
                }
            }

            guard refreshGeneration == catalogGeneration else { return }
            recordingIDsByReleaseID = recordingIDsByReleaseID.filter {
                refreshedAlbumIDsByReleaseID[$0.key] == albumIDsByReleaseID[$0.key]
            }
            matchedSongsByReleaseID = matchedSongsByReleaseID.filter {
                refreshedAlbumIDsByReleaseID[$0.key] == albumIDsByReleaseID[$0.key]
            }
            releaseIDs = refreshedReleaseIDs
            albumIDsByReleaseID = refreshedAlbumIDsByReleaseID
            catalogReleasesByID = refreshedCatalogReleasesByID
            normalizedArtistCredits = refreshedArtistCredits
            normalizedArtistCreditsByAlbumTitle =
                refreshedArtistCreditsByAlbumTitle
            catalogSummary = LibraryCatalogSummary(
                identifiedAlbumCount: refreshedAlbumIDsByReleaseID.values
                    .reduce(0) { $0 + $1.count },
                totalAlbumCount: seenAlbumIDs.count
            )
            lastSuccessfulCatalogRefresh = now()
            catalogState = .ready
        } catch is CancellationError {
            guard refreshGeneration == catalogGeneration else { return }
            catalogState = lastSuccessfulCatalogRefresh == nil
                ? .unknown : .ready
        } catch {
            guard refreshGeneration == catalogGeneration else { return }
            catalogState = lastSuccessfulCatalogRefresh == nil
                ? .failed(error.localizedDescription) : .ready
        }
    }

    func prepareTrackAvailability(forRelease releaseID: String) async {
        guard let releaseID = Self.releaseID(from: releaseID) else { return }

        if catalogState != .ready {
            await refreshCatalog()
        }
        guard catalogState == .ready,
              recordingIDsByReleaseID[releaseID] == nil,
              let albumIDs = albumIDsByReleaseID[releaseID],
              albumIDs.count == 1,
              let albumID = albumIDs.first else {
            return
        }

        if let detailLoadTask = detailLoadTasks[releaseID] {
            await detailLoadTask.value
            return
        }

        let detailGeneration = catalogGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadTrackAvailability(
                releaseID: releaseID,
                albumID: albumID,
                generation: detailGeneration
            )
        }
        detailLoadTasks[releaseID] = task
        await task.value
        if detailGeneration == catalogGeneration {
            detailLoadTasks[releaseID] = nil
        }
    }

    func searchCatalog(
        query: String,
        limit: Int
    ) -> [LibraryCatalogRelease] {
        return LibraryCatalogSearch.search(
            catalogReleasesByID.keys.sorted().compactMap {
                catalogReleasesByID[$0]
            },
            query: query,
            limit: limit
        )
    }

    private func loadTrackAvailability(
        releaseID: String,
        albumID: String,
        generation: Int
    ) async {
        do {
            let credentials = try connection.catalogCredentials()
            let detail = try await client.album(
                profile: credentials.profile,
                password: credentials.password,
                id: albumID
            )
            try Task.checkCancellation()
            guard generation == catalogGeneration,
                  albumIDsByReleaseID[releaseID] == [albumID] else {
                return
            }

            recordingIDsByReleaseID[releaseID] =
                Self.uniqueRecordingIDs(in: detail.songs)
            matchedSongsByReleaseID[releaseID] =
                Self.uniqueMatchedSongs(in: detail)
            if let existing = catalogReleasesByID[releaseID] {
                catalogReleasesByID[releaseID] = LibraryCatalogRelease(
                    releaseID: existing.releaseID,
                    title: existing.title,
                    artistName: existing.artistName,
                    date: existing.date,
                    country: existing.country,
                    label: existing.label,
                    format: existing.format ?? Self.albumFormat(detail),
                    trackTitles: detail.songs.compactMap(\.title)
                )
            }
            objectWillChange.send()
        } catch {
            // A failed detail request leaves any previously valid cache intact.
        }
    }

    func containsRelease(_ releaseID: String) -> Bool {
        guard let releaseID = Self.releaseID(from: releaseID) else {
            return false
        }
        return releaseIDs.contains(releaseID)
    }

    func containsArtist(named artistName: String) -> Bool {
        let artist = Self.normalizedLibraryText(artistName)
        guard !artist.isEmpty else { return false }
        return normalizedArtistCredits.contains(artist)
    }

    func containsReleaseGroup(title: String, artistName: String) -> Bool {
        let artist = Self.normalizedLibraryText(artistName)
        let album = Self.normalizedLibraryText(title)
        guard !artist.isEmpty, !album.isEmpty else { return false }
        return normalizedArtistCreditsByAlbumTitle[album]?.contains {
            Self.artistCredit($0, contains: artist)
        } == true
    }

    func containsTrack(_ identity: LibraryTrackIdentity) -> Bool {
        guard identity.allowsRecordingFallback,
              let releaseID = Self.releaseID(from: identity.releaseID),
              let recordingID = Self.recordingID(from: identity.recordingID)
        else {
            return false
        }
        return recordingIDsByReleaseID[releaseID]?.contains(recordingID) == true
    }

    func playableTrack(
        for identity: LibraryTrackIdentity
    ) -> LibraryPlayableTrack? {
        guard identity.allowsRecordingFallback,
              let releaseID = Self.releaseID(from: identity.releaseID),
              let recordingID = Self.recordingID(from: identity.recordingID),
              let match = matchedSongsByReleaseID[releaseID]?[recordingID]
        else {
            return nil
        }
        let song = match.song
        return LibraryPlayableTrack(
            id: song.id,
            releaseTrackID: identity.releaseTrackID,
            recordingID: recordingID,
            releaseID: releaseID,
            fallbackArtist: match.fallbackArtist,
            duration: song.duration.map(TimeInterval.init),
            audioFormat: Self.playbackAudioFormat(for: song),
            assetReference: PlaybackAssetReference(
                source: source,
                providerItemID: song.id,
                displayName: "NAVIDROME",
                seekCapability: .remoteMedia(
                    suffix: song.suffix,
                    contentType: song.contentType
                )
            )
        )
    }

    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        guard reference.source == source,
              let match = matchedSongsByReleaseID.values.lazy
                .compactMap({ matches in
                    matches.values.first {
                        $0.song.id == reference.providerItemID
                    }
                }).first,
              let mediaSize = match.song.size,
              mediaSize > 0 else {
            throw PlaybackAssetResolutionError.assetUnavailable
        }
        let provider = NavidromeRemoteAudioByteSourceProvider(
            connection: connection,
            songID: match.song.id,
            mediaSize: mediaSize
        )
        return .remoteAudio(
            RemotePlaybackAsset(
                source: source,
                providerItemID: match.song.id,
                displayName: "NAVIDROME",
                mediaSize: mediaSize,
                suffix: match.song.suffix,
                contentType: match.song.contentType,
                byteSourceProvider: provider
            )
        )
    }

    private func invalidateCatalog() {
        catalogGeneration += 1
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        for task in detailLoadTasks.values {
            task.cancel()
        }
        detailLoadTasks.removeAll()
        releaseIDs.removeAll()
        albumIDsByReleaseID.removeAll()
        catalogReleasesByID.removeAll()
        recordingIDsByReleaseID.removeAll()
        matchedSongsByReleaseID.removeAll()
        normalizedArtistCredits.removeAll()
        normalizedArtistCreditsByAlbumTitle.removeAll()
        catalogSummary = LibraryCatalogSummary()
        lastSuccessfulCatalogRefresh = nil
        catalogState = .unknown
    }

    nonisolated static func releaseID(from value: String?) -> String? {
        canonicalMBID(from: value)
    }

    nonisolated static func recordingID(from value: String?) -> String? {
        canonicalMBID(from: value)
    }

    nonisolated private static func canonicalMBID(from value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed),
              uuid.uuidString.caseInsensitiveCompare(trimmed) == .orderedSame else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    nonisolated private static func normalizedArtistCredits(
        in album: OpenSubsonicAlbum
    ) -> Set<String> {
        let values = album.artists.map(\.name) + [album.artist].compactMap { $0 }
        return Set(
            values.compactMap { value in
                let normalized = normalizedLibraryText(value)
                return normalized.isEmpty ? nil : normalized
            }
        )
    }

    nonisolated private static func catalogRelease(
        releaseID: String,
        album: OpenSubsonicAlbum
    ) -> LibraryCatalogRelease {
        let artistName = album.artist?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let fallbackArtist = artistName.isEmpty
            ? album.artists.map(\.name).joined(separator: ", ")
            : artistName
        return LibraryCatalogRelease(
            releaseID: releaseID,
            title: album.name,
            artistName: fallbackArtist,
            format: albumFormat(album),
            trackTitles: album.songs.compactMap(\.title)
        )
    }

    nonisolated private static func albumFormat(
        _ album: OpenSubsonicAlbum
    ) -> String? {
        let formats = Set(
            album.songs.compactMap { song in
                let suffix = song.suffix?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                return suffix.isEmpty ? nil : suffix.uppercased()
            }
        )
        guard !formats.isEmpty else { return nil }
        return formats.sorted().joined(separator: "/")
    }

    nonisolated private static func normalizedLibraryText(
        _ value: String
    ) -> String {
        LibraryCatalogSearch.normalizedText(value)
    }

    nonisolated private static func artistCredit(
        _ credit: String,
        contains artist: String
    ) -> Bool {
        credit == artist
            || credit.hasPrefix("\(artist) ")
            || credit.hasSuffix(" \(artist)")
            || credit.contains(" \(artist) ")
    }

    nonisolated private static func uniqueRecordingIDs(
        in songs: [OpenSubsonicSong]
    ) -> Set<String> {
        var occurrenceCounts = [String: Int]()
        for song in songs {
            guard let recordingID = recordingID(from: song.musicBrainzID) else {
                continue
            }
            occurrenceCounts[recordingID, default: 0] += 1
        }
        return Set(
            occurrenceCounts.compactMap { recordingID, count in
                count == 1 ? recordingID : nil
            }
        )
    }

    nonisolated private static func uniqueMatchedSongs(
        in album: OpenSubsonicAlbum
    ) -> [String: NavidromeMatchedSong] {
        let uniqueIDs = uniqueRecordingIDs(in: album.songs)
        let albumArtist = album.artist?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let fallbackArtist = albumArtist.isEmpty
            ? album.artists.map(\.name).joined(separator: ", ")
            : albumArtist
        var matches = [String: NavidromeMatchedSong]()
        for song in album.songs {
            guard let recordingID = recordingID(from: song.musicBrainzID),
                  uniqueIDs.contains(recordingID) else {
                continue
            }
            matches[recordingID] = NavidromeMatchedSong(
                song: song,
                fallbackArtist: fallbackArtist
            )
        }
        return matches
    }

    nonisolated private static func playbackAudioFormat(
        for song: OpenSubsonicSong
    ) -> PlaybackAudioFormat? {
        guard let sampleRate = song.samplingRate,
              sampleRate > 0,
              let channelCount = song.channelCount,
              channelCount > 0 else {
            return nil
        }
        return PlaybackAudioFormat(
            codec: song.suffix?.uppercased() ?? "REMOTE",
            bitDepth: song.bitDepth,
            sampleRate: Double(sampleRate),
            bitrate: song.bitRate.map { Double($0) * 1_000 },
            channelCount: channelCount
        )
    }
}
