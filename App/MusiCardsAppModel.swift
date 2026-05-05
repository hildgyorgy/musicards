//
//  MusiCardsAppModel.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import Foundation
import SwiftUI
import Combine
import UIKit
import MediaPlayer

@MainActor
final class MusiCardsAppModel: ObservableObject {
    @Published var activeIndex: Int = 0
    @Published var selectedReleaseID: String?
    @Published var selectedRelease: MBRelease?
    @Published var selectedReleaseCover: UIImage?
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

    // Pagination for release groups
    @Published var isLoadingMoreReleaseGroups: Bool = false
    @Published var hasMoreReleaseGroups: Bool = false

    let searchViewModel: SearchViewModel
    let trackDetailStore: TrackDetailStore
    let classicalMetadataStore: ClassicalMetadataStore

    private let musicBrainzService = MusicBrainzService()

    private let recentArtistsKey = "recentArtists"
    private let recentReleasesKey = "recentReleases"

    private var nowPlayingReleaseGroupID: String?
    private var nowPlayingReleaseGroupTitle: String?
    private var nowPlayingArtistName: String?
    private var nowPlayingObserver: NSObjectProtocol?

    // Pagination state
    private let releaseGroupsPageSize: Int = 25
    private var releaseGroupsOffset: Int = 0
    private var currentArtistIDForGroups: String?

    init() {
        let service = musicBrainzService

        self.searchViewModel = SearchViewModel(service: service)
        self.trackDetailStore = TrackDetailStore(service: service)
        self.classicalMetadataStore = ClassicalMetadataStore(service: service)

        loadRecents()
        startNowPlayingUpdates()
    }

    var isBlockingNavigationLoad: Bool {
        isLoadingRelease || isLoadingArtistHeader
    }

    // MARK: - Release

    func selectRelease(_ row: SearchReleaseRow) {
        selectedReleaseID = row.id
        isLoadingRelease = true
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

            withAnimation(DeckStyle.animation) {
                activeIndex = DeckCardID.release.activeIndex
            }
        } catch {
            selectedRelease = nil
            selectedReleaseCover = nil
            isLoadingRelease = false
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

            withAnimation(DeckStyle.animation) {
                activeIndex = DeckCardID.artist.activeIndex
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

        activeIndex = DeckCardID.search.activeIndex
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

    // MARK: - Now Playing

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

        withAnimation(DeckStyle.animation) {
            activeIndex = DeckCardID.search.activeIndex
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
                metaLine: releaseMetaLine(
                    date: best.date,
                    country: best.country,
                    labelInfo: best.labelInfo,
                    media: best.media
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

    private func releaseMetaLine(
        date: String?,
        country: String?,
        labelInfo: [MBLabelInfo]?,
        media: [MBMedium]?
    ) -> String {
        let parts = [
            MBDateTextFormatter.year(from: date),
            country ?? "",
            labelInfo?.compactMap { $0.label?.name }.first ?? "",
            media?.compactMap { $0.format }.first ?? ""
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return parts.joined(separator: " • ")
    }
}
