import XCTest
import CoreGraphics
@testable import DAM

/// DDC/CI packets for display brightness, and which modes are put back after a wake.
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
}
