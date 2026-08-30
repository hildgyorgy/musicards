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

struct WikipediaSummary: Equatable, Sendable {
    let title: String
    let extract: String
    let languageCode: String
    let pageURL: URL
}

private struct WikipediaPageReference {
    let title: String
    let languageCode: String
    let pageURL: URL
}

enum MusicBrainzErrorCategory: Equatable {
    case cancelled
    case connectivity
    case timeout
    case rateLimited
    case serverUnavailable
    case httpFailure
    case dataFailure
    case invalidRequest
    case unexpected
}

enum MusicBrainzServiceError: Error {
    case connectivity(URLError)
    case timeout(URLError)
    case rateLimited(statusCode: Int, retryAfter: TimeInterval?)
    case serverUnavailable(statusCode: Int)
    case httpFailure(statusCode: Int)
    case dataFailure(Error)
    case invalidRequest(URLError)
    case unexpected(Error)

    var category: MusicBrainzErrorCategory {
        switch self {
        case .connectivity: return .connectivity
        case .timeout: return .timeout
        case .rateLimited: return .rateLimited
        case .serverUnavailable: return .serverUnavailable
        case .httpFailure: return .httpFailure
        case .dataFailure: return .dataFailure
        case .invalidRequest: return .invalidRequest
        case .unexpected: return .unexpected
        }
    }

    static func fromHTTPStatus(
        _ statusCode: Int,
        retryAfter: TimeInterval? = nil
    ) -> MusicBrainzServiceError {
        switch statusCode {
        case 429:
            return .rateLimited(
                statusCode: statusCode,
                retryAfter: retryAfter
            )
        case 500...599: return .serverUnavailable(statusCode: statusCode)
        default: return .httpFailure(statusCode: statusCode)
        }
    }
}

func musicBrainzErrorCategory(for error: Error) -> MusicBrainzErrorCategory {
    if let error = error as? MusicBrainzServiceError {
        return error.category
    }

    if let urlError = error as? URLError {
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .connectivity
        case .badURL, .unsupportedURL:
            return .invalidRequest
        default:
            return .unexpected
        }
    }

    if error is CancellationError {
        return .cancelled
    }

    return .unexpected
}

actor RateLimiter {
    private(set) var lastAdmission: ContinuousClock.Instant?
    private let minimumInterval: Duration
    private let clock = ContinuousClock()

    init(minimumInterval: TimeInterval = 1.05) {
        self.minimumInterval = .nanoseconds(
            Int64(minimumInterval * 1_000_000_000)
        )
    }

    @discardableResult
    func waitIfNeeded() async throws -> ContinuousClock.Instant {
        while let lastAdmission {
            let elapsed = lastAdmission.duration(to: clock.now)
            let remaining = minimumInterval - elapsed
            guard remaining > .zero else { break }
            try await Task.sleep(for: remaining, clock: clock)
        }

        try Task.checkCancellation()
        let admission = clock.now
        lastAdmission = admission
        return admission
    }
}

