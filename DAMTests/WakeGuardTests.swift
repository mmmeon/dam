import XCTest
@testable import DAM

final class WakeGuardTests: XCTestCase {

    /// A wake by hand gives seconds to unlock in, the power button more for Touch ID; any
    /// other, as over the network, none.
    func testOnlyAWakeByHandIsWatched() {
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.PowerButton (User)"), 15)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.KeyboardTouchpad"), 3)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.LidOpen (User)"), 3)
        XCTAssertNil(WakeGuard.allowance(forWake: "ARPT"), "Wi-Fi, as Wake on LAN")
        XCTAssertNil(WakeGuard.allowance(forWake: "RTC (Alarm)"))
        XCTAssertNil(WakeGuard.allowance(forWake: ""))
    }
}
