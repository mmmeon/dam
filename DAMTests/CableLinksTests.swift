import XCTest
@testable import DAM

final class CableLinksTests: XCTestCase {

    private let wifi = (interface: "en0", subnet: LocalNetwork.Subnet(address: [10, 10, 1, 167], mask: [255, 255, 255, 0]))
    private let cable = (interface: "en12", subnet: LocalNetwork.Subnet(address: [169, 254, 113, 17], mask: [255, 255, 0, 0]))

    func testAdmitsAddressesOnACableOnly() {
        let subnets = [wifi, cable]
        XCTAssertTrue(CableLinks.admits([169, 254, 112, 114], scope: nil, subnets: subnets, cable: ["en12"]))
        XCTAssertFalse(CableLinks.admits([10, 10, 1, 20], scope: nil, subnets: subnets, cable: ["en12"]), "Wi-Fi")
        XCTAssertFalse(CableLinks.admits([127, 0, 0, 1], scope: nil, subnets: subnets, cable: ["en12"]), "this Mac")
        XCTAssertFalse(CableLinks.admits([8, 8, 8, 8], scope: nil, subnets: subnets, cable: ["en12"]), "elsewhere")
        XCTAssertFalse(CableLinks.admits([169, 254, 112, 114], scope: nil, subnets: subnets, cable: []), "unplugged")
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 169, 254, 112, 114]
        XCTAssertTrue(CableLinks.admits(mapped, scope: nil, subnets: subnets, cable: ["en12"]), "IPv4 written as IPv6")
    }

    func testRefusesALinkLocalAddressWiFiHasToo() {
        // Wi-Fi with no DHCP answer takes a 169.254 address as well.
        let wifiLinkLocal = (interface: "en0", subnet: LocalNetwork.Subnet(address: [169, 254, 7, 7], mask: [255, 255, 0, 0]))
        XCTAssertFalse(CableLinks.admits([169, 254, 112, 114], scope: nil, subnets: [wifiLinkLocal, cable], cable: ["en12"]))
    }

    func testGoesByTheScopeOfALinkLocalIPv6Address() {
        let address: [UInt8] = [0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0xE0, 0x23, 0x31, 0xFF, 0xFE, 0x72, 0x1E, 0x65]
        XCTAssertTrue(CableLinks.admits(address, scope: "en12", subnets: [], cable: ["en12"]))
        XCTAssertFalse(CableLinks.admits(address, scope: "en0", subnets: [], cable: ["en12"]))
    }
}
