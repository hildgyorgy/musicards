import XCTest
@testable import MusiCards

final class ReleaseSelectionRaceTests: XCTestCase {
    @MainActor
    func testLatestReleaseSelectionWinsWhenOlderSuccessFinishesLast() async {
        let model = makeModel { id in
            if id == "A" {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return Self.release(id: id)
        }

        model.selectRelease(row(id: "A"))
        model.selectRelease(row(id: "B"))

        await eventually {
            model.selectedRelease?.id == "B" && !model.isLoadingRelease
        }
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(model.selectedReleaseID, "B")
        XCTAssertEqual(model.selectedRelease?.id, "B")
        XCTAssertNil(model.releaseError)
    }

    @MainActor
    func testOlderReleaseFailureCannotClearNewerSuccess() async {
        let model = makeModel { id in
            if id == "A" {
                try? await Task.sleep(nanoseconds: 150_000_000)
                throw ReleaseLoadTestError.failed
            }
            return Self.release(id: id)
        }

        model.selectRelease(row(id: "A"))
        model.selectRelease(row(id: "B"))

        await eventually {
            model.selectedRelease?.id == "B" && !model.isLoadingRelease
        }
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(model.selectedReleaseID, "B")
        XCTAssertEqual(model.selectedRelease?.id, "B")
        XCTAssertNil(model.releaseError)
    }

    @MainActor
    private func makeModel(
        loader: @escaping @Sendable (String) async throws -> MBRelease
    ) -> MusiCardsAppModel {
        MusiCardsAppModel(
            playbackEngine: PendingPlaybackEngine(),
            releaseDetailLoader: loader,
            releaseCoverLoader: { _ in nil }
        )
    }

    private func row(id: String) -> SearchReleaseRow {
        SearchReleaseRow(
            id: id,
            title: "Release \(id)",
            artistLine: "Artist",
            metaLine: "",
            disambiguation: "",
            hasCoverArt: false
        )
    }

    nonisolated private static func release(id: String) -> MBRelease {
        MBRelease(
            id: id,
            title: "Release \(id)",
            artistCredit: nil,
            date: nil,
            country: nil,
            barcode: nil,
            disambiguation: nil,
            labelInfo: nil,
            media: nil,
            releaseGroup: nil,
            relations: nil,
            annotation: nil
        )
    }

    @MainActor
    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

private enum ReleaseLoadTestError: Error {
    case failed
}
