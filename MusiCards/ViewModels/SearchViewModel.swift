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
    private let musicBrainzService: MusicBrainzService
    private let localLibrary: LocalLibraryStore

    init(service: MusicBrainzService, localLibrary: LocalLibraryStore) {
        self.musicBrainzService = service
        self.localLibrary = localLibrary
    }

    // Search mode pagination
    private var currentOffset = 0
    private let pageSize = 20

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

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if q.isEmpty { return .idle }

        if q.contains(",") || MBIdentifiers.isBareBarcode(q) || MBIdentifiers.isMBID(q) {
            return .releaseResults
        } else {
            return .artistResults
        }
    }

    // MARK: - Search entry point

    func queryDidChange() {
        if suppressNextQueryChange {
                suppressNextQueryChange = false
                return
            }
        
        searchTask?.cancel()
        currentOffset = 0
        hasMoreResults = true
        isLoadingMore = false
        searchError = nil
        isSearching = false

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard q.count >= 3 else {
            releaseResults = []
            artistRows = []
            return
        }

        isSearching = true

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await performSearch()
        }
    }

    func switchToSearch() {
        mode = .search
        searchQuery = ""
        releaseResults = []
        artistRows = []
        searchError = nil
        isSearching = false
        // Reset version pagination
        versionsOffset = 0
        hasMoreVersions = false
        isLoadingMoreVersions = false
        currentReleaseGroupID = nil
    }

    func searchByBarcode(_ barcode: String) {
        searchTask?.cancel()
        currentOffset = 0
        hasMoreResults = true
        isLoadingMore = false
        searchError = nil
        isSearching = true
        mode = .search
        searchQuery = ""
        artistRows = []
        releaseResults = []

        let normalized = barcode.filter(\.isNumber)

        searchTask = Task {
            defer { isSearching = false }
            do {
                let results = try await musicBrainzService.searchReleases(
                    query: "barcode:\(normalized)",
                    limit: pageSize,
                    offset: 0
                )

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
        searchError = nil
        isLoadingMore = false
        hasMoreResults = true

        switch mode {
        case .search:
            currentOffset = 0
            releaseResults = []
            artistRows = []

            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 3 else { return }

            isSearching = true
            searchTask = Task {
                await performSearch()
            }

        case .releaseGroupResults(let releaseGroupID):
            releaseResults = []
            artistRows = []
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
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    private func yearRangeText(from lifeSpan: MBLifeSpan?) -> String {
        MBTextFormatter.lifeSpanTextOrEmpty(from: lifeSpan)
    }

    private func performSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard q.count >= 3 else {
            isSearching = false
            return
        }

        defer { isSearching = false }
        searchError = nil

        do {
            if q.contains(",") || MBIdentifiers.isBareBarcode(q) || MBIdentifiers.isMBID(q) {
                let results = try await musicBrainzService.searchReleases(
                    query: q,
                    limit: pageSize,
                    offset: currentOffset
                )
                let sorted = playableReleasesFirst(
                    sortRawReleases(results, query: q)
                )
                releaseResults = []
                artistRows = []
                currentOffset = results.count
                hasMoreResults = results.count == pageSize
                await prepareReleaseRowsSequentially(from: sorted, append: false)

            } else {
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

                artistRows = playableArtistsFirst(rows)
                releaseResults = []
                currentOffset = rows.count
                hasMoreResults = rows.count == pageSize
            }

            searchError = nil

        } catch is CancellationError {
            return
        } catch {
            releaseResults = []
            artistRows = []
            hasMoreResults = false
            searchError = error
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

        searchTask?.cancel()
        releaseResults = []
        artistRows = []
        searchError = nil
        isSearching = true

        Task {
            await fetchReleaseGroupResults(releaseGroupID: releaseGroupID)
        }
    }

    private func fetchReleaseGroupResults(releaseGroupID: String) async {
        defer { isSearching = false }

        do {
            let (results, hasMore) = try await musicBrainzService.fetchReleasesForReleaseGroup(
                id: releaseGroupID,
                limit: versionsPageSize,
                offset: 0
            )

            let sorted = playableReleasesFirst(sortedVersions(results))

            releaseResults = []
            artistRows = []
            searchError = nil
            versionsOffset = results.count
            hasMoreVersions = hasMore

            await prepareReleaseRowsSequentially(from: sorted, append: false)

        } catch is CancellationError {
            return
        } catch {
            releaseResults = []
            artistRows = []
            searchError = error
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

        let threshold = max(releaseResults.count - 5, 0)
        guard let index = releaseResults.firstIndex(where: { $0.id == currentItem.id }),
              index >= threshold else { return }

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
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        do {
            let results = try await musicBrainzService.searchReleases(
                query: q,
                limit: pageSize,
                offset: currentOffset
            )
            let sorted = playableReleasesFirst(
                sortRawReleases(results, query: q)
            )
            currentOffset += results.count
            hasMoreResults = results.count == pageSize
            await prepareReleaseRowsSequentially(from: sorted, append: true)
        } catch is CancellationError {
            return
        } catch {
            hasMoreResults = false
        }
    }

    private func loadMoreArtists() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
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
            isPlayable: { localLibrary.containsRelease($0.id) }
        )
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
            isPlayable: { localLibrary.containsRelease($0.id) }
        )
    }

    private func playableArtistsFirst(
        _ artists: [SearchArtistRow]
    ) -> [SearchArtistRow] {
        stablePlayableFirst(
            artists,
            isPlayable: { localLibrary.containsArtist(named: $0.name) }
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

    private func prepareReleaseRowsSequentially(
        from releases: [MBReleaseSearchResult],
        append: Bool
    ) async {
        if !append { releaseResults = [] }

        let maxConcurrent = 6
        var nextIndex = 0
        var prepared: [Int: SearchReleaseRow] = [:]
        var iterator = releases.enumerated().makeIterator()

        await withTaskGroup(of: (Int, SearchReleaseRow).self) { group in
            for _ in 0..<min(maxConcurrent, releases.count) {
                guard let (i, r) = iterator.next() else { break }
                group.addTask {
                    let img = await CoverArtCache.shared.image(for: r.id, size: .thumbnail)
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
                        let img = await CoverArtCache.shared.image(for: nextR.id, size: .thumbnail)
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
