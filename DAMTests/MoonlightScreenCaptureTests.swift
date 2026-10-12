import XCTest
import CoreGraphics
@testable import DAM

/// Captures a streaming display, never one the user looks at; skipped when there is none,
/// when DAM may not record the screen, and unless asked for (see below).
final class MoonlightScreenCaptureTests: XCTestCase {

    private func streamingDisplay() throws -> CGDirectDisplayID {
        let online = DisplayArrangement.onlineDisplayIDs()
        guard let id = online.first(where: {
            CGDisplayVendorNumber($0) == VideoManager.anchorVendorID && CGDisplayModelNumber($0) == VideoManager.streamingProductID
        }) else { throw XCTSkip("no streaming display to capture") }
        return id
    }

    func testCapturesFramesAtTheStreamSize() throws {
        // Under xcodebuild capture gets no frames: macOS judges Screen Recording by the process
        // that started the tests. Run with DAM_TEST_CAPTURE=1 from one that may record.
        guard ProcessInfo.processInfo.environment["DAM_TEST_CAPTURE"] == "1" else {
            throw XCTSkip("capture checked only with DAM_TEST_CAPTURE=1")
        }
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
