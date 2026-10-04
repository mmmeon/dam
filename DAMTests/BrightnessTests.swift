import XCTest
import CoreGraphics
@testable import DAM

/// DDC/CI packets for display brightness, matching displays to their Apple silicon
/// framebuffers, and which modes are put back after a wake.
final class BrightnessTests: XCTestCase {

    // MARK: - DDC packets

    func testGetVCP_brightness() {
        // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC
        XCTAssertEqual(DDC.getVCP(DDC.brightness), [0x51, 0x82, 0x01, 0x10, 0xAC])
    }

    func testSetVCP_brightness() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A
        XCTAssertEqual(DDC.setVCP(DDC.brightness, value: 50), [0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    func testSetVCP_splitsValueIntoBytes() {
        let packet = DDC.setVCP(DDC.brightness, value: 0x0102)
        XCTAssertEqual(Array(packet[4...5]), [0x01, 0x02])
    }

    private func reply(result: UInt8 = 0, code: UInt8 = 0x10, max: UInt16 = 100, current: UInt16 = 70) -> [UInt8] {
        [0x6E, 0x88, 0x02, result, code, 0x00,
         UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF), 0x00]
    }

    func testParseVCPReply_readsMaximumAndCurrent() {
        let value = DDC.parseVCPReply(reply(max: 0x0190, current: 0x00C8), code: 0x10)
        XCTAssertEqual(value?.max, 400)
        XCTAssertEqual(value?.current, 200)
    }

    func testParseVCPReply_errorResult_isNil() {
        XCTAssertNil(DDC.parseVCPReply(reply(result: 0x01), code: 0x10))
    }

    func testParseVCPReply_otherFeature_isNil() {
        XCTAssertNil(DDC.parseVCPReply(reply(code: 0x12), code: 0x10))
    }

    func testParseVCPReply_nonsenseValues_isNil() {
        XCTAssertNil(DDC.parseVCPReply(reply(max: 0, current: 0), code: 0x10))
        XCTAssertNil(DDC.parseVCPReply(reply(max: 100, current: 101), code: 0x10))
    }

    func testParseVCPReply_echoOfRequest_isNil() {
        // What an absent display leaves in the buffer.
        XCTAssertNil(DDC.parseVCPReply([0x51, 0x82, 0x01, 0x10, 0xAC, 0, 0, 0, 0, 0, 0], code: 0x10))
    }

    func testParseVCPReply_short_isNil() {
        XCTAssertNil(DDC.parseVCPReply([0x6E, 0x88, 0x02, 0x00], code: 0x10))
    }

    // MARK: - modesToRestore

    func testModesToRestore_changedMode_isPutBack() {
        let restore = VideoManager.modesToRestore(saved: [1: 10], current: [1: 11], available: [1: [10, 11]], skip: [])
        XCTAssertEqual(restore, [1: 10])
    }

    func testModesToRestore_unchanged_isLeft() {
        XCTAssertEqual(VideoManager.modesToRestore(saved: [1: 10], current: [1: 10], available: [1: [10]], skip: []), [:])
    }

    func testModesToRestore_goneDisplay_isLeft() {
        XCTAssertEqual(VideoManager.modesToRestore(saved: [1: 10], current: [:], available: [:], skip: []), [:])
    }

    func testModesToRestore_modeNoLongerOffered_isLeft() {
        XCTAssertEqual(VideoManager.modesToRestore(saved: [1: 10], current: [1: 11], available: [1: [11]], skip: []), [:])
    }

    func testModesToRestore_skipped_isLeft() {
        let restore = VideoManager.modesToRestore(saved: [1: 10, 2: 20], current: [1: 11, 2: 21],
                                                  available: [1: [10, 11], 2: [20, 21]], skip: [1])
        XCTAssertEqual(restore, [2: 20])
    }

    // MARK: - DisplayRegistry matching

    private func attributes(_ vendor: UInt32, _ product: UInt32, serial: UInt32? = nil,
                            name: String? = nil) -> DisplayRegistry.Attributes {
        DisplayRegistry.Attributes(vendor: vendor, product: product, serial: serial, name: name)
    }

    func testMatches_vendorAndProductMustAgree() {
        let candidates = [attributes(0x30AE, 1), attributes(0x10AC, 2), attributes(0x30AE, 2)]
        XCTAssertEqual(DisplayRegistry.matches(vendor: 0x30AE, product: 2, serial: 0, in: candidates), [2])
    }

    func testMatches_agreeingSerialRanksFirst() {
        let candidates = [attributes(1, 2, serial: 7), attributes(1, 2), attributes(1, 2, serial: 9)]
        XCTAssertEqual(DisplayRegistry.matches(vendor: 1, product: 2, serial: 9, in: candidates), [2, 1, 0])
    }

    func testUniqueMatch_differentlyEncodedSerial_stillFits() {
        XCTAssertEqual(DisplayRegistry.uniqueMatch(vendor: 1, product: 2, serial: 1234,
                                                   in: [attributes(1, 2, serial: 0x31323334)]), 0)
    }

    func testUniqueMatch_identicalMonitorsWithoutSerials_isNil() {
        XCTAssertNil(DisplayRegistry.uniqueMatch(vendor: 1, product: 2, serial: 0,
                                                 in: [attributes(1, 2), attributes(1, 2)]))
    }

    func testUniqueMatch_identicalMonitorsToldApartBySerial() {
        let candidates = [attributes(1, 2, serial: 5), attributes(1, 2, serial: 6)]
        XCTAssertEqual(DisplayRegistry.uniqueMatch(vendor: 1, product: 2, serial: 6, in: candidates), 1)
    }

    func testUniqueMatch_none_isNil() {
        XCTAssertNil(DisplayRegistry.uniqueMatch(vendor: 1, product: 2, serial: 0, in: [attributes(3, 4)]))
    }

    func testProductName_onIntel_isNil() throws {
        #if arch(arm64)
        throw XCTSkip("Apple silicon has display framebuffers to read")
        #else
        XCTAssertNil(DisplayRegistry.productName(for: CGMainDisplayID()))
        #endif
    }

    // MARK: - GammaTables

    private let tables = GammaTables(red: [0, 0.5, 1], green: [0, 0.4, 0.9], blue: [0.1, 0.5, 1])

    func testGammaTables_scaled() {
        let half = tables.scaled(by: 0.5)
        XCTAssertEqual(half.red, [0, 0.25, 0.5])
        XCTAssertEqual(half.green, [0, 0.2, 0.45])
        XCTAssertEqual(half.blue, [0.05, 0.25, 0.5])
    }

    func testGammaTables_readBackRounding_isClose() {
        let readBack = GammaTables(red: [0, 0.502, 0.998], green: [0, 0.4, 0.9], blue: [0.1, 0.5, 1])
        XCTAssertTrue(readBack.isClose(to: tables))
    }

    func testGammaTables_reset_isNotClose() {
        XCTAssertFalse(tables.isClose(to: tables.scaled(by: 0.9)))
    }
}
