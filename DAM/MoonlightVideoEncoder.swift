//
//  MoonlightVideoEncoder.swift
//
//  Encodes frames to H.264 for Moonlight with as little delay as the encoder allows: in
//  real time, without reordering frames or holding any back, and with keyframes only when
//  asked for. Frames are handed over through a single slot that a newer frame takes over,
//  and encoded one at a time on a thread of their own, so the caller never waits for the
//  encoder, the next frame encoded is always the latest, and nothing queues up.
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
    /// Whether the encoder takes Apple's low-latency rate control, which not every Mac has.
    let hasLowLatencyRateControl: Bool

    private let session: VTCompressionSession
    private let output: (Frame) -> Void
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.encoder", qos: .userInteractive)
    private let lock = NSLock()
    /// Whether the encoding thread is taking frames from the slot.
    private var busy = false
    private var waiting: (buffer: CVPixelBuffer, time: CMTime)?
    private var keyFrameRequested = true
    /// The last time given to the encoder, which needs them to rise; on the encoding thread.
    private var lastTime = CMTime.negativeInfinity

    /// `output` is called on the encoding thread for each frame, as soon as it is encoded.
    init(settings: Settings, output: @escaping (Frame) -> Void) throws {
        self.settings = settings
        self.output = output
        var made: (VTCompressionSession, Bool)?
        // Low-latency rate control where the encoder takes it, else the plain real-time one.
        for lowLatency in [true, false] {
            var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width),
                                                    height: Int32(settings.height), codecType: kCMVideoCodecType_H264,
                                                    encoderSpecification: specification as CFDictionary,
                                                    imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                    outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            if status == noErr, let session {
                made = (session, lowLatency)
                break
            }
            veLog.debug("encoder with low-latency rate control \(lowLatency): \(status)")
        }
        guard let (session, lowLatency) = made else { throw MoonlightVideoError.session(kVTVideoEncoderNotAvailableNowErr) }
        self.session = session
        hasLowLatencyRateControl = lowLatency
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
        veLog.debug("encoder \(settings.width)×\(settings.height)@\(settings.fps) \(settings.bitrateKbps) kbps, hardware \(self.isHardware), low-latency \(lowLatency)")
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

    /// Encodes frames from the slot until it is empty.
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
            // A picture sent again comes with the time it had; move it past the last one.
            let rising = time > lastTime ? time : CMTimeAdd(lastTime, CMTime(value: 1, timescale: 1000))
            lastTime = rising
            if !encodeNow(buffer, at: rising, keyFrame: key), key { requestKeyFrame() }
        }
    }

    /// Encodes one frame and waits for it, so the encoder holds no more than one.
    private func encodeNow(_ buffer: CVPixelBuffer, at time: CMTime, keyFrame: Bool) -> Bool {
        let options = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let submitted = DispatchTime.now().uptimeNanoseconds
        var encoded = false
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time,
                                                     duration: .invalid, frameProperties: options,
                                                     infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self, status == noErr, !flags.contains(.frameDropped), let sample,
                  let (data, isKeyFrame) = Self.annexB(sample) else {
                veLog.error("encode: \(status)")
                return
            }
            encoded = true
            self.output(Frame(data: data, isKeyFrame: isKeyFrame, time: time, submitted: submitted,
                              encoded: DispatchTime.now().uptimeNanoseconds))
        }
        guard status == noErr else {
            veLog.error("encode frame: \(status)")
            return false
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: time)
        return encoded
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
