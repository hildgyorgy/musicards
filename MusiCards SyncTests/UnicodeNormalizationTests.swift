import XCTest

final class UnicodeNormalizationTests: XCTestCase {

    func testHungarianNameHasEquivalentNFCAndNFDForms() {
        let displayedName = "Nyeső Mária"
        let nfc = displayedName.precomposedStringWithCanonicalMapping
        let nfd = displayedName.decomposedStringWithCanonicalMapping

        XCTAssertEqual(nfc, nfd)
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        XCTAssertEqual(
            nfd.precomposedStringWithCanonicalMapping,
            nfc
        )
    }
}
