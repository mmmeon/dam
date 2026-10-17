//
//  H264OneReference.swift
//
//  Rewrites the slices of Apple's low-latency encoder so that a decoder holding a single
//  reference frame plays them. On an Intel Mac at least, that encoder now and then marks a
//  frame as a long-term reference and has the next frame predict from it by reordering its
//  reference list, while its SPS allows four references. Moonlight rewrites every SPS to
//  one, and FFmpeg, which Moonlight decodes with everywhere (on a Mac too, VideoToolbox
//  doing the work under it), then finds two references where one fits, drops one each
//  frame, and the picture breaks up until the next keyframe.
//
//  The long-term frame predicted from has always been the frame just before: the one a
//  plain reference list starts with anyway. So each slice is rewritten to keep the plain
//  list and mark its frame the plain way (sliding window), and no frame is ever long-term;
//  the pictures decoded stay the same. Whether they do is checked against the encoder's own
//  reference frames, followed from the slices; should a frame predict from any but the one
//  before, `rewrite` says so, for a keyframe to mend the picture.
//

import Foundation

final class H264OneReference {

    private struct SPS {
        var chromaArrayType = 1
        var log2MaxFrameNum = 4
        var pocType = 0
        var log2MaxPocLsb = 4
        var deltaPicOrderAlwaysZero = false
        var maxRefFrames = 1
        var frameMbsOnly = true
    }

    private struct PPS {
        var spsID = 0
        var cabac = false
        var bottomFieldPicOrder = false
        var sliceGroups = 1
        var refIdxL0 = 1
        var refIdxL1 = 1
        var weightedPred = false
        var weightedBipred = 0
        var deblockingControl = false
        var redundantPicCount = false
    }

    private struct Slice {
        var firstMb = 0
        /// slice_type mod 5: 0 P, 1 B, 2 I, 3 SP, 4 SI.
        var type = 0
        var activeRefsL0 = 1
        /// Bits from ref_pic_list_modification_flag_l0 to the end of its operations, when set.
        var modification: Range<Int>?
        var modificationOps: [(op: Int, value: Int)] = []
        /// Bits from adaptive_ref_pic_marking_mode_flag to the end of its operations, when set.
        var marking: Range<Int>?
        var markingOps: [(op: Int, values: [Int])] = []
        var idrLongTerm = false
        /// The bit after the header.
        var end = 0
        var cabac = false
    }

    /// A header that runs past the bytes read, or names a parameter set not seen.
    private struct Unreadable: Error {}

    private var sps: [Int: SPS] = [:]
    private var pps: [Int: PPS] = [:]
    /// The encoder's reference frames as it sees them, each by its count among reference
    /// frames since the last keyframe: short-term ones oldest first, long-term ones by index.
    private var shortTerm: [Int] = []
    private var longTerm: [Int: Int] = [:]
    private var count = 0
    /// Whether every frame since the last keyframe predicted from the frame before it.
    private var clean = true

    /// `units`, one access unit's NAL units without start codes, with its slices rewritten,
    /// and whether the pictures decoded stop being the encoder's at this frame, which
    /// predicts from another than the frame before (or cannot be read): until the next
    /// keyframe, which the caller should ask for, they are not.
    func rewrite(_ units: [Data]) -> (units: [Data], broken: Bool) {
        let wasClean = clean
        var out: [Data] = []
        var frameDone = false
        for unit in units {
            guard let first = unit.first else { out.append(unit); continue }
            let type = Int(first & 0x1F)
            let reference = first >> 5 != 0
            do {
                switch type {
                case 7: try parseSPS(Self.unescape(unit))
                case 8: try parsePPS(Self.unescape(unit))
                case 1, 5:
                    var rbsp = Self.unescape(unit.prefix(64))
                    var slice: Slice
                    do {
                        slice = try parseSlice(rbsp, idr: type == 5, reference: reference)
                    } catch is Unreadable {
                        rbsp = Self.unescape(unit)
                        slice = try parseSlice(rbsp, idr: type == 5, reference: reference)
                    }
                    if !frameDone {
                        frameDone = true
                        follow(slice, idr: type == 5, reference: reference)
                    }
                    if slice.modification != nil || slice.marking != nil, slice.cabac {
                        out.append(Self.rewritten(unit, slice))
                        continue
                    }
                    if slice.modification != nil || slice.marking != nil { clean = false }
                default: break
                }
            } catch {
                clean = false
            }
            out.append(unit)
        }
        return (out, wasClean && !clean)
    }

    // MARK: The encoder's reference frames

