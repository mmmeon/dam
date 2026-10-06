import XCTest
@testable import DAM

final class MenuBarIconTests: XCTestCase {

    func testNoConnectionsIsATrickle() {
        XCTAssertEqual(MenuBarIcon.outflowFraction(for: 0), 16 / 129.406, accuracy: 0.0001)
    }

    func testOutflowWidensWithEachConnectionUpToTheCap() {
        let fractions = (0...MenuBarIcon.maxCount).map(MenuBarIcon.outflowFraction(for:))
        for (narrower, wider) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThan(narrower, wider)
        }
        XCTAssertLessThan(fractions.last!, 1)
    }

    func testCountsPastTheCapDrawAsTheCap() {
        let cap = MenuBarIcon.outflowFraction(for: MenuBarIcon.maxCount)
        XCTAssertEqual(MenuBarIcon.outflowFraction(for: MenuBarIcon.maxCount + 5), cap)
    }

    func testNegativeCountsDrawAsNone() {
        XCTAssertEqual(MenuBarIcon.outflowFraction(for: -2), MenuBarIcon.outflowFraction(for: 0))
    }

    func testImageIsAMenuBarTemplate() {
        let image = MenuBarIcon.image(fraction: MenuBarIcon.outflowFraction(for: 2), spin: 10)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, MenuBarIcon.size)
    }
}
