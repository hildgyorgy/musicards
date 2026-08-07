//
//  MusiCardsAppModel.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import Foundation
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import MediaPlayer
#endif

@MainActor
final class MusiCardsAppModel: ObservableObject {
    @Published var deckSelection = DeckSelection<MusiCardID>(
        activeID: .home,
        activeSlotIndex: 0
    )
    @Published var selectedReleaseID: String?
    @Published var selectedRelease: MBRelease?
    @Published var selectedReleaseCover: PlatformImage?
    @Published var isLoadingRelease: Bool = false
    @Published var selectedArtistID: String?
    @Published var selectedArtist: MBArtistDetail?
    @Published var isLoadingArtistHeader: Bool = false
    @Published var isLoadingArtistWikipedia: Bool = false
    @Published var artistReleaseGroups: [MBReleaseGroupSummary] = []
    @Published var artistWikipedia: (title: String, extract: String)?
    @Published var releaseError: Error?
    @Published var artistError: Error?
    @Published var recentArtists: [SearchArtistRow] = []
    @Published var recentReleases: [SearchReleaseRow] = []
    @Published var nowPlayingRelease: SearchReleaseRow?
    @Published private(set) var hasCurrentPlaybackItem = false
    
    @Published var isShazamListening: Bool = false
    @Published var shazamStatusMessage: String?

    // Pagination for release groups
    @Published var isLoadingMoreReleaseGroups: Bool = false
    @Published var hasMoreReleaseGroups: Bool = false

    let searchViewModel: SearchViewModel
    let trackDetailStore: TrackDetailStore
    let classicalMetadataStore: ClassicalMetadataStore
    let playbackController: PlaybackController
    let localLibrary: LocalLibraryStore

    private var localPlaybackNowPlayingCoordinator:
        PlatformNowPlayingCoordinator?
    private var playbackItemObservation: AnyCancellable?

    private let musicBrainzService = MusicBrainzService()

    private let recentArtistsKey = "recentArtists"
    private let recentReleasesKey = "recentReleases"

#if os(iOS)
    private let shazamService = ShazamRecognitionService()
    private var nowPlayingReleaseGroupID: String?
    private var nowPlayingReleaseGroupTitle: String?
    private var nowPlayingArtistName: String?
    private var nowPlayingObserver: NSObjectProtocol?
    #endif

    private let releaseGroupsPageSize: Int = 25
    private var releaseGroupsOffset: Int = 0
    private var currentArtistIDForGroups: String?

    init(playbackEngine: PlaybackEngine? = nil) {
        let service = musicBrainzService
        let playbackEngine = playbackEngine ?? PlaybackEngineFactory.makeDefault()

        self.searchViewModel = SearchViewModel(service: service)
        self.trackDetailStore = TrackDetailStore(service: service)
        self.classicalMetadataStore = ClassicalMetadataStore(service: service)
        self.playbackController = PlaybackController(engine: playbackEngine)
        self.localLibrary = LocalLibraryStore()
        self.localPlaybackNowPlayingCoordinator =
            PlatformNowPlayingCoordinator(controller: self.playbackController)
        self.playbackItemObservation = self.playbackController.$currentIndex
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] hasCurrentItem in
                self?.hasCurrentPlaybackItem = hasCurrentItem
            }

        loadRecents()
