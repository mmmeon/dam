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
//  again. Apple's low-latency rate control hands each frame back on its own, but on this
//  encoder it predicts from long-term reference frames, which a decoder holding one
//  reference frame cannot follow: FFmpeg, which Moonlight decodes with everywhere, and
//  Moonlight rewrites any SPS it gets to one reference frame. Neither the SPS nor the
//  encoder's properties (ReferenceBufferCount, EnableLTR: ignored) mend it, so its slices
//  are rewritten instead (see H264OneReference). It is used only when the settings ask for
//  it (`lowLatency`). Asking the encoder to complete a frame would also bring it out at
//  once, but starts the next afresh as a keyframe.
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
        /// Whether frames may be predicted from later ones (B-frames): smaller for the
        /// same picture, at a couple of frames' delay. Never for Moonlight.
        var reordering = false
        /// No more than `rateLimitMultiple` times the bitrate over any `rateLimitWindow`
        /// seconds, which keeps a keyframe from being many times a frame's share.
        var rateLimitMultiple = 1.5
        var rateLimitWindow = 0.25
        /// Seconds between keyframes; 0 for only when asked.
        var keyFrameInterval = 0
        /// Whether the encoder may trade picture quality for speed.
        var prioritizeSpeed = false
        /// Whether frames come at a steady rate, every one of them to be encoded: a burst
        /// of them queues up (a few deep) rather than each taking the place of the last,
        /// and none is nudged out (see `nudgeDelay`), the stream bringing its own repeats.
        /// Off for Moonlight, whose frames come as the screen changes.
        var steady = false
        /// Whether to ask for Apple's low-latency rate control, which hands each frame back
        /// as soon as it is encoded, without a nudge (see the top of the file); ignored
        /// with `reordering`, which it does not allow.
        var lowLatency = false
    }

    /// One encoded frame as an H.264 Annex B access unit; a keyframe starts with its SPS and PPS.
    struct Frame {
        let data: Data
        let isKeyFrame: Bool
        /// The frame's NAL units, without its parameter sets, as `data` has them.
        let units: [Data]
        /// The frame as the encoder handed it back, with its parameter sets in the format
        /// description (see `parameterSets`); its own NAL units may differ from `units`.
        let sample: CMSampleBuffer
        /// The time it was given with.
        let time: CMTime
        /// When the frame was given to the encoder.
        let submitted: UInt64
        /// When the encoder handed it back.
        let encoded: UInt64
        /// Whether it is the picture before it given again, to nudge that one out (see the
        /// top of the file), rather than a new picture.
        var isRepeat = false

        /// The access unit with 4-byte lengths before its NAL units, as MP4 wants it.
        var avcc: Data {
            var out = Data()
            for unit in units {
                out.append(bigEndian: UInt32(unit.count))
                out.append(unit)
            }
            return out
        }
    }

    let settings: Settings
    /// Whether the encoder runs on the GPU's media engine rather than the CPU.
    let isHardware: Bool
    /// Whether the encoder took low-latency rate control; not every Mac's does.
    let isLowLatency: Bool

    private let session: VTCompressionSession
    private let output: (Frame) -> Void
    /// Rewrites low-latency frames for decoders holding one reference frame; on the encoder's thread.
    private let oneReference: H264OneReference?
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.encoder", qos: .userInteractive)
    private let lock = NSLock()
    /// Whether the encoding thread is taking frames from the slot.
    private var busy = false
    private var waiting: [(CVPixelBuffer, CMTime)] = []
    private var keyFrameRequested = true
    /// Frames given to the encoder and not yet handed back; under `lock`.
    private var pending = 0
    /// Frames the encoder dropped or failed on; under `lock`.
    private var dropped = 0
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
        // Low-latency rate control when asked for and the encoder takes it, else the plain
        // real-time one.
        var made: (VTCompressionSession, Bool)?
        var status = noErr
        for lowLatency in settings.lowLatency && !settings.reordering ? [true, false] : [false] {
            var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var session: VTCompressionSession?
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width),
                                                height: Int32(settings.height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            if status == noErr, let session {
                made = (session, lowLatency)
                break
            }
            if lowLatency { veLog.debug("encoder without low-latency rate control: \(status)") }
        }
        guard let (session, lowLatency) = made else { throw MoonlightVideoError.session(status) }
        self.session = session
        isLowLatency = lowLatency
        oneReference = lowLatency ? H264OneReference() : nil
        var hardware: CFBoolean?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &hardware)
        isHardware = (hardware as? Bool) ?? false

        let keyFrameSeconds = settings.keyFrameInterval > 0 ? settings.keyFrameInterval : 3600
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: settings.reordering,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.fps,
            // Keyframes only when asked for (Moonlight asks after losing packets), an hour
            // apart otherwise, unless the settings want them regularly.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: settings.fps * keyFrameSeconds,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyFrameSeconds,
        ]
        properties.merge(Self.rateProperties(settings.bitrateKbps, settings)) { $1 }
        // Without reordering, no frame is held back for one that follows.
        if !settings.reordering { properties[kVTCompressionPropertyKey_MaxFrameDelayCount] = 0 }
        if settings.prioritizeSpeed { properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] = true }
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if status != noErr { veLog.debug("encoder property \(key as String, privacy: .public): \(status)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        veLog.debug("encoder \(settings.width)×\(settings.height)@\(settings.fps) \(settings.bitrateKbps) kbps, hardware \(self.isHardware), low-latency \(self.isLowLatency)")
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// The average bitrate, and the limit that keeps a keyframe from being many times a
    /// frame's share of it: for Moonlight no more than one and a half times the rate over any
    /// quarter second, so it fits within the packets Moonlight takes with parity and goes out
    /// in a few frames' time.
    private static func rateProperties(_ kbps: Int, _ settings: Settings) -> [CFString: Any] {
        [kVTCompressionPropertyKey_AverageBitRate: kbps * 1000,
         kVTCompressionPropertyKey_DataRateLimits: [
            NSNumber(value: Int(Double(kbps * 1000 / 8) * settings.rateLimitMultiple * settings.rateLimitWindow)),
            NSNumber(value: settings.rateLimitWindow)]]
    }

    /// Changes the bitrate from the next frame encoded.
    func setBitrate(kbps: Int) {
        queue.async { [self] in
            for (key, value) in Self.rateProperties(kbps, settings) {
                let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
                if status != noErr { veLog.debug("encoder property \(key as String, privacy: .public): \(status)") }
            }
        }
    }

    /// Makes the next frame encoded a keyframe.
    func requestKeyFrame() {
        lock.lock()
        keyFrameRequested = true
        lock.unlock()
    }

    /// Frames given to `encode` that never came out: passed over for a newer one, or dropped
    /// or failed on by the encoder.
    var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    /// Puts `buffer` in the slot, in place of any frame not yet taken (or, for a steady
    /// stream, behind it), and returns at once.
    func encode(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        if settings.steady {
            waiting.append((buffer, time))
            if waiting.count > 4 { waiting.removeFirst(); dropped += 1 }
        } else {
            dropped += waiting.count
            waiting = [(buffer, time)]
        }
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Gives the encoder frames from the slot until it is empty.
    private func drain() {
        while true {
            lock.lock()
            guard let (buffer, time) = waiting.first else {
                busy = false
                lock.unlock()
                return
            }
            waiting.removeFirst()
            let key = keyFrameRequested
            keyFrameRequested = false
            lock.unlock()
            if !submit(buffer, at: time, keyFrame: key), key { requestKeyFrame() }
            lastBuffer = buffer
            guard !settings.steady else { continue }
            // Bring this frame out should no other follow it.
            let generation = submissions
            queue.asyncAfter(deadline: .now() + nudgeDelay) { [weak self] in
                guard let self, self.submissions == generation, let last = self.lastBuffer else { return }
                self.lock.lock()
                let held = self.pending > 0
                self.lock.unlock()
                if held { _ = self.submit(last, at: self.lastTime, keyFrame: false, counted: false) }
            }
        }
    }

    /// Gives the encoder one frame; it is handed back on the encoder's own thread, in order.
    /// Returns false when the encoder would not take it. One not `counted` (a picture given
    /// again to nudge the last out) isn't a frame lost when it doesn't come out.
    private func submit(_ buffer: CVPixelBuffer, at time: CMTime, keyFrame: Bool, counted: Bool = true) -> Bool {
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
                  let (sets, _) = Self.parameterSets(sample), var units = Self.nalUnits(sample) else {
                if counted {
                    self.lock.lock()
                    self.dropped += 1
                    self.lock.unlock()
                }
                veLog.error("encode: \(status)")
                if keyFrame { self.requestKeyFrame() }
                return
            }
            let isKeyFrame = Self.isKeyFrame(sample)
            if let oneReference = self.oneReference {
                // Parameter sets go in too, to read the slices by; they come out as they are.
                let given = isKeyFrame ? sets : []
                let (rewritten, broken) = oneReference.rewrite(given + units)
                units = Array(rewritten.dropFirst(given.count))
                if broken {
                    veLog.error("a frame predicts from one a single reference cannot hold; asking for a keyframe")
                    self.requestKeyFrame()
                }
            }
            let startCode = Data([0, 0, 0, 1])
            var data = Data()
            for unit in (isKeyFrame ? sets : []) + units {
                data.append(startCode)
                data.append(unit)
            }
            self.output(Frame(data: data, isKeyFrame: isKeyFrame, units: units, sample: sample, time: rising,
                              submitted: submitted, encoded: DispatchTime.now().uptimeNanoseconds, isRepeat: !counted))
        }
        guard status == noErr else {
            veLog.error("encode frame: \(status)")
            lock.lock()
            pending -= 1
            if counted { dropped += 1 }
            lock.unlock()
            return false
        }
        return true
    }

    /// Whether `sample` is a keyframe.
    static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// The parameter sets in `sample`'s format description, SPS first, and the size of the
    /// length before each NAL unit in its data.
    static func parameterSets(_ sample: CMSampleBuffer) -> (sets: [Data], lengthSize: Int)? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var count = 0
        var lengthSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &lengthSize)
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, Int(lengthSize))
    }

    /// The NAL units in `sample`, without their lengths.
    private static func nalUnits(_ sample: CMSampleBuffer) -> [Data]? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let (_, lengthSize) = parameterSets(sample) else { return nil }
        let total = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == noErr else {
            return nil
        }
        var units: [Data] = []
        var offset = 0
        while offset + lengthSize <= total {
            let length = bytes[offset..<(offset + lengthSize)].reduce(0) { $0 << 8 | Int($1) }
            offset += lengthSize
            guard length > 0, offset + length <= total else { return nil }
            units.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return units
    }
}
