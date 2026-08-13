import CoreGraphics
import Foundation
import XCTest
@testable import MusiCards

#if os(macOS)
final class PlatformNowPlayingCoordinatorTests: XCTestCase {
    func testArtworkRequestHandlerCanRunOffMainQueue() {
        let pngData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let artwork = PlatformNowPlayingCoordinator.makeArtwork(from: pngData)
        XCTAssertNotNil(artwork)

        nonisolated(unsafe) let backgroundArtwork = artwork
        let requestFinished = expectation(description: "Artwork requested")

        DispatchQueue.global(qos: .userInitiated).async {
            let image = backgroundArtwork?.image(at: CGSize(width: 64, height: 64))
            XCTAssertNotNil(image)
            requestFinished.fulfill()
        }

        wait(for: [requestFinished], timeout: 2)
    }
}
#endif
