import XCTest
@testable import MusiCards

final class AudioOutputRouteTests: XCTestCase {
    @MainActor
    func testOutputSampleRateUsesActualRouteValue() {
        let route = AudioOutputRoute(
            deviceID: nil,
            deviceName: "Chord Mojo 2",
            transport: .usb,
            sampleRate: 44_100
        )

        XCTAssertEqual(route.displayName, "CHORD MOJO 2")
        XCTAssertEqual(route.sampleRateText, "44.1 kHz")
    }

    @MainActor
    func testUnavailableOutputSampleRateIsOmitted() {
        let route = AudioOutputRoute(
            deviceID: nil,
            deviceName: "AirPlay Speaker",
            transport: .airPlay,
            sampleRate: 44_100
        )

        XCTAssertNil(route.sampleRateText)
    }

    @MainActor
    func testBuiltInOutputUsesHostDeviceName() {
        let route = AudioOutputRoute(
            deviceID: nil,
            deviceName: "Speaker",
            transport: .builtIn,
            sampleRate: nil
        )

        XCTAssertEqual(route.displayName(builtInDeviceName: "THIS IPHONE"), "THIS IPHONE")
        XCTAssertEqual(route.displayName(builtInDeviceName: "THIS IPAD"), "THIS IPAD")
        #if os(macOS)
        XCTAssertEqual(route.displayName, "SPEAKER")
        #endif
    }
}
