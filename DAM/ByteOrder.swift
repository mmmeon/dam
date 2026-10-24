//
//  ByteOrder.swift
//
//  Integers written into Data and read back, either byte order: for the wire formats
//  (Moonlight's, OpenDisplay's) and what VideoToolbox writes into a stream.
//

import Foundation

extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// Reading back what those write, from bytes counted from the start of the collection,
/// so a slice of Data, whose indices go on from where it was cut, reads the same.
extension Collection where Element == UInt8, Index == Int {
    /// The `T` whose bytes begin `offset` bytes in, least significant first; they must be there.
    func read<T: FixedWidthInteger>(littleEndian _: T.Type, at offset: Int) -> T {
        integer(at: offset, bigEndian: false)
    }

    /// The `T` whose bytes begin `offset` bytes in, most significant first; they must be there.
    func read<T: FixedWidthInteger>(bigEndian _: T.Type, at offset: Int) -> T {
        integer(at: offset, bigEndian: true)
    }

    private func integer<T: FixedWidthInteger>(at offset: Int, bigEndian: Bool) -> T {
        let start = startIndex + offset
        let bytes = self[start..<(start + MemoryLayout<T>.size)]
        let ordered = bigEndian ? Array(bytes) : bytes.reversed()
        return T(truncatingIfNeeded: ordered.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }
}
