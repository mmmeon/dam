import XCTest
import CoreGraphics
import CoreMedia
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

    // MARK: frame rate

    func testLoosensTheFrameLimitOnlyWhenTheDisplayIsNoFasterThanTheStream() {
        let interval = MoonlightScreenCapture.minimumFrameInterval
        XCTAssertEqual(interval(60, 60), CMTime(value: 1, timescale: 120))
        XCTAssertEqual(interval(60, 59.94), CMTime(value: 1, timescale: 120))
        XCTAssertEqual(interval(60, 50), CMTime(value: 1, timescale: 120))
        XCTAssertEqual(interval(30, 60), CMTime(value: 1, timescale: 30))
        XCTAssertEqual(interval(60, 120), CMTime(value: 1, timescale: 60))
        XCTAssertEqual(interval(60, 0), CMTime(value: 1, timescale: 60))
    }

    func testPacerPassesFramesAtTheStreamRate() {
        var pacer = FramePacer(fps: 60)
        let times = (0..<10).map { CMTime(value: Int64($0) * 1000, timescale: 60_000) }
        XCTAssertEqual(times.filter { pacer.allows($0) }.count, 10)
    }

    func testPacerLeavesOutFramesFromAFasterDisplay() {
        var pacer = FramePacer(fps: 60)
        let times = (0..<12).map { CMTime(value: Int64($0) * 1000, timescale: 120_000) }
        XCTAssertEqual(times.filter { pacer.allows($0) }.count, 6)
    }

    func testPacerStartsAgainWhenTimeGoesBack() {
        var pacer = FramePacer(fps: 60)
        XCTAssertTrue(pacer.allows(CMTime(value: 10, timescale: 1)))
        XCTAssertTrue(pacer.allows(CMTime(value: 1, timescale: 1)))
    }

    // MARK: - Shared capture

    /// Two streams of one display at one size share a capture; one that joins late gets
    /// the last picture at once; the capture stops once both have left.
    func testStreamsOfOneDisplayShareACapture() throws {
        let makeCapture = SharedScreenCapture.makeCapture, startCapture = SharedScreenCapture.startCapture
        defer { SharedScreenCapture.makeCapture = makeCapture; SharedScreenCapture.startCapture = startCapture }
        var made: [SharedScreenCapture.Key] = []
        var deliver: ((CVPixelBuffer, CMTime) -> Void)?
        SharedScreenCapture.makeCapture = { key, frame in
            made.append(key)
            deliver = frame
            return MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height, fps: key.fps, frame: frame)
        }
        SharedScreenCapture.startCapture = { _, done in done(nil) }
        let key = SharedScreenCapture.Key(displayID: 9, width: 64, height: 64, fps: 60, showsCursor: true)
        let before = SharedScreenCapture.count

        var firstFrames = 0
        let first = SharedScreenCapture.subscribe(key, frame: { _, _ in firstFrames += 1 }, audio: { _ in },
                                                  started: { XCTAssertNil($0) })
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        deliver?(try XCTUnwrap(buffer), CMTime(value: 1, timescale: 60))
        XCTAssertEqual(firstFrames, 1)

        let joined = expectation(description: "the last picture")
        let second = SharedScreenCapture.subscribe(key, frame: { _, time in
            XCTAssertEqual(time, CMTime(value: 1, timescale: 60)); joined.fulfill()
        }, audio: { _ in }, started: { XCTAssertNil($0) })
        wait(for: [joined], timeout: 2)
        XCTAssertEqual(made, [key], "one capture")
        XCTAssertEqual(SharedScreenCapture.count, before + 1)

        // Another size is another capture.
        let other = SharedScreenCapture.subscribe(.init(displayID: 9, width: 32, height: 32, fps: 60, showsCursor: true),
                                                  frame: { _, _ in }, audio: { _ in }, started: { _ in })
        XCTAssertEqual(made.count, 2)
        other.cancel()

        first.cancel()
        XCTAssertEqual(SharedScreenCapture.count, before + 1, "still one stream on it")
        second.cancel()
        XCTAssertEqual(SharedScreenCapture.count, before)
        SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: { _ in }, started: { _ in }).cancel()
        XCTAssertEqual(made.count, 3, "started afresh")
    }

    /// A capture that stops on its own, as when replayd dies, is let go: its streams hear,
    /// and the next to come starts another rather than join it.
    func testACaptureThatStopsIsLetGoAndItsStreamsAreTold() {
        let makeCapture = SharedScreenCapture.makeCapture, startCapture = SharedScreenCapture.startCapture
        defer { SharedScreenCapture.makeCapture = makeCapture; SharedScreenCapture.startCapture = startCapture }
        var made: [MoonlightScreenCapture] = []
        SharedScreenCapture.makeCapture = { key, frame in
            let capture = MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height,
                                                 fps: key.fps, frame: frame)
            made.append(capture)
            return capture
        }
        SharedScreenCapture.startCapture = { _, done in done(nil) }
        let key = SharedScreenCapture.Key(displayID: 7, width: 64, height: 64, fps: 60, showsCursor: true)
        let before = SharedScreenCapture.count
        var stopped: [Error] = []
        let first = SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: { _ in }, started: { _ in },
                                                  stopped: { stopped.append($0) })
        let second = SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: { _ in }, started: { _ in },
                                                   stopped: { stopped.append($0) })
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(SharedScreenCapture.count, before + 1)

        made.first?.onStop?(MoonlightCaptureError.displayNotFound(7))
        XCTAssertEqual(stopped.count, 2, "both streams hear")
        XCTAssertEqual(SharedScreenCapture.count, before)
        let third = SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: { _ in }, started: { _ in })
        XCTAssertEqual(made.count, 2, "started afresh")
        for subscription in [first, second, third] { subscription.cancel() }
        XCTAssertEqual(SharedScreenCapture.count, before)
    }

    func testACaptureThatCouldNotStartIsLetGo() {
        let makeCapture = SharedScreenCapture.makeCapture, startCapture = SharedScreenCapture.startCapture
        defer { SharedScreenCapture.makeCapture = makeCapture; SharedScreenCapture.startCapture = startCapture }
        SharedScreenCapture.makeCapture = { key, frame in
            MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height, fps: key.fps, frame: frame)
        }
        SharedScreenCapture.startCapture = { _, done in done(MoonlightCaptureError.noPermission) }
        let before = SharedScreenCapture.count
        var failed = false
        let subscription = SharedScreenCapture.subscribe(.init(displayID: 8, width: 64, height: 64, fps: 60, showsCursor: false),
                                                         frame: { _, _ in }, audio: { _ in }, started: { failed = $0 != nil })
        XCTAssertTrue(failed)
        XCTAssertEqual(SharedScreenCapture.count, before)
        subscription.cancel()
    }
}
