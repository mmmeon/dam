//
//  MoonlightVideoEncoder.swift
//
//  Encodes frames to H.264 for Moonlight with as little delay as the encoder allows: in
//  real time, without reordering frames, with one reference frame, and with keyframes only
//  when asked for. Frames are handed over through a single slot that a newer frame takes
//  over, and given to the encoder one at a time on a thread of their own, so the caller
//  never waits for the encoder and the next frame encoded is always the latest.
//
//  The plain real-time encoder (an Intel Mac's, at least) hands a frame back only once
//  the next one is in, so while the screen moves each frame comes out a frame's time late,
//  and when it stops the last frame is nudged out by giving the encoder the same picture
//  again. Apple's low-latency rate control would hand each frame back on its own, but on
//  this encoder it predicts from long-term reference frames while its SPS allows one;
//  FFmpeg, which Moonlight decodes with on Linux and Windows, then discards a reference
//  every frame and the picture breaks up until the next keyframe, and Moonlight rewrites
//  any SPS it gets to one reference frame, so neither the SPS nor the encoder's
//  properties (ReferenceBufferCount, EnableLTR: ignored) can mend it. Asking the encoder to
//  complete a frame would also bring it out at once, but starts the next afresh as a
//  keyframe.
//

import CoreMedia
import Foundation
import VideoToolbox
import os.log

private let veLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightVideo")

enum MoonlightVideoError: Error {
    case session(OSStatus)
}

final class MoonlightVideoEncoder {

