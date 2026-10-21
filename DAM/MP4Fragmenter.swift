//
//  MP4Fragmenter.swift
//
//  Puts H.264 frames and AAC packets in fragmented MP4, the form browsers take through
//  Media Source Extensions and players read as a live file: one segment up front with the
//  movie's tracks and codec settings and no samples, then a fragment (moof and mdat) per
//  frame, handed on as it is made, so a client is never waiting for a segment to fill.
//  Video is on track 1 at 90 kHz, sound on track 2 at 48 kHz; decode times count from
//  whatever zero the caller picks, and must only rise within each track.
//

import Foundation

final class MP4Fragmenter {

    /// What the video track is made of; the parameter sets go in the init segment's avcC box.
    struct VideoConfig: Equatable {
        var width: Int
        var height: Int
        var sps: [Data]
        var pps: [Data]
    }

    static let videoTimescale = 90_000
    static let audioTimescale = 48_000
    /// Samples in each AAC packet.
    static let aacFrameLength = 1024
    static let videoTrack: UInt32 = 1
    static let audioTrack: UInt32 = 2

    /// Fragments are numbered from 1 across both tracks.
    private var sequence: UInt32 = 0

    /// The codec string MSE wants for the video track: avc1 and the SPS's profile, constraints and level.
    static func codecs(sps: Data, audio: Bool) -> String {
        let bytes = [UInt8](sps.prefix(4))
        let profile = bytes.count == 4 ? String(format: "%02X%02X%02X", bytes[1], bytes[2], bytes[3]) : "640028"
        return "avc1.\(profile)" + (audio ? ",mp4a.40.2" : "")
    }

    // MARK: - Init segment

    /// The movie's header: file type, the tracks, and that samples follow in fragments.
    func initSegment(video: VideoConfig, audio: Bool) -> Data {
        var brands = Data("isom".utf8) + Self.u32(0x200)
        brands += Data("isomiso5iso6avc1mp41".utf8)
        let ftyp = Self.box("ftyp", brands)
        var traks = Self.videoTrak(video)
        if audio { traks += Self.audioTrak() }
        var trex = Self.trex(track: Self.videoTrack)
        if audio { trex += Self.trex(track: Self.audioTrack) }
        var movie = Self.mvhd(nextTrack: audio ? 3 : 2) + traks
        movie += Self.box("mvex", trex)
        let moov = Self.box("moov", movie)
        return ftyp + moov
    }

    // MARK: - Fragments

    /// One frame as a fragment. `sample` is the access unit with 4-byte length prefixes;
    /// `decodeTime` and `duration` in 90 kHz; `compositionOffset` is how much later than
    /// its decode time the frame shows, for streams with frames out of order.
    func videoFragment(_ sample: Data, decodeTime: Int64, duration: Int, compositionOffset: Int = 0,
                       keyFrame: Bool) -> Data {
        let flags: UInt32 = keyFrame ? 0x0200_0000 : 0x0101_0000
        return fragment(track: Self.videoTrack, decodeTime: decodeTime,
                        samples: [(data: sample, duration: duration, flags: flags, offset: compositionOffset)])
    }

    /// AAC packets, one sample each of `aacFrameLength` samples, from `decodeTime` in 48 kHz.
    func audioFragment(_ packets: [Data], decodeTime: Int64) -> Data {
        fragment(track: Self.audioTrack, decodeTime: decodeTime,
                 samples: packets.map { (data: $0, duration: Self.aacFrameLength, flags: 0x0200_0000, offset: 0) })
    }

