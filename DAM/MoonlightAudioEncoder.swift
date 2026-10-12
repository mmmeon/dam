//
//  MoonlightAudioEncoder.swift
//
//  Encodes the Mac's sound to Opus for Moonlight with macOS's own encoder: 48 kHz stereo,
//  in packets as short as Moonlight asks for (5 ms by default), at a constant bitrate so
//  every packet is one size, as Moonlight needs within each block of four. Samples are
//  encoded as soon as a packet's worth has come; nothing is held back beyond that.
//

import AudioToolbox
import CoreMedia
import Foundation
import os.log

private let aeLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightAudio")

enum MoonlightAudioError: Error {
    case converter(OSStatus)
}

final class MoonlightAudioEncoder {

    static let sampleRate = 48_000
    static let channels = 2
    /// What the input callback answers once it has given this packet's samples. Answering
    /// none with noErr would end the stream, and the encoder would start each packet afresh.
    static let waitingForInput = OSStatus(bitPattern: 0x6D6F_7265)   // 'more'

    /// Samples per channel in each packet.
    let frameCount: Int
    let bitrate: Int

    private let converter: AudioConverterRef
    private let output: (Data) -> Void
    /// Interleaved samples waiting to fill a packet; never more than one packet's worth.
    private var pending: [Float] = []
    private let maxPacketSize: Int

    /// `packetDuration` is in milliseconds; `output` gets each Opus packet on the caller's thread.
    init(packetDuration: Int = 5, bitrate: Int = 96_000, output: @escaping (Data) -> Void) throws {
        frameCount = Self.sampleRate * packetDuration / 1000
        self.bitrate = bitrate
        self.output = output
        var pcm = Self.pcmFormat
        var opus = AudioStreamBasicDescription(mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatOpus,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameCount),
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(Self.channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        var made: AudioConverterRef?
        let status = AudioConverterNew(&pcm, &opus, &made)
        guard status == noErr, let made else { throw MoonlightAudioError.converter(status) }
        converter = made
        var rate = UInt32(bitrate)
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        var constant = UInt32(kAudioCodecBitRateControlMode_Constant)
        AudioConverterSetProperty(converter, kAudioCodecPropertyBitRateControlMode,
                                  UInt32(MemoryLayout<UInt32>.size), &constant)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var maximum: UInt32 = 0
        AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maximum)
        maxPacketSize = max(Int(maximum), 1500)
        pending.reserveCapacity(frameCount * Self.channels)
        aeLog.debug("Opus \(packetDuration) ms packets at \(bitrate / 1000) kbps")
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// 32-bit float, interleaved stereo at 48 kHz.
    static let pcmFormat = AudioStreamBasicDescription(
        mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)

    /// Takes interleaved stereo samples and sends every packet they complete.
    func encode(interleaved samples: UnsafeBufferPointer<Float>) {
        var index = 0
        let packetSamples = frameCount * Self.channels
        while index < samples.count {
            let take = min(packetSamples - pending.count, samples.count - index)
            pending.append(contentsOf: samples[index..<(index + take)])
            index += take
            if pending.count == packetSamples {
                if let packet = encodePending() { output(packet) }
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Takes captured sound in any layout macOS hands over: float, interleaved or one buffer
    /// per channel, mono or stereo. It must already be at 48 kHz.
    func encode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              Int(description.mSampleRate) == Self.sampleRate else { return }
        var block: CMBlockBuffer?
        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &listSize,
                                                                bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                flags: 0, blockBufferOut: nil)
        let list = AudioBufferList.allocate(maximumBuffers: max(1, listSize / MemoryLayout<AudioBuffer>.stride))
        defer { list.unsafeMutablePointer.deallocate() }
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(description.mChannelsPerFrame)
        let interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var stereo = [Float](repeating: 0, count: frames * Self.channels)
        for frame in 0..<frames {
            for channel in 0..<Self.channels {
                // Mono goes to both sides; channels past two are left out.
                let source = min(channel, channels - 1)
                let value: Float
                if interleaved {
                    value = list[0].mData!.assumingMemoryBound(to: Float.self)[frame * channels + source]
                } else {
                    value = list[source].mData!.assumingMemoryBound(to: Float.self)[frame]
                }
                stereo[frame * Self.channels + channel] = value
            }
        }
        stereo.withUnsafeBufferPointer { encode(interleaved: $0) }
    }

    /// Encodes the full packet in `pending`.
    private func encodePending() -> Data? {
        var packet = [UInt8](repeating: 0, count: maxPacketSize)
        var packetCount: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let feed = Feed()
        let status: OSStatus = pending.withUnsafeMutableBufferPointer { samples in
            feed.samples = samples
            return packet.withUnsafeMutableBytes { bytes in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(Self.channels), mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, packets, data, _, context in
                    let feed = Unmanaged<Feed>.fromOpaque(context!).takeUnretainedValue()
                    // The packet's samples once; then none yet, which keeps the stream going.
                    guard let samples = feed.samples else {
                        packets.pointee = 0
                        return MoonlightAudioEncoder.waitingForInput
                    }
                    feed.samples = nil
                    data.pointee.mNumberBuffers = 1
                    data.pointee.mBuffers.mNumberChannels = UInt32(MoonlightAudioEncoder.channels)
                    data.pointee.mBuffers.mDataByteSize = UInt32(samples.count * MemoryLayout<Float>.size)
                    data.pointee.mBuffers.mData = UnsafeMutableRawPointer(samples.baseAddress)
                    packets.pointee = UInt32(samples.count / MoonlightAudioEncoder.channels)
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &packetCount, &buffers, &description)
            }
        }
        guard status == noErr || status == Self.waitingForInput, packetCount == 1, description.mDataByteSize > 0 else {
            aeLog.error("encode: \(status), \(packetCount) packets")
            return nil
        }
        let start = Int(description.mStartOffset)
        return Data(packet[start..<(start + Int(description.mDataByteSize))])
    }

    private final class Feed {
        var samples: UnsafeMutableBufferPointer<Float>?
    }
}