#if os(iOS)
        startNowPlayingUpdates()
        #endif
        localLibrary.startAutomaticRefresh()
    }

    func playLocalFile(_ url: URL) {
        let request = playbackController.beginQueueRequest()
        Task {
            guard await playbackController.prepareForQueueReplacement(request)
            else { return }
            let artworkData = await LocalAudioMetadataLoader.artworkData(
                from: url
            )
            guard !Task.isCancelled else { return }
            let track = PlaybackTrack(
                id: url.standardizedFileURL.path,
                releaseTrackID: nil,
                recordingID: nil,
                releaseID: nil,
                title: url.deletingPathExtension().lastPathComponent,
                artist: "Local audio",
                albumTitle: "",
                duration: nil,
                artworkData: artworkData
            )
            let item = PlaybackQueueItem(
                track: track,
                source: .localFile(url)
            )

            guard await playbackController.replaceQueue(
                with: [item],
                request: request
            ) else { return }
            await playbackController.play()
        }
    }

    func selectMusicFolder(_ url: URL) {
        localLibrary.selectMusicFolder(url)
    }

    func refreshLocalLibrary() {
        Task { await localLibrary.refreshAll() }
    }

    func restoreAudioOutputConfiguration() {
        playbackController.restoreOutputConfiguration()
    }

    func playIndexedTrack(
        releaseTrackID: String?,
        recordingID: String?
    ) {
        guard let release = selectedRelease,
              let selectedFile = localLibrary.audioFile(
                releaseID: release.id,
                releaseTrackID: releaseTrackID,
                recordingID: recordingID
              ),
              let selectedURL = localLibrary.url(for: selectedFile) else {
            return
        }

        let request = playbackController.beginQueueRequest()
        Task {
            guard await playbackController.prepareForQueueReplacement(request)
            else { return }
            let artworkData = await LocalAudioMetadataLoader.artworkData(
                from: selectedURL
            )
            guard !Task.isCancelled else { return }
            let artist = MBTextFormatter.artistLine(from: release.artistCredit)
            var items: [PlaybackQueueItem] = []
            var selectedIndex = 0

            for (mediumIndex, medium) in (release.media ?? []).enumerated() {
                for track in medium.tracks ?? [] {
                    guard let file = localLibrary.audioFile(
                        releaseID: release.id,
                        releaseTrackID: track.id,
                        recordingID: track.recording?.id
                    ), let url = localLibrary.url(for: file) else {
                        continue
                    }

                    if trackMatchesSelection(
                        track,
                        releaseTrackID: releaseTrackID,
                        recordingID: recordingID
                    ) {
                        selectedIndex = items.count
                    }
                    let playbackTrack = PlaybackTrack(
                        id: file.id,
                        releaseTrackID: file.releaseTrackMBID ?? track.id,
                        recordingID: file.recordingMBID,
                        releaseID: file.releaseMBID,
                        title: track.title,
                        artist: artist.isEmpty ? file.artist : artist,
                        albumTitle: release.title,
                        duration: file.duration ?? track.length.map {
                            Double($0) / 1_000
                        },
                        artworkData: artworkData,
                        mediumFormat: medium.format,
                        discNumber: medium.position ?? mediumIndex + 1,
                        trackNumber: track.position,
                        audioFormat: PlaybackAudioFormat(
                            codec: file.codec,
                            bitDepth: file.bitDepth,
                            sampleRate: file.sampleRate,
                            bitrate: file.bitrate,
                            channelCount: file.channelCount
                        )
                    )
                    items.append(
                        PlaybackQueueItem(
                            track: playbackTrack,
                            source: .localFile(url)
                        )
                    )
                }
            }

            guard !items.isEmpty else {
                playbackController.abandonQueueRequest(request)
                return
            }
            guard await playbackController.replaceQueue(
                with: items,
                startingAt: selectedIndex,
                request: request
            ) else { return }
            await playbackController.play()
        }
    }

    private func trackMatchesSelection(
        _ track: MBTrack,
        releaseTrackID: String?,
        recordingID: String?
    ) -> Bool {
        if let releaseTrackID {
            return track.id == releaseTrackID
        }
        return track.recording?.id == recordingID
    }

    var isBlockingNavigationLoad: Bool {
        isLoadingRelease || isLoadingArtistHeader
    }

    // MARK: - Release

    func selectRelease(_ row: SearchReleaseRow) {
        selectedReleaseID = row.id
        isLoadingRelease = true
        releaseError = nil
        selectedRelease = nil
        selectedReleaseCover = nil

        Task {
            await loadReleaseAndCover(id: row.id)
        }
    }

    func retryRelease() {
        guard let selectedReleaseID else { return }

        isLoadingRelease = true
        releaseError = nil
        selectedRelease = nil
        selectedReleaseCover = nil

        Task {
            await loadReleaseAndCover(id: selectedReleaseID)
        }
    }

    private func loadReleaseAndCover(id: String) async {
        do {
            let release = try await musicBrainzService.loadRelease(id: id)
            let cover = await CoverArtCache.shared.image(for: id, size: .full)

            selectedRelease = release
            selectedReleaseCover = cover
            isLoadingRelease = false

            withAnimation(AppStyle.animation) {
                deckSelection = DeckSelection<MusiCardID>(
                    activeID: .release,
                    activeSlotIndex: MusiCardID.release.slotIndex
                )
            }
        } catch {
            selectedRelease = nil
            selectedReleaseCover = nil
            isLoadingRelease = false
            releaseError = error
        }
    }

    // MARK: - Artist

    func selectArtist(_ row: SearchArtistRow) {
        selectArtist(id: row.id)
    }

    func selectArtist(id: String) {
        // Reset pagination
        releaseGroupsOffset = 0
        hasMoreReleaseGroups = false
        isLoadingMoreReleaseGroups = false
        currentArtistIDForGroups = nil

        selectedArtistID = id
        selectedArtist = nil
        artistReleaseGroups = []
        artistWikipedia = nil
        artistError = nil

        isLoadingArtistHeader = true
        isLoadingArtistWikipedia = false

        Task {
            await loadArtist(id: id)
        }
    }

    func retryArtist() {
        if let artistID = selectedArtistID {
            selectArtist(id: artistID)
        }
    }

    private func loadArtist(id: String) async {
        do {
            // Load artist info and first page of release groups in parallel
            async let artistTask = musicBrainzService.fetchArtist(id: id)
            async let releaseGroupsTask = musicBrainzService.fetchArtistReleaseGroups(
                id: id,
                limit: releaseGroupsPageSize,
                offset: 0
            )

            let artist = try await artistTask
            let (groups, hasMore) = try await releaseGroupsTask

            selectedArtist = artist
            artistReleaseGroups = groups
            hasMoreReleaseGroups = hasMore
            releaseGroupsOffset = groups.count
            currentArtistIDForGroups = id

            isLoadingArtistHeader = false

            withAnimation(AppStyle.animation) {
                deckSelection = DeckSelection<MusiCardID>(
                    activeID: .artist,
                    activeSlotIndex: MusiCardID.artist.slotIndex
                )
            }

            // Wikipedia loads after — non-blocking, card is already visible
            isLoadingArtistWikipedia = true

            if let wikidataURL = artist.relations?
                .first(where: { $0.type == "wikidata" })?
                .url?
                .resource
                .flatMap(URL.init(string:)) {

                artistWikipedia = try await musicBrainzService.fetchWikipediaSummary(from: wikidataURL)
            } else {
                artistWikipedia = nil
            }

            isLoadingArtistWikipedia = false

        } catch {
            selectedArtist = nil
            artistReleaseGroups = []
            artistWikipedia = nil
            isLoadingArtistHeader = false
            isLoadingArtistWikipedia = false
            artistError = error
        }
    }

    // MARK: - Release group pagination

    func loadMoreReleaseGroupsIfNeeded(currentItem: MBReleaseGroupSummary) {
        guard !isLoadingMoreReleaseGroups, hasMoreReleaseGroups else { return }

        // Trigger when within 5 items of the end
        let threshold = max(artistReleaseGroups.count - 5, 0)
        guard let index = artistReleaseGroups.firstIndex(of: currentItem),
              index >= threshold else { return }

        isLoadingMoreReleaseGroups = true

        Task {
            await loadMoreReleaseGroups()
        }
    }

    private func loadMoreReleaseGroups() async {
        guard let artistID = currentArtistIDForGroups else {
            isLoadingMoreReleaseGroups = false
            return
        }

        do {
            let (groups, hasMore) = try await musicBrainzService.fetchArtistReleaseGroups(
                id: artistID,
                limit: releaseGroupsPageSize,
                offset: releaseGroupsOffset
            )

            artistReleaseGroups.append(contentsOf: groups)
            hasMoreReleaseGroups = hasMore
            releaseGroupsOffset += groups.count

        } catch {
            // Silently fail — user can scroll again to retry
        }

        isLoadingMoreReleaseGroups = false
    }

    // MARK: - Release group selection

    func selectReleaseGroup(_ group: MBReleaseGroupSummary) {
        guard let artistName = selectedArtist?.name else { return }

        searchViewModel.loadReleaseGroupResults(
            releaseGroupID: group.id,
            releaseTitle: group.title,
            artistName: artistName
        )

        deckSelection = DeckSelection<MusiCardID>(
            activeID: .search,
            activeSlotIndex: MusiCardID.search.slotIndex
        )
    }

    // MARK: - Recents

    func addRecentArtist(_ artist: SearchArtistRow) {
        recentArtists.removeAll { $0.id == artist.id }
        recentArtists.insert(artist, at: 0)
        recentArtists = Array(recentArtists.prefix(3))
        saveRecents()
    }

    func addRecentRelease(_ release: SearchReleaseRow) {
        recentReleases.removeAll { $0.id == release.id }
        recentReleases.insert(release, at: 0)
        recentReleases = Array(recentReleases.prefix(3))
        saveRecents()
    }

    private func loadRecents() {
        let defaults = UserDefaults.standard

        if let artistData = defaults.data(forKey: recentArtistsKey),
           let decodedArtists = try? JSONDecoder().decode([SearchArtistRow].self, from: artistData) {
            recentArtists = decodedArtists
        }

        if let releaseData = defaults.data(forKey: recentReleasesKey),
           let decodedReleases = try? JSONDecoder().decode([SearchReleaseRow].self, from: releaseData) {
            recentReleases = decodedReleases
        }
    }

    private func saveRecents() {
        let defaults = UserDefaults.standard

        if let artistData = try? JSONEncoder().encode(recentArtists) {
            defaults.set(artistData, forKey: recentArtistsKey)
        }

        if let releaseData = try? JSONEncoder().encode(recentReleases) {
            defaults.set(releaseData, forKey: recentReleasesKey)
        }
    }

    // MARK: - Shazam

    func startShazamSearch() {
    #if os(iOS)
        guard !isShazamListening else { return }

        isShazamListening = true
        shazamStatusMessage = nil

        Task {
            do {
                let match = try await shazamService.recognize()

                print("Shazam match:", match.artist, "-", match.title)

                searchViewModel.searchByRecognizedTrack(match)

                isShazamListening = false
                shazamStatusMessage = nil
                
            } catch {
                print("Shazam error:", error)

                shazamStatusMessage = shazamMessage(for: error)

                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    shazamStatusMessage = nil
                }

                isShazamListening = false
            }
        }
    #endif
    }
    
    private func shazamMessage(for error: Error) -> String {
    #if os(iOS)
        if let shazamError = error as? ShazamRecognitionError {
            switch shazamError {
            case .microphonePermissionDenied:
                return "Microphone access denied"
            case .noMatch:
                return "No match"
            case .missingTitleOrArtist:
                return "Incomplete Shazam match"
            }
        }
    #endif

        return "Shazam failed"
    }
    
    // MARK: - Now Playing

