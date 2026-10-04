import XCTest
@testable import MusiCards

final class MusicBrainzSearchQueryTests: XCTestCase {
    func testRateLimitAppliesOnlyToMusicBrainzHosts() throws {
        XCTAssertTrue(
            MusicBrainzService.requiresMusicBrainzRateLimit(
                try XCTUnwrap(URL(string: "https://musicbrainz.org/ws/2/artist"))
            )
        )
        XCTAssertTrue(
            MusicBrainzService.requiresMusicBrainzRateLimit(
                try XCTUnwrap(URL(string: "https://beta.musicbrainz.org/ws/2/artist"))
            )
        )
        XCTAssertFalse(
            MusicBrainzService.requiresMusicBrainzRateLimit(
                try XCTUnwrap(URL(string: "https://www.wikidata.org/wiki/Q1"))
            )
        )
        XCTAssertFalse(
            MusicBrainzService.requiresMusicBrainzRateLimit(
                try XCTUnwrap(URL(string: "https://de.wikipedia.org/api/rest_v1/page/summary/Test"))
            )
        )
    }

    func testCommaSearchKeepsArtistAndReleaseFields() {
        XCTAssertEqual(
            MusicBrainzService.releaseSearchQuery(
                from: "Patricia Barber, Verse"
            ),
            "artist:(Patricia Barber) AND release:(Verse)"
        )
    }

    func testMultiwordReleaseSearchRequiresEveryWord() {
        XCTAssertEqual(
            MusicBrainzService.releaseSearchQuery(from: "Kind of Blue"),
            "\"Kind\" AND \"of\" AND \"Blue\""
        )
    }

    func testLucenePunctuationIsEscaped() {
        XCTAssertEqual(
            MusicBrainzService.releaseSearchQuery(from: "AC/DC: Live"),
            "\"AC/DC:\" AND \"Live\""
        )
        XCTAssertEqual(
            MusicBrainzService.luceneEscapedText("AC/DC (Live)"),
            "AC\\/DC \\(Live\\)"
        )
    }

    func testQuotedWordEscapesEmbeddedQuote() {
        XCTAssertEqual(
            MusicBrainzService.releaseSearchQuery(from: "Miles \"Electric\""),
            "\"Miles\" AND \"\\\"Electric\\\"\""
        )
    }

    func testExactReleaseGroupValidationQueryPreservesLuceneFields() {
        let query = "rgid:11111111-1111-1111-1111-111111111111 AND (reid:22222222-2222-2222-2222-222222222222)"

        XCTAssertEqual(MusicBrainzService.releaseSearchQuery(from: query), query)
    }

    func testWikipediaSummaryURLTreatsSlashAsTitleContent() {
        XCTAssertEqual(
            MusicBrainzService.wikipediaSummaryURL(for: "AC/DC")?.absoluteString,
            "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC"
        )
    }

    func testWikipediaSummaryURLDoesNotInterpretQueryOrFragmentCharacters() {
        XCTAssertEqual(
            MusicBrainzService.wikipediaSummaryURL(for: "Who? #1")?.absoluteString,
            "https://en.wikipedia.org/api/rest_v1/page/summary/Who%3F_%231"
        )
    }

    func testWikipediaLanguagePreferenceUsesEnglishThenArtistThenFallback() {
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["de", "en", "hu"],
                nativeLanguages: ["de"],
                preferredLanguages: ["hu-HU"]
            ),
            "en"
        )
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["de", "es", "hu"],
                nativeLanguages: ["es"],
                preferredLanguages: ["hu-HU"]
            ),
            "es"
        )
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["de", "hu"],
                nativeLanguages: ["es"],
                preferredLanguages: ["hu-HU"]
            ),
            "hu"
        )
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["es"],
                preferredLanguages: ["hu-HU"]
            ),
            "es"
        )
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["de", "simple"],
                preferredLanguages: ["hu-HU"]
            ),
            "simple"
        )
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["fr", "de"],
                preferredLanguages: ["hu-HU"]
            ),
            "de"
        )
    }

    func testWikidataNativeLanguageResolvesToWikipediaLanguageCode() {
        let artist: [String: Any] = [
            "claims": [
                "P103": [
                    [
                        "rank": "normal",
                        "mainsnak": [
                            "datavalue": ["value": ["id": "Q1321"]]
                        ]
                    ]
                ]
            ]
        ]
        let languages: [String: Any] = [
            "entities": [
                "Q1321": [
                    "claims": [
                        "P424": [
                            [
                                "rank": "normal",
                                "mainsnak": [
                                    "datavalue": ["value": "es"]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let ids = MusicBrainzService.nativeLanguageItemIDs(in: artist)
        XCTAssertEqual(ids, ["Q1321"])
        XCTAssertEqual(
            MusicBrainzService.wikimediaLanguageCodes(
                in: languages,
                for: ids
            ),
            ["es"]
        )
    }

    @MainActor
    func testWikipediaSummarySelectsArtistLanguageWhenEnglishIsMissing()
        async throws {
        let artistData = Data("""
        {"entities":{"Q999":{"claims":{"P103":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"id":"Q1321"}}}}]},"sitelinks":{"eswiki":{"title":"Artista","url":"https://es.wikipedia.org/wiki/Artista"},"frwiki":{"title":"Artiste","url":"https://fr.wikipedia.org/wiki/Artiste"}}}}}
        """.utf8)
        let languageData = Data("""
        {"entities":{"Q1321":{"claims":{"P424":[{"rank":"normal","mainsnak":{"datavalue":{"value":"es"}}}]}}}}
        """.utf8)
        let summaryData = Data("""
        {"extract":"Spanish artist biography"}
        """.utf8)
        let service = MusicBrainzService(
            rateLimiter: RateLimiter(minimumInterval: 0),
            retryDelays: [],
            requestExecutor: { request in
                let url = try XCTUnwrap(request.url)
                let data: Data
                if url.path.contains("Special:EntityData/Q999.json") {
                    data = artistData
                } else if url.path == "/w/api.php" {
                    data = languageData
                } else if url.host == "es.wikipedia.org" {
                    data = summaryData
                } else {
                    throw URLError(.badURL)
                }
                return (
                    data,
                    try XCTUnwrap(HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
        )

        let summary = try await service.fetchWikipediaSummary(
            from: try XCTUnwrap(URL(string: "https://www.wikidata.org/wiki/Q999"))
        )
        XCTAssertEqual(summary?.languageCode, "es")
        XCTAssertEqual(summary?.extract, "Spanish artist biography")
        XCTAssertEqual(
            summary?.pageURL.absoluteString,
            "https://es.wikipedia.org/wiki/Artista"
        )
    }

    func testWikipediaURLsUseSelectedLanguage() {
        XCTAssertEqual(
            MusicBrainzService.wikipediaSummaryURL(
                for: "[re:jazz]",
                languageCode: "de"
            )?.absoluteString,
            "https://de.wikipedia.org/api/rest_v1/page/summary/%5Bre:jazz%5D"
        )
        XCTAssertEqual(
            MusicBrainzService.wikipediaPageURL(
                for: "[re:jazz]",
                languageCode: "de"
            )?.absoluteString,
            "https://de.wikipedia.org/wiki/%5Bre:jazz%5D"
        )
    }
}