    private func fragment(track: UInt32, decodeTime: Int64,
                          samples: [(data: Data, duration: Int, flags: UInt32, offset: Int)]) -> Data {
        sequence &+= 1
        let withOffsets = samples.contains { $0.offset != 0 }
        // tfhd: default-base-is-moof, so data offsets count from the moof's start.
        let tfhd = Self.fullBox("tfhd", version: 0, flags: 0x020000, Self.u32(track))
        let tfdt = Self.fullBox("tfdt", version: 1, flags: 0, Self.u64(UInt64(max(decodeTime, 0))))
        // trun: data offset, and each sample's duration, size and flags (and offset).
        let trunFlags: UInt32 = 0x000001 | 0x000100 | 0x000200 | 0x000400 | (withOffsets ? 0x000800 : 0)
        let entrySize = withOffsets ? 16 : 12
        let trunSize = 12 + 4 + 4 + samples.count * entrySize
        let trafSize = 8 + tfhd.count + tfdt.count + trunSize
        let moofSize = 8 + 16 + trafSize
        var trun = Data()
        trun += Self.u32(UInt32(samples.count))
        trun += Self.u32(UInt32(moofSize + 8))
        for sample in samples {
            trun += Self.u32(UInt32(sample.duration))
            trun += Self.u32(UInt32(sample.data.count))
            trun += Self.u32(sample.flags)
            if withOffsets { trun += Self.u32(UInt32(bitPattern: Int32(sample.offset))) }
        }
        let trunBox = Self.fullBox("trun", version: withOffsets ? 1 : 0, flags: trunFlags, trun)
        let traf = Self.box("traf", tfhd + tfdt + trunBox)
        let mfhd = Self.fullBox("mfhd", version: 0, flags: 0, Self.u32(sequence))
        let moof = Self.box("moof", mfhd + traf)
        assert(moof.count == moofSize)
        var payload = Data()
        for sample in samples { payload += sample.data }
        return moof + Self.box("mdat", payload)
    }

    // MARK: - Tracks

    private static func mvhd(nextTrack: UInt32) -> Data {
        var body = Data()
        body += u32(0) + u32(0)                 // created, modified
        body += u32(1000) + u32(0)              // timescale, duration: unknown
        body += u32(0x0001_0000) + u16(0x0100)  // rate, volume
        body += Data(count: 10)
        body += matrix
        body += Data(count: 24)                 // pre_defined
        body += u32(nextTrack)
        return fullBox("mvhd", version: 0, flags: 0, body)
    }

    private static func tkhd(track: UInt32, width: Int, height: Int, volume: UInt16) -> Data {
        var body = Data()
        body += u32(0) + u32(0)                 // created, modified
        body += u32(track) + u32(0) + u32(0)    // ID, reserved, duration
        body += Data(count: 8)
        body += u16(0) + u16(0)                 // layer, alternate group
        body += u16(volume) + u16(0)
        body += matrix
        body += u32(UInt32(width) << 16) + u32(UInt32(height) << 16)
        return fullBox("tkhd", version: 0, flags: 0x7, body)
    }

    private static func mdhd(timescale: Int) -> Data {
        var body = u32(0) + u32(0)
        body += u32(UInt32(timescale)) + u32(0)
        body += u16(0x55C4) + u16(0)   // language: und
        return fullBox("mdhd", version: 0, flags: 0, body)
    }

    private static func hdlr(_ type: String, name: String) -> Data {
        var body = u32(0) + Data(type.utf8)
        body += Data(count: 12)
        body += Data(name.utf8) + Data([0])
        return fullBox("hdlr", version: 0, flags: 0, body)
    }

    private static var dinf: Data {
        let url = fullBox("url ", version: 0, flags: 1, Data())
        return box("dinf", fullBox("dref", version: 0, flags: 0, u32(1) + url))
    }

    /// Empty sample tables: every sample comes in a fragment.
    private static func stbl(entry: Data) -> Data {
        var body = fullBox("stsd", version: 0, flags: 0, u32(1) + entry)
        body += fullBox("stts", version: 0, flags: 0, u32(0))
        body += fullBox("stsc", version: 0, flags: 0, u32(0))
        body += fullBox("stsz", version: 0, flags: 0, u32(0) + u32(0))
        body += fullBox("stco", version: 0, flags: 0, u32(0))
        return box("stbl", body)
    }