#if os(iOS)
    func openNowPlayingVersions() {
        guard
            let groupID = nowPlayingReleaseGroupID,
            let release = nowPlayingRelease
        else { return }

        searchViewModel.loadReleaseGroupResults(
            releaseGroupID: groupID,
            releaseTitle: nowPlayingReleaseGroupTitle ?? release.title,
            artistName: nowPlayingArtistName ?? release.artistLine
        )

        withAnimation(AppStyle.animation) {
            deckSelection = DeckSelection<MusiCardID>(
                activeID: .search,
                activeSlotIndex: MusiCardID.search.slotIndex
            )
        }
    }

    private func startNowPlayingUpdates() {
        guard nowPlayingObserver == nil else { return }

        let status = MPMediaLibrary.authorizationStatus()

        if status == .authorized {
            Task {
                await refreshNowPlayingRelease()
            }
        } else if status == .notDetermined {
            MPMediaLibrary.requestAuthorization { [weak self] newStatus in
                guard newStatus == .authorized else { return }

                Task { @MainActor in
                    await self?.refreshNowPlayingRelease()
                }
            }
        }

        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()

        nowPlayingObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNowPlayingRelease()
            }
        }
    }

    private func refreshNowPlayingRelease() async {
        let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem

        guard let album = item?.albumTitle,
              !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            nowPlayingRelease = nil
            nowPlayingReleaseGroupID = nil
            nowPlayingReleaseGroupTitle = nil
            nowPlayingArtistName = nil
            return
        }

        let artist =
            item?.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? item?.albumArtist
            : item?.artist

        guard let artist,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            nowPlayingRelease = nil
            nowPlayingReleaseGroupID = nil
            nowPlayingReleaseGroupTitle = nil
            nowPlayingArtistName = nil
            return
        }

        do {
            let query = "\(artist), \(album)"

            let results = try await musicBrainzService.searchReleases(
                query: query,
                limit: 5,
                offset: 0
            )

            guard let best = results.first else {
                nowPlayingRelease = nil
                nowPlayingReleaseGroupID = nil
                nowPlayingReleaseGroupTitle = nil
                nowPlayingArtistName = nil
                return
            }

            let hasCoverArt = await CoverArtCache.shared.image(for: best.id, size: .thumbnail) != nil
            let detailedRelease = try? await musicBrainzService.loadRelease(id: best.id)

            nowPlayingRelease = SearchReleaseRow(
                id: best.id,
                title: best.title,
                artistLine: best.artistCredit?.compactMap { $0.name }.joined(separator: ", ") ?? "",
                metaLine: MBTextFormatter.releaseMetaLine(
                    year: MBTextFormatter.year(from: best.date),
                    country: best.country,
                    label: best.labelInfo?.compactMap { $0.label?.name }.first,
                    format: best.media?.compactMap { $0.format }.first
                ),
                disambiguation: best.disambiguation ?? "",
                hasCoverArt: hasCoverArt
            )

            nowPlayingReleaseGroupID = detailedRelease?.releaseGroup?.id
            nowPlayingReleaseGroupTitle = detailedRelease?.releaseGroup?.title ?? best.title
            nowPlayingArtistName = artist

        } catch {
            nowPlayingRelease = nil
            nowPlayingReleaseGroupID = nil
            nowPlayingReleaseGroupTitle = nil
            nowPlayingArtistName = nil
        }
    }
#endif
}
