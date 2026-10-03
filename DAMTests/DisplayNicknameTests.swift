import XCTest
@testable import DAM

final class DisplayNicknameTests: XCTestCase {
    private let displayName = "Nickname Test Display"

    override func tearDown() {
        VisibilityPreferences.setNickname(nil, .display, for: displayName)
        super.tearDown()
    }

    private func info() -> DisplayInfo {
        DisplayInfo(id: displayName, name: displayName, isConnected: true, cgDisplayID: 0,
                    isMirroring: false, isBuiltIn: false)
    }

    func testLabelFallsBackToName() {
        XCTAssertEqual(info().label, displayName)
    }

    func testNicknameReplacesLabelButNotName() {
        VisibilityPreferences.setNickname("  TV  ", .display, for: displayName)
        XCTAssertEqual(info().label, "TV")
        XCTAssertEqual(info().name, displayName)
    }

    func testBlankNicknameClears() {
        VisibilityPreferences.setNickname("TV", .display, for: displayName)
        VisibilityPreferences.setNickname("   ", .display, for: displayName)
        XCTAssertNil(VisibilityPreferences.nickname(.display, for: displayName))
    }

    func testKindsKeepSeparateNicknames() {
        defer { VisibilityPreferences.setNickname(nil, .audio, for: displayName) }
        VisibilityPreferences.setNickname("Desk", .audio, for: displayName)
        XCTAssertEqual(AudioDevice(id: 0, name: displayName).label, "Desk")
        XCTAssertEqual(info().label, displayName)
    }
}
