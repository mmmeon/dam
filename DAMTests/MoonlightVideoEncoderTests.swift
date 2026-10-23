import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import DAM

final class MoonlightVideoEncoderTests: XCTestCase {

    private let settings = MoonlightVideoEncoder.Settings(width: 1280, height: 720, fps: 60, bitrateKbps: 10000)

    /// A 4:2:0 frame like the ones screen capture hands over, with a pattern that moves with `seed`.
    private func frame(_ seed: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
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
    private func nalTypes(_ data: Data, _ codec: VideoCodec = .h264) -> [Int] {
        let bytes = [UInt8](data)
        var types: [Int] = []
        var index = 0
        while index + 4 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                types.append(codec.nalType(bytes[index + 4]))
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
    private func makeEncoder(_ collector: Collector, settings: MoonlightVideoEncoder.Settings? = nil) throws -> MoonlightVideoEncoder {
        let encoder = try MoonlightVideoEncoder(settings: settings ?? self.settings, output: collector.add)
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

    /// The repeats that nudge frames out say so: they wait in the encoder for the next
    /// picture, and a stream doesn't count that wait as its delay.
    func testRepeatsSayTheyAreRepeats() throws {
        let collector = Collector()
        let encoder = try makeEncoder(collector)
        // Each frame's nudge waits for the next frame; the last one brings the others' out.
        for seed in 0..<4 { try encodeOne(encoder, collector, seed: seed) }
        collector.lock.lock(); defer { collector.lock.unlock() }
        let repeats = collector.frames.filter { $0.time.timescale != 60 }
        XCTAssertGreaterThanOrEqual(repeats.count, 3, "frames left alone are nudged out")
        XCTAssertTrue(repeats.allSatisfy(\.isRepeat))
        XCTAssertTrue(collector.frames.filter { $0.time.timescale == 60 }.allSatisfy { !$0.isRepeat })
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

    // MARK: Low-latency rate control

    func testLowLatencyHandsAFrameBackWithoutANudge() throws {
        var lowLatency = settings
        lowLatency.lowLatency = true
        let collector = Collector()
        let encoder = try makeEncoder(collector, settings: lowLatency)
        try XCTSkipUnless(encoder.isLowLatency, "this Mac's encoder has no low-latency rate control")
        try encodeOne(encoder, collector, seed: 0)
        // Long enough for a nudge to have come, had one been needed.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        collector.lock.lock(); defer { collector.lock.unlock() }
        XCTAssertEqual(collector.frames.map(\.time), [time(0)])
    }

    func testLowLatencyIsLeftOffUnlessAskedFor() throws {
        // Made first: on a Mac without a hardware encoder it skips, which inside the assert would fail.
        let encoder = try makeEncoder(Collector())
        XCTAssertFalse(encoder.isLowLatency)
    }

    func testLowLatencyIsLeftOffWithReordering() throws {
        var settings = settings
        settings.lowLatency = true
        settings.reordering = true
        let encoder = try makeEncoder(Collector(), settings: settings)
        XCTAssertFalse(encoder.isLowLatency)
    }

    // MARK: - HEVC

    private func makeHEVCEncoder(_ collector: Collector, lowLatency: Bool = false) throws -> MoonlightVideoEncoder {
        try XCTSkipUnless(VideoCodec.support[.hevc]?.hardware == true, "no hardware HEVC encoder on this Mac")
        var settings = self.settings
        settings.codec = .hevc
        settings.lowLatency = lowLatency
        return try makeEncoder(collector, settings: settings)
    }

    /// Moonlight takes an HEVC frame as a keyframe by a VPS at its start, followed by the
    /// SPS and PPS, then a slice it can start from.
    func testAnHEVCKeyFrameStartsWithItsVPSThenSPSAndPPS() throws {
        let collector = Collector()
        let encoder = try makeHEVCEncoder(collector)
        for seed in 0..<3 { try encodeOne(encoder, collector, seed: seed) }
        let given = collector.given
        XCTAssertEqual(given.map(\.isKeyFrame), [true, false, false])
        let types = nalTypes(given[0].data, .hevc)
        XCTAssertEqual(Array(types.prefix(3)), [32, 33, 34], "\(types)")
        XCTAssertTrue(types.contains { (16...21).contains($0) }, "a slice to start from: \(types)")
        XCTAssertTrue(nalTypes(given[1].data, .hevc).allSatisfy { $0 < 16 || (35...40).contains($0) }, "\(nalTypes(given[1].data, .hevc))")

        encoder.requestKeyFrame()
        try encodeOne(encoder, collector, seed: 3)
        XCTAssertEqual(Array(nalTypes(try XCTUnwrap(collector.given.last).data, .hevc).prefix(3)), [32, 33, 34])
    }

    func testHEVCParameterSetsComeInTheOrderAKeyFrameCarriesThem() throws {
        let collector = Collector()
        let encoder = try makeHEVCEncoder(collector)
        try encodeOne(encoder, collector, seed: 0)
        let (sets, lengthSize) = try XCTUnwrap(MoonlightVideoEncoder.parameterSets(try XCTUnwrap(collector.given.first).sample))
        XCTAssertEqual(Array(sets.map { VideoCodec.hevc.nalType($0[0]) }.prefix(3)), [32, 33, 34])
        XCTAssertEqual(lengthSize, 4)
    }

    /// Where the HEVC encoder has no low-latency rate control, asking for it gives the
    /// plain encoder, nudged, rather than no stream.
    func testHEVCFallsBackToThePlainEncoderWithoutLowLatency() throws {
        let collector = Collector()
        let encoder = try makeHEVCEncoder(collector, lowLatency: true)
        XCTAssertEqual(encoder.isLowLatency, VideoCodec.support[.hevc]?.lowLatency)
        for seed in 0..<2 { try encodeOne(encoder, collector, seed: seed) }
        XCTAssertEqual(collector.given.count, 2)
    }

    /// What Automatic goes by, measured on this Mac's encoders.
    func testEncodersAreMeasured() throws {
        try XCTSkipUnless(VideoCodec.support[.h264]?.hardware == true, "no hardware video encoder on this Mac")
        let h264 = try XCTUnwrap(VideoCodec.performance[.h264])
        XCTAssertGreaterThan(h264.framesPerSecond, 60, "H.264 keeps up with 1080p60")
        XCTAssertLessThanOrEqual(h264.heldFrames, 1)
        if VideoCodec.support[.hevc]?.hardware == true {
            let hevc = try XCTUnwrap(VideoCodec.performance[.hevc])
            XCTAssertGreaterThan(hevc.framesPerSecond, 0)
            XCTAssertLessThan(hevc.heldFrames, 4, "comes back at all")
        }
    }

    /// Measured once for the Mac as it is, and again only once that changes.
    func testEncodersAreMeasuredOncePerMac() throws {
        let suite = "\(AppIdentity.shortID).tests.performance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let measured = [VideoCodec.h264: VideoCodec.Performance(framesPerSecond: 140, heldFrames: 1),
                        .hevc: VideoCodec.Performance(framesPerSecond: 37, heldFrames: 2)]
        var runs = 0
        func kept(_ fingerprint: String) -> [VideoCodec: VideoCodec.Performance] {
            VideoCodec.kept(for: fingerprint, in: defaults) { runs += 1; return measured }
        }
        XCTAssertEqual(kept("MacBookPro14,2 22H730"), measured)
        XCTAssertEqual(kept("MacBookPro14,2 22H730"), measured)
        XCTAssertEqual(runs, 1, "kept")
        XCTAssertEqual(kept("MacBookPro14,2 22H800"), measured)
        XCTAssertEqual(runs, 2, "measured again on another macOS")

        XCTAssertEqual(VideoCodec.kept(for: "Mac15,3 24A335", in: defaults) { nil }, [:])
        XCTAssertEqual(kept("Mac15,3 24A335"), measured)
        XCTAssertEqual(runs, 3, "a failure isn't kept")
    }

    func testTheFingerprintNamesTheMacAndItsEncoders() {
        let fingerprint = VideoCodec.fingerprint
        XCTAssertEqual(fingerprint, VideoCodec.fingerprint, "the same each time")
        XCTAssertTrue(fingerprint.contains("Mac"), "the model: \(fingerprint)")
        XCTAssertTrue(fingerprint.contains("com.apple.videotoolbox.videoencoder."), fingerprint)
    }

    /// HDR10 from frames as HDR capture hands them over: 10-bit RGB in BT.2100 PQ.
    func testHDR10IsMain10InBT2020PQWithItsMetadata() throws {
        try XCTSkipUnless(VideoCodec.support[.hevc]?.main10 == true, "no hardware HEVC Main10 on this Mac")
        var settings = self.settings
        settings.codec = .hevc
        settings.hdr = .canonical
        let collector = Collector()
        let encoder = try makeEncoder(collector, settings: settings)
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, settings.width, settings.height, kCVPixelFormatType_ARGB2101010LEPacked,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &made),
                       kCVReturnSuccess)
        let picture = try XCTUnwrap(made)
        CVBufferSetAttachment(picture, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(picture, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        let done = expectation(description: "frame")
        collector.onFrame = { if $0.time == self.time(0) { done.fulfill() } }
        encoder.encode(picture, at: time(0))
        wait(for: [done], timeout: 5)
        let frame = try XCTUnwrap(collector.given.first)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(frame.sample))
        let extensions = try XCTUnwrap(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        XCTAssertEqual(extensions["BitsPerComponent"] as? Int, 10)
        XCTAssertEqual(extensions[kCVImageBufferColorPrimariesKey as String] as? String, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(extensions[kCVImageBufferTransferFunctionKey as String] as? String,
                       kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(extensions[kCVImageBufferMasteringDisplayColorVolumeKey as String] as? Data,
                       MoonlightHDRMetadata.canonical.masteringDisplayColorVolume)
        // The SPS's general_profile_idc: 2 is Main10.
        let sps = try XCTUnwrap(MoonlightVideoEncoder.parameterSets(frame.sample)?.sets.first { VideoCodec.hevc.nalType($0[0]) == 33 })
        XCTAssertEqual(sps[3] & 0x1F, 2, "Main10")
    }

    /// Below a frame's most the limit is the rate's share of a quarter second; above it, the
    /// window shrinks so a keyframe can never be made larger than can be sent, at the same rate.
    func testTheRateLimitKeepsAFrameSendable() throws {
        func limits(_ kbps: Int, largestFrame: Int?) throws -> (bytes: Double, seconds: Double) {
            var settings = MoonlightVideoEncoder.Settings(width: 1920, height: 1080, fps: 60, bitrateKbps: kbps)
            settings.largestFrame = largestFrame
            let pair = try XCTUnwrap(MoonlightVideoEncoder.rateProperties(kbps, settings)[kVTCompressionPropertyKey_DataRateLimits]
                                        as? [NSNumber])
            return (pair[0].doubleValue, pair[1].doubleValue)
        }
        let largest = MoonlightPacketizer.largestFrame(packetSize: 1392)
        let low = try limits(20_000, largestFrame: largest)
        XCTAssertEqual(low.bytes, 937_500)
        XCTAssertEqual(low.seconds, 0.25)
        let high = try limits(200_000, largestFrame: largest)
        XCTAssertLessThanOrEqual(high.bytes, 0.9 * Double(largest))
        XCTAssertEqual(high.bytes / high.seconds, 200_000_000 / 8 * 1.5, accuracy: 100, "the same rate")
        XCTAssertEqual(try limits(200_000, largestFrame: nil).bytes, 9_375_000, "no most, no cap")
    }

    func testCodecsNameNALUnitTypesTheirOwnWay() {
        XCTAssertEqual(VideoCodec.h264.nalType(0x67), 7)
        XCTAssertEqual(VideoCodec.h264.nalType(0x65), 5)
        XCTAssertEqual(VideoCodec.hevc.nalType(0x40), 32, "VPS")
        XCTAssertEqual(VideoCodec.hevc.nalType(0x42), 33, "SPS")
        XCTAssertEqual(VideoCodec.hevc.nalType(0x44), 34, "PPS")
        XCTAssertEqual(VideoCodec.hevc.nalType(0x26), 19, "IDR_W_RADL")
        XCTAssertEqual(VideoCodec(moonlightFormat: 0), .h264)
        XCTAssertEqual(VideoCodec(moonlightFormat: 1), .hevc)
        XCTAssertNil(VideoCodec(moonlightFormat: 2), "AV1: no Mac encodes it")
    }
}
