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

    func testWikipediaDarkURLAddsBothNightModeParameters() throws {
        let original = try XCTUnwrap(URL(string: "https://en.wikipedia.org/wiki/Miles_Davis"))
        let transformed = WikipediaURLPresentation.url(original, isDark: true)
        let components = try XCTUnwrap(URLComponents(url: transformed, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(items["vectornightmode"], "1")
        XCTAssertEqual(items["minervanightmode"], "1")
        XCTAssertEqual(components.path, "/wiki/Miles_Davis")
    }

    func testWikipediaLightURLRemainsCanonical() throws {
        let original = try XCTUnwrap(URL(string: "https://hu.wikipedia.org/wiki/Liszt_Ferenc?oldformat=true#Korai_evek"))

        XCTAssertEqual(WikipediaURLPresentation.url(original, isDark: false), original)
    }

    func testWikipediaDarkURLPreservesQueryFragmentAndReplacesExistingNightMode() throws {
        let original = try XCTUnwrap(URL(string: "https://en.wikipedia.org/wiki/Miles_Davis?oldformat=true&vectornightmode=0#Early_life"))
        let transformed = WikipediaURLPresentation.url(original, isDark: true)
        let components = try XCTUnwrap(URLComponents(url: transformed, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(components.host, "en.wikipedia.org")
        XCTAssertEqual(components.fragment, "Early_life")
        XCTAssertEqual(items.filter { $0.name == "vectornightmode" }.count, 1)
        XCTAssertEqual(items.filter { $0.name == "minervanightmode" }.count, 1)
        XCTAssertTrue(items.contains { $0.name == "oldformat" && $0.value == "true" })
        XCTAssertEqual(items.first { $0.name == "vectornightmode" }?.value, "1")
    }
}
