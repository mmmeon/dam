import XCTest
import CoreMedia
import IOSurface
@testable import DAM

final class DisplayStreamCaptureTests: XCTestCase {

    /// A surface-backed 4:2:0 buffer, each plane's rows filled with their number plus `seed`.
    private func surfaceBuffer(width: Int, height: Int, seed: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, DisplayStreamCapture.pixelFormat, attributes, &buffer)
        let made = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(made, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(made) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(made, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(made, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(made, plane) {
                memset(base + row * stride, Int32(UInt8(truncatingIfNeeded: row) &+ seed), stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(made, [])
        return made
    }

    func testFramesAreCopiedOutOfTheStreamsSurface() throws {
        let source = try surfaceBuffer(width: 64, height: 36, seed: 7)
        let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(source)?.takeUnretainedValue())
        let capture = DisplayStreamCapture(displayID: 1, width: 64, height: 36, fps: 60) { _, _ in }
        let copy = try XCTUnwrap(capture.copy(surface))
        XCTAssertNotEqual(CVPixelBufferGetIOSurface(copy)?.takeUnretainedValue(), surface, "a buffer of its own")
        XCTAssertEqual(CVPixelBufferGetWidth(copy), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(copy), 36)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(copy, plane)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(copy, plane) {
                XCTAssertEqual(base[row * stride], UInt8(row) &+ 7, "plane \(plane) row \(row)")
                XCTAssertEqual(base[row * stride + CVPixelBufferGetWidthOfPlane(copy, plane) - 1], UInt8(row) &+ 7)
            }
        }
    }

    func testRowsAreCopiedBetweenDifferentPaddings() {
        let from: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0]          // 3 bytes of picture in rows of 4
        var to = [UInt8](repeating: 9, count: 12)              // rows of 6
        from.withUnsafeBytes { source in
            to.withUnsafeMutableBytes { target in
                DisplayStreamCapture.copyRows(from: source.baseAddress!, fromStride: 4,
                                              to: target.baseAddress!, toStride: 6, rows: 2)
            }
        }
        XCTAssertEqual(to, [1, 2, 3, 0, 9, 9, 4, 5, 6, 0, 9, 9])
    }

    func testTheSettingPicksWhichCaptureIsMade() {
        let uses = SharedScreenCapture.usesDisplayStream
        defer { SharedScreenCapture.usesDisplayStream = uses }
        let key = SharedScreenCapture.Key(displayID: 1, width: 64, height: 36, fps: 60, showsCursor: true)
        SharedScreenCapture.usesDisplayStream = true
        XCTAssertTrue(SharedScreenCapture.makeCapture(key) { _, _ in } is DisplayStreamCapture)
        SharedScreenCapture.usesDisplayStream = false
        XCTAssertTrue(SharedScreenCapture.makeCapture(key) { _, _ in } is MoonlightScreenCapture)
    }

    /// Under XCTest the capture may not record the screen (the test runner's permission
    /// decides), so it must fail at once rather than hang.
    func testStartingWithoutPermissionFails() throws {
        try XCTSkipIf(CGPreflightScreenCaptureAccess(), "this runner may record the screen")
        let capture = DisplayStreamCapture(displayID: CGMainDisplayID(), width: 64, height: 36, fps: 60) { _, _ in }
        var result: Error?
        capture.start { result = $0 }
        guard case MoonlightCaptureError.noPermission? = result else { return XCTFail("\(String(describing: result))") }
    }
}