    private static func videoTrak(_ video: VideoConfig) -> Data {
        var avc1 = Data()
        avc1 += Data(count: 6) + u16(1)                       // reserved, data reference index
        avc1 += Data(count: 16)                               // pre_defined, reserved
        avc1 += u16(UInt16(video.width)) + u16(UInt16(video.height))
        avc1 += u32(0x0048_0000) + u32(0x0048_0000)           // 72 dpi
        avc1 += u32(0)
        avc1 += u16(1) + Data(count: 32)                      // frame count, compressor name
        avc1 += u16(0x0018) + u16(0xFFFF)                     // depth, pre_defined
        var avcC = Data()
        let sps = video.sps.first ?? Data(count: 4)
        let profile: [UInt8] = (1...3).map { sps.count > $0 ? sps[$0] : 0 }
        avcC += Data([1] + profile)
        avcC += Data([UInt8(0xFF)])                           // 4-byte NAL lengths
        avcC += Data([0xE0 | UInt8(video.sps.count)])
        for set in video.sps { avcC += u16(UInt16(set.count)) + set }
        avcC += Data([UInt8(video.pps.count)])
        for set in video.pps { avcC += u16(UInt16(set.count)) + set }
        avc1 += box("avcC", avcC)
        var minf = fullBox("vmhd", version: 0, flags: 1, Data(count: 8)) + dinf
        minf += stbl(entry: box("avc1", avc1))
        var mdia = mdhd(timescale: videoTimescale) + hdlr("vide", name: "VideoHandler")
        mdia += box("minf", minf)
        return box("trak", tkhd(track: videoTrack, width: video.width, height: video.height, volume: 0) + box("mdia", mdia))
    }

    private static func audioTrak() -> Data {
        var mp4a = Data()
        mp4a += Data(count: 6) + u16(1)                       // reserved, data reference index
        mp4a += Data(count: 8)                                // version, revision, vendor
        mp4a += u16(2) + u16(16)                              // channels, sample size
        mp4a += u16(0) + u16(0)                               // compression ID, packet size
        mp4a += u32(UInt32(audioTimescale) << 16)
        // AudioSpecificConfig: AAC LC, 48 kHz, stereo.
        let config = Data([0x11, 0x90])
        let decoderSpecific = Data([0x05, UInt8(config.count)]) + config
        var decoderConfig = Data([0x40, 0x15, 0, 0, 0])   // AAC, audio stream, buffer size
        decoderConfig += u32(0) + u32(0)                  // bitrates: unknown
        decoderConfig += decoderSpecific
        var descriptor = Data([0x03, UInt8(3 + 2 + decoderConfig.count + 3)])
        descriptor += u16(UInt16(audioTrack)) + Data([0])
        descriptor += Data([0x04, UInt8(decoderConfig.count)]) + decoderConfig
        descriptor += Data([0x06, 1, 0x02])
        mp4a += fullBox("esds", version: 0, flags: 0, descriptor)
        var minf = fullBox("smhd", version: 0, flags: 0, u32(0)) + dinf
        minf += stbl(entry: box("mp4a", mp4a))
        var mdia = mdhd(timescale: audioTimescale) + hdlr("soun", name: "SoundHandler")
        mdia += box("minf", minf)
        return box("trak", tkhd(track: audioTrack, width: 0, height: 0, volume: 0x0100) + box("mdia", mdia))
    }

    private static func trex(track: UInt32) -> Data {
        var body = u32(track) + u32(1)   // default sample description
        body += u32(0) + u32(0) + u32(0)  // default duration, size, flags
        return fullBox("trex", version: 0, flags: 0, body)
    }

    // MARK: - Boxes

    /// The unity transform.
    private static let matrix: Data = {
        var matrix = Data()
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { matrix += u32(value) }
        return matrix
    }()

    static func box(_ type: String, _ body: Data) -> Data {
        u32(UInt32(8 + body.count)) + Data(type.utf8) + body
    }

    static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: Data) -> Data {
        box(type, Data([version, UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)]) + body)
    }

    static func u16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
    static func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(value >> (24 - 8 * $0) & 0xFF) }) }
    static func u64(_ value: UInt64) -> Data { Data((0..<8).map { UInt8(value >> (56 - 8 * $0) & 0xFF) }) }
}