    struct Settings: Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var bitrateKbps: Int
    }

    /// One encoded frame as an H.264 Annex B access unit; a keyframe starts with its SPS and PPS.
    struct Frame {
        let data: Data
        let isKeyFrame: Bool
        /// The time it was given with.
        let time: CMTime
        /// When the frame was given to the encoder.
        let submitted: UInt64
        /// When the encoder handed it back.
        let encoded: UInt64
    }

    let settings: Settings
    /// Whether the encoder runs on the GPU's media engine rather than the CPU.
    let isHardware: Bool

    private let session: VTCompressionSession
    private let output: (Frame) -> Void
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.encoder", qos: .userInteractive)
    private let lock = NSLock()
    /// Whether the encoding thread is taking frames from the slot.
    private var busy = false
    private var waiting: (buffer: CVPixelBuffer, time: CMTime)?
    private var keyFrameRequested = true
    /// Frames given to the encoder and not yet handed back; under `lock`.
    private var pending = 0
    /// Counts frames given to the encoder, to tell whether another came after one; on the encoding thread.
    private var submissions = 0
    /// The last time given to the encoder, which needs them to rise; on the encoding thread.
    private var lastTime = CMTime.negativeInfinity
    private var lastBuffer: CVPixelBuffer?
    /// How long after a frame is given to the encoder, with none after it, the same picture
    /// is given again to bring it out: a little over a frame's time, so that while the
    /// screen moves the next frame does it instead.
    private let nudgeDelay: DispatchTimeInterval

    /// `output` is called on the encoder's thread for each frame, as soon as it is encoded.
    /// With the default MoonlightH264Dump naming a file, every frame is appended to it as
    /// well, as an Annex B stream to look at with other tools.
    init(settings: Settings, output: @escaping (Frame) -> Void) throws {
        self.settings = settings
        nudgeDelay = .microseconds(1_250_000 / max(settings.fps, 1))
        if let path = UserDefaults.standard.string(forKey: "MoonlightH264Dump"),
           FileManager.default.createFile(atPath: path, contents: nil),
           let dump = FileHandle(forWritingAtPath: path) {
            veLog.debug("dumping the stream to \(path, privacy: .public)")
            self.output = { frame in
                dump.write(frame.data)
                output(frame)
            }
        } else {
            self.output = output
        }
        let specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width),
                                                height: Int32(settings.height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let session = made else { throw MoonlightVideoError.session(status) }
        self.session = session
        var hardware: CFBoolean?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &hardware)
        isHardware = (hardware as? Bool) ?? false

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_AverageBitRate: settings.bitrateKbps * 1000,
            // Keeps a keyframe from being many times a frame's share of the bitrate: no more
            // than one and a half times the rate over any quarter second, so it fits within
            // the packets Moonlight takes with parity and goes out in a few frames' time.
            kVTCompressionPropertyKey_DataRateLimits: [NSNumber(value: settings.bitrateKbps * 1000 / 8 * 3 / 8),
                                                       NSNumber(value: 0.25)],
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.fps,
            // Keyframes only when Moonlight asks, after losing packets; an hour apart otherwise.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: settings.fps * 3600,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 3600,
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if status != noErr { veLog.debug("encoder property \(key as String, privacy: .public): \(status)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        veLog.debug("encoder \(settings.width)×\(settings.height)@\(settings.fps) \(settings.bitrateKbps) kbps, hardware \(self.isHardware)")
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Makes the next frame encoded a keyframe.
    func requestKeyFrame() {
        lock.lock()
        keyFrameRequested = true
        lock.unlock()
    }

    /// Puts `buffer` in the slot, in place of any frame not yet taken, and returns at once.
    func encode(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        waiting = (buffer, time)
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Gives the encoder frames from the slot until it is empty.
    private func drain() {
        while true {
            lock.lock()
            guard let (buffer, time) = waiting else {
                busy = false
                lock.unlock()
                return
            }
            waiting = nil
            let key = keyFrameRequested
            keyFrameRequested = false
            lock.unlock()
            if !submit(buffer, at: time, keyFrame: key), key { requestKeyFrame() }
            lastBuffer = buffer
            // Bring this frame out should no other follow it.
            let generation = submissions
            queue.asyncAfter(deadline: .now() + nudgeDelay) { [weak self] in
                guard let self, self.submissions == generation, let last = self.lastBuffer else { return }
                self.lock.lock()
                let held = self.pending > 0
                self.lock.unlock()
                if held { _ = self.submit(last, at: self.lastTime, keyFrame: false) }
            }
        }
    }

    /// Gives the encoder one frame; it is handed back on the encoder's own thread, in order.
    /// Returns false when the encoder would not take it.
    private func submit(_ buffer: CVPixelBuffer, at time: CMTime, keyFrame: Bool) -> Bool {
        // A picture given again comes with the time it had; move it past the last one.
        let rising = time > lastTime ? time : CMTimeAdd(lastTime, CMTime(value: 1, timescale: 1000))
        lastTime = rising
        submissions += 1
        let options = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let submitted = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        pending += 1
        lock.unlock()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: rising,
                                                     duration: .invalid, frameProperties: options,
                                                     infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self else { return }
            self.lock.lock()
            self.pending -= 1
            self.lock.unlock()
            guard status == noErr, !flags.contains(.frameDropped), let sample,
                  let (data, isKeyFrame) = Self.annexB(sample) else {
                veLog.error("encode: \(status)")
                if keyFrame { self.requestKeyFrame() }
                return
            }
            self.output(Frame(data: data, isKeyFrame: isKeyFrame, time: rising, submitted: submitted,
                              encoded: DispatchTime.now().uptimeNanoseconds))
        }
        guard status == noErr else {
            veLog.error("encode frame: \(status)")
            lock.lock()
            pending -= 1
            lock.unlock()
            return false
        }
        return true
    }

    /// The access unit in `sample` with Annex B start codes, its SPS and PPS first when it is
    /// a keyframe, and whether it is one.
    static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let startCode = Data([0, 0, 0, 1])
        var out = Data()

        var parameterSets = 0
        var lengthSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &parameterSets,
                                                           nalUnitHeaderLengthOut: &lengthSize)
        if isKeyFrame {
            for index in 0..<parameterSets {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                out.append(startCode)
                out.append(pointer, count: size)
            }
        }

        let total = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == noErr else {
            return nil
        }
        // Length-prefixed NAL units to start-code-prefixed ones.
        var offset = 0
        let width = Int(lengthSize)
        while offset + width <= total {
            let length = bytes[offset..<(offset + width)].reduce(0) { $0 << 8 | Int($1) }
            offset += width
            guard length > 0, offset + length <= total else { return nil }
            out.append(startCode)
            out.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        return (out, isKeyFrame)
    }
}
