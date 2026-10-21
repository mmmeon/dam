import XCTest
import AudioToolbox
import CoreMedia
@testable import DAM

final class MoonlightAudioEncoderTests: XCTestCase {

    /// `seconds` of a 440 Hz tone, interleaved stereo at 48 kHz.
    private func tone(seconds: Double) -> [Float] {
        let frames = Int(48_000 * seconds)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.5
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    func testEveryFiveMillisecondsMakesOnePacket() throws {
        var packets: [Data] = []
        let encoder = try MoonlightAudioEncoder(packetDuration: 5) { packets.append($0) }
        XCTAssertEqual(encoder.frameCount, 240)
        // 0.1 s in uneven pieces: 20 packets, none held back.
        let samples = tone(seconds: 0.1)
        samples.withUnsafeBufferPointer { all in
            var index = 0
            for piece in [100, 333, 1024, 77] {
                while index < all.count {
                    let end = min(index + piece * 2, all.count)
                    encoder.encode(interleaved: UnsafeBufferPointer(rebasing: all[index..<end]))
                    index = end
                }
            }
        }
        XCTAssertEqual(packets.count, 20)
        XCTAssertTrue(packets.allSatisfy { !$0.isEmpty && $0.count < 400 }, "\(packets.map(\.count))")
    }

    /// Captured sound as macOS hands it over: interleaved float stereo.
    private func sampleBuffer(_ samples: [Float]) throws -> CMSampleBuffer {
        var format = MoonlightAudioEncoder.pcmFormat
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                                                      magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                      formatDescriptionOut: &description), noErr)
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                          blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                          dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                          blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        samples.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0,
                                              dataLength: length)
        }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: try XCTUnwrap(description),
            sampleCount: samples.count / 2, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testSkipsTheFirstSamplesOfCapturedSoundWhenAsked() throws {
        var packets = 0
        let encoder = try MoonlightAudioEncoder(packetDuration: 5) { _ in packets += 1 }
        let sample = try sampleBuffer(tone(seconds: 0.01))
        encoder.encode(sample)
        XCTAssertEqual(packets, 2, "480 samples, two packets")
        encoder.encode(sample, skipping: 240)
        XCTAssertEqual(packets, 3, "half of them")
        encoder.encode(sample, skipping: 1000)
        XCTAssertEqual(packets, 3, "none")
    }

    func testPacketsDecodeBackToTheTone() throws {
        var packets: [Data] = []
        let encoder = try MoonlightAudioEncoder(packetDuration: 5) { packets.append($0) }
        tone(seconds: 0.2).withUnsafeBufferPointer { encoder.encode(interleaved: $0) }

        // macOS's own Opus decoder, as a stand-in for the one in Moonlight.
        var opus = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 240, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var pcm = MoonlightAudioEncoder.pcmFormat
        var converter: AudioConverterRef?
        XCTAssertEqual(AudioConverterNew(&opus, &pcm, &converter), noErr)
        let decoder = try XCTUnwrap(converter)
        defer { AudioConverterDispose(decoder) }
        // Fed in order, as a client decodes them; the converter reads the packet and its
        // description after the callback returns, so they live in memory of their own.
        final class Feed {
            var packet: Data?
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: 16)
            let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            deinit { bytes.deallocate(); description.deallocate() }
        }
        let feed = Feed()
        var energy: Float = 0
        for (index, packet) in packets.enumerated() {
            var out = [Float](repeating: 0, count: 240 * 2)
            var frames: UInt32 = 240
            feed.packet = packet
            let status = out.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return AudioConverterFillComplexBuffer(decoder, { _, count, data, descriptions, context in
                    let feed = Unmanaged<Feed>.fromOpaque(context!).takeUnretainedValue()
                    guard let packet = feed.packet else { count.pointee = 0; return MoonlightAudioEncoder.waitingForInput }
                    feed.packet = nil
                    packet.withUnsafeBytes { feed.bytes.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                    data.pointee.mNumberBuffers = 1
                    data.pointee.mBuffers.mData = feed.bytes
                    data.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
                    feed.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                            mDataByteSize: UInt32(packet.count))
                    descriptions?.pointee = feed.description
                    count.pointee = 1
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
            }
            XCTAssertTrue(status == noErr || status == MoonlightAudioEncoder.waitingForInput, "\(status)")
            if index >= packets.count - 10 { energy += out.prefix(Int(frames) * 2).reduce(0) { $0 + $1 * $1 } }
        }
        XCTAssertGreaterThan(energy / Float(10 * 480), 0.05, "the tone comes back, not silence")
    }
}
