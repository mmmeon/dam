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

    // MARK: - Failure announcements

    func testACancelIsNotAnnounced() {
        XCTAssertNil(ScreenMirroringPanelError.cancelled.announcement)
    }

    func testFailingToDriveThePanelPointsToTheManualRoute() {
        let errors: [ScreenMirroringPanelError] = [.openerNotFound, .tileNotFound, .pressFailed(.failure)]
        for error in errors {
            XCTAssertEqual(error.announcement,
                           "Could not open Screen Mirroring. Use Screen Mirroring in Control Center instead")
        }
    }

    func testABusyPanelIsNotReportedAsFailingToOpen() {
        XCTAssertEqual(ScreenMirroringPanelError.busy.announcement,
                       "Screen Mirroring is still changing. Try again in a moment")
    }

    func testAMissingDeviceIsNamed() {
        XCTAssertEqual(ScreenMirroringPanelError.deviceNotFound(tv).announcement,
                       "Living Room TV is not listed in Screen Mirroring. Check that it is on and nearby")
    }
}
