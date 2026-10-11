import XCTest
@testable import DAM

/// How the Screen Mirroring diagnosis report replaces names before it is shared.
final class ReportRedactorTests: XCTestCase {

    private func redactor(displays: [String] = [], iPads: [String] = [],
                          userNames: [String] = [], computerNames: [String] = []) -> ReportRedactor {
        ReportRedactor(displays: displays, iPads: iPads, userNames: userNames, computerNames: computerNames)
    }

    func testDisplaysAndIPads_becomeNumberedTokens() {
        let r = redactor(displays: ["Living Room TV", "Bedroom"], iPads: ["Jane's iPad"])
        XCTAssertEqual(r.redact("Living Room TV, Bedroom and Jane's iPad"),
                       "Display 1, Display 2 and iPad 1")
    }

    func testNameInsideAnIdentifier_isReplaced() {
        let r = redactor(displays: ["Living Room TV"])
        XCTAssertEqual(r.redact("AXCheckBox id=screen-mirroring-device-Living Room TV"),
                       "AXCheckBox id=screen-mirroring-device-Display 1")
    }

    func testLongerName_isReplacedWhole() {
        let r = redactor(displays: ["TV", "Living Room TV 2", "Living Room TV"])
        XCTAssertEqual(r.redact("Living Room TV 2 / Living Room TV"), "Display 1 / Display 2")
    }

    func testRepeatedName_keepsItsFirstToken() {
        let r = redactor(displays: ["Den TV", "Den TV", "Office"])
        XCTAssertEqual(r.redact("Den TV, Office"), "Display 1, Display 2")
    }

    func testUserAndComputerNames() {
        let r = redactor(userNames: ["Jane Appleseed", "jane"], computerNames: ["Jane's MacBook Pro"])
        XCTAssertEqual(r.redact("Jane Appleseed (jane) on Jane's MacBook Pro"),
                       "the user (the user) on this Mac")
    }

    func testNamesShorterThanThree_areLeftAlone() {
        let r = redactor(displays: ["TV"])
        XCTAssertEqual(r.redact("TV id=TV"), "TV id=TV")
    }
}
