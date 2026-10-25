import XCTest
@testable import DAM

final class WakeGuardTests: XCTestCase {

    /// A wake the kernel says someone at the Mac made gives seconds to unlock in, the power
    /// button more for Touch ID, as does one that doesn't say what woke it; any other none.
    func testOnlyAWakeBySomeoneAtTheMacIsWatched() {
        // A MacBookPro14,2 woken by a key or its trackpad, by its power button, and from a
        // dark wake (seen 2026-10-25).
        XCTAssertEqual(WakeGuard.allowance(forWake: "SPIT", byUser: true), 3)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.PowerButton PWRB", byUser: true), 15)
        XCTAssertEqual(WakeGuard.allowance(forWake: "", byUser: true), 15)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.PowerButton (User)", byUser: true), 15)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.LidOpen (User)", byUser: true), 3)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.KeyboardTouchpad", byUser: true), 3)
        XCTAssertNil(WakeGuard.allowance(forWake: "ARPT", byUser: false), "Wi-Fi, as Wake on LAN")
        XCTAssertNil(WakeGuard.allowance(forWake: "SPIT", byUser: false), "the kernel's word counts")
    }

    /// Without the kernel's word, the reason alone says.
    func testWithoutTheKernelsWordTheReasonSays() {
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.PowerButton (User)", byUser: nil), 15)
        XCTAssertEqual(WakeGuard.allowance(forWake: "EC.KeyboardTouchpad", byUser: nil), 3)
        XCTAssertEqual(WakeGuard.allowance(forWake: "SPIT", byUser: nil), 3)
        XCTAssertNil(WakeGuard.allowance(forWake: "ARPT", byUser: nil))
        XCTAssertNil(WakeGuard.allowance(forWake: "RTC (Alarm)", byUser: nil))
        XCTAssertNil(WakeGuard.allowance(forWake: "", byUser: nil))
    }

    /// A lock's time doesn't run while the Mac sleeps, and a wake nobody at the Mac made
    /// ends any time running, so it isn't slept straight away.
    func testNoTimeRunsThroughASleepOrPastAWakeNobodyMade() {
        let guarded = WakeGuard()
        guarded.arm(10, "locked")
        guarded.wentToSleep()
        XCTAssertFalse(guarded.isWatching, "asleep")

        guarded.arm(10, "locked")
        guarded.woke(reason: "ARPT", type: "Network", byUser: false, locked: true)
        XCTAssertFalse(guarded.isWatching, "Wake on LAN")

        guarded.woke(reason: "SPIT", type: "User", byUser: true, locked: true)
        XCTAssertTrue(guarded.isWatching, "a key")
        guarded.woke(reason: "SPIT", type: "User", byUser: true, locked: false)
        XCTAssertFalse(guarded.isWatching, "unlocked")
    }
}