    /// Follows the encoder's reference frames through the first slice of a frame, and
    /// whether the frame predicts from the one before.
    private func follow(_ slice: Slice, idr: Bool, reference: Bool) {
        if idr {
            shortTerm = []
            longTerm = [:]
            count = 0
            clean = true
        } else if slice.type != 2 && slice.type != 4 {
            if slice.activeRefsL0 != 1 || slice.type == 1 { clean = false }
            var predictedFrom: Int?
            if let op = slice.modificationOps.first {
                switch op.op {
                case 0: predictedFrom = count - (op.value + 1)
                case 2: predictedFrom = longTerm[op.value]
                default: predictedFrom = nil
                }
            } else {
                predictedFrom = shortTerm.last ?? longTerm.min { $0.key < $1.key }?.value
            }
            if predictedFrom != count - 1 { clean = false }
        }
        guard reference else { return }
        let current = count
        count += 1
        if idr {
            if slice.idrLongTerm { longTerm[0] = current; clean = false } else { shortTerm = [current] }
            return
        }
        if slice.marking == nil {
            let maxRefs = sps.values.first?.maxRefFrames ?? 1
            if shortTerm.count + longTerm.count >= max(maxRefs, 1), !shortTerm.isEmpty { shortTerm.removeFirst() }
            shortTerm.append(current)
            return
        }
        var markedLongTerm = false
        for op in slice.markingOps {
            switch op.op {
            case 1: shortTerm.removeAll { $0 == current - (op.values[0] + 1) }
            case 2: longTerm.removeValue(forKey: op.values[0])
            case 3:
                let frame = current - (op.values[0] + 1)
                shortTerm.removeAll { $0 == frame }
                longTerm[op.values[1]] = frame
            case 4: longTerm = longTerm.filter { $0.key < op.values[0] }
            case 5: shortTerm = []; longTerm = [:]
            case 6: longTerm[op.values[0]] = current; markedLongTerm = true
            default: break
            }
        }
        if !markedLongTerm { shortTerm.append(current) }
    }

    // MARK: Parsing

