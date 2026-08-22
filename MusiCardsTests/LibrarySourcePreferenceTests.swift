import Foundation
import XCTest
@testable import MusiCards

final class LibrarySourcePreferenceTests: XCTestCase {
    func testDisconnectingInactiveSourcePreservesActiveSource() {
        XCTAssertEqual(
            LibrarySourceSelectionPolicy.sourceAfterDisconnect(
                .navidrome,
                activeSource: .local,
                localIsConnected: true,
                navidromeIsConnected: false
            ),
            .local
        )
    }

    func testDisconnectingActiveLocalFallsBackToNavidrome() {
        XCTAssertEqual(
            LibrarySourceSelectionPolicy.sourceAfterDisconnect(
                .local,
                activeSource: .local,
                localIsConnected: false,
                navidromeIsConnected: true
            ),
            .navidrome
        )
    }

    func testDisconnectingActiveNavidromeFallsBackToLocal() {
        XCTAssertEqual(
            LibrarySourceSelectionPolicy.sourceAfterDisconnect(
                .navidrome,
                activeSource: .navidrome,
                localIsConnected: true,
                navidromeIsConnected: false
            ),
            .local
        )
    }

    func testDisconnectingFinalActiveSourceClearsSelection() {
        XCTAssertNil(
            LibrarySourceSelectionPolicy.sourceAfterDisconnect(
                .local,
                activeSource: .local,
                localIsConnected: false,
                navidromeIsConnected: false
            )
        )
        XCTAssertNil(
            LibrarySourceSelectionPolicy.sourceAfterDisconnect(
                .navidrome,
                activeSource: .navidrome,
                localIsConnected: false,
                navidromeIsConnected: false
            )
        )
    }

    func testRoundTripsBothLibrarySourcesAndClearsSelection() throws {
        let suiteName = "LibrarySourcePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(LibrarySourcePreference.load(from: defaults))

        LibrarySourcePreference.save(.navidrome, to: defaults)
        XCTAssertEqual(
            LibrarySourcePreference.load(from: defaults),
            .navidrome
        )
        XCTAssertEqual(
            LibrarySourcePreference.restoredSource(
                from: defaults,
                navidromeIsConfigured: true
            ),
            .navidrome
        )
        XCTAssertEqual(
            LibrarySourcePreference.restoredSource(
                from: defaults,
                navidromeIsConfigured: false
            ),
            .local
        )

        LibrarySourcePreference.save(.local, to: defaults)
        XCTAssertEqual(LibrarySourcePreference.load(from: defaults), .local)

        LibrarySourcePreference.save(nil, to: defaults)
        XCTAssertNil(LibrarySourcePreference.load(from: defaults))
    }
}
