import XCTest
@testable import DAM

final class ScreenMirroringPanelTests: XCTestCase {

    private let tv = "Living Room TV"

    func testMatchesTheCheckboxWhoseIdentifierEndsWithTheDeviceName() {
        XCTAssertTrue(ScreenMirroringPanel.matchesDevice(
            identifier: "screen-mirroring-device-Living Room TV", title: nil,
            role: "AXCheckBox", deviceName: tv))
    }

    func testSkipsTheDisclosureTriangleThatSharesTheIdentifier() {
        XCTAssertFalse(ScreenMirroringPanel.matchesDevice(
            identifier: "screen-mirroring-device-Living Room TV", title: nil,
            role: "AXDisclosureTriangle", deviceName: tv))
    }

    func testFallsBackToTheTitleWithoutAnIdentifier() {
        XCTAssertTrue(ScreenMirroringPanel.matchesDevice(
            identifier: nil, title: "Living Room TV", role: "AXCheckBox", deviceName: tv))
    }

    func testIgnoresTheTitleWhenThereIsAnIdentifier() {
        XCTAssertFalse(ScreenMirroringPanel.matchesDevice(
            identifier: "screen-mirroring-device-Office TV", title: "Living Room TV",
            role: "AXCheckBox", deviceName: tv))
    }

    func testDoesNotMatchAnotherDevice() {
        XCTAssertFalse(ScreenMirroringPanel.matchesDevice(
            identifier: "screen-mirroring-device-Office TV", title: nil,
            role: "AXCheckBox", deviceName: tv))
    }
}
