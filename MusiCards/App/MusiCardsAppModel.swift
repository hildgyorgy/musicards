//
//  MusiCardsAppModel.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import Foundation
import SwiftUI
import Combine
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import MediaPlayer
#endif

@MainActor
final class MusiCardsAppModel: ObservableObject {
    nonisolated private static let shazamLogger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "Shazam"
    )

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
    @Published var selectedArtistName: String = ""
    @Published var selectedArtistLifeSpan: String?
    @Published var isLoadingArtistHeader: Bool = false
    @Published var isLoadingArtistWikipedia: Bool = false
    @Published var artistReleaseGroups: [MBReleaseGroupSummary] = []
    @Published var discographyError: Error?
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

    @Published var activeLibrarySource: LibrarySource? {
        didSet {
            libraryManager.setActiveSource(activeLibrarySource)
            LibrarySourcePreference.save(activeLibrarySource)
        }
    }

    let searchViewModel: SearchViewModel
    let trackDetailStore: TrackDetailStore
    let classicalMetadataStore: ClassicalMetadataStore
    let playbackController: PlaybackController
    let localLibrary: LocalLibraryStore
    let libraryManager: LibraryManager
    let navidromeConnection: NavidromeConnectionStore
    private let releasePlaybackQueueBuilder: ReleasePlaybackQueueBuilder

    private var localPlaybackNowPlayingCoordinator:
        PlatformNowPlayingCoordinator?
    private var playbackItemObservation: AnyCancellable?
    private var searchModeObservation: AnyCancellable?

    private let musicBrainzService = MusicBrainzService()
    private let releaseDetailLoader: @Sendable (String) async throws -> MBRelease
    private let releaseCoverLoader: @Sendable (String) async -> PlatformImage?

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
    private var releaseSelectionGeneration: UInt64 = 0
    private var releaseLoadTask: Task<Void, Never>?
    private var artistSelectionGeneration: UInt64 = 0
    private var artistLoadTask: Task<Void, Never>?
    private var artistPaginationTask: Task<Void, Never>?

    init(
        playbackEngine: PlaybackEngine? = nil,
        releaseDetailLoader: (@Sendable (String) async throws -> MBRelease)? = nil,
        releaseCoverLoader: (@Sendable (String) async -> PlatformImage?)? = nil
    ) {
        let service = musicBrainzService
        let playbackEngine = playbackEngine ?? PlaybackEngineFactory.makeDefault()
        let localLibrary = LocalLibraryStore()
        let navidromeConnection = NavidromeConnectionStore()
        let navidromeLibraryProvider = NavidromeLibraryProvider(
            connectionStore: navidromeConnection
        )
        let libraryManager = LibraryManager(
            localProvider: LocalLibraryProvider(store: localLibrary),
            navidromeProvider: navidromeLibraryProvider
        )
        let playbackController = PlaybackController(
            engine: playbackEngine,
            assetResolver: libraryManager
        )
        let releasePlaybackQueueBuilder = ReleasePlaybackQueueBuilder(
            libraryManager: libraryManager
        )

        self.navidromeConnection = navidromeConnection
        self.localLibrary = localLibrary
        self.libraryManager = libraryManager
        self.releasePlaybackQueueBuilder = releasePlaybackQueueBuilder
        self.releaseDetailLoader = releaseDetailLoader ?? { id in
            try await service.loadRelease(id: id)
        }
        self.releaseCoverLoader = releaseCoverLoader ?? { id in
            await CoverArtCache.shared.image(for: id, size: .full)
        }
        self.searchViewModel = SearchViewModel(
            service: service,
            libraryManager: libraryManager
        )
        self.trackDetailStore = TrackDetailStore(service: service)
        self.classicalMetadataStore = ClassicalMetadataStore(service: service)
        self.playbackController = playbackController
        self.searchModeObservation = self.searchViewModel.objectWillChange
            .sink { [weak self] in
                // SearchViewModel publishes before its @Published value is
                // installed; yield once so the deck reads the new mode.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.objectWillChange.send()
                }
            }
        self.localPlaybackNowPlayingCoordinator =
            PlatformNowPlayingCoordinator(controller: self.playbackController)
        self.playbackItemObservation = self.playbackController.$currentIndex
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] hasCurrentItem in
                self?.hasCurrentPlaybackItem = hasCurrentItem
            }

        let restoredLibrarySource = LibrarySourcePreference.restoredSource(
            navidromeIsConfigured: navidromeConnection.isConfigured
        )
        self.activeLibrarySource = restoredLibrarySource
        libraryManager.setActiveSource(restoredLibrarySource)
        LibrarySourcePreference.save(restoredLibrarySource)

        loadRecents()
