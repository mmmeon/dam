//
//  MoonlightVideoEncoder.swift
//
//  Encodes frames to H.264 or HEVC for Moonlight with as little delay as the encoder allows: in
//  real time, without reordering frames, with one reference frame, and with keyframes only
//  when asked for. Frames are handed over through a single slot that a newer frame takes
//  over, and given to the encoder one at a time on a thread of their own, so the caller
//  never waits for the encoder and the next frame encoded is always the latest.
//
//  The plain real-time encoder (an Intel Mac's, at least) hands a frame back only once
//  the next one is in (HEVC's on the Intel test Mac, the one after that), so while the
//  screen moves each frame comes out a frame's time late, and when it stops the last
//  frame is nudged out by giving the encoder the same picture again. Apple's low-latency rate control hands each frame back on its own, but on this
//  encoder it predicts from long-term reference frames, which a decoder holding one
//  reference frame cannot follow: FFmpeg, which Moonlight decodes with everywhere, and
//  Moonlight rewrites any SPS it gets to one reference frame. Neither the SPS nor the
//  encoder's properties (ReferenceBufferCount, EnableLTR: ignored) mend it, so its slices
//  are rewritten instead (see H264OneReference). It is used only when the settings ask for
//  it (`lowLatency`). Asking the encoder to complete a frame would also bring it out at
//  once, but starts the next afresh as a keyframe.
//
//  What differs between codecs is kept in VideoCodec: the encoder's type and profile, how
//  a NAL unit names its type, and the order of the parameter sets. A Mac 2017 or later
//  encodes HEVC in hardware; none encodes AV1 (Apple's media engines only decode it), so
//  it has no case. The Intel test Mac's HEVC encoder has no low-latency rate control.
//

import CoreMedia
import Foundation
import VideoToolbox
import os.log

private let veLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightVideo")

enum MoonlightVideoError: Error {
    case session(OSStatus)
}

/// A codec the Mac's video encoder makes, as Annex B NAL units.
enum VideoCodec: String, CaseIterable {
    /// H.264 High.
    case h264
    /// HEVC Main: 8-bit 4:2:0.
    case hevc

