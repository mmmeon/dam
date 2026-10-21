import XCTest
@testable import DAM

final class MP4FragmenterTests: XCTestCase {

    /// A box: its type and payload (after the size and type).
    private struct Box {
        let type: String
        let payload: Data
        var size: Int { payload.count + 8 }
        /// The boxes in the payload, from `offset` in.
        func children(from offset: Int = 0) -> [Box] { MP4FragmenterTests.boxes(in: payload[(payload.startIndex + offset)...]) }
        func child(_ type: String) -> Box? { children().first { $0.type == type } }
        func u32(_ at: Int) -> UInt32 {
            payload[(payload.startIndex + at)..<(payload.startIndex + at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u64(_ at: Int) -> UInt64 {
            payload[(payload.startIndex + at)..<(payload.startIndex + at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }
    }

    private static func boxes(in data: Data) -> [Box] {
        var boxes: [Box] = []
        var index = data.startIndex
        while index + 8 <= data.endIndex {
            let size = Int(data[index..<(index + 4)].reduce(0) { $0 << 8 | UInt32($1) })
            let type = String(decoding: data[(index + 4)..<(index + 8)], as: UTF8.self)
            guard size >= 8, index + size <= data.endIndex else { XCTFail("bad box \(type) of \(size) at \(index)"); break }
            boxes.append(Box(type: type, payload: data[(index + 8)..<(index + size)]))
            index += size
        }
        return boxes
    }

    private let sps = Data([0x67, 0x64, 0x00, 0x33, 0xAC, 0x13])
    private let pps = Data([0x68, 0xEE, 0x1F, 0x2C])
    private var video: MP4Fragmenter.VideoConfig { .init(width: 1920, height: 1080, sps: [sps], pps: [pps]) }

    // Full boxes: the version and flags take the first 4 bytes of the payload.

    func testInitSegmentHasTheTracksAndTheirCodecSettings() throws {
        let segment = MP4Fragmenter().initSegment(video: video, audio: true)
        let top = Self.boxes(in: segment)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(segment.count, top.reduce(0) { $0 + $1.size }, "nothing outside the boxes")
        XCTAssertEqual(String(decoding: top[0].payload.prefix(4), as: UTF8.self), "isom")

        let moov = top[1]
        XCTAssertEqual(moov.children().map(\.type), ["mvhd", "trak", "trak", "mvex"])
        XCTAssertEqual(try XCTUnwrap(moov.child("mvhd")).u32(4 + 8), 1000, "movie timescale")
        XCTAssertEqual(try XCTUnwrap(moov.child("mvex")).children().map(\.type), ["trex", "trex"])

        let traks = moov.children().filter { $0.type == "trak" }
        let videoTrak = traks[0]
        XCTAssertEqual(try XCTUnwrap(videoTrak.child("tkhd")).u32(4 + 8), 1, "track 1")
        let videoMedia = try XCTUnwrap(videoTrak.child("mdia"))
        XCTAssertEqual(try XCTUnwrap(videoMedia.child("mdhd")).u32(4 + 8), 90_000)
        let stbl = try XCTUnwrap(videoMedia.child("minf")?.child("stbl"))
        XCTAssertEqual(stbl.children().map(\.type), ["stsd", "stts", "stsc", "stsz", "stco"])
        let avc1 = try XCTUnwrap(stbl.child("stsd")?.children(from: 8).first)
        XCTAssertEqual(avc1.type, "avc1")
        XCTAssertEqual(avc1.u32(24) >> 16, 1920)
        XCTAssertEqual(avc1.u32(24) & 0xFFFF, 1080)
        let avcC = try XCTUnwrap(avc1.children(from: 78).first { $0.type == "avcC" })
        XCTAssertEqual([UInt8](avcC.payload.prefix(6)), [1, 0x64, 0x00, 0x33, 0xFF, 0xE1], "profile, level, 4-byte lengths, one SPS")
        XCTAssertNotNil(avcC.payload.range(of: sps))
        XCTAssertNotNil(avcC.payload.range(of: pps))

        let audioTrak = traks[1]
        XCTAssertEqual(try XCTUnwrap(audioTrak.child("tkhd")).u32(4 + 8), 2, "track 2")
        let audioMedia = try XCTUnwrap(audioTrak.child("mdia"))
        XCTAssertEqual(try XCTUnwrap(audioMedia.child("mdhd")).u32(4 + 8), 48_000)
        let mp4a = try XCTUnwrap(audioMedia.child("minf")?.child("stbl")?.child("stsd")?.children(from: 8).first)
        XCTAssertEqual(mp4a.type, "mp4a")
        let esds = try XCTUnwrap(mp4a.children(from: 28).first { $0.type == "esds" })
        XCTAssertNotNil(esds.payload.range(of: Data([0x05, 0x02, 0x11, 0x90])), "AAC LC, 48 kHz, stereo")
    }

    func testInitSegmentWithoutSoundHasOneTrack() throws {
        let moov = try XCTUnwrap(Self.boxes(in: MP4Fragmenter().initSegment(video: video, audio: false)).last)
        XCTAssertEqual(moov.children().map(\.type), ["mvhd", "trak", "mvex"])
        XCTAssertEqual(try XCTUnwrap(moov.child("mvex")).children().count, 1)
    }

    func testVideoFragmentPointsAtItsSample() throws {
        let fragmenter = MP4Fragmenter()
        let sample = Data([0, 0, 0, 3, 0x65, 0x88, 0x84])
        let fragment = fragmenter.videoFragment(sample, decodeTime: 180_000, duration: 1500, keyFrame: true)
        let top = Self.boxes(in: fragment)
        XCTAssertEqual(top.map(\.type), ["moof", "mdat"])
        let moof = top[0]
        XCTAssertEqual(try XCTUnwrap(moof.child("mfhd")).u32(4), 1, "first fragment")
        let traf = try XCTUnwrap(moof.child("traf"))
        XCTAssertEqual(traf.children().map(\.type), ["tfhd", "tfdt", "trun"])
        XCTAssertEqual(try XCTUnwrap(traf.child("tfhd")).u32(4), 1, "video track")
        XCTAssertEqual(try XCTUnwrap(traf.child("tfdt")).u64(4), 180_000)
        let trun = try XCTUnwrap(traf.child("trun"))
        XCTAssertEqual(trun.u32(0) & 0xFFFFFF, 0x000701, "data offset and each sample's duration, size and flags")
        XCTAssertEqual(trun.u32(4), 1, "one sample")
        XCTAssertEqual(Int(trun.u32(8)), moof.size + 8, "the sample starts right after mdat's header")
        XCTAssertEqual(trun.u32(12), 1500)
        XCTAssertEqual(Int(trun.u32(16)), sample.count)
        XCTAssertEqual(trun.u32(20), 0x0200_0000, "a keyframe depends on nothing")
        XCTAssertEqual(top[1].payload, sample)

        let next = fragmenter.videoFragment(sample, decodeTime: 181_500, duration: 1500, keyFrame: false)
        let nextMoof = try XCTUnwrap(Self.boxes(in: next).first)
        XCTAssertEqual(try XCTUnwrap(nextMoof.child("mfhd")).u32(4), 2)
        XCTAssertEqual(try XCTUnwrap(nextMoof.child("traf")?.child("trun")).u32(20), 0x0101_0000, "depends on another, not sync")
    }

    func testFrameShownLaterThanDecodedCarriesTheOffset() throws {
        let fragment = MP4Fragmenter().videoFragment(Data([0, 0, 0, 1, 0x41]), decodeTime: 0, duration: 1500,
                                                     compositionOffset: 3000, keyFrame: false)
        let trun = try XCTUnwrap(Self.boxes(in: fragment).first?.child("traf")?.child("trun"))
        XCTAssertEqual(trun.payload[trun.payload.startIndex], 1, "version 1: signed offsets")
        XCTAssertEqual(trun.u32(0) & 0xFFFFFF, 0x000701 | 0x000800)
        XCTAssertEqual(trun.u32(24), 3000)
        XCTAssertEqual(Int(trun.u32(8)), Self.boxes(in: fragment)[0].size + 8)
    }

    func testAudioFragmentHoldsEveryPacket() throws {
        let packets = [Data(repeating: 1, count: 300), Data(repeating: 2, count: 310), Data(repeating: 3, count: 290)]
        let fragment = MP4Fragmenter().audioFragment(packets, decodeTime: 48_000)
        let top = Self.boxes(in: fragment)
        let traf = try XCTUnwrap(top[0].child("traf"))
        XCTAssertEqual(try XCTUnwrap(traf.child("tfhd")).u32(4), 2, "sound track")
        XCTAssertEqual(try XCTUnwrap(traf.child("tfdt")).u64(4), 48_000)
        let trun = try XCTUnwrap(traf.child("trun"))
        XCTAssertEqual(trun.u32(4), 3)
        for (index, packet) in packets.enumerated() {
            XCTAssertEqual(trun.u32(12 + index * 12), 1024, "a packet's samples")
            XCTAssertEqual(Int(trun.u32(16 + index * 12)), packet.count)
        }
        XCTAssertEqual(top[1].payload, packets.reduce(Data(), +))
    }

    func testCodecsNameTheProfileInTheSPS() {
        XCTAssertEqual(MP4Fragmenter.codecs(sps: sps, audio: true), "avc1.640033,mp4a.40.2")
        XCTAssertEqual(MP4Fragmenter.codecs(sps: sps, audio: false), "avc1.640033")
    }
}
