//
//  MusicBrainzService.swift
//  MBViewer
//

import Foundation

protocol MusicBrainzSearchServing {
    func searchReleases(
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> [MBReleaseSearchResult]
    func searchArtists(
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> [MBArtistSearchResult]
    func fetchReleasesForReleaseGroup(
        id: String,
        limit: Int,
        offset: Int
    ) async throws -> (releases: [MBReleaseSearchResult], hasMore: Bool)
    func searchRecordings(
        trackTitle: String,
        artistName: String?,
        limit: Int,
        offset: Int
    ) async throws -> [MBRecordingSearchResult]
    func loadRelease(id: String) async throws -> MBRelease
}

private actor RateLimiter {
    private var lastRequestTime: Date = .distantPast
    private let minimumInterval: TimeInterval = 1.05

    func waitIfNeeded() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)

        if elapsed < minimumInterval {
            let waitNanoseconds = UInt64((minimumInterval - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: waitNanoseconds)
        }

        lastRequestTime = Date()
    }
}

struct MusicBrainzService {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1" }
    private var userAgent: String { "MusiCards/\(version) (hild.gyorgy@freemail.hu)" }
    private static let sharedRateLimiter = RateLimiter()

    private func data(from url: URL) async throws -> Data {
        await Self.sharedRateLimiter.waitIfNeeded()

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    func searchReleases(
        query: String,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> [MBReleaseSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if MBIdentifiers.isMBID(trimmed) {
            return try await fetchReleaseByMBID(trimmed)
        }

        if MBIdentifiers.isBareBarcode(trimmed) {
            return try await searchReleasesByBarcode(trimmed, limit: limit, offset: offset)
        }

        let smartQuery = Self.releaseSearchQuery(from: query)

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "query", value: smartQuery),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "inc", value: "artist-credits+labels+media")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        let response = try JSONDecoder().decode(MBReleaseSearchResponse.self, from: data)
        return response.releases
    }

    func loadRelease(id: String) async throws -> MBRelease {
        let urlString = "https://musicbrainz.org/ws/2/release/\(id)?fmt=json&inc=recordings+artist-credits+recording-level-rels+artist-rels+label-rels+labels+release-groups+annotation+url-rels"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        return try JSONDecoder().decode(MBRelease.self, from: data)
    }

    func searchArtists(
        query: String,
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> [MBArtistSearchResult] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "query", value: Self.luceneEscapedText(query)),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        let response = try JSONDecoder().decode(MBArtistSearchResponse.self, from: data)
        return response.artists
    }

    func fetchArtist(id: String) async throws -> MBArtistDetail {
        let urlString = "https://musicbrainz.org/ws/2/artist/\(id)?fmt=json&inc=url-rels"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        return try JSONDecoder().decode(MBArtistDetail.self, from: data)
    }

    nonisolated static func releaseSearchQuery(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)

            let artistPart = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let releasePart = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            var fields: [String] = []

            if !artistPart.isEmpty {
                fields.append("artist:(\(luceneEscapedText(artistPart)))")
            }

            if !releasePart.isEmpty {
                fields.append("release:(\(luceneEscapedText(releasePart)))")
            }

