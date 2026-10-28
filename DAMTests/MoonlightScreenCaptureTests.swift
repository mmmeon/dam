import XCTest
import CoreGraphics
import CoreImage
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
    private var savedBusyTimeout = MoonlightScreenCapture.busyAnswerTimeout
    private var savedLive = MoonlightScreenCapture.liveCaptures

    override func setUp() {
        super.setUp()
        savedFetch = MoonlightScreenCapture.fetchContent
        savedRestart = MoonlightScreenCapture.restartService
        savedTimeout = MoonlightScreenCapture.answerTimeout
        savedBusyTimeout = MoonlightScreenCapture.busyAnswerTimeout
        savedLive = MoonlightScreenCapture.liveCaptures
        MoonlightScreenCapture.answerTimeout = 0.1
        MoonlightScreenCapture.busyAnswerTimeout = 0.1
        MoonlightScreenCapture.liveCaptures = { 0 }
    }

    override func tearDown() {
        MoonlightScreenCapture.fetchContent = savedFetch
        MoonlightScreenCapture.restartService = savedRestart
        MoonlightScreenCapture.answerTimeout = savedTimeout
        MoonlightScreenCapture.busyAnswerTimeout = savedBusyTimeout
        MoonlightScreenCapture.liveCaptures = savedLive
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

    /// While another capture runs replayd answers it, so a slow lookup is waited for longer
    /// rather than ended by killing replayd, which would end the other capture too.
    func testLeavesReplaydAloneWhileAnotherCaptureRuns() {
        MoonlightScreenCapture.liveCaptures = { 1 }
        let (error, asked, restarts) = start(answers: [nil])
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(asked, 1)
        guard case MoonlightCaptureError.serviceNotAnswering? = error else {
            return XCTFail("expected serviceNotAnswering, got \(String(describing: error))")
        }
    }

    func testLeavesReplaydAloneWhenScreenCaptureKitAnswers() {
        let (_, asked, restarts) = start(answers: [NSError(domain: "test", code: 1)])
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(asked, 1)
    }

    /// A capture counts once while it runs, whether it then stops, stops on its own or goes,
    /// and not again once stopped.
    func testACaptureCountsOnceAmongTheLiveOnes() {
        let live = savedLive
        let before = live()
        var capture: MoonlightScreenCapture? = MoonlightScreenCapture(displayID: 1, width: 64, height: 64, fps: 30) { _, _ in }
        capture?.setLive(true)
        capture?.setLive(true)
        XCTAssertEqual(live(), before + 1)
        capture?.stop()
        XCTAssertEqual(live(), before)
        capture?.setLive(true)
        capture?.setLive(false)
        capture = nil
        XCTAssertEqual(live(), before, "not counted again once stopped, nor taken off twice")

        capture = MoonlightScreenCapture(displayID: 1, width: 64, height: 64, fps: 30) { _, _ in }
        capture?.setLive(true)
        XCTAssertEqual(live(), before + 1)
        capture = nil
        XCTAssertEqual(live(), before, "taken off as it goes")
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

    func testPacerSaysHowLongAFrameTooSoonWaits() throws {
        var pacer = FramePacer(fps: 60)
        XCTAssertNil(pacer.wait(for: CMTime(value: 0, timescale: 1000)))
        let wait = try XCTUnwrap(pacer.wait(for: CMTime(value: 5, timescale: 1000)))
        XCTAssertEqual(wait, 0.0075, accuracy: 1e-9, "0.75 frame times after the last, less the 5 ms since")
        pacer.took(CMTime(value: 5, timescale: 1000))
        XCTAssertNotNil(pacer.wait(for: CMTime(value: 10, timescale: 1000)), "paced from the one held, once it went")
        XCTAssertNil(pacer.wait(for: CMTime(value: 18, timescale: 1000)))
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        return try XCTUnwrap(made)
    }

    /// A frame that comes too soon after the one before, as a screen goes still, still goes:
    /// a frame time after that one, so the picture shown is the last.
    func testAFrameTooSoonBeforeAStillScreenGoesLater() throws {
        let lock = NSLock()
        var handed: [(CVPixelBuffer, Double, Date)] = []
        let both = expectation(description: "both frames")
        both.expectedFulfillmentCount = 2
        let capture = MoonlightScreenCapture(displayID: 1, width: 64, height: 64, fps: 60) { buffer, time in
            lock.lock(); handed.append((buffer, CMTimeGetSeconds(time), Date())); lock.unlock()
            both.fulfill()
        }
        let first = try pixelBuffer(), last = try pixelBuffer()
        let start = Date()
        capture.captured(first, at: CMTime(value: 0, timescale: 1000))
        capture.captured(last, at: CMTime(value: 5, timescale: 1000))
        wait(for: [both], timeout: 2)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(handed.map(\.1), [0, 0.005])
        XCTAssertTrue(handed.last?.0 === last)
        XCTAssertGreaterThan(handed.last?.2.timeIntervalSince(start) ?? 0, 0.006, "held until 0.75 frame times had passed")
    }

    /// A frame held back is left out once a newer one goes in its place.
    func testAFrameHeldBackIsLeftOutForANewerOne() throws {
        let lock = NSLock()
        var times: [Double] = []
        let capture = MoonlightScreenCapture(displayID: 1, width: 64, height: 64, fps: 60) { _, time in
            lock.lock(); times.append(CMTimeGetSeconds(time)); lock.unlock()
        }
        let buffer = try pixelBuffer()
        capture.captured(buffer, at: CMTime(value: 0, timescale: 1000))
        capture.captured(buffer, at: CMTime(value: 5, timescale: 1000))
        capture.captured(buffer, at: CMTime(value: 7, timescale: 1000))
        capture.captured(buffer, at: CMTime(value: 20, timescale: 1000))
        let settled = expectation(description: "past any wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(times, [0, 0.02])
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

    /// Sound is captured only while a stream on the capture takes it, as Moonlight's do and
    /// OpenDisplay's don't.
    func testSoundIsCapturedOnlyWhileAStreamTakesIt() {
        let makeCapture = SharedScreenCapture.makeCapture, startCapture = SharedScreenCapture.startCapture
        defer { SharedScreenCapture.makeCapture = makeCapture; SharedScreenCapture.startCapture = startCapture }
        var made: ScreenCaptureSource?
        SharedScreenCapture.makeCapture = { key, frame in
            let capture = MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height,
                                                 fps: key.fps, frame: frame)
            made = capture
            return capture
        }
        SharedScreenCapture.startCapture = { _, done in done(nil) }
        let key = SharedScreenCapture.Key(displayID: 5, width: 64, height: 64, fps: 60, showsCursor: true)

        let silent = SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: nil, started: { _ in })
        XCTAssertEqual(made?.capturesAudio, false, "nobody takes sound")
        let listening = SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: { _ in }, started: { _ in })
        XCTAssertEqual(made?.capturesAudio, true)
        listening.cancel()
        XCTAssertEqual(made?.capturesAudio, false, "the one taking sound left")
        silent.cancel()

        SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: { _ in }, started: { _ in }).cancel()
        XCTAssertEqual(made?.capturesAudio, true, "the first to subscribe takes sound")
    }

    /// A stream joining as a new frame comes never gets the older last picture after it.
    func testAJoiningStreamNeverGetsAnOlderPictureAfterANewer() throws {
        let makeCapture = SharedScreenCapture.makeCapture, startCapture = SharedScreenCapture.startCapture
        defer { SharedScreenCapture.makeCapture = makeCapture; SharedScreenCapture.startCapture = startCapture }
        var deliver: ((CVPixelBuffer, CMTime) -> Void)?
        SharedScreenCapture.makeCapture = { key, frame in
            deliver = frame
            return MoonlightScreenCapture(displayID: key.displayID, width: key.width, height: key.height, fps: key.fps, frame: frame)
        }
        SharedScreenCapture.startCapture = { _, done in done(nil) }
        let key = SharedScreenCapture.Key(displayID: 6, width: 64, height: 64, fps: 60, showsCursor: true)
        let first = SharedScreenCapture.subscribe(key, frame: { _, _ in }, audio: { _ in }, started: { _ in })
        defer { first.cancel() }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        let buffer = try XCTUnwrap(made)
        deliver?(buffer, CMTime(value: 1, timescale: 60))

        for round in 2..<20 {
            let lock = NSLock()
            var times: [CMTime] = []
            let joined = SharedScreenCapture.subscribe(key, frame: { _, time in lock.lock(); times.append(time); lock.unlock() },
                                                       audio: { _ in }, started: { _ in })
            // A newer frame at once, racing the last picture handed over on joining.
            deliver?(buffer, CMTime(value: CMTimeValue(round), timescale: 60))
            Thread.sleep(forTimeInterval: 0.02)
            joined.cancel()
            lock.lock()
            XCTAssertEqual(times.last, CMTime(value: CMTimeValue(round), timescale: 60), "round \(round): \(times)")
            lock.unlock()
        }
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

    /// PQ's curve, which the reference white is found by: 100 and 203 nits, and the ends.
    func testPQSignalsStandForTheirLight() {
        XCTAssertEqual(HDR10Converter.pqNits(0.5081), 100, accuracy: 0.5)
        XCTAssertEqual(HDR10Converter.pqNits(0.5806), 203, accuracy: 0.5)
        XCTAssertEqual(HDR10Converter.pqNits(0), 0, accuracy: 0.001)
        XCTAssertEqual(HDR10Converter.pqNits(1), 10_000, accuracy: 1)
    }

    /// Where Core Image puts SDR white in PQ is measured, not fallen back on: 100 nits on
    /// macOS 13 (a stop up to 203), 203 on macOS 14 (none).
    func testTheReferenceWhiteIsMeasured() throws {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let gain = try XCTUnwrap(HDR10Converter.measuredGain(in: context))
        switch ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
        case 13: XCTAssertEqual(gain, log2(203.0 / 100.0), accuracy: 0.05)
        case 14: XCTAssertEqual(gain, 0)
        default: break
        }
    }

    /// SDR white, as a display is captured before macOS 15, goes to BT.2408's 203 nits in
    /// HDR10's PQ, where HDR10 players show it, not macOS's 100.
    func testHDR10PutsSDRWhiteAtTheReferenceLevel() throws {
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &made),
                       kCVReturnSuccess)
        let white = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(white, [])
        for (plane, value) in [(0, Int32(235)), (1, Int32(128))] {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(white, plane))
            memset(base, value, CVPixelBufferGetBytesPerRowOfPlane(white, plane) * CVPixelBufferGetHeightOfPlane(white, plane))
        }
        CVPixelBufferUnlockBaseAddress(white, [])
        CVBufferSetAttachment(white, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(white, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(white, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        let out = try XCTUnwrap(XCTUnwrap(HDR10Converter(width: 64, height: 64)).convert(white))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(CVBufferCopyAttachment(out, kCVImageBufferTransferFunctionKey, nil) as? String,
                       kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 0)).assumingMemoryBound(to: UInt16.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 1)).assumingMemoryBound(to: UInt16.self)
        // PQ of 203 nits, in 10-bit video range: 64 + 0.5806 × 876.
        XCTAssertEqual(Int(luma[32 * CVPixelBufferGetBytesPerRowOfPlane(out, 0) / 2 + 32] >> 6), 573, accuracy: 2)
        XCTAssertEqual(Int(chroma[0] >> 6), 512, accuracy: 2, "still grey")
    }

    /// A saturated colour is written with BT.2020's matrix, as the frame is tagged, from the
    /// first frame on: the buffer is tagged before Core Image renders into it.
    func testHDR10WritesSaturatedColoursWithBT2020sMatrix() throws {
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &made),
                       kCVReturnSuccess)
        let red = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(red, [])
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(red)).assumingMemoryBound(to: UInt32.self)
        for index in 0..<(CVPixelBufferGetBytesPerRow(red) / 4 * 64) { pixels[index] = 0xFFFF_0000 }
        CVPixelBufferUnlockBaseAddress(red, [])

        // The colour in PQ and BT.2020, as Core Image makes it, then through BT.2020's matrix.
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        var rgb = [Float](repeating: 0, count: 4)
        context.render(CIImage(cvPixelBuffer: red), toBitmap: &rgb, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!)
        let y = 0.2627 * Double(rgb[0]) + 0.6780 * Double(rgb[1]) + 0.0593 * Double(rgb[2])
        let expected = (y: 64 + 876 * y, cb: 512 + 896 * (Double(rgb[2]) - y) / 1.8814,
                        cr: 512 + 896 * (Double(rgb[0]) - y) / 1.4746)

        let converter = try XCTUnwrap(HDR10Converter(width: 64, height: 64, gain: 0))
        for frame in ["first", "second"] {
            let out = try XCTUnwrap(converter.convert(red))
            XCTAssertEqual(CVBufferCopyAttachment(out, kCVImageBufferYCbCrMatrixKey, nil) as? String,
                           kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
            CVPixelBufferLockBaseAddress(out, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
            let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 0)).assumingMemoryBound(to: UInt16.self)
            let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(out, 1)).assumingMemoryBound(to: UInt16.self)
            XCTAssertEqual(Double(luma[0] >> 6), expected.y, accuracy: 3, "\(frame) frame's luma")
            XCTAssertEqual(Double(chroma[0] >> 6), expected.cb, accuracy: 3, "\(frame) frame's Cb")
            XCTAssertEqual(Double(chroma[1] >> 6), expected.cr, accuracy: 3, "\(frame) frame's Cr")
        }
    }
}
