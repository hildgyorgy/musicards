import XCTest
@testable import MusiCards

@MainActor
final class ArtistProgressiveLoadingTests: XCTestCase {
    func testSearchArtistContextKeepsImmediateHeaderMetadata() {
        let row = SearchArtistRow(id: "artist-id", name: "Example Artist", lifeSpan: "1970–")

        XCTAssertEqual(row.name, "Example Artist")
        XCTAssertEqual(row.lifeSpan, "1970–")
    }

    func testDiscographyGroupingKeepsTypeOrderAndNewestFirst() {
        let groups = [
            MBReleaseGroupSummary(id: "single", title: "Single", primaryType: "Single", secondaryTypes: nil, firstReleaseDate: "2020", disambiguation: nil),
            MBReleaseGroupSummary(id: "album-old", title: "Old", primaryType: "Album", secondaryTypes: nil, firstReleaseDate: "2010", disambiguation: nil),
            MBReleaseGroupSummary(id: "album-new", title: "New", primaryType: "Album", secondaryTypes: nil, firstReleaseDate: "2020", disambiguation: nil)
        ]

        let sections = groupedDiscographySections(from: groups)

        XCTAssertEqual(sections.map { $0.title }, ["Album", "Single"])
        XCTAssertEqual(sections[0].items.map { $0.id }, ["album-new", "album-old"])
    }
}