    var name: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    var profileLevel: CFString {
        switch self {
        case .h264: return kVTProfileLevel_H264_High_AutoLevel
        case .hevc: return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }

    /// The type of a NAL unit whose header starts with `byte`.
    func nalType(_ byte: UInt8) -> Int {
        switch self {
        case .h264: return Int(byte & 0x1F)
        case .hevc: return Int(byte >> 1 & 0x3F)
        }
    }

    /// The parameter sets' NAL unit types, in the order a keyframe carries them: SPS and
    /// PPS, with HEVC's VPS before them.
    var parameterSetTypes: [Int] {
        switch self {
        case .h264: return [7, 8]
        case .hevc: return [32, 33, 34]
        }
    }

    /// Moonlight's bit for it in ServerCodecModeSupport (SCM_H264, SCM_HEVC).
    var moonlightCodecMode: Int {
        switch self {
        case .h264: return 0x0001
        case .hevc: return 0x0100
        }
    }

    /// What Moonlight's ANNOUNCE calls it (x-nv-vqos[0].bitStreamFormat).
    var moonlightFormat: Int {
        switch self {
        case .h264: return 0
        case .hevc: return 1
        }
    }

    init?(moonlightFormat: Int) {
        guard let codec = Self.allCases.first(where: { $0.moonlightFormat == moonlightFormat }) else { return nil }
        self = codec
    }

    /// What this Mac's encoder does with a codec.
    struct Support: Equatable {
        /// Whether it encodes it on the GPU's media engine.
        var hardware: Bool
        /// Whether it takes low-latency rate control for it (see the top of the file).
        var lowLatency: Bool
        /// Whether it makes HEVC Main10 in hardware, as HDR10 needs.
        var main10 = false
    }

    /// What this Mac's encoder does with each codec, found the first time it is asked by
    /// making a session of each, which takes a few milliseconds.
    static let support: [VideoCodec: Support] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.probe()) })

    private func probe() -> Support {
        func makes(lowLatency: Bool, profile: CFString? = nil) -> Bool {
            var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: codecType,
                                                    encoderSpecification: specification as CFDictionary,
                                                    imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                    outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            guard status == noErr, let session else { return false }
            defer { VTCompressionSessionInvalidate(session) }
            return profile.map { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: $0) == noErr } ?? true
        }
        let support = Support(hardware: makes(lowLatency: false), lowLatency: makes(lowLatency: true),
                              main10: self == .hevc && makes(lowLatency: false, profile: kVTProfileLevel_HEVC_Main10_AutoLevel))
        veLog.debug("\(name, privacy: .public): hardware \(support.hardware), low-latency \(support.lowLatency), main10 \(support.main10)")
        return support
    }

    /// How a codec's hardware encoder does at 1080p as a stream has it (real time, without
    /// reordering), which no property tells: a session may take MaxFrameDelayCount and still
    /// hold a frame, as H.264's does on the Intel test Mac.
    struct Performance: Codable, Equatable {
        /// Frames a second it encodes, given one after another as fast as it takes them.
        var framesPerSecond: Double
        /// Pictures the plain encoder takes before it hands the first back: 0 where each
        /// comes out on its own; on the Intel test Mac 1 for H.264 and 2 for HEVC.
        var heldFrames: Int
    }

    /// Each hardware encoder's performance, found the first time it is asked: measured once
    /// for the Mac as it is (see `fingerprint`), which takes about a second on the Intel test
    /// Mac, and kept, to be measured again only when that changes. None for a codec without one.
    static let performance = kept(for: fingerprint, in: .dam) { measureAll() }

    /// The performance kept in `defaults` for `fingerprint`, or else what `measuring` finds,
    /// kept for it in place of any other; nothing is kept when it finds nothing.
    static func kept(for fingerprint: String, in defaults: UserDefaults,
                     measuring: () -> [VideoCodec: Performance]?) -> [VideoCodec: Performance] {
        if let data = defaults.data(forKey: performanceKey),
           let saved = try? JSONDecoder().decode(KeptPerformance.self, from: data), saved.fingerprint == fingerprint {
            return Dictionary(uniqueKeysWithValues: saved.codecs.compactMap { name, performance in
                VideoCodec(rawValue: name).map { ($0, performance) }
            })
        }
        guard let measured = measuring() else { return [:] }
        let kept = KeptPerformance(fingerprint: fingerprint,
                                   codecs: Dictionary(uniqueKeysWithValues: measured.map { ($0.key.rawValue, $0.value) }))
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: performanceKey) }
        return measured
    }

    private struct KeptPerformance: Codable {
        let fingerprint: String
        let codecs: [String: Performance]
    }
    private static let performanceKey = "\(AppIdentity.shortID).encoderPerformance"

    /// What a measurement holds for: the Mac's model, the macOS build its encoders come with,
    /// and the encoders VideoToolbox lists, which another GPU would change.
    static var fingerprint: String {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "" }
            return String(cString: value)
        }
        var list: CFArray?
        VTCopyVideoEncoderList(nil, &list)
        let encoders = ((list as? [[String: Any]]) ?? []).compactMap { $0[kVTVideoEncoderList_EncoderID as String] as? String }
        return ([sysctl("hw.model"), sysctl("kern.osversion")] + encoders.sorted()).joined(separator: " ")
    }

    /// Every hardware encoder measured, or nil when one of them couldn't be, so that a
    /// failure isn't kept.
    private static func measureAll() -> [VideoCodec: Performance]? {
        var measured: [VideoCodec: Performance] = [:]
        for codec in allCases where support[codec]?.hardware == true {
            guard let performance = codec.measure() else {
                veLog.error("\(codec.name, privacy: .public) encoder could not be measured")
                return nil
            }
            veLog.debug("\(codec.name, privacy: .public) at 1080p: \(performance.framesPerSecond, format: .fixed(precision: 0)) frames a second, \(performance.heldFrames) held")
            measured[codec] = performance
        }
        return measured
    }

    private func measure() -> Performance? {
        let width = 1920, height = 1080
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
                                         encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr,
              let session = made, let pictures = Self.testPictures(width: width, height: height) else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: profileLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_AverageBitRate: 20_000_000,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)

        let lock = NSLock()
        var encoded = 0
        let came = DispatchSemaphore(value: 0)
        var time = 0
        func submit() -> Bool {
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pictures[time % pictures.count],
                presentationTimeStamp: CMTime(value: CMTimeValue(time), timescale: 60), duration: .invalid,
                frameProperties: nil, infoFlagsOut: nil) { status, flags, sample in
                    if status == noErr, !flags.contains(.frameDropped), sample != nil {
                        lock.lock(); encoded += 1; lock.unlock()
                    }
                    came.signal()
                }
            time += 1
            return status == noErr
        }
        // Pictures given a few frames' time apart until the first comes back.
        var held = 0
        while held < 4 {
            guard submit() else { return nil }
            if came.wait(timeout: .now() + .milliseconds(50)) == .success { break }
            held += 1
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        // Then as fast as it takes them.
        lock.lock(); let before = encoded; lock.unlock()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<30 { guard submit() else { return nil } }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        lock.lock(); let frames = encoded - before; lock.unlock()
        return Performance(framesPerSecond: Double(frames) / max(seconds, 0.001), heldFrames: held)
    }

    /// A few 4:2:0 pictures, each different, with detail across them for an encoder to work
    /// at: one row of a random walk, laid on every row at another offset.
    private static func testPictures(width: Int, height: Int) -> [CVPixelBuffer]? {
        let period = width * 2
        var walk = [UInt8](repeating: 128, count: period + width)
        var seed: UInt32 = 12345
        for index in walk.indices.dropFirst() {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            walk[index] = walk[index - 1] &+ UInt8(truncatingIfNeeded: seed >> 28) &- 8
        }
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
        var pictures: [CVPixelBuffer] = []
        for picture in 0..<4 {
            var made: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      attributes, &made) == kCVReturnSuccess, let buffer = made else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    let offset = (row * 7919 + picture * 104_729) % period
                    _ = walk.withUnsafeBytes { memcpy(base + row * stride, $0.baseAddress! + offset, min(stride, width)) }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            pictures.append(buffer)
        }
        return pictures
    }
}