            if !fields.isEmpty {
                return fields.joined(separator: " AND ")
            }
        }

        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        if words.count >= 2 {
            return words.map {
                "\"\(luceneQuotedText($0))\""
            }.joined(separator: " AND ")
        } else {
            return luceneEscapedText(trimmed)
        }
    }

    /// Escapes Lucene query syntax while retaining the existing search shape.
    /// URLComponents handles URL encoding separately; this protects the
    /// MusicBrainz query parser from user-entered punctuation.
    nonisolated static func luceneEscapedText(_ value: String) -> String {
        let reserved = Set("+-&|!(){}[]^\"~*?:\\/")
        return value.reduce(into: "") { result, character in
            if reserved.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }

    private nonisolated static func luceneQuotedText(
        _ value: String
    ) -> String {
        value.reduce(into: "") { result, character in
            if character == "\\" || character == "\"" {
                result.append("\\")
            }
            result.append(character)
        }
    }

    private func wikidataID(from url: URL) -> String? {
        url.lastPathComponent
    }

    func searchReleasesByBarcode(
        _ barcode: String,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> [MBReleaseSearchResult] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "query", value: "barcode:\(barcode)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "inc", value: "artist-credits+labels+media")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        let response = try JSONDecoder().decode(MBReleaseSearchResponse.self, from: data)
        return response.releases
    }

    func fetchReleaseByMBID(_ mbid: String) async throws -> [MBReleaseSearchResult] {
        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?fmt=json&inc=artist-credits+labels+media"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        let release = try JSONDecoder().decode(MBRelease.self, from: data)

        let result = MBReleaseSearchResult(
            id: release.id,
            title: release.title,
            date: release.date,
            country: release.country,
            disambiguation: release.disambiguation,
            score: 100,
            artistCredit: release.artistCredit,
            labelInfo: release.labelInfo,
            media: release.media
        )

        return [result]
    }

    func fetchArtistReleaseGroups(
        id: String,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> (groups: [MBReleaseGroupSummary], hasMore: Bool) {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group")
        components?.queryItems = [
            URLQueryItem(name: "artist", value: id),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let data = try await data(from: url)
        let result = try JSONDecoder().decode(MBReleaseGroupBrowseResponse.self, from: data)
        let nextOffset = offset + result.releaseGroups.count
        let hasMore = nextOffset < result.count
        return (result.releaseGroups, hasMore)
    }

    func fetchWikipediaSummary(from wikidataURL: URL) async throws -> (title: String, extract: String)? {
        guard let qid = wikidataID(from: wikidataURL) else { return nil }

        let wikidataAPI = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json")!
        let wikidataData = try await data(from: wikidataAPI)

        let json = try JSONSerialization.jsonObject(with: wikidataData) as? [String: Any]

        guard
            let entities = json?["entities"] as? [String: Any],
            let entity = entities[qid] as? [String: Any],
            let sitelinks = entity["sitelinks"] as? [String: Any],
            let enwiki = sitelinks["enwiki"] as? [String: Any],
            let title = enwiki["title"] as? String
        else {
            return nil
        }

        let encodedTitle = title.replacingOccurrences(of: " ", with: "_")
        let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encodedTitle)")!

        let summaryData = try await data(from: summaryURL)
        let summaryJSON = try JSONSerialization.jsonObject(with: summaryData) as? [String: Any]
        let extract = summaryJSON?["extract"] as? String

        return (title, extract ?? "")
    }

    // Now returns (releases, hasMore) and uses a sensible page size
    func fetchReleasesForReleaseGroup(
        id: String,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> (releases: [MBReleaseSearchResult], hasMore: Bool) {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")
        components?.queryItems = [
            URLQueryItem(name: "release-group", value: id),
            URLQueryItem(name: "inc", value: "artist-credits+labels+recordings"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        let result = try JSONDecoder().decode(MBReleaseSearchResponse.self, from: data)
        return (result.releases, result.releases.count == limit)
    }

    /// Resolve a Shazam match through recording search and return its releases.
    func searchRecordings(
        trackTitle: String,
        artistName: String? = nil,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> [MBRecordingSearchResult] {
        var queryParts: [String] = ["recording:(\(trackTitle))"]
        if let artist = artistName, !artist.isEmpty {
            queryParts.append("artist:(\(artist))")
        }
        let query = queryParts.joined(separator: " AND ")

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "inc", value: "artist-credits+releases+labels+media")
        ]

        guard let url = components?.url else { throw URLError(.badURL) }

        let data = try await data(from: url)
        let response = try JSONDecoder().decode(MBRecordingSearchResponse.self, from: data)
        return response.recordings
    }

    func fetchRecording(id: String) async throws -> MBRecording {
        let urlString = """
        https://musicbrainz.org/ws/2/recording/\(id)?fmt=json&inc=artist-rels+work-rels+recording-rels+work-level-rels+place-rels
        """

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        return try JSONDecoder().decode(MBRecording.self, from: data)
    }

    func fetchWork(id: String) async throws -> MBWork {
        let urlString = """
        https://musicbrainz.org/ws/2/work/\(id)?fmt=json&inc=artist-rels
        """

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let data = try await data(from: url)
        return try JSONDecoder().decode(MBWork.self, from: data)
    }
}

extension MusicBrainzService: MusicBrainzSearchServing {}
