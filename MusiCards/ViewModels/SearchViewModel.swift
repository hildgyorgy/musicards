//
//  SearchViewModel.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: - Single search field (search mode)
    @Published var searchQuery: String = ""

    // MARK: - Display-only labels (release-group mode, never trigger search)
    @Published var displayTitle: String = ""
    @Published var displayArtist: String = ""

    // MARK: - Results
    @Published var releaseResults: [SearchReleaseRow] = []
    @Published var artistRows: [SearchArtistRow] = []

    // MARK: - Search mode pagination
    @Published var isLoadingMore = false
    @Published var hasMoreResults = true

    // MARK: - Release group mode pagination (separate — never collides with search)
    @Published var isLoadingMoreVersions = false
    @Published var hasMoreVersions = false

    // MARK: - Shared state
    @Published var mode: SearchMode = .search
    @Published var searchError: Error?
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?
    private var suppressNextQueryChange = false
    private var libraryAvailabilityObservation: AnyCancellable?
    private let musicBrainzService: any MusicBrainzSearchServing
    private let libraryManager: LibraryManager
    private let searchDebounceNanoseconds: UInt64
    private var searchGeneration: UInt64 = 0
    private var lastScheduledNormalizedQuery: String?
    private var activeReleaseSearchQuery: String?
    private var libraryReleaseRows: [SearchReleaseRow] = []
    private var musicBrainzReleaseRows: [SearchReleaseRow] = []
    private var promotedReleaseIDs: Set<String> = []
    private var visibleReleaseLimit = 20
    private var hasMoreMusicBrainzReleaseResults = true

    init(
        service: any MusicBrainzSearchServing,
        libraryManager: LibraryManager,
        searchDebounceNanoseconds: UInt64 = 350_000_000
    ) {
        self.musicBrainzService = service
        self.libraryManager = libraryManager
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
        libraryAvailabilityObservation = libraryManager.objectWillChange.sink {
            @MainActor [weak self] in
            // ObservableObject publishes immediately before its state changes.
            // Re-rank on the next main-actor turn so source switches and a
            // newly ready Navidrome catalog are already visible to queries.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.activeLibraryDidChange()
            }
        }
    }

    // Search mode pagination
    private var currentOffset = 0
    private let pageSize = 20
    private let librarySearchLimit = 50

    // Release group mode pagination
    private var versionsOffset = 0
    private let versionsPageSize = 25
    private var currentReleaseGroupID: String?

    // MARK: - Derived state

    var contentState: SearchContentState {
        guard case .search = mode else { return .releaseResults }

        if !releaseResults.isEmpty {
            return .releaseResults
        }

        if !artistRows.isEmpty {
            return .artistResults
        }

        let q = normalizedSearchQuery

        if q.isEmpty { return .idle }

        if q.contains(",") || MBIdentifiers.isBareBarcode(q) || MBIdentifiers.isMBID(q) {
            return .releaseResults
        } else {
            return .artistResults
        }
    }

    // MARK: - Search entry point

    func queryDidChange() {
        let q = normalizedSearchQuery

        if suppressNextQueryChange {
            suppressNextQueryChange = false
            lastScheduledNormalizedQuery = q
            return
        }

        guard q != lastScheduledNormalizedQuery else { return }
        lastScheduledNormalizedQuery = q
        
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        currentOffset = 0
        hasMoreResults = true
        isLoadingMore = false
        searchError = nil
        isSearching = false
        resetReleaseSearchMergeState()
        promotedReleaseIDs = []

        guard q.count >= 3 else {
            releaseResults = []
            artistRows = []
            return
        }

        isSearching = true

        searchTask = Task {
            try? await Task.sleep(nanoseconds: searchDebounceNanoseconds)
            guard !Task.isCancelled, generation == searchGeneration else {
                return
            }
            await performSearch(generation: generation)
        }
    }

    func switchToSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        lastScheduledNormalizedQuery = ""
        mode = .search
        searchQuery = ""
        releaseResults = []
        artistRows = []
        searchError = nil
        isSearching = false
        isLoadingMore = false
        // Reset version pagination
        versionsOffset = 0
        hasMoreVersions = false
        isLoadingMoreVersions = false
        currentReleaseGroupID = nil
        resetReleaseSearchMergeState()
        promotedReleaseIDs = []
    }

    func searchByBarcode(_ barcode: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        currentOffset = 0
        hasMoreResults = true
        isLoadingMore = false
        searchError = nil
        isSearching = true
        mode = .search
        lastScheduledNormalizedQuery = ""
        searchQuery = ""
        artistRows = []
        releaseResults = []
        resetReleaseSearchMergeState()
        promotedReleaseIDs = []

        let normalized = barcode.filter(\.isNumber)

        searchTask = Task {
            defer {
                if generation == searchGeneration { isSearching = false }
            }
            do {
                let results = try await musicBrainzService.searchReleases(
                    query: "barcode:\(normalized)",
                    limit: pageSize,
                    offset: 0
                )

                guard generation == searchGeneration else { return }
                releaseResults = []
                artistRows = []
                currentOffset = results.count
                hasMoreResults = results.count == pageSize
                searchError = nil

                await prepareReleaseRowsSequentially(
                    from: playableReleasesFirst(results),
                    append: false
                )

            } catch is CancellationError {
                return
            } catch {
                if Self.isCancellation(error) { return }
                guard generation == searchGeneration else { return }
                releaseResults = []
                artistRows = []
                hasMoreResults = false
                searchError = error
            }
        }
    }
