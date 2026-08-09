import XCTest
@testable import MusiCards_Sync

final class RsyncVersionParserTests: XCTestCase {
    private let parser = RsyncVersionParser()

    func testParsesVersionAndIconvCapability() throws {
        let info = try XCTUnwrap(parser.parse(
            """
            rsync  version 3.4.4  protocol version 32
            Capabilities:
                64-bit files, optional secluded-args, iconv, no prealloc
            Optimizations:
                openssl-crypto
            """
        ))

        XCTAssertEqual(
            info.version,
            RsyncVersion(major: 3, minor: 4, patch: 4)
        )
        XCTAssertTrue(info.supportsIconv)
        XCTAssertEqual(
            info.displayLine,
            "rsync  version 3.4.4  protocol version 32"
        )
    }

    func testRejectsMissingVersionLine() {
        XCTAssertNil(parser.parse("command not found"))
    }

    func testReportsMissingIconvCapability() throws {
        let info = try XCTUnwrap(parser.parse(
            """
            rsync  version 3.2.7  protocol version 31
            Capabilities:
                64-bit files, no iconv, no prealloc
            """
        ))

        XCTAssertFalse(info.supportsIconv)
    }

    func testVersionComparisonUsesNumericComponents() {
        XCTAssertGreaterThan(
            RsyncVersion(major: 3, minor: 2, patch: 10),
            RsyncVersion(major: 3, minor: 2, patch: 6)
        )
        XCTAssertLessThan(
            RsyncVersion(major: 3, minor: 1, patch: 9),
            RsyncVersion(major: 3, minor: 2, patch: 0)
        )
    }
}
