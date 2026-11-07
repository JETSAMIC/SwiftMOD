// TestSupport.swift
//
// Hand-assembles `.mod` byte streams from the layout in
// Reference/MOD-Format.md so tests never depend on third-party fixtures.

import Foundation
@testable import SwiftMOD

struct ModBuilder {

    struct Sample {
        var name = ""
        var data: [Int8] = []
        var finetuneNibble: UInt8 = 0
        var volume: UInt8 = 64
        var loopStartWords: UInt16 = 0
        var loopLengthWords: UInt16 = 1
        /// Header length in words; defaults to `data.count / 2`.
        var lengthWords: UInt16?
    }

    var title = "test"
    /// 4-character tag, or `nil` for a 15-sample Soundtracker module.
    var tag: String? = "M.K."
    var channels = 4
    var songLength: UInt8 = 1
    var restart: UInt8 = 0x7F
    var orders: [UInt8] = [0]
    var samples: [Int: Sample] = [:]          // 1-based sample number
    /// Stored pattern blocks; defaults to max(orders) + 1.
    var patternCount: Int?
    var cells: [(pattern: Int, row: Int, channel: Int, cell: MODCell)] = []

    mutating func set(_ pattern: Int = 0, row: Int, ch: Int = 0,
                      period: UInt16 = 0, sample: UInt8 = 0,
                      fx: UInt8 = 0, param: UInt8 = 0) {
        cells.append((pattern, row, ch, MODCell(period: period, sampleNumber: sample,
                                                effect: fx, effectParam: param)))
    }

    static func cellBytes(_ c: MODCell) -> [UInt8] {
        [(c.sampleNumber & 0xF0) | UInt8((c.period >> 8) & 0x0F),
         UInt8(c.period & 0xFF),
         ((c.sampleNumber & 0x0F) << 4) | (c.effect & 0x0F),
         c.effectParam]
    }

    func build() -> Data {
        let slots = tag == nil ? 15 : 31
        let headerSize = tag == nil ? 600 : 1084
        var out = [UInt8](repeating: 0, count: headerSize)
        for (i, b) in title.utf8.prefix(20).enumerated() { out[i] = b }
        for n in 1...slots {
            guard let s = samples[n] else { continue }
            let base = 20 + (n - 1) * 30
            for (i, b) in s.name.utf8.prefix(22).enumerated() { out[base + i] = b }
            let words = s.lengthWords ?? UInt16(s.data.count / 2)
            out[base + 22] = UInt8(words >> 8); out[base + 23] = UInt8(words & 0xFF)
            out[base + 24] = s.finetuneNibble
            out[base + 25] = s.volume
            out[base + 26] = UInt8(s.loopStartWords >> 8); out[base + 27] = UInt8(s.loopStartWords & 0xFF)
            out[base + 28] = UInt8(s.loopLengthWords >> 8); out[base + 29] = UInt8(s.loopLengthWords & 0xFF)
        }
        let songBase = tag == nil ? 470 : 950
        out[songBase] = songLength
        out[songBase + 1] = restart
        for (i, o) in orders.prefix(128).enumerated() { out[songBase + 2 + i] = o }
        if let tag { for (i, b) in tag.utf8.prefix(4).enumerated() { out[1080 + i] = b } }

        let blockChannels = tag == "FLT8" ? 4 : channels
        let blockBytes = 64 * blockChannels * 4
        let count = patternCount ?? (Int(orders.max() ?? 0) + 1)
        var patterns = [UInt8](repeating: 0, count: count * blockBytes)
        for c in cells {
            let off = c.pattern * blockBytes + (c.row * blockChannels + c.channel) * 4
            patterns.replaceSubrange(off..<(off + 4), with: Self.cellBytes(c.cell))
        }
        out += patterns
        for n in 1...slots {
            guard let s = samples[n] else { continue }
            out += s.data.map { UInt8(bitPattern: $0) }
        }
        return Data(out)
    }

    func file() throws -> MODFile { try MODFile(data: build()) }

    func replayer(loop: Bool = false) throws -> MODReplayer {
        MODReplayer(file: try file(), loopSong: loop)
    }

    /// A looping-free sample of `count` bytes with a ramp body.
    static func ramp(_ count: Int, volume: UInt8 = 64) -> Sample {
        Sample(data: (0..<count).map { Int8(truncatingIfNeeded: ($0 % 100) + 1) }, volume: volume)
    }
}

extension MODReplayer {
    /// Run `n` ticks.
    mutating func ticks(_ n: Int) {
        for _ in 0..<n { tick() }
    }
}
