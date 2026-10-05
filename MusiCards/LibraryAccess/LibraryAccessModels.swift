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
    let mediumPosition: Int?
    let trackPosition: Int?

    init(
        releaseID: String,
        releaseTrackID: String?,
        recordingID: String?,
        allowsRecordingFallback: Bool,
        mediumPosition: Int? = nil,
        trackPosition: Int? = nil
    ) {
        self.releaseID = releaseID
        self.releaseTrackID = releaseTrackID
        self.recordingID = recordingID
        self.allowsRecordingFallback = allowsRecordingFallback
        self.mediumPosition = mediumPosition
        self.trackPosition = trackPosition
    }
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

/// Explicit search intent passed through the library provider boundary.
/// User-entered comma syntax is parsed once by SearchViewModel; providers do
/// not infer search behavior from punctuation.
nonisolated enum LibraryCatalogQuery: Equatable, Sendable {
    case artists(matching: String)
    case releases(artist: String?, text: String?)
    case releaseID(String)
}

/// Shared, deterministic catalog matching used by Local and Navidrome.
/// Artist terms match artist metadata. Release text matches release and track
/// titles, preserving the existing library-first search behavior.
nonisolated enum LibraryCatalogSearch {
    static func search(
        _ releases: [LibraryCatalogRelease],
        query: LibraryCatalogQuery,
        limit: Int = 50
    ) -> [LibraryCatalogRelease] {
        guard limit > 0 else { return [] }

        return releases.enumerated().compactMap { index, release in
            score(release, query: query).map {
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
        query: LibraryCatalogQuery
    ) -> Int? {
        let artist = normalizedText(release.artistName)
        let title = normalizedText(release.title)
        let tracks = release.trackTitles.map(normalizedText)
        let artistQuery: String
        let titleQuery: String

        switch query {
        case .releaseID(let releaseID):
            let normalizedReleaseID = release.releaseID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedQueryID = releaseID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedReleaseID == normalizedQueryID ? 1_000 : nil

        case .artists(let queryText):
            artistQuery = normalizedText(queryText)
            titleQuery = ""
            let artistTokens = tokens(queryText)
            guard includesEvery(artist, tokens: artistTokens) else {
                return nil
            }

        case .releases(let artistText, let releaseText):
            artistQuery = normalizedText(artistText ?? "")
            titleQuery = normalizedText(releaseText ?? "")
            let artistTokens = tokens(artistText ?? "")
            let releaseTokens = tokens(releaseText ?? "")
            guard !artistTokens.isEmpty || !releaseTokens.isEmpty else {
                return nil
            }
            let artistMatches = artistTokens.isEmpty
                || includesEvery(artist, tokens: artistTokens)
            let releaseMatches = releaseTokens.isEmpty
                || includesEvery(title, tokens: releaseTokens)
                || tracks.contains {
                    includesEvery($0, tokens: releaseTokens)
                }
            guard artistMatches && releaseMatches else { return nil }
        }

        var result = 10
        if !titleQuery.isEmpty, title == titleQuery { result += 100 }
        if !artistQuery.isEmpty, artist == artistQuery { result += 80 }
        if !titleQuery.isEmpty, title.hasPrefix(titleQuery) { result += 40 }
        if !artistQuery.isEmpty, artist.hasPrefix(artistQuery) { result += 30 }

        let trackNeedle = titleQuery
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