#if os(iOS)
        startNowPlayingUpdates()
        #endif
        localLibrary.startAutomaticRefresh()
    }

    func selectMusicFolder(_ url: URL) {
        localLibrary.selectMusicFolder(url)
    }

    func createOrUpdateLibraryIndex(_ url: URL) {
        #if os(macOS)
        localLibrary.createOrUpdateLibraryIndex(in: url)
        #endif
    }

    func disconnectMusicLibrary() {
        localLibrary.disconnectLibrary()
    }

    func restoreAudioOutputConfiguration() {
        playbackController.restoreOutputConfiguration()
    }

    func refreshActiveLibraryIfNeeded() {
        Task {
            await libraryManager.refreshActiveCatalogIfNeeded()
        }
    }

    func playIndexedTrack(
        releaseTrackID: String?,
        recordingID: String?
    ) {
        guard let release = selectedRelease else {
            return
        }
        let selection = ReleasePlaybackSelection(
            releaseTrackID: releaseTrackID,
            recordingID: recordingID
        )
        let playbackSource = libraryManager.source

        let request = playbackController.beginQueueRequest()
        Task {
            guard await playbackController.prepareForQueueReplacement(request)
            else { return }
            guard let queue = await releasePlaybackQueueBuilder.buildQueue(
                for: release,
                selection: selection,
                source: playbackSource,
                artworkData: playbackArtworkData()
            ) else {
                playbackController.abandonQueueRequest(request)
                return
            }
            guard await playbackController.replaceQueue(
                with: queue.items,
                startingAt: queue.selectedIndex,
                request: request
            ) else { return }
            await playbackController.play()
        }
    }

    private func playbackArtworkData() -> Data? {
        #if canImport(UIKit)
        selectedReleaseCover?.pngData()
        #elseif canImport(AppKit)
        selectedReleaseCover?.tiffRepresentation
        #else
        nil
        #endif
    }

    func playSelectedRelease() {
        guard let release = selectedRelease else { return }
        let playbackSource = libraryManager.source
        let request = playbackController.beginQueueRequest()
        Task {
            guard await playbackController.prepareForQueueReplacement(request)
            else { return }
            await libraryManager.prepareTrackAvailability(
                forRelease: release.id,
                from: playbackSource
            )
            guard let selection = releasePlaybackQueueBuilder
                .firstPlayableSelection(
                    in: release,
                    source: playbackSource
                ),
                  let queue = await releasePlaybackQueueBuilder.buildQueue(
                    for: release,
                    selection: selection,
                    source: playbackSource,
                    artworkData: playbackArtworkData()
                  ) else {
                playbackController.abandonQueueRequest(request)
                return
            }
            guard await playbackController.replaceQueue(
                with: queue.items,
                startingAt: queue.selectedIndex,
                request: request
            ) else { return }
            await playbackController.play()
        }
    }

    var isBlockingNavigationLoad: Bool {
        isLoadingRelease || isLoadingArtistHeader
    }

    // MARK: - Release

    func selectRelease(
        _ row: SearchReleaseRow,
        activateImmediately: Bool = false
    ) {
        releaseLoadTask?.cancel()
        releaseSelectionGeneration &+= 1
        let generation = releaseSelectionGeneration

        selectedReleaseID = row.id
        isLoadingRelease = true
        releaseError = nil
        selectedRelease = nil
        selectedReleaseCover = nil

        if activateImmediately {
            withAnimation(AppStyle.animation) {
                deckSelection = DeckSelection<MusiCardID>(
                    activeID: .release,
                    activeSlotIndex: MusiCardID.release.slotIndex
                )
            }
        }

        releaseLoadTask = Task {
            await loadReleaseAndCover(id: row.id, generation: generation)
        }
    }

    /// Recent-history mutation is deliberately a side effect of selecting
    /// the exact tapped Release, never a prerequisite for navigation.
    func selectRecentRelease(_ row: SearchReleaseRow) {
        selectRelease(row, activateImmediately: true)
        addRecentRelease(row)
    }

    func retryRelease() {
        guard let selectedReleaseID else { return }

        releaseLoadTask?.cancel()
        releaseSelectionGeneration &+= 1
        let generation = releaseSelectionGeneration

        isLoadingRelease = true
        releaseError = nil
        selectedRelease = nil
        selectedReleaseCover = nil

        releaseLoadTask = Task {
            await loadReleaseAndCover(
                id: selectedReleaseID,
                generation: generation
            )
        }
    }

    private func loadReleaseAndCover(
        id: String,
        generation: UInt64
    ) async {
        do {
            async let releaseTask = releaseDetailLoader(id)
            async let coverTask = releaseCoverLoader(id)

            let release = try await releaseTask
            let cover = await coverTask

            guard generation == releaseSelectionGeneration,
                  selectedReleaseID == id else {
                return
            }

            selectedRelease = release
            selectedReleaseCover = cover
            isLoadingRelease = false

            withAnimation(AppStyle.animation) {
                deckSelection = DeckSelection<MusiCardID>(
                    activeID: .release,
                    activeSlotIndex: MusiCardID.release.slotIndex
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == releaseSelectionGeneration,
                  selectedReleaseID == id else {
                return
            }

            selectedRelease = nil
            selectedReleaseCover = nil
            isLoadingRelease = false
            releaseError = error
        }
    }

    // MARK: - Artist

    func selectArtist(_ row: SearchArtistRow) {
        selectArtist(id: row.id, name: row.name, lifeSpan: row.lifeSpan.nilIfEmpty)
    }

    func selectArtist(id: String) {
        selectArtist(id: id, name: nil, lifeSpan: nil)
    }

    private func selectArtist(id: String, name: String?, lifeSpan: String?) {
        artistLoadTask?.cancel()
        artistPaginationTask?.cancel()
        artistSelectionGeneration &+= 1
        let generation = artistSelectionGeneration

        // Reset pagination
        releaseGroupsOffset = 0
        hasMoreReleaseGroups = false
        isLoadingMoreReleaseGroups = false
        currentArtistIDForGroups = id

        selectedArtistID = id
        selectedArtist = nil
        selectedArtistName = name ?? ""
        selectedArtistLifeSpan = lifeSpan
        artistReleaseGroups = []
        discographyError = nil
        artistWikipedia = nil
        artistError = nil

        isLoadingArtistHeader = false
        isLoadingArtistWikipedia = false

        withAnimation(AppStyle.animation) {
            deckSelection = DeckSelection<MusiCardID>(
                activeID: .artist,
                activeSlotIndex: MusiCardID.artist.slotIndex
            )
        }
        artistLoadTask = Task { await loadArtist(id: id, generation: generation) }
    }

    func retryArtist() {
        if let artistID = selectedArtistID {
            if discographyError != nil {
                retryDiscography(for: artistID)
            } else {
                selectArtist(
                    id: artistID,
                    name: selectedArtistName.nilIfEmpty,
                    lifeSpan: selectedArtistLifeSpan
                )
            }
        }
    }

    func retryDiscography() {
        guard let artistID = selectedArtistID else { return }
        retryDiscography(for: artistID)
    }

    nonisolated static func hasUsableArtistHeader(
        artist: MBArtistDetail?,
        name: String
    ) -> Bool {
        artist != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func retryDiscography(for artistID: String) {
        artistLoadTask?.cancel()
        artistPaginationTask?.cancel()
        let generation = artistSelectionGeneration

        discographyError = nil
        if selectedArtistName.isEmpty { artistError = nil }
        artistReleaseGroups = []
        releaseGroupsOffset = 0
        hasMoreReleaseGroups = false
        isLoadingMoreReleaseGroups = false
        currentArtistIDForGroups = artistID

        artistLoadTask = Task {
            guard await loadDiscographyPage(id: artistID, generation: generation) else {
                return
            }
            if selectedArtist == nil {
                await loadArtistDetail(id: artistID, generation: generation)
            }
        }
    }

    private func loadArtist(id: String, generation: UInt64) async {
        guard await loadDiscographyPage(id: id, generation: generation) else { return }
        await loadArtistDetail(id: id, generation: generation)
    }

    private func loadDiscographyPage(id: String, generation: UInt64) async -> Bool {
        do {
            let (groups, hasMore) = try await musicBrainzService.fetchArtistReleaseGroups(
                id: id, limit: releaseGroupsPageSize, offset: 0
            )
            guard generation == artistSelectionGeneration, selectedArtistID == id else { return false }
            artistReleaseGroups = groups
            discographyError = nil
            hasMoreReleaseGroups = hasMore
            releaseGroupsOffset = groups.count
            currentArtistIDForGroups = id
            return true
        } catch is CancellationError { return false }
        catch {
            guard generation == artistSelectionGeneration, selectedArtistID == id else { return false }
            discographyError = error
            if !Self.hasUsableArtistHeader(artist: selectedArtist, name: selectedArtistName) {
                artistError = error
            }
            return false
        }
    }

    private func loadArtistDetail(id: String, generation: UInt64) async {
        do {
            let artist = try await musicBrainzService.fetchArtist(id: id)
            guard generation == artistSelectionGeneration, selectedArtistID == id else { return }
            selectedArtist = artist
            if selectedArtistName.isEmpty { selectedArtistName = artist.name }
            if selectedArtistLifeSpan == nil {
                selectedArtistLifeSpan = MBTextFormatter.lifeSpanText(from: artist.lifeSpan)
            }

            isLoadingArtistWikipedia = true

            if let wikidataURL = artist.relations?
                .first(where: { $0.type == "wikidata" })?
                .url?
                .resource
                .flatMap(URL.init(string:)) {

                let summary = try await musicBrainzService.fetchWikipediaSummary(from: wikidataURL)
                guard generation == artistSelectionGeneration, selectedArtistID == id else { return }
                artistWikipedia = summary
            } else {
                artistWikipedia = nil
            }

            isLoadingArtistWikipedia = false

        } catch is CancellationError {
            return
        } catch {
            guard generation == artistSelectionGeneration, selectedArtistID == id else { return }
            isLoadingArtistWikipedia = false
            if !Self.hasUsableArtistHeader(artist: selectedArtist, name: selectedArtistName) {
                artistError = error
            }
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

        let generation = artistSelectionGeneration
        artistPaginationTask?.cancel()
        artistPaginationTask = Task { await loadMoreReleaseGroups(generation: generation) }
    }

    private func loadMoreReleaseGroups(generation: UInt64) async {
        defer {
            if generation == artistSelectionGeneration { isLoadingMoreReleaseGroups = false }
        }
        guard let artistID = currentArtistIDForGroups else {
            return
        }

        do {
            let (groups, hasMore) = try await musicBrainzService.fetchArtistReleaseGroups(
                id: artistID,
                limit: releaseGroupsPageSize,
                offset: releaseGroupsOffset
            )

            guard generation == artistSelectionGeneration, selectedArtistID == artistID else { return }

            artistReleaseGroups.append(contentsOf: groups)
            hasMoreReleaseGroups = hasMore
            releaseGroupsOffset += groups.count

        } catch {
            // Silently fail — user can scroll again to retry
        }

    }

    // MARK: - Release group selection

    func selectReleaseGroup(_ group: MBReleaseGroupSummary) {
        let artistName = selectedArtist?.name ?? selectedArtistName
        guard !artistName.isEmpty else { return }

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

                Self.shazamLogger.debug(
                    "Shazam match artist=\(match.artist, privacy: .private) title=\(match.title, privacy: .private)"
                )

                searchViewModel.searchByRecognizedTrack(match)

                isShazamListening = false
                shazamStatusMessage = nil
                
            } catch {
                let nsError = error as NSError
                Self.shazamLogger.error(
                    "Shazam recognition failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) detail=\(nsError.localizedDescription, privacy: .private)"
                )

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

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
