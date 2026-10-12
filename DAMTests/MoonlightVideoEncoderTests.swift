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

    private final class Collector {
        let lock = NSLock()
        var frames: [MoonlightVideoEncoder.Frame] = []
        var onFrame: (() -> Void)?
        func add(_ frame: MoonlightVideoEncoder.Frame) {
            lock.lock(); frames.append(frame); lock.unlock()
            onFrame?()
        }
    }

    private func encodeOne(_ encoder: MoonlightVideoEncoder, _ collector: Collector, seed: Int) throws {
        let done = expectation(description: "frame \(seed)")
        collector.onFrame = { done.fulfill() }
        encoder.encode(try frame(seed), at: CMTime(value: CMTimeValue(seed), timescale: 60))
        wait(for: [done], timeout: 5)
    }

    func testFirstFrameIsAKeyFrameWithItsParameterSets() throws {
        let collector = Collector()
        let encoder = try MoonlightVideoEncoder(settings: settings, output: collector.add)
        try encodeOne(encoder, collector, seed: 0)
        let first = try XCTUnwrap(collector.frames.first)
        XCTAssertTrue(first.isKeyFrame)
        XCTAssertEqual(Array(nalTypes(first.data).prefix(2)), [7, 8], "SPS and PPS first")
        XCTAssertTrue(nalTypes(first.data).contains(5), "an IDR slice")
    }

    func testLaterFramesAreNotKeyFramesUntilAskedFor() throws {
        let collector = Collector()
        let encoder = try MoonlightVideoEncoder(settings: settings, output: collector.add)
        for seed in 0..<5 { try encodeOne(encoder, collector, seed: seed) }
        XCTAssertEqual(collector.frames.map(\.isKeyFrame), [true, false, false, false, false])
        XCTAssertFalse(nalTypes(collector.frames[1].data).contains(7))

        encoder.requestKeyFrame()
        try encodeOne(encoder, collector, seed: 5)
        XCTAssertTrue(try XCTUnwrap(collector.frames.last).isKeyFrame)
        try encodeOne(encoder, collector, seed: 6)
        XCTAssertFalse(try XCTUnwrap(collector.frames.last).isKeyFrame)
    }

    func testFramesArrivingFasterThanTheEncoderSkipToTheLatest() throws {
        let collector = Collector()
        let encoder = try MoonlightVideoEncoder(settings: settings, output: collector.add)
        let frames = try (0..<20).map(frame)
        let last = expectation(description: "last frame")
        collector.onFrame = { if collector.frames.last?.time.value == 19 { last.fulfill() } }
        for (seed, pixels) in frames.enumerated() {
            encoder.encode(pixels, at: CMTime(value: CMTimeValue(seed), timescale: 60))
        }
        wait(for: [last], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertLessThan(collector.frames.count, 20, "some frames skipped rather than queued")
        XCTAssertEqual(collector.frames.map(\.time.value), collector.frames.map(\.time.value).sorted())
    }

    func testReportsHowLongEncodingTakes() throws {
        let collector = Collector()
        let encoder = try MoonlightVideoEncoder(settings: settings, output: collector.add)
        for seed in 0..<30 { try encodeOne(encoder, collector, seed: seed) }
        let times = collector.frames.dropFirst().map { Double($0.encoded - $0.submitted) / 1_000_000 }.sorted()
        let median = times[times.count / 2]
        NSLog("%@", "encoder: hardware \(encoder.isHardware), low-latency rate control \(encoder.hasLowLatencyRateControl), " +
              "median \(String(format: "%.2f", median)) ms, worst \(String(format: "%.2f", times.last ?? 0)) ms at 720p")
        XCTAssertLessThan(median, 16.7, "slower than a frame at 60 Hz")
    }
}
