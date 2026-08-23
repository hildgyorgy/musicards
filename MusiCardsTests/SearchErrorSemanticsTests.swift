import XCTest
@testable import MusiCards

final class SearchErrorSemanticsTests: XCTestCase {
    func testConnectivityPresentationUsesConnectionGuidance() {
        let view = ErrorStateView.searchRetry(
            for: URLError(.notConnectedToInternet),
            { }
        )

        XCTAssertEqual(view.title, "Couldn't reach MusicBrainz")
        XCTAssertEqual(view.subtitle, "Check your connection and try again")
    }

    func testTimeoutPresentationDoesNotBlameConnectivity() {
        let view = ErrorStateView.searchRetry(for: URLError(.timedOut)) { }

        XCTAssertEqual(view.title, "MusicBrainz request timed out")
        XCTAssertEqual(view.subtitle, "Please try again")
    }

    func testRateLimitStatusIsPreservedAndUsesTemporaryServiceMessage() {
        let error = MusicBrainzServiceError.fromHTTPStatus(429)
        let view = ErrorStateView.searchRetry(for: error) { }

        if case .rateLimited(let statusCode) = error {
            XCTAssertEqual(statusCode, 429)
        } else {
            XCTFail("Expected rate-limit error")
        }
        XCTAssertEqual(view.title, "MusicBrainz is temporarily unavailable")
    }

    func testServerStatusIsPreservedAndUsesTemporaryServiceMessage() {
        let error = MusicBrainzServiceError.fromHTTPStatus(503)
        let view = ErrorStateView.searchRetry(for: error) { }

        if case .serverUnavailable(let statusCode) = error {
            XCTAssertEqual(statusCode, 503)
        } else {
            XCTFail("Expected server error")
        }
        XCTAssertEqual(view.title, "MusicBrainz is temporarily unavailable")
    }

    func testOtherHTTPStatusUsesNeutralDataMessage() {
        let error = MusicBrainzServiceError.fromHTTPStatus(404)
        let view = ErrorStateView.searchRetry(for: error) { }

        if case .httpFailure(let statusCode) = error {
            XCTAssertEqual(statusCode, 404)
        } else {
            XCTFail("Expected HTTP error")
        }
        XCTAssertEqual(view.title, "Couldn't load MusicBrainz results")
        XCTAssertEqual(view.subtitle, "Please try again")
    }

    func testDecodingFailureUsesNeutralDataMessage() {
        let error = MusicBrainzServiceError.dataFailure(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test"))
        )
        let view = ErrorStateView.searchRetry(for: error) { }

        XCTAssertEqual(view.title, "Couldn't load MusicBrainz results")
        XCTAssertNotEqual(view.subtitle, "Check your connection and try again")
    }

    func testCancellationIsRecognizedAsControlFlow() {
        XCTAssertTrue(SearchViewModel.isCancellation(CancellationError()))
        XCTAssertTrue(SearchViewModel.isCancellation(URLError(.cancelled)))
    }
}
