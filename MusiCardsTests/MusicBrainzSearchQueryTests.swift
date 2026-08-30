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

    func testWikipediaLanguagePreferenceUsesEnglishThenDeviceThenSimple() {
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["de", "en", "hu"],
                preferredLanguages: ["hu-HU"]
            ),
            "en"
        )
        XCTAssertEqual(
            MusicBrainzService.preferredWikipediaLanguage(
                availableLanguages: ["de", "hu"],
                preferredLanguages: ["hu-HU"]
            ),
            "hu"
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
