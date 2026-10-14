import XCTest
import CoreMedia
import CoreVideo
@testable import DAM

final class MoonlightVideoEncoderTests: XCTestCase {

    private let settings = MoonlightVideoEncoder.Settings(width: 1280, height: 720, fps: 60, bitrateKbps: 10000)

    /// A 4:2:0 frame like the ones screen capture hands over, with a pattern that moves with `seed`.
    private func frame(_ seed: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, settings.width, settings.height,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer),
                       kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, plane)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
                memset(base + row * stride, Int32((row + seed * 7) & 0xFF), stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// NAL unit types in an Annex B access unit, in order.
    private func nalTypes(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        var types: [UInt8] = []
        var index = 0
        while index + 4 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                types.append(bytes[index + 4] & 0x1F)
                index += 4
            } else {
                index += 1
            }
        }
        return types
    }

    private func time(_ seed: Int) -> CMTime { CMTime(value: CMTimeValue(seed), timescale: 60) }

    /// Collects frames as they come. The encoder brings a frame out by giving it the same
    /// picture again when no other follows, so the frames given here come interleaved
    /// with repeats of them, told apart by their time: a repeat's is moved on by a millisecond.
    private final class Collector {
        let lock = NSLock()
        var frames: [MoonlightVideoEncoder.Frame] = []
        var onFrame: ((MoonlightVideoEncoder.Frame) -> Void)?
        func add(_ frame: MoonlightVideoEncoder.Frame) {
            lock.lock(); frames.append(frame); lock.unlock()
            onFrame?(frame)
        }
        /// The frames given, without the repeats.
        var given: [MoonlightVideoEncoder.Frame] {
            lock.lock(); defer { lock.unlock() }
            return frames.filter { $0.time.timescale == 60 }
        }
    }

    /// An encoder on this Mac's hardware. These tests are of the hardware path, the one
    /// streaming takes on any Mac; a virtual machine, as the GitHub runners are, has only
    /// Apple's software encoder, which takes seconds a frame there.
    private func makeEncoder(_ collector: Collector) throws -> MoonlightVideoEncoder {
        let encoder = try MoonlightVideoEncoder(settings: settings, output: collector.add)
        try XCTSkipUnless(encoder.isHardware, "no hardware video encoder on this Mac")
        return encoder
    }

    private func encodeOne(_ encoder: MoonlightVideoEncoder, _ collector: Collector, seed: Int) throws {
        let done = expectation(description: "frame \(seed)")
        let expected = time(seed)
        collector.onFrame = { if $0.time == expected { done.fulfill() } }
        encoder.encode(try frame(seed), at: expected)
        wait(for: [done], timeout: 5)
    }

    func testFirstFrameIsAKeyFrameWithItsParameterSets() throws {
        let collector = Collector()
        let encoder = try makeEncoder(collector)
        try encodeOne(encoder, collector, seed: 0)
        let first = try XCTUnwrap(collector.given.first)
        XCTAssertTrue(first.isKeyFrame)
        XCTAssertEqual(Array(nalTypes(first.data).prefix(2)), [7, 8], "SPS and PPS first")
        XCTAssertTrue(nalTypes(first.data).contains(5), "an IDR slice")
    }

    func testLaterFramesAreNotKeyFramesUntilAskedFor() throws {
        let collector = Collector()
        let encoder = try makeEncoder(collector)
        for seed in 0..<5 { try encodeOne(encoder, collector, seed: seed) }
        XCTAssertEqual(collector.given.map(\.isKeyFrame), [true, false, false, false, false])
        XCTAssertFalse(nalTypes(try XCTUnwrap(collector.given.dropFirst().first).data).contains(7))
        XCTAssertTrue(collector.frames.allSatisfy { $0.isKeyFrame == ($0.time == time(0)) }, "repeats are not keyframes either")

        encoder.requestKeyFrame()
        try encodeOne(encoder, collector, seed: 5)
        XCTAssertTrue(try XCTUnwrap(collector.given.last).isKeyFrame)
        try encodeOne(encoder, collector, seed: 6)
        XCTAssertFalse(try XCTUnwrap(collector.given.last).isKeyFrame)
    }

    func testAFrameLeftAloneIsBroughtOutWithinAFewFramesTime() throws {
        let collector = Collector()
        let encoder = try makeEncoder(collector)
        let began = DispatchTime.now().uptimeNanoseconds
        try encodeOne(encoder, collector, seed: 0)
        try encodeOne(encoder, collector, seed: 1)
        let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        XCTAssertLessThan(took, 2 * 2.5 * 1000 / 60, "two frames, each nudged out, in well under five frames' time")
    }

    func testFramesArrivingFasterThanTheEncoderComeOutInOrder() throws {
        let collector = Collector()
        let encoder = try makeEncoder(collector)
        let frames = try (0..<20).map(frame)
        let last = expectation(description: "last frame")
        collector.onFrame = { if $0.time == self.time(19) { last.fulfill() } }
        for (seed, pixels) in frames.enumerated() {
            encoder.encode(pixels, at: time(seed))
        }
        wait(for: [last], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let given = collector.given.map(\.time.value)
        XCTAssertLessThanOrEqual(given.count, 20)
        XCTAssertEqual(given, given.sorted())
        XCTAssertEqual(given.last, 19)
    }

    func testReportsHowLongEncodingTakes() throws {
        let collector = Collector()
        let encoder = try makeEncoder(collector)
        for seed in 0..<30 { try encodeOne(encoder, collector, seed: seed) }
        // One frame at a time, each held by the encoder until brought out a frame's time later.
        let times = collector.given.dropFirst().map { Double($0.encoded - $0.submitted) / 1_000_000 }.sorted()
        let median = times[times.count / 2]
        NSLog("%@", "encoder: hardware \(encoder.isHardware), " +
              "median \(String(format: "%.2f", median)) ms, worst \(String(format: "%.2f", times.last ?? 0)) ms at 720p")
        XCTAssertLessThan(median, 2 * 1000 / 60, "slower than two frames at 60 Hz")
    }
}