struct MusicBrainzService {
    typealias RequestExecutor = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)
    typealias RetrySleeper = @Sendable (Duration) async throws -> Void

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1" }
    private var userAgent: String { "MusiCards/\(version) (hild.gyorgy@freemail.hu)" }
    private static let sharedRateLimiter = RateLimiter()
    private static let defaultRetryDelays: [Duration] = [
        .milliseconds(500),
        .milliseconds(1_500),
        .seconds(3),
        .seconds(5),
        .seconds(8)
    ]

    private let rateLimiter: RateLimiter
    private let retryDelays: [Duration]
    private let maximumTotalRetryDelay: Duration
    private let requestExecutor: RequestExecutor
    private let retrySleeper: RetrySleeper

    init(
        rateLimiter: RateLimiter = Self.sharedRateLimiter,
        retryDelays: [Duration] = Self.defaultRetryDelays,
        maximumTotalRetryDelay: Duration = .seconds(20),
        requestExecutor: @escaping RequestExecutor = { request in
            try await URLSession.shared.data(for: request)
        },
        retrySleeper: @escaping RetrySleeper = { delay in
            try await Task.sleep(for: delay)
        }
    ) {
        self.rateLimiter = rateLimiter
        self.retryDelays = retryDelays
        self.maximumTotalRetryDelay = maximumTotalRetryDelay
        self.requestExecutor = requestExecutor
        self.retrySleeper = retrySleeper
    }

    private func data(from url: URL) async throws -> Data {
        var retryIndex = 0
        var totalRetryDelay = Duration.zero

        while true {
            do {
                return try await performRequest(from: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MusicBrainzServiceError {
                try Task.checkCancellation()

                guard retryIndex < retryDelays.count,
                      Self.isRetryable(error) else {
                    throw error
                }

                var delay = retryDelays[retryIndex]
                if case .rateLimited(_, let retryAfter?) = error {
                    delay = max(delay, Self.duration(seconds: retryAfter))
                }

                guard totalRetryDelay + delay <= maximumTotalRetryDelay else {
                    throw error
                }

                retryIndex += 1
                totalRetryDelay += delay
                try await retrySleeper(delay)
            }
        }
    }

    private func performRequest(from url: URL) async throws -> Data {
        if Self.requiresMusicBrainzRateLimit(url) {
            try await rateLimiter.waitIfNeeded()
        }
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestExecutor(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut {
                throw MusicBrainzServiceError.timeout(error)
            }
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed,
                 .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw MusicBrainzServiceError.connectivity(error)
            case .badURL, .unsupportedURL:
                throw MusicBrainzServiceError.invalidRequest(error)
            default:
                throw MusicBrainzServiceError.unexpected(error)
            }
        } catch {
            throw MusicBrainzServiceError.unexpected(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MusicBrainzServiceError.unexpected(
                URLError(.badServerResponse)
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw MusicBrainzServiceError.fromHTTPStatus(
                httpResponse.statusCode,
                retryAfter: Self.retryAfterInterval(from: httpResponse)
            )
        }

        return data
    }

    nonisolated static func requiresMusicBrainzRateLimit(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "musicbrainz.org" || host.hasSuffix(".musicbrainz.org")
    }

    nonisolated static func isRetryable(
        _ error: MusicBrainzServiceError
    ) -> Bool {
        switch error {
        case .timeout, .rateLimited, .serverUnavailable:
            return true
        case .connectivity(let urlError):
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost,
                 .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        case .httpFailure, .dataFailure, .invalidRequest, .unexpected:
            return false
        }
    }

    nonisolated static func retryAfterInterval(
        from response: HTTPURLResponse,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(value), seconds >= 0 {
            return seconds
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format

            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }

        return nil
    }

    nonisolated private static func duration(
        seconds: TimeInterval
    ) -> Duration {
        let clamped = min(max(0, seconds), Double(Int64.max) / 1_000_000_000)
        return .nanoseconds(Int64(clamped * 1_000_000_000))
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MusicBrainzServiceError.dataFailure(error)
        }
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
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        let response = try decode(MBReleaseSearchResponse.self, from: data)
        return response.releases
    }

    func loadRelease(id: String) async throws -> MBRelease {
        let urlString = "https://musicbrainz.org/ws/2/release/\(id)?fmt=json&inc=recordings+artist-credits+recording-level-rels+artist-rels+label-rels+labels+release-groups+annotation+url-rels"

        guard let url = URL(string: urlString) else {
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        return try decode(MBRelease.self, from: data)
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
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        let response = try decode(MBArtistSearchResponse.self, from: data)
        return response.artists
    }

    func fetchArtist(id: String) async throws -> MBArtistDetail {
        let urlString = "https://musicbrainz.org/ws/2/artist/\(id)?fmt=json&inc=url-rels"

        guard let url = URL(string: urlString) else {
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        return try decode(MBArtistDetail.self, from: data)
    }

    nonisolated static func releaseSearchQuery(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return trimmed }

        // Release Versions validation supplies an already-formed exact
        // MusicBrainz field query (for example rgid + reid). Do not run it
        // through the human-search rewriter, which would escape its Lucene
        // operators and field names.
        if trimmed.contains("rgid:") || trimmed.contains("reid:") {
            return trimmed
        }

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
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        let response = try decode(MBReleaseSearchResponse.self, from: data)
        return response.releases
    }

    func fetchReleaseByMBID(_ mbid: String) async throws -> [MBReleaseSearchResult] {
        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?fmt=json&inc=artist-credits+labels+media"

        guard let url = URL(string: urlString) else {
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        let release = try decode(MBRelease.self, from: data)

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
        guard let url = components?.url else {
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }
        let data = try await data(from: url)
        let result = try decode(MBReleaseGroupBrowseResponse.self, from: data)
        let nextOffset = offset + result.releaseGroups.count
        let hasMore = nextOffset < result.count
        return (result.releaseGroups, hasMore)
    }

    func fetchWikipediaSummary(
        from wikidataURL: URL
    ) async throws -> WikipediaSummary? {
        guard let qid = wikidataID(from: wikidataURL) else { return nil }

        let wikidataAPI = URL(
            string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json"
        )!
        let wikidataData = try await data(from: wikidataAPI)

        let json: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: wikidataData
            ) as? [String: Any] else {
                throw MusicBrainzServiceError.dataFailure(
                    URLError(.cannotParseResponse)
                )
            }
            json = object
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MusicBrainzServiceError {
            throw error
        } catch {
            throw MusicBrainzServiceError.dataFailure(error)
        }

        guard let entities = json["entities"] as? [String: Any],
              let entity = entities[qid] as? [String: Any],
              let sitelinks = entity["sitelinks"] as? [String: Any] else {
            return nil
        }

        let pages = sitelinks.values.compactMap { value
            -> WikipediaPageReference? in
            guard let sitelink = value as? [String: Any],
                  let title = sitelink["title"] as? String,
                  let urlString = sitelink["url"] as? String,
                  let pageURL = URL(string: urlString),
                  let host = pageURL.host?.lowercased(),
                  host.hasSuffix(".wikipedia.org") else {
                return nil
            }

            let languageCode = String(
                host.dropLast(".wikipedia.org".count)
            )
            guard !languageCode.isEmpty else { return nil }

            return WikipediaPageReference(
                title: title,
                languageCode: languageCode,
                pageURL: pageURL
            )
        }

        guard let languageCode = Self.preferredWikipediaLanguage(
            availableLanguages: Set(pages.map(\.languageCode)),
            preferredLanguages: Locale.preferredLanguages
        ),
              let page = pages.first(where: {
                  $0.languageCode == languageCode
              }),
              let summaryURL = Self.wikipediaSummaryURL(
                  for: page.title,
                  languageCode: languageCode
              ) else {
            return nil
        }

        let summaryData = try await data(from: summaryURL)
        let summaryJSON: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: summaryData
            ) as? [String: Any] else {
                throw MusicBrainzServiceError.dataFailure(
                    URLError(.cannotParseResponse)
                )
            }
            summaryJSON = object
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MusicBrainzServiceError {
            throw error
        } catch {
            throw MusicBrainzServiceError.dataFailure(error)
        }

        return WikipediaSummary(
            title: page.title,
            extract: summaryJSON["extract"] as? String ?? "",
            languageCode: languageCode,
            pageURL: page.pageURL
        )
    }

    nonisolated static func preferredWikipediaLanguage(
        availableLanguages: Set<String>,
        preferredLanguages: [String]
    ) -> String? {
        let available = Set(availableLanguages.map { $0.lowercased() })
        let preferred = preferredLanguages.compactMap {
            normalizedWikipediaLanguage($0)
        }
        let priority = ["en"] + preferred + ["simple"]

        for language in priority where available.contains(language) {
            return language
        }
        return available.sorted().first
    }

    nonisolated static func wikipediaSummaryURL(
        for title: String,
        languageCode: String = "en"
    ) -> URL? {
        wikipediaURL(
            for: title,
            languageCode: languageCode,
            pathPrefix: "/api/rest_v1/page/summary/"
        )
    }

    nonisolated static func wikipediaPageURL(
        for title: String,
        languageCode: String = "en"
    ) -> URL? {
        wikipediaURL(
            for: title,
            languageCode: languageCode,
            pathPrefix: "/wiki/"
        )
    }

    nonisolated private static func wikipediaURL(
        for title: String,
        languageCode: String,
        pathPrefix: String
    ) -> URL? {
        let normalizedLanguage = languageCode.lowercased()
        let allowedLanguageCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-"
        )
        guard !normalizedLanguage.isEmpty,
              normalizedLanguage.unicodeScalars.allSatisfy(
                  allowedLanguageCharacters.contains
              ) else {
            return nil
        }

        let underscored = title.replacingOccurrences(of: " ", with: "_")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encodedTitle = underscored.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else {
            return nil
        }

        return URL(
            string: "https://\(normalizedLanguage).wikipedia.org"
                + "\(pathPrefix)\(encodedTitle)"
        )
    }

    nonisolated private static func normalizedWikipediaLanguage(
        _ identifier: String
    ) -> String? {
        let normalized = identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalized == "simple" {
            return normalized
        }
        return normalized.split(separator: "-").first.map(String.init)
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
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        let result = try decode(MBReleaseSearchResponse.self, from: data)
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

        guard let url = components?.url else {
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        let response = try decode(MBRecordingSearchResponse.self, from: data)
        return response.recordings
    }

    func fetchRecording(id: String) async throws -> MBRecording {
        let urlString = """
        https://musicbrainz.org/ws/2/recording/\(id)?fmt=json&inc=artist-rels+work-rels+recording-rels+work-level-rels+place-rels
        """

        guard let url = URL(string: urlString) else {
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        return try decode(MBRecording.self, from: data)
    }

    func fetchWork(id: String) async throws -> MBWork {
        let urlString = """
        https://musicbrainz.org/ws/2/work/\(id)?fmt=json&inc=artist-rels
        """

        guard let url = URL(string: urlString) else {
            throw MusicBrainzServiceError.invalidRequest(URLError(.badURL))
        }

        let data = try await data(from: url)
        return try decode(MBWork.self, from: data)
    }
}

extension MusicBrainzService: MusicBrainzSearchServing {}