    private func parseSPS(_ rbsp: [UInt8]) throws {
        var bits = BitReader(rbsp, from: 8)
        let profile = try bits.u(8)
        _ = try bits.u(16)
        let id = try bits.ue()
        var s = SPS()
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = try bits.ue()
            if chroma == 3 { s.chromaArrayType = try bits.u(1) == 1 ? 0 : 3 } else { s.chromaArrayType = chroma }
            _ = try bits.ue(); _ = try bits.ue(); _ = try bits.u(1)
            if try bits.u(1) == 1 {
                for list in 0..<(chroma != 3 ? 8 : 12) where try bits.u(1) == 1 {
                    var last = 8, next = 8
                    for _ in 0..<(list < 6 ? 16 : 64) {
                        if next != 0 { next = (last + (try bits.se()) + 256) % 256 }
                        if next != 0 { last = next }
                    }
                }
            }
        }
        s.log2MaxFrameNum = try bits.ue() + 4
        s.pocType = try bits.ue()
        if s.pocType == 0 {
            s.log2MaxPocLsb = try bits.ue() + 4
        } else if s.pocType == 1 {
            s.deltaPicOrderAlwaysZero = try bits.u(1) == 1
            _ = try bits.se(); _ = try bits.se()
            for _ in 0..<(try bits.ue()) { _ = try bits.se() }
        }
        s.maxRefFrames = try bits.ue()
        _ = try bits.u(1)
        _ = try bits.ue(); _ = try bits.ue()
        s.frameMbsOnly = try bits.u(1) == 1
        sps[id] = s
    }

    private func parsePPS(_ rbsp: [UInt8]) throws {
        var bits = BitReader(rbsp, from: 8)
        let id = try bits.ue()
        var p = PPS()
        p.spsID = try bits.ue()
        p.cabac = try bits.u(1) == 1
        p.bottomFieldPicOrder = try bits.u(1) == 1
        p.sliceGroups = try bits.ue() + 1
        // Slice groups are left alone (see parseSlice), so their map need not be read.
        guard p.sliceGroups == 1 else { pps[id] = p; return }
        p.refIdxL0 = try bits.ue() + 1
        p.refIdxL1 = try bits.ue() + 1
        p.weightedPred = try bits.u(1) == 1
        p.weightedBipred = try bits.u(2)
        _ = try bits.se(); _ = try bits.se(); _ = try bits.se()
        p.deblockingControl = try bits.u(1) == 1
        _ = try bits.u(1)
        p.redundantPicCount = try bits.u(1) == 1
        pps[id] = p
    }

    private func parseSlice(_ rbsp: [UInt8], idr: Bool, reference: Bool) throws -> Slice {
        var bits = BitReader(rbsp, from: 8)
        var slice = Slice()
        slice.firstMb = try bits.ue()
        slice.type = try bits.ue() % 5
        guard let p = pps[try bits.ue()], let s = sps[p.spsID], p.sliceGroups == 1 else { throw Unreadable() }
        slice.cabac = p.cabac
        _ = try bits.u(s.log2MaxFrameNum)
        var field = false
        if !s.frameMbsOnly, try bits.u(1) == 1 { field = true; _ = try bits.u(1) }
        if idr { _ = try bits.ue() }
        if s.pocType == 0 {
            _ = try bits.u(s.log2MaxPocLsb)
            if p.bottomFieldPicOrder && !field { _ = try bits.se() }
        } else if s.pocType == 1 && !s.deltaPicOrderAlwaysZero {
            _ = try bits.se()
            if p.bottomFieldPicOrder && !field { _ = try bits.se() }
        }
        if p.redundantPicCount { _ = try bits.ue() }
        let b = slice.type == 1
        if b { _ = try bits.u(1) }
        slice.activeRefsL0 = p.refIdxL0
        var activeRefsL1 = p.refIdxL1
        if slice.type == 0 || slice.type == 3 || b, try bits.u(1) == 1 {
            slice.activeRefsL0 = try bits.ue() + 1
            if b { activeRefsL1 = try bits.ue() + 1 }
        }
        if slice.type != 2 && slice.type != 4 {
            let start = bits.position
            if try bits.u(1) == 1 {
                while true {
                    let op = try bits.ue()
                    if op == 3 { break }
                    slice.modificationOps.append((op, try bits.ue()))
                }
                slice.modification = start..<bits.position
            }
            if b, try bits.u(1) == 1 {
                // Only list 0 is rewritten; a B slice is never clean anyway (see follow).
                while try bits.ue() != 3 { _ = try bits.ue() }
            }
        }
        if (p.weightedPred && (slice.type == 0 || slice.type == 3)) || (p.weightedBipred == 1 && b) {
            _ = try bits.ue()
            if s.chromaArrayType != 0 { _ = try bits.ue() }
            for list in 0..<(b ? 2 : 1) {
                for _ in 0..<(list == 0 ? slice.activeRefsL0 : activeRefsL1) {
                    if try bits.u(1) == 1 { _ = try bits.se(); _ = try bits.se() }
                    if s.chromaArrayType != 0, try bits.u(1) == 1 {
                        for _ in 0..<4 { _ = try bits.se() }
                    }
                }
            }
        }
        if reference {
            if idr {
                _ = try bits.u(1)
                slice.idrLongTerm = try bits.u(1) == 1
            } else {
                let start = bits.position
                if try bits.u(1) == 1 {
                    while true {
                        let op = try bits.ue()
                        if op == 0 { break }
                        var values: [Int] = []
                        if op == 1 || op == 3 { values.append(try bits.ue()) }
                        if op == 2 { values.append(try bits.ue()) }
                        if op == 3 || op == 6 { values.append(try bits.ue()) }
                        if op == 4 { values.append(try bits.ue()) }
                        slice.markingOps.append((op, values))
                    }
                    slice.marking = start..<bits.position
                }
            }
        }
        if p.cabac && slice.type != 2 && slice.type != 4 { _ = try bits.ue() }
        _ = try bits.se()
        if slice.type == 3 || slice.type == 4 {
            if slice.type == 3 { _ = try bits.u(1) }
            _ = try bits.se()
        }
        if p.deblockingControl, try bits.ue() != 1 { _ = try bits.se(); _ = try bits.se() }
        slice.end = bits.position
        return slice
    }

    // MARK: Rewriting

    /// `unit` with its list modification and marking operations taken out of its header,
    /// each flag left as 0. A CABAC slice's data starts on a byte after its header, padded
    /// with 1 bits, so the data is copied as it is after new padding.
    private static func rewritten(_ unit: Data, _ slice: Slice) -> Data {
        let rbsp = unescape(unit)
        var writer = BitWriter()
        var position = 0
        for range in [slice.modification, slice.marking].compactMap({ $0 }) {
            writer.copy(rbsp, from: position, to: range.lowerBound)
            writer.put(0)
            position = range.upperBound
        }
        writer.copy(rbsp, from: position, to: slice.end)
        while writer.count % 8 != 0 { writer.put(1) }
        var bytes = writer.bytes
        bytes.append(contentsOf: rbsp[((slice.end + 7) / 8)...])
        return Data(escape(bytes))
    }

    /// The bytes of a NAL unit without its emulation prevention bytes.
    static func unescape<Bytes: Collection>(_ unit: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(unit.count)
        var zeros = 0
        for byte in unit {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// `bytes` with emulation prevention bytes put in, as a NAL unit carries them.
    static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 64)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte <= 3 { out.append(3); zeros = 0 }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        if out.last == 0 { out.append(3) }
        return out
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position: Int

        init(_ bytes: [UInt8], from position: Int) {
            self.bytes = bytes
            self.position = position
        }

        mutating func u(_ count: Int) throws -> Int {
            var value = 0
            for _ in 0..<count {
                guard position >> 3 < bytes.count else { throw Unreadable() }
                value = value << 1 | Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
                position += 1
            }
            return value
        }

        mutating func ue() throws -> Int {
            var zeros = 0
            while try u(1) == 0 {
                zeros += 1
                guard zeros < 32 else { throw Unreadable() }
            }
            return (1 << zeros) - 1 + (try u(zeros))
        }

        mutating func se() throws -> Int {
            let k = try ue()
            return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var count = 0

        mutating func put(_ bit: UInt8) {
            if count & 7 == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= bit << (7 - UInt8(count & 7))
            count += 1
        }

        mutating func copy(_ source: [UInt8], from start: Int, to end: Int) {
            for position in start..<end { put(source[position >> 3] >> (7 - UInt8(position & 7)) & 1) }
        }
    }
}
