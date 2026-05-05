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

    // Track whether the current comma-search fell back to recording/track search

    // MARK: - Shared state
    @Published var mode: SearchMode = .search
    @Published var searchError: Error?
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?
    private let musicBrainzService: MusicBrainzService

    init(service: MusicBrainzService) {
        self.musicBrainzService = service
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

        if q.contains(",") || isBareBarcode(q) || isMBID(q) {
            return .releaseResults
        } else {
            return .artistResults
        }
    }

    // MARK: - Search entry point

    func queryDidChange() {
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

                await prepareReleaseRowsSequentially(from: results, append: false)

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
        MBDateTextFormatter.lifeSpanTextOrEmpty(from: lifeSpan)
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
            if q.contains(",") || isBareBarcode(q) || isMBID(q) {
                if isBareBarcode(q) || isMBID(q) {
                    // Barcode / MBID — release lookup only, no track search
                    let results = try await musicBrainzService.searchReleases(
                        query: q,
                        limit: pageSize,
                        offset: currentOffset
                    )
                    let sorted = sortRawReleases(results, query: q)
                    releaseResults = []
                    artistRows = []
                    currentOffset = results.count
                    hasMoreResults = results.count == pageSize
                    await prepareReleaseRowsSequentially(from: sorted, append: false)

                } else {
                    // Comma query — run release search AND track search in parallel,
                    // then merge: release-title matches first, track-containing releases appended.
                    let parsed = parseCommaQuery(q)

                    async let releasesFetch = musicBrainzService.searchReleases(
                        query: q,
                        limit: pageSize,
                        offset: 0
                    )
                    async let recordingsFetch = musicBrainzService.searchRecordings(
                        trackTitle: parsed.after,
                        artistName: parsed.before.isEmpty ? nil : parsed.before,
                        limit: pageSize,
                        offset: 0
                    )

                    let (releaseResults_, recordings) = try await (releasesFetch, recordingsFetch)

                    let sortedReleases = sortRawReleases(releaseResults_, query: q)
                    let trackReleases  = flattenRecordingResults(recordings)

                    // Merge: keep release-title hits first, append track hits not already present
                    // Track-only results are sorted: searched artist first, compilations last
                    let releaseIDs = Set(sortedReleases.map(\.id))
                    let trackOnly  = sortTrackOnlyResults(
                        trackReleases.filter { !releaseIDs.contains($0.id) },
                        artistQuery: parsed.before
                    )
                    let merged     = sortedReleases + trackOnly

                    releaseResults = []
                    artistRows = []
                    currentOffset = merged.count
                    hasMoreResults = releaseResults_.count == pageSize || trackReleases.count == pageSize

                    await prepareReleaseRowsSequentially(from: merged, append: false)
                }

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

                artistRows = rows
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

            let sorted = sortedVersions(results)

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

            let sorted = sortedVersions(results)
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
            if q.contains(",") && !isBareBarcode(q) && !isMBID(q) {
                // Parallel release + track search, same merge logic as initial search
                let parsed = parseCommaQuery(q)

                async let releasesFetch = musicBrainzService.searchReleases(
                    query: q,
                    limit: pageSize,
                    offset: currentOffset
                )
                async let recordingsFetch = musicBrainzService.searchRecordings(
                    trackTitle: parsed.after,
                    artistName: parsed.before.isEmpty ? nil : parsed.before,
                    limit: pageSize,
                    offset: currentOffset
                )

                let (releaseResults_, recordings) = try await (releasesFetch, recordingsFetch)

                let sortedReleases = sortRawReleases(releaseResults_, query: q)
                let trackReleases  = flattenRecordingResults(recordings)

                let existing   = Set(releaseResults.map(\.id))
                let releaseIDs = Set(sortedReleases.map(\.id))
                let trackOnly  = sortTrackOnlyResults(
                    trackReleases.filter { !releaseIDs.contains($0.id) },
                    artistQuery: parsed.before
                )
                let merged     = (sortedReleases + trackOnly).filter { !existing.contains($0.id) }

                currentOffset += merged.count
                hasMoreResults = releaseResults_.count == pageSize || trackReleases.count == pageSize

                await prepareReleaseRowsSequentially(from: merged, append: true)

            } else {
                let results = try await musicBrainzService.searchReleases(
                    query: q,
                    limit: pageSize,
                    offset: currentOffset
                )
                let sorted = sortRawReleases(results, query: q)
                currentOffset += results.count
                hasMoreResults = results.count == pageSize
                await prepareReleaseRowsSequentially(from: sorted, append: true)
            }
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

            appendUniqueArtistRows(rows)
            currentOffset += results.count
            hasMoreResults = results.count == pageSize

        } catch is CancellationError {
            return
        } catch {
            hasMoreResults = false
        }
    }

    // MARK: - Row builders

    private nonisolated func artistLine(from artistCredit: [MBArtistCredit]?) -> String {
        artistCredit?.compactMap { $0.name }.joined(separator: ", ") ?? ""
    }

    private nonisolated func releaseMetaLine(
        date: String?, country: String?,
        labelInfo: [MBLabelInfo]?, media: [MBMedium]?
    ) -> String {
        let parts = [
            MBDateTextFormatter.year(from: date),
            country ?? "",
            labelInfo?.compactMap { $0.label?.name }.first ?? "",
            media?.compactMap { $0.format }.first ?? ""
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return parts.joined(separator: " • ")
    }

    private func appendUniqueReleaseRow(_ row: SearchReleaseRow) {
        guard !releaseResults.contains(where: { $0.id == row.id }) else { return }
        releaseResults.append(row)
    }

    private func appendUniqueArtistRows(_ rows: [SearchArtistRow]) {
        let existing = Set(artistRows.map(\.id))
        artistRows.append(contentsOf: rows.filter { !existing.contains($0.id) })
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
            artistLine: artistLine(from: artistCredit),
            metaLine: releaseMetaLine(date: date, country: country, labelInfo: labelInfo, media: media),
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

    // MARK: - Track search helpers

    /// Split "artist, track" or ", track" into its two parts.
    private nonisolated func parseCommaQuery(_ q: String) -> (before: String, after: String) {
        let raw = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commaIndex = raw.firstIndex(of: ",") else {
            return (before: "", after: raw)
        }
        let before = String(raw[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after  = String(raw[raw.index(after: commaIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (before: before, after: after)
    }

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

    /// Sort track-only results so the searched artist's own releases come first,
    /// then everything else (compilations, various-artists, etc.) in original order.
    private nonisolated func sortTrackOnlyResults(
        _ releases: [MBReleaseSearchResult],
        artistQuery: String
    ) -> [MBReleaseSearchResult] {
        guard !artistQuery.isEmpty else { return releases }

        let needle = artistQuery.lowercased()

        return releases.sorted { a, b in
            let aMatch = artistCreditMatches(a.artistCredit, needle: needle)
            let bMatch = artistCreditMatches(b.artistCredit, needle: needle)
            if aMatch != bMatch { return aMatch }
            return false  // stable: preserve original order within each group
        }
    }

    private nonisolated func artistCreditMatches(
        _ credit: [MBArtistCredit]?,
        needle: String
    ) -> Bool {
        guard let credit else { return false }
        return credit.contains {
            $0.name.lowercased().contains(needle)
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

private func isBareBarcode(_ text: String) -> Bool {
    text.allSatisfy(\.isNumber) && text.count >= 8
}

private func isMBID(_ text: String) -> Bool {
    let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    return text.range(of: pattern, options: .regularExpression) != nil
}
