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

    // MARK: replayd not answering

    private var savedFetch = MoonlightScreenCapture.fetchContent
    private var savedRestart = MoonlightScreenCapture.restartService
    private var savedTimeout = MoonlightScreenCapture.answerTimeout

    override func setUp() {
        super.setUp()
        savedFetch = MoonlightScreenCapture.fetchContent
        savedRestart = MoonlightScreenCapture.restartService
        savedTimeout = MoonlightScreenCapture.answerTimeout
        MoonlightScreenCapture.answerTimeout = 0.1
    }

    override func tearDown() {
        MoonlightScreenCapture.fetchContent = savedFetch
        MoonlightScreenCapture.restartService = savedRestart
        MoonlightScreenCapture.answerTimeout = savedTimeout
        super.tearDown()
    }

    /// Starts a capture whose lookups are answered by `answers` in turn; nil never answers.
    private func start(answers: [Error?]) -> (error: Error?, asked: Int, restarts: Int) {
        let lock = NSLock()
        var asked = 0, restarts = 0
        MoonlightScreenCapture.fetchContent = { reply in
            lock.lock(); let answer = asked < answers.count ? answers[asked] : nil; asked += 1; lock.unlock()
            if let answer { reply(nil, answer) }
        }
        MoonlightScreenCapture.restartService = { lock.lock(); restarts += 1; lock.unlock() }
        let capture = MoonlightScreenCapture(displayID: 1, width: 64, height: 64, fps: 30) { _, _ in }
        let done = expectation(description: "start answered")
        var result: Error?
        capture.start { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        return (result, asked, restarts)
    }

    func testRestartsReplaydAndAsksAgainWhenScreenCaptureKitDoesNotAnswer() {
        let notFound = NSError(domain: "test", code: 1)
        let (error, asked, restarts) = start(answers: [nil, notFound])
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(error as NSError?, notFound)
    }

    func testGivesUpWhenReplaydStillDoesNotAnswerOnceRestarted() {
        let (error, asked, restarts) = start(answers: [nil, nil])
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(asked, 2)
        guard case MoonlightCaptureError.serviceNotAnswering? = error else {
            return XCTFail("expected serviceNotAnswering, got \(String(describing: error))")
        }
    }

    func testLeavesReplaydAloneWhenScreenCaptureKitAnswers() {
        let (_, asked, restarts) = start(answers: [NSError(domain: "test", code: 1)])
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(asked, 1)
    }
}
