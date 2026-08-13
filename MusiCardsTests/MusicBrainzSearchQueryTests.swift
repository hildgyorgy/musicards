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
}
