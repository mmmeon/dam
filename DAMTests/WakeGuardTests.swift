import XCTest
@testable import DAM

final class WakeGuardTests: XCTestCase {

    /// A wake by hand gives seconds to unlock in, the power button more for Touch ID; any
    /// other, as over the network, none.
    func testOnlyAWakeByHandIsWatched() {
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.PowerButton (User)", type: ""), 15)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.KeyboardTouchpad", type: "UserActivity Assertion"), 3)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.LidOpen (User)", type: ""), 3)
        XCTAssertNil(WakeGuard.allowance(forWake: "ARPT", type: "UserActivity Assertion"), "Wi-Fi, as Wake on LAN")
        XCTAssertNil(WakeGuard.allowance(forWake: "RTC (Alarm)", type: ""))
        XCTAssertNil(WakeGuard.allowance(forWake: "", type: ""))
        // A MacBookPro14,2 woken from sleep by a key (seen 2026-10-25).
        XCTAssertEqual(WakeGuard.allowance(forWake: "SPIT", type: "User"), 3)
        // And from a dark wake: no reason, the type alone.
        XCTAssertEqual(WakeGuard.allowance(forWake: "", type: "UserActivity Assertion"), 15)
        XCTAssertNil(WakeGuard.allowance(forWake: "", type: "Maintenance"))
    }
}
