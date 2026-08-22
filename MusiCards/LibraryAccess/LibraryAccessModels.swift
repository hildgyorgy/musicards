import Foundation

nonisolated enum LibraryCatalogState: Equatable, Sendable {
    case unknown
    case loading
    case ready
    case failed(String)
}

/// Source-independent catalog totals shown for the active music library.
nonisolated struct LibraryCatalogSummary: Equatable, Sendable {
    var identifiedAlbumCount = 0
    var totalAlbumCount: Int?
}

/// MusicBrainz identity used to ask the active library whether a release track
/// is available. A recording match is permitted only when the caller has
/// already established that the recording occurs uniquely on the release.
nonisolated struct LibraryTrackIdentity: Hashable, Sendable {
    let releaseID: String
    let releaseTrackID: String?
    let recordingID: String?
    let allowsRecordingFallback: Bool
}

/// Minimal release metadata exposed by any already-loaded library catalog.
/// MusicBrainz Release MBID remains the sole identity used when these results
/// are merged with the global MusicBrainz search.
nonisolated struct LibraryCatalogRelease: Equatable, Sendable {
    let releaseID: String
    let title: String
    let artistName: String
    let date: String?
    let country: String?
    let label: String?
    let format: String?
    let trackTitles: [String]

    init(
        releaseID: String,
        title: String,
        artistName: String,
        date: String? = nil,
        country: String? = nil,
        label: String? = nil,
        format: String? = nil,
        trackTitles: [String] = []
    ) {
        self.releaseID = releaseID
        self.title = title
        self.artistName = artistName
        self.date = date
        self.country = country
        self.label = label
        self.format = format
        self.trackTitles = trackTitles
    }
}

/// Shared, deterministic catalog matching used by Local and Navidrome.
/// This mirrors the proven library-first web search: comma syntax scopes the
/// left side to artist and the right side to release/track; otherwise every
/// normalized token may occur across artist, release and track metadata.
nonisolated enum LibraryCatalogSearch {
    static func search(
        _ releases: [LibraryCatalogRelease],
        query: String,
        limit: Int = 50
    ) -> [LibraryCatalogRelease] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        return releases.enumerated().compactMap { index, release in
            score(release, query: trimmed).map {
                (release: release, score: $0, index: index)
            }
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }.prefix(limit).map(\.release)
    }

    static func normalizedText(_ value: String) -> String {
        value
            .folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .joined(separator: " ")
    }

    private static func score(
        _ release: LibraryCatalogRelease,
        query: String
    ) -> Int? {
        let normalizedReleaseID = release.releaseID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedQueryID = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedReleaseID == normalizedQueryID {
            return 1_000
        }

        let artist = normalizedText(release.artistName)
        let title = normalizedText(release.title)
        let tracks = release.trackTitles.map(normalizedText)
        let commaIndex = query.firstIndex(of: ",")
        let matches: Bool

        if let commaIndex {
            let artistTokens = tokens(String(query[..<commaIndex]))
            let releaseStart = query.index(after: commaIndex)
            let releaseTokens = tokens(String(query[releaseStart...]))
            let artistMatches = artistTokens.isEmpty
                || includesEvery(artist, tokens: artistTokens)
            let releaseMatches = releaseTokens.isEmpty
                || includesEvery(title, tokens: releaseTokens)
                || tracks.contains {
                    includesEvery($0, tokens: releaseTokens)
                }
            matches = artistMatches && releaseMatches
                && (!artistTokens.isEmpty || !releaseTokens.isEmpty)
        } else {
            let queryTokens = tokens(query)
            let allText = ([artist, title] + tracks).joined(separator: " ")
            matches = includesEvery(allText, tokens: queryTokens)
        }

        guard matches else { return nil }

        let titleQuery: String
        let artistQuery: String
        if let commaIndex {
            artistQuery = normalizedText(String(query[..<commaIndex]))
            titleQuery = normalizedText(
                String(query[query.index(after: commaIndex)...])
            )
        } else {
            let normalizedQuery = normalizedText(query)
            artistQuery = normalizedQuery
            titleQuery = normalizedQuery
        }
        var result = 10
        if !titleQuery.isEmpty, title == titleQuery { result += 100 }
        if !artistQuery.isEmpty, artist == artistQuery { result += 80 }
        if !titleQuery.isEmpty, title.hasPrefix(titleQuery) { result += 40 }
        if !artistQuery.isEmpty, artist.hasPrefix(artistQuery) { result += 30 }

        let trackQuery: String
        if let commaIndex {
            trackQuery = String(query[query.index(after: commaIndex)...])
        } else {
            trackQuery = query
        }
        let trackNeedle = normalizedText(trackQuery)
        if !trackNeedle.isEmpty,
           tracks.contains(where: { $0.contains(trackNeedle) }) {
            result += 20
        }
        return result
    }

    private static func tokens(_ value: String) -> [String] {
        normalizedText(value).split(separator: " ").map(String.init)
    }

    private static func includesEvery(
        _ haystack: String,
        tokens: [String]
    ) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy(haystack.contains)
    }
}
