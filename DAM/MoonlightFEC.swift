//
//  MoonlightFEC.swift
//
//  The Reed-Solomon parity Moonlight recovers lost video packets with, as the nanors
//  library it decodes with defines it: GF(2^8) with polynomial 0x11D, and a Cauchy matrix
//  whose row j, column i is 1 / ((P + i) XOR j) for P parity shards. Each parity byte is
//  the sum over the data shards of that coefficient times the data byte at the same place.
//

import Foundation

enum MoonlightFEC {

    /// The most shards, data and parity, one block can have.
    static let maxShards = 255

    private static let tables: (exp: [UInt8], log: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [UInt8](repeating: 0, count: 256)
        var value = 1
        for power in 0..<255 {
            exp[power] = UInt8(value)
            log[value] = UInt8(power)
            value <<= 1
            if value & 0x100 != 0 { value ^= 0x11D }
        }
        for power in 255..<512 { exp[power] = exp[power - 255] }
        return (exp, log)
    }()

    /// Every product, row by multiplier: `products[a << 8 | b]` is a × b.
    private static let products: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256 * 256)
        for a in 1..<256 {
            for b in 1..<256 { table[a << 8 | b] = multiply(UInt8(a), UInt8(b)) }
        }
        return table
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return tables.exp[Int(tables.log[Int(a)]) + Int(tables.log[Int(b)])]
    }

    static func inverse(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "0 has no inverse")
        return tables.exp[255 - Int(tables.log[Int(a)])]
    }

    /// The coefficient of data shard `column` in parity shard `row`, for `parityCount` of them.
    static func coefficient(row: Int, column: Int, parityCount: Int) -> UInt8 {
        inverse(UInt8((parityCount + column) ^ row))
    }

    /// `count` parity shards for `shards`, which are all one length.
    static func parity(of shards: [Data], count: Int) -> [Data] {
        guard count > 0, let length = shards.first?.count else { return [] }
        precondition(shards.count + count <= maxShards && shards.allSatisfy { $0.count == length })
        return products.withUnsafeBufferPointer { products in
            (0..<count).map { row in
                var out = Data(count: length)
                out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                    let parity = target.bindMemory(to: UInt8.self)
                    for (column, shard) in shards.enumerated() {
                        let row = Int(coefficient(row: row, column: column, parityCount: count)) << 8
                        shard.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                            let data = source.bindMemory(to: UInt8.self)
                            for index in 0..<length { parity[index] ^= products[row | Int(data[index])] }
                        }
                    }
                }
                return out
            }
        }
    }

    /// How many parity shards a block of `dataShards` gets, and the percentage that says so.
    /// Moonlight works the count out again from the percentage, as ceil(D × pct / 100), so
    /// the two must agree. `percentage` is the aim, raised for small blocks to give at
    /// least `minimum` and lowered to keep the block within 255 shards.
    static func parityCount(dataShards: Int, percentage: Int, minimum: Int) -> (count: Int, percentage: Int) {
        guard dataShards > 0, percentage > 0 else { return (0, 0) }
        func count(_ pct: Int) -> Int { (dataShards * pct + 99) / 100 }
        var pct = min(percentage, 255)
        if count(pct) < minimum, let raised = (pct...255).first(where: { count($0) >= minimum }) { pct = raised }
        while pct > 0, dataShards + count(pct) > maxShards { pct -= 1 }
        return (count(pct), pct)
    }
}
