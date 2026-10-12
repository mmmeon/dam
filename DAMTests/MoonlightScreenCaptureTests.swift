import XCTest
import CoreGraphics
@testable import DAM

/// Captures a streaming display, never one the user looks at; skipped when there is none
/// or DAM may not record the screen.
final class MoonlightScreenCaptureTests: XCTestCase {

    private func streamingDisplay() throws -> CGDirectDisplayID {
        let online = DisplayArrangement.onlineDisplayIDs()
        guard let id = online.first(where: {
            CGDisplayVendorNumber($0) == VideoManager.anchorVendorID && CGDisplayModelNumber($0) == VideoManager.streamingProductID
        }) else { throw XCTSkip("no streaming display to capture") }
        return id
    }

    func testCapturesFramesAtTheStreamSize() throws {
        guard MoonlightScreenCapture.hasPermission else { throw XCTSkip("no Screen Recording permission") }
        let id = try streamingDisplay()
        let lock = NSLock()
        var sizes: [CGSize] = []
        let first = expectation(description: "a frame")
        first.assertForOverFulfill = false
        let capture = MoonlightScreenCapture(displayID: id, width: 1280, height: 720, fps: 60) { buffer, _ in
            lock.lock(); sizes.append(CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))); lock.unlock()
            first.fulfill()
        }
        let started = expectation(description: "started")
        var startError: Error?
        capture.start { startError = $0; started.fulfill() }
        wait(for: [started], timeout: 10)
        XCTAssertNil(startError)
        wait(for: [first], timeout: 5)
        capture.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(sizes.first, CGSize(width: 1280, height: 720))
    }
}