#if os(iOS)
func searchByRecognizedTrack(_ match: ShazamMatch) {
    searchTask?.cancel()

    currentOffset = 0
    hasMoreResults = false
    isLoadingMore = false
    searchError = nil
    isSearching = true

    mode = .search
    artistRows = []
    releaseResults = []
    promotedReleaseIDs = []

    let artist = match.artist.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = match.title.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !artist.isEmpty, !title.isEmpty else {
        isSearching = false
        return
    }

    suppressNextQueryChange = true
    searchQuery = "\(artist), \(title)"

    searchTask = Task {
        defer { isSearching = false }

        do {
            let recordings = try await musicBrainzService.searchRecordings(
                trackTitle: title,
                artistName: artist,
                limit: 20,
                offset: 0
            )

            let trackReleases = flattenRecordingResults(recordings)

            for candidate in trackReleases.prefix(20) {
                guard artistMatchRank(candidate.artistCredit, artistQuery: artist) <= 1 else {
                    continue
                }

                guard let detailedRelease = try? await musicBrainzService.loadRelease(id: candidate.id) else {
                    continue
                }

                guard releaseContainsTrackTitle(detailedRelease, trackTitle: title) else {
                    continue
                }

                if let releaseGroupID = detailedRelease.releaseGroup?.id {
                    loadReleaseGroupResults(
                        releaseGroupID: releaseGroupID,
                        releaseTitle: detailedRelease.releaseGroup?.title ?? candidate.title,
                        artistName: artist
                    )
                    return
                }

                releaseResults = []
                artistRows = []
                currentOffset = 1
                hasMoreResults = false

                await prepareReleaseRowsSequentially(
                    from: [candidate],
                    append: false
                )
                return
            }

            releaseResults = []
            artistRows = []
            hasMoreResults = false
            searchError = nil

        } catch is CancellationError {
            return
        } catch {
            if Self.isCancellation(error) { return }
            releaseResults = []
            artistRows = []
            hasMoreResults = false
            searchError = error
        }
    }
}
#endif

    func retrySearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        searchError = nil
        isLoadingMore = false
        hasMoreResults = true

        switch mode {
        case .search:
            currentOffset = 0
            releaseResults = []
            artistRows = []
            resetReleaseSearchMergeState()
            promotedReleaseIDs = []

            let q = normalizedSearchQuery
            guard q.count >= 3 else { return }

            isSearching = true
            searchTask = Task {
                await performSearch(generation: generation)
            }

        case .releaseGroupResults(let releaseGroupID):
            releaseResults = []
            artistRows = []
            promotedReleaseIDs = []
            versionsOffset = 0
            hasMoreVersions = false
            isSearching = true

            Task {
                await fetchReleaseGroupResults(releaseGroupID: releaseGroupID)
            }
        }
    }

    // MARK: - Private search

    private func hasEnoughInput() -> Bool {
        normalizedSearchQuery.count >= 3
    }

    private var normalizedSearchQuery: String {
        Self.normalizeSearchQuery(searchQuery)
    }

    nonisolated static func normalizeSearchQuery(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private func yearRangeText(from lifeSpan: MBLifeSpan?) -> String {
        MBTextFormatter.lifeSpanTextOrEmpty(from: lifeSpan)
    }

    private func performSearch(generation: UInt64) async {
        let q = normalizedSearchQuery

        guard q.count >= 3, generation == searchGeneration else {
            isSearching = false
            return
        }

        searchError = nil

        do {
            if q.contains(",") || MBIdentifiers.isBareBarcode(q) || MBIdentifiers.isMBID(q) {
                activeReleaseSearchQuery = q
                musicBrainzReleaseRows = []
                updateLibraryReleaseResults(query: q)
                artistRows = []
                if !libraryReleaseRows.isEmpty {
                    // The owned results are useful immediately; the global
                    // MusicBrainz request continues without hiding them.
                    isSearching = false
                    isLoadingMore = true
                }

                let results = try await musicBrainzService.searchReleases(
                    query: q,
                    limit: pageSize,
                    offset: currentOffset
                )
                try Task.checkCancellation()
                guard generation == searchGeneration,
                      q == activeReleaseSearchQuery else {
                    return
                }
                let sorted = sortRawReleases(results, query: q)
                currentOffset = results.count
                hasMoreMusicBrainzReleaseResults = results.count == pageSize
                let rows = makeReleaseRows(from: sorted)
                guard generation == searchGeneration,
                      q == activeReleaseSearchQuery else {
                    return
                }
                musicBrainzReleaseRows = rows
                publishMergedReleaseResults()
                isSearching = false
                isLoadingMore = false

            } else {
                resetReleaseSearchMergeState()
                let results = try await musicBrainzService.searchArtists(
                    query: q,
                    limit: pageSize,
                    offset: currentOffset
                )
                try Task.checkCancellation()
                guard generation == searchGeneration else { return }

                let rows = results.map {
                    SearchArtistRow(
                        id: $0.id,
                        name: $0.name,
                        lifeSpan: yearRangeText(from: $0.lifeSpan)
                    )
                }

                artistRows = playableArtistsFirst(rows)
                releaseResults = []
                currentOffset = rows.count
                hasMoreResults = rows.count == pageSize
                isSearching = false
            }

            searchError = nil

        } catch is CancellationError {
            if generation == searchGeneration {
                isSearching = false
                isLoadingMore = false
            }
            return
        } catch {
            if Self.isCancellation(error) {
                if generation == searchGeneration {
                    isSearching = false
                    isLoadingMore = false
                }
                return
            }
            guard generation == searchGeneration else { return }
            isSearching = false
            isLoadingMore = false
            if libraryReleaseRows.isEmpty {
                releaseResults = []
                artistRows = []
                searchError = error
            } else {
                // Match the web behavior: an online failure must not discard
                // already available active-library results.
                searchError = nil
            }
            hasMoreMusicBrainzReleaseResults = false
            if activeReleaseSearchQuery != nil {
                publishMergedReleaseResults()
            } else {
                hasMoreResults = false
            }
        }
    }

    // MARK: - Release group mode

    func loadReleaseGroupResults(
        releaseGroupID: String,
        releaseTitle: String,
        artistName: String
    ) {
        displayTitle = releaseTitle
        displayArtist = artistName
        mode = .releaseGroupResults(releaseGroupID: releaseGroupID)

        // Reset version pagination
        versionsOffset = 0
        hasMoreVersions = false
        isLoadingMoreVersions = false
        currentReleaseGroupID = releaseGroupID
        promotedReleaseIDs = []

        searchTask?.cancel()
        releaseResults = []
        artistRows = []
        searchError = nil
        isSearching = true

        searchTask = Task {
            await fetchReleaseGroupResults(releaseGroupID: releaseGroupID)
        }
    }

    private func fetchReleaseGroupResults(releaseGroupID: String) async {
        defer { isSearching = false }

        // Discover owned candidates locally first, then prove their exact
        // Release Group membership through MusicBrainz identifiers.
        let promotedRows = await validatedLibraryReleaseRows(
            releaseGroupID: releaseGroupID,
            releaseTitle: displayTitle,
            artistName: displayArtist
        )
        guard !Task.isCancelled else { return }
        if !promotedRows.isEmpty {
            promotedReleaseIDs = Set(promotedRows.map(\.id))
            publishPromotedLibraryRows(promotedRows)
            // Let the promoted rows become visible while the bounded MB page
            // request is still in flight.
            isSearching = false
        }

        do {
            let (results, hasMore) = try await musicBrainzService.fetchReleasesForReleaseGroup(
                id: releaseGroupID,
                limit: versionsPageSize,
                offset: 0
            )

            let sorted = playableReleasesFirst(sortedVersions(results))

            if promotedRows.isEmpty {
                releaseResults = []
            }
            artistRows = []
            searchError = nil
            versionsOffset = results.count
            hasMoreVersions = hasMore

            await prepareReleaseRowsSequentially(
                from: sorted,
                append: !promotedRows.isEmpty
            )

        } catch is CancellationError {
            return
        } catch {
            if Self.isCancellation(error) { return }
            if promotedRows.isEmpty {
                releaseResults = []
                artistRows = []
                searchError = error
            }
        }
    }

    // MARK: - Release group version pagination

    func loadMoreIfNeededForReleaseVersion(currentItem: SearchReleaseRow) {
        guard case .releaseGroupResults = mode else { return }
        guard !isLoadingMoreVersions, hasMoreVersions else { return }

        let threshold = max(releaseResults.count - 5, 0)
        guard let index = releaseResults.firstIndex(where: { $0.id == currentItem.id }),
              index >= threshold else { return }

        isLoadingMoreVersions = true

        Task {
            await loadMoreVersions()
        }
    }

    private func loadMoreVersions() async {
        guard let groupID = currentReleaseGroupID else {
            isLoadingMoreVersions = false
            return
        }

        do {
            let (results, hasMore) = try await musicBrainzService.fetchReleasesForReleaseGroup(
                id: groupID,
                limit: versionsPageSize,
                offset: versionsOffset
            )

            let sorted = playableReleasesFirst(sortedVersions(results))
            versionsOffset += results.count
            hasMoreVersions = hasMore

            await prepareReleaseRowsSequentially(from: sorted, append: true)

        } catch is CancellationError {
            // ignore
        } catch {
            // silently fail — user can scroll again
        }

        isLoadingMoreVersions = false
    }

    private func validatedLibraryReleaseRows(
        releaseGroupID: String,
        releaseTitle: String,
        artistName: String
    ) async -> [SearchReleaseRow] {
        let query = "\(artistName), \(releaseTitle)"
        let candidates = libraryManager.searchCatalog(
            query: query,
            limit: librarySearchLimit
        )
        guard !candidates.isEmpty else { return [] }

        let candidateIDs = candidates.map(\.releaseID)
        let exactQuery = "rgid:\(releaseGroupID) AND ("
            + candidateIDs.map { "reid:\($0)" }.joined(separator: " OR ")
            + ")"

        do {
            let matches = try await musicBrainzService.searchReleases(
                query: exactQuery,
                limit: candidateIDs.count,
                offset: 0
            )
            let validatedIDs = Set(
                matches
                    .map(\.id)
                    .filter { candidateIDs.contains($0) }
            )
            return candidates
                .filter { validatedIDs.contains($0.releaseID) }
                .map(makeLibraryReleaseRow)
        } catch is CancellationError {
            return []
        } catch {
            // Candidate validation is an optimization; the normal versions
            // page remains the fallback when this request is unavailable.
            return []
        }
    }

    private func publishPromotedLibraryRows(_ rows: [SearchReleaseRow]) {
        for row in rows {
            appendUniqueReleaseRow(row)
        }
    }

    // Sort versions by year then format priority (vinyl → cd → digital → other)
    private func sortedVersions(_ releases: [MBReleaseSearchResult]) -> [MBReleaseSearchResult] {
        releases.sorted { a, b in
            let yearA = year(from: a.date)
            let yearB = year(from: b.date)

            if yearA != yearB {
                return yearA < yearB
            }

            return mediaPriority(a.media) < mediaPriority(b.media)
        }
    }

    // MARK: - Search pagination

    func loadMoreIfNeededForRelease(currentItem: SearchReleaseRow) {
        guard mode == .search else { return }
        guard !isLoadingMore, hasMoreResults else { return }
        guard releaseResults.last?.id == currentItem.id else { return }

        isLoadingMore = true

        Task {
            await loadMoreReleases()
            isLoadingMore = false
        }
    }

    func loadMoreIfNeededForArtist(currentItem: SearchArtistRow) {
        guard mode == .search else { return }
        guard !isLoadingMore, hasMoreResults else { return }

        let threshold = max(artistRows.count - 5, 0)
        guard let index = artistRows.firstIndex(where: { $0.id == currentItem.id }),
              index >= threshold else { return }

        isLoadingMore = true

        Task {
            await loadMoreArtists()
            isLoadingMore = false
        }
    }

    private func loadMoreReleases() async {
        let q = normalizedSearchQuery
        let generation = searchGeneration
        guard !q.isEmpty, q == activeReleaseSearchQuery else { return }

        let nextVisibleLimit = visibleReleaseLimit + pageSize
        guard hasMoreMusicBrainzReleaseResults else {
            visibleReleaseLimit = nextVisibleLimit
            publishMergedReleaseResults()
            return
        }

        do {
            let results = try await musicBrainzService.searchReleases(
                query: q,
                limit: pageSize,
                offset: currentOffset
            )
            try Task.checkCancellation()
            guard generation == searchGeneration,
                  q == activeReleaseSearchQuery else {
                return
            }
            let sorted = sortRawReleases(results, query: q)
            currentOffset += results.count
            hasMoreMusicBrainzReleaseResults = results.count == pageSize
            let rows = makeReleaseRows(from: sorted)
            guard generation == searchGeneration,
                  q == activeReleaseSearchQuery else {
                return
            }
            visibleReleaseLimit = nextVisibleLimit
            appendUniqueMusicBrainzReleaseRows(rows)
            publishMergedReleaseResults()
        } catch is CancellationError {
            return
        } catch {
            hasMoreMusicBrainzReleaseResults = false
            hasMoreResults = false
        }
    }

    private func loadMoreArtists() async {
        let q = normalizedSearchQuery
        guard !q.isEmpty else { return }

        do {
            let results = try await musicBrainzService.searchArtists(
                query: q,
                limit: pageSize,
                offset: currentOffset
            )

            let rows = results.map {
                SearchArtistRow(
                    id: $0.id,
                    name: $0.name,
                    lifeSpan: yearRangeText(from: $0.lifeSpan)
                )
            }

            appendUniqueArtistRows(playableArtistsFirst(rows))
            currentOffset += results.count
            hasMoreResults = results.count == pageSize

        } catch is CancellationError {
            return
        } catch {
            hasMoreResults = false
        }
    }

    // MARK: - Row builders

    private func appendUniqueReleaseRow(_ row: SearchReleaseRow) {
        guard !releaseResults.contains(where: { $0.id == row.id }) else { return }
        releaseResults.append(row)
        releaseResults = stablePlayableFirst(
            releaseResults,
            isPlayable: { libraryManager.containsRelease($0.id) }
        )
    }

    private func activeLibraryDidChange() {
        if mode == .search,
           let query = activeReleaseSearchQuery,
           query == normalizedSearchQuery {
            updateLibraryReleaseResults(query: query)
            return
        }

        let reordered = stablePlayableFirst(
            releaseResults,
            isPlayable: { libraryManager.containsRelease($0.id) }
        )
        guard reordered.map(\.id) != releaseResults.map(\.id) else { return }
        releaseResults = reordered
    }

    private func updateLibraryReleaseResults(query: String) {
        libraryReleaseRows = libraryManager.searchCatalog(
            query: query,
            limit: librarySearchLimit
        ).map(makeLibraryReleaseRow)
        publishMergedReleaseResults()
    }

    private func makeLibraryReleaseRow(
        _ release: LibraryCatalogRelease
    ) -> SearchReleaseRow {
        SearchReleaseRow(
            id: release.releaseID,
            title: release.title,
            artistLine: release.artistName,
            metaLine: MBTextFormatter.releaseMetaLine(
                year: MBTextFormatter.year(from: release.date),
                country: release.country,
                label: release.label,
                format: release.format
            ),
            disambiguation: "",
            // The exact library Release MBID is a playable result. Let the
            // row request the same full artwork cache entry as the Release
            // card, even before MusicBrainz enriches the row metadata.
            hasCoverArt: true
        )
    }

    private func publishMergedReleaseResults() {
        let merged = Self.mergeLibraryFirst(
            libraryRows: libraryReleaseRows,
            musicBrainzRows: musicBrainzReleaseRows
        )
        releaseResults = Array(merged.prefix(visibleReleaseLimit))
        hasMoreResults = hasMoreMusicBrainzReleaseResults
            || merged.count > visibleReleaseLimit
    }

    private func appendUniqueMusicBrainzReleaseRows(
        _ rows: [SearchReleaseRow]
    ) {
        var seen = Set(
            musicBrainzReleaseRows.map { Self.canonicalReleaseID($0.id) }
        )
        for row in rows {
            if seen.insert(Self.canonicalReleaseID(row.id)).inserted {
                musicBrainzReleaseRows.append(row)
            }
        }
    }

    private func resetReleaseSearchMergeState() {
        activeReleaseSearchQuery = nil
        libraryReleaseRows = []
        musicBrainzReleaseRows = []
        visibleReleaseLimit = pageSize
        hasMoreMusicBrainzReleaseResults = true
    }

    nonisolated static func mergeLibraryFirst(
        libraryRows: [SearchReleaseRow],
        musicBrainzRows: [SearchReleaseRow]
    ) -> [SearchReleaseRow] {
        var remoteByID = [String: SearchReleaseRow]()
        for row in musicBrainzRows {
            let key = canonicalReleaseID(row.id)
            if remoteByID[key] == nil { remoteByID[key] = row }
        }

        var seen = Set<String>()
        var merged: [SearchReleaseRow] = []
        for libraryRow in libraryRows {
            let key = canonicalReleaseID(libraryRow.id)
            guard seen.insert(key).inserted else { continue }
            if let enriched = remoteByID[key] {
                merged.append(
                    SearchReleaseRow(
                        id: libraryRow.id,
                        title: enriched.title,
                        artistLine: enriched.artistLine,
                        metaLine: enriched.metaLine,
                        disambiguation: enriched.disambiguation,
                        hasCoverArt: enriched.hasCoverArt
                    )
                )
            } else {
                merged.append(libraryRow)
            }
        }

        for row in musicBrainzRows {
            let key = canonicalReleaseID(row.id)
            if seen.insert(key).inserted { merged.append(row) }
        }
        return merged
    }

    nonisolated private static func canonicalReleaseID(
        _ value: String
    ) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func appendUniqueArtistRows(_ rows: [SearchArtistRow]) {
        let existing = Set(artistRows.map(\.id))
        artistRows.append(contentsOf: rows.filter { !existing.contains($0.id) })
        artistRows = playableArtistsFirst(artistRows)
    }

    private func playableReleasesFirst(
        _ releases: [MBReleaseSearchResult]
    ) -> [MBReleaseSearchResult] {
        stablePlayableFirst(
            releases,
            isPlayable: { libraryManager.containsRelease($0.id) }
        )
    }

    private func playableArtistsFirst(
        _ artists: [SearchArtistRow]
    ) -> [SearchArtistRow] {
        stablePlayableFirst(
            artists,
            isPlayable: { libraryManager.containsArtist(named: $0.name) }
        )
    }

    private func stablePlayableFirst<Element>(
        _ elements: [Element],
        isPlayable: (Element) -> Bool
    ) -> [Element] {
        let grouped = Dictionary(grouping: elements, by: isPlayable)
        return (grouped[true] ?? []) + (grouped[false] ?? [])
    }

    private nonisolated func makeReleaseRow(
        id: String, title: String,
        artistCredit: [MBArtistCredit]?,
        date: String?, country: String?,
        labelInfo: [MBLabelInfo]?, media: [MBMedium]?,
        disambiguation: String?, hasCoverArt: Bool
    ) -> SearchReleaseRow {
        SearchReleaseRow(
            id: id, title: title,
            artistLine: MBTextFormatter.artistLine(from: artistCredit),
            metaLine: MBTextFormatter.releaseMetaLine(
                year: MBTextFormatter.year(from: date),
                country: country,
                label: labelInfo?.compactMap { $0.label?.name }.first,
                format: media?.compactMap { $0.format }.first
            ),
            disambiguation: disambiguation ?? "",
            hasCoverArt: hasCoverArt
        )
    }

    private nonisolated func sortRawReleases(
        _ releases: [MBReleaseSearchResult], query: String
    ) -> [MBReleaseSearchResult] {
        let raw = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let titleQuery: String = {
            if let commaIndex = raw.firstIndex(of: ",") {
                let afterComma = raw[raw.index(after: commaIndex)...]
                return afterComma.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return raw
            }
        }()

        guard !titleQuery.isEmpty else { return releases }

        return releases.sorted { a, b in
            let aT = a.title.lowercased()
            let bT = b.title.lowercased()
            let aExact = aT == titleQuery
            let bExact = bT == titleQuery

            if aExact != bExact { return aExact }

            let aPrefix = aT.hasPrefix(titleQuery)
            let bPrefix = bT.hasPrefix(titleQuery)

            if aPrefix != bPrefix { return aPrefix }

            return false
        }
    }

    private nonisolated func makeReleaseRows(
        from releases: [MBReleaseSearchResult]
    ) -> [SearchReleaseRow] {
        releases.map { release in
            makeReleaseRow(
                id: release.id,
                title: release.title,
                artistCredit: release.artistCredit,
                date: release.date,
                country: release.country,
                labelInfo: release.labelInfo,
                media: release.media,
                disambiguation: release.disambiguation,
                // Search rows must never wait for Cover Art Archive. The
                // thumbnail view resolves the image lazily and keeps its
                // placeholder when the release has no cover.
                hasCoverArt: true
            )
        }
    }

    private func prepareReleaseRowsSequentially(
        from releases: [MBReleaseSearchResult],
        append: Bool
    ) async {
        if !append { releaseResults = [] }

        let maxConcurrent = 6
        var nextIndex = 0
        var prepared: [Int: SearchReleaseRow] = [:]
        var iterator = releases.enumerated().makeIterator()
        let promotedIDs = promotedReleaseIDs

        await withTaskGroup(of: (Int, SearchReleaseRow).self) { group in
            for _ in 0..<min(maxConcurrent, releases.count) {
                guard let (i, r) = iterator.next() else { break }
                group.addTask {
                    let artworkSize: CoverArtSize = promotedIDs.contains(r.id)
                        ? .full
                        : .thumbnail
                    let img = await CoverArtCache.shared.image(for: r.id, size: artworkSize)
                    let row = self.makeReleaseRow(
                        id: r.id,
                        title: r.title,
                        artistCredit: r.artistCredit,
                        date: r.date,
                        country: r.country,
                        labelInfo: r.labelInfo,
                        media: r.media,
                        disambiguation: r.disambiguation,
                        hasCoverArt: img != nil
                    )
                    return (i, row)
                }
            }

            while let (finishedIndex, row) = await group.next() {
                prepared[finishedIndex] = row

                while let readyRow = prepared[nextIndex] {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.appendUniqueReleaseRow(readyRow)
                    }
                    prepared.removeValue(forKey: nextIndex)
                    nextIndex += 1
                }

                if let (nextI, nextR) = iterator.next() {
                    group.addTask {
                        let artworkSize: CoverArtSize = promotedIDs.contains(nextR.id)
                            ? .full
                            : .thumbnail
                        let img = await CoverArtCache.shared.image(for: nextR.id, size: artworkSize)
                        let row = self.makeReleaseRow(
                            id: nextR.id,
                            title: nextR.title,
                            artistCredit: nextR.artistCredit,
                            date: nextR.date,
                            country: nextR.country,
                            labelInfo: nextR.labelInfo,
                            media: nextR.media,
                            disambiguation: nextR.disambiguation,
                            hasCoverArt: img != nil
                        )
                        return (nextI, row)
                    }
                }
            }
        }
    }

    // MARK: - Shazam recording resolution helpers

    /// Flatten recording search results into a deduplicated list of releases.
    /// Preserves score-order by keeping the first occurrence of each release ID.
    private nonisolated func flattenRecordingResults(
        _ recordings: [MBRecordingSearchResult]
    ) -> [MBReleaseSearchResult] {
        var seen = Set<String>()
        var out:  [MBReleaseSearchResult] = []

        for recording in recordings {
            for release in recording.releases ?? [] {
                guard !seen.contains(release.id) else { continue }
                seen.insert(release.id)
                // Build a result that carries artist credit from the recording
                // (releases returned inside a recording response often lack artist-credit)
                let enriched = MBReleaseSearchResult(
                    id: release.id,
                    title: release.title,
                    date: release.date,
                    country: release.country,
                    disambiguation: release.disambiguation,
                    score: release.score,
                    artistCredit: release.artistCredit ?? recording.artistCredit,
                    labelInfo: release.labelInfo,
                    media: release.media
                )
                out.append(enriched)
            }
        }
        return out
    }

    private nonisolated func releaseContainsTrackTitle(
        _ release: MBRelease,
        trackTitle: String
    ) -> Bool {
        let needle = normalizedTrackTitle(trackTitle)

        let tracks = release.media?
            .flatMap { $0.tracks ?? [] } ?? []

        return tracks.contains { track in
            normalizedTrackTitle(track.title) == needle
        }
    }

    private nonisolated func normalizedTrackTitle(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func artistMatchRank(
        _ credit: [MBArtistCredit]?,
        artistQuery: String
    ) -> Int {
        guard let credit else { return 3 }

        let haystack = credit
            .map(\.name)
            .joined(separator: " ")
            .lowercased()

        let query = artistQuery.lowercased()

        if haystack.contains(query) {
            return 0
        }

        let strongTokens = artistQueryTokens(from: query)

        if strongTokens.contains(where: { haystack.contains($0) }) {
            return 1
        }

        let weakTokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        if weakTokens.contains(where: { haystack.contains($0) }) {
            return 2
        }

        return 3
    }

    private nonisolated func artistQueryTokens(from query: String) -> [String] {
        let genericTokens: Set<String> = [
            "the", "a", "an",
            "and", "or", "of",
            "band", "trio", "quartet", "quintet",
            "ensemble", "orchestra", "choir",
            "group", "project"
        ]

        return query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { token in
                token.count >= 3 && !genericTokens.contains(token)
            }
    }

    // MARK: - Private helpers

    private nonisolated func mediaPriority(_ media: [MBMedium]?) -> Int {
        let formats = media?.compactMap { $0.format?.lowercased() } ?? []
        if formats.contains(where: { $0.contains("vinyl") }) { return 0 }
        if formats.contains(where: { $0.contains("cd") }) { return 1 }
        if formats.contains(where: { $0.contains("digital") }) { return 2 }
        return 3
    }

    private nonisolated func year(from date: String?) -> Int {
        guard let date, date.count >= 4 else { return Int.max }
        return Int(date.prefix(4)) ?? Int.max
    }
}
