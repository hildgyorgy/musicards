import XCTest
@testable import MusiCards

final class MusicBrainzSearchQueryTests: XCTestCase {
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
}