final class MoonlightVideoEncoder {

    struct Settings: Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var bitrateKbps: Int
        var codec = VideoCodec.h264
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
        /// HDR10 with this metadata, for HEVC: Main10 in BT.2020 with PQ, frames given in a
        /// 10-bit format tagged so (see MoonlightScreenCapture); nil for SDR.
        var hdr: MoonlightHDRMetadata?
    }

    /// One encoded frame as an Annex B access unit; a keyframe starts with its parameter
    /// sets (SPS and PPS, and for HEVC the VPS before them).
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
    /// Frames given to the encoder and not yet handed back, not counting pictures given
    /// again to nudge them out; under `lock`.
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
                                                height: Int32(settings.height), codecType: settings.codec.codecType,
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
        // HEVC's references are named in each slice, which Moonlight leaves alone.
        oneReference = lowLatency && settings.codec == .h264 ? H264OneReference() : nil
        var hardware: CFBoolean?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &hardware)
        isHardware = (hardware as? Bool) ?? false

        let keyFrameSeconds = settings.keyFrameInterval > 0 ? settings.keyFrameInterval : 3600
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: settings.reordering,
            kVTCompressionPropertyKey_ProfileLevel: settings.codec.profileLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.fps,
            // Keyframes only when asked for (Moonlight asks after losing packets), an hour
            // apart otherwise, unless the settings want them regularly.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: settings.fps * keyFrameSeconds,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyFrameSeconds,
        ]
        switch settings.codec {
        case .h264: properties[kVTCompressionPropertyKey_H264EntropyMode] = kVTH264EntropyMode_CABAC
        // Every keyframe one a decoder can start from, with nothing after it predicted from before it.
        case .hevc: properties[kVTCompressionPropertyKey_AllowOpenGOP] = false
        }
        if let hdr = settings.hdr, settings.codec == .hevc {
            // Written into the SPS and SEI, which Moonlight's decoders take the picture's colour from.
            properties[kVTCompressionPropertyKey_ProfileLevel] = kVTProfileLevel_HEVC_Main10_AutoLevel
            properties[kVTCompressionPropertyKey_ColorPrimaries] = kCVImageBufferColorPrimaries_ITU_R_2020
            properties[kVTCompressionPropertyKey_TransferFunction] = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            properties[kVTCompressionPropertyKey_YCbCrMatrix] = kCVImageBufferYCbCrMatrix_ITU_R_2020
            properties[kVTCompressionPropertyKey_MasteringDisplayColorVolume] = hdr.masteringDisplayColorVolume as CFData
            properties[kVTCompressionPropertyKey_ContentLightLevelInfo] = hdr.contentLightLevel as CFData
        }
        properties.merge(Self.rateProperties(settings.bitrateKbps, settings)) { $1 }
        // Without reordering, no frame is held back for one that follows.
        if !settings.reordering { properties[kVTCompressionPropertyKey_MaxFrameDelayCount] = 0 }
        if settings.prioritizeSpeed { properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] = true }
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if status != noErr { veLog.debug("encoder property \(key as String, privacy: .public): \(status)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        veLog.debug("encoder \(settings.codec.name, privacy: .public)\(settings.hdr != nil ? " HDR10" : "", privacy: .public) \(settings.width)×\(settings.height)@\(settings.fps) \(settings.bitrateKbps) kbps, hardware \(self.isHardware), low-latency \(self.isLowLatency)")
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
            nudge(after: submissions)
        }
    }

    /// Gives the encoder the last picture again a nudge's delay from now, unless another
    /// was given meanwhile, for as long as a frame given to it is still held: once for an
    /// encoder that holds one frame, as H.264's does, and twice for one that holds two, as
    /// HEVC's does on the Intel test Mac.
    private func nudge(after generation: Int) {
        queue.asyncAfter(deadline: .now() + nudgeDelay) { [weak self] in
            guard let self, self.submissions == generation, let last = self.lastBuffer else { return }
            self.lock.lock()
            let held = self.pending > 0
            self.lock.unlock()
            guard held, self.submit(last, at: self.lastTime, keyFrame: false, counted: false) else { return }
            self.nudge(after: self.submissions)
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
        if counted {
            lock.lock()
            pending += 1
            lock.unlock()
        }
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: rising,
                                                     duration: .invalid, frameProperties: options,
                                                     infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self else { return }
            if counted {
                self.lock.lock()
                self.pending -= 1
                self.lock.unlock()
            }
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
            if counted {
                lock.lock()
                pending -= 1
                dropped += 1
                lock.unlock()
            }
            return false
        }
        return true
    }

    /// Whether `sample` is a keyframe.
    static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// The parameter sets in `sample`'s format description, in the order a keyframe carries
    /// them (see VideoCodec), and the size of the length before each NAL unit in its data.
    static func parameterSets(_ sample: CMSampleBuffer) -> (sets: [Data], lengthSize: Int)? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let codec: VideoCodec = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC ? .hevc : .h264
        let parameterSet = codec == .hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
                                          : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        var count = 0
        var lengthSize: Int32 = 4
        _ = parameterSet(format, 0, nil, nil, &count, &lengthSize)
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard parameterSet(format, index, &pointer, &size, nil, nil) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        // Each in its place; any other kept after them, as HEVC's format may hold an SEI.
        let order = codec.parameterSetTypes
        sets.sort { (order.firstIndex(of: codec.nalType($0.first ?? 0)) ?? order.count) <
                    (order.firstIndex(of: codec.nalType($1.first ?? 0)) ?? order.count) }
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
