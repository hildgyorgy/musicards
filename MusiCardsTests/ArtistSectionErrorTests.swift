import XCTest
@testable import MusiCards

final class ArtistSectionErrorTests: XCTestCase {
    func testKnownArtistHeaderDoesNotAllowGlobalArtistFailure() {
        XCTAssertTrue(
            MusiCardsAppModel.hasUsableArtistHeader(
                artist: nil,
                name: "Miles Davis"
            )
        )
    }

    func testMBIDOnlyPathAllowsGlobalFailureOnlyWithoutIdentity() {
        XCTAssertFalse(
            MusiCardsAppModel.hasUsableArtistHeader(
                artist: nil,
                name: "   "
            )
        )
    }

    func testDiscographyErrorUsesSectionSpecificPresentation() {
        let view = ErrorStateView.discographyRetry(
            for: MusicBrainzServiceError.timeout(URLError(.timedOut)),
            { }
        )

        XCTAssertEqual(view.title, "Discography request timed out")
        XCTAssertEqual(view.subtitle, "Please try again")
    }

    func testDiscographyConnectivityErrorKeepsConnectivityGuidance() {
        let view = ErrorStateView.discographyRetry(
            for: MusicBrainzServiceError.connectivity(
                URLError(.notConnectedToInternet)
            ),
            { }
        )

        XCTAssertEqual(view.title, "Couldn't load discography")
        XCTAssertEqual(view.subtitle, "Check your connection and try again")
    }
}
