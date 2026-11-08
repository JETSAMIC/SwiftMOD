/// MODParser.swift
///
/// Decoder for Amiga `.mod` files. Every offset and length read from
/// the file is validated against the data before use; a malformed file
/// throws `MODError`, never traps.
///
/// Layout handling (see `Reference/MOD-Format.md`):
///
/// - 31-sample modules are identified by the tag at offset 1080.
/// - Data with no known tag is parsed as a 15-sample Soundtracker module
///   only if it passes structural validation (song length, order
///   values, sample header ranges, and plausible pattern cells).
/// - The number of stored patterns is `max(order table) + 1` over all
///   128 entries (what ProTracker writes), falling back to the used
///   entries only when the larger count does not fit the file.
/// - `FLT8` patterns are stored as 4-channel pairs and are reassembled
///   into 8-channel patterns.
/// - Sample bodies cut off by the end of the file are shortened rather
///   than rejected (`MODFile.isTruncated`).
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker was
/// consulted in writing this parser.

import Foundation

enum MODParser {

    private struct SampleHeader {
        var name: String
        var lengthBytes: Int
        var finetune: Int8
        var volume: UInt8
        var loopStartBytes: Int
        var loopLengthBytes: Int
    }

    private struct Layout {
        let signature: MODSignature
        let headerSize: Int
        let sampleSlots: Int
        let songLengthOffset: Int
    }

    // MARK: - Entry point

    static func parse(_ data: Data) throws -> MODFile {
        let bytes = [UInt8](data)

        if bytes.count >= 1084,
           let signature = MODSignature.detect(bytes: Array(bytes[1080..<1084])) {
            return try parse(bytes, layout: Layout(
                signature: signature, headerSize: 1084,
                sampleSlots: 31, songLengthOffset: 950))
        }

        // No tag. A valid Soundtracker module is at least
        // 600 header + 1024 pattern bytes, so anything shorter than the
        // 31-sample header is reported as truncated.
        guard bytes.count >= 1084 else { throw MODError.truncated(.header) }
        let layout = Layout(signature: .noSignature15Sample, headerSize: 600,
                            sampleSlots: 15, songLengthOffset: 470)
        guard looksLikeSoundtracker(bytes) else { throw MODError.unrecognizedFormat }
        return try parse(bytes, layout: layout)
    }

    // MARK: - Common decoder

    private static func parse(_ bytes: [UInt8], layout: Layout) throws -> MODFile {
        guard bytes.count >= layout.headerSize else { throw MODError.truncated(.header) }
        let is15 = layout.sampleSlots == 15
        let signature = layout.signature

        // Title + sample headers.
        let title = readString(bytes, 0, 20)
        var headers: [SampleHeader] = []
        headers.reserveCapacity(layout.sampleSlots)
        for i in 0..<layout.sampleSlots {
            headers.append(readSampleHeader(bytes, at: 20 + i * 30, soundtracker: is15))
        }

        // Song length, restart byte, order table.
        let songLength = Int(bytes[layout.songLengthOffset])
        guard (1...128).contains(songLength) else {
            throw MODError.invalidSongLength(songLength)
        }
        let restartByte = bytes[layout.songLengthOffset + 1]
        let orderBase = layout.songLengthOffset + 2
        var orders = Array(bytes[orderBase..<(orderBase + 128)])

        // FLT8 stores only even order values (each names the first
        // half of a 4-channel pair); halve them so they index the
        // reassembled 8-channel patterns.
        let paired = signature.isStarTrekkerPaired
        if paired { orders = orders.map { $0 / 2 } }

        // Pattern count.
        let channels = signature.channelCount
        let patternBytes = 64 * channels * 4
        let sampleBytes = headers.reduce(0) { $0 + $1.lengthBytes }
        let maxUsed = Int(orders[0..<songLength].max() ?? 0)
        let maxAll = Int(orders.max() ?? 0)
        var patternCount = maxAll + 1
        if maxAll != maxUsed {
            let allEnd = layout.headerSize + (maxAll + 1) * patternBytes
            let usedEnd = layout.headerSize + (maxUsed + 1) * patternBytes
            if allEnd > bytes.count || (allEnd + sampleBytes > bytes.count
                                        && usedEnd + sampleBytes <= bytes.count) {
                patternCount = maxUsed + 1
            }
        }

        let patternsEnd = layout.headerSize + patternCount * patternBytes
        guard patternsEnd <= bytes.count else { throw MODError.truncated(.patterns) }

        var patterns: [MODPattern] = []
        patterns.reserveCapacity(patternCount)
        for p in 0..<patternCount {
            let base = layout.headerSize + p * patternBytes
            if paired {
                // Two consecutive 4-channel blocks: channels 0-3 then 4-7.
                let left = decodeRows(bytes, at: base, channels: 4)
                let right = decodeRows(bytes, at: base + 1024, channels: 4)
                patterns.append(MODPattern(rows: zip(left, right).map { $0 + $1 }))
            } else {
                patterns.append(MODPattern(rows: decodeRows(bytes, at: base, channels: channels)))
            }
        }

        // Sample bodies.
        var samples: [MODSample] = []
        samples.reserveCapacity(layout.sampleSlots)
        var cursor = patternsEnd
        var truncated = false
        for h in headers {
            let start = min(cursor, bytes.count)
            let end = min(cursor + h.lengthBytes, bytes.count)
            if end - start < h.lengthBytes { truncated = true }
            let pcm = bytes[start..<end].map { Int8(bitPattern: $0) }
            cursor += h.lengthBytes
            samples.append(makeSample(h, data: pcm, soundtracker: is15))
        }

        return MODFile(
            title: title,
            signature: signature,
            channelCount: channels,
            samples: samples,
            songLength: songLength,
            restartByte: restartByte,
            patternOrder: orders,
            patterns: patterns,
            isTruncated: truncated
        )
    }

    // MARK: - Samples

    private static func readSampleHeader(_ b: [UInt8], at base: Int, soundtracker: Bool) -> SampleHeader {
        let nibble = b[base + 24] & 0x0F
        return SampleHeader(
            name: readString(b, base, 22),
            lengthBytes: Int(readUInt16BE(b, base + 22)) * 2,
            // The pre-NoiseTracker byte at +24 is not a finetune.
            finetune: soundtracker ? 0 : Int8(bitPattern: nibble << 4) >> 4,
            volume: min(b[base + 25], 64),
            loopStartBytes: Int(readUInt16BE(b, base + 26)) * 2,
            loopLengthBytes: Int(readUInt16BE(b, base + 28)) * 2
        )
    }

    /// Build a sample with validated loop bounds.
    private static func makeSample(_ h: SampleHeader, data: [Int8], soundtracker: Bool) -> MODSample {
        let length = data.count
        // Every Soundtracker version stores the loop start in bytes (the
        // loop length is still in words); readSampleHeader doubled it.
        var loopStart = soundtracker ? h.loopStartBytes / 2 : h.loopStartBytes
        var loopLength = h.loopLengthBytes
        if loopLength > 2 {
            if loopStart >= length {
                loopLength = 0
            } else if loopStart + loopLength > length {
                loopLength = length - loopStart
            }
        }
        if loopLength <= 2 {
            loopStart = 0
            loopLength = 0
        }
        return MODSample(name: h.name, length: length, finetune: h.finetune,
                         volume: h.volume, loopStart: loopStart,
                         loopLength: loopLength, data: data)
    }

    // MARK: - Patterns

    private static func decodeRows(_ b: [UInt8], at offset: Int, channels: Int) -> [MODRow] {
        var rows: [MODRow] = []
        rows.reserveCapacity(64)
        for r in 0..<64 {
            var row: MODRow = []
            row.reserveCapacity(channels)
            for c in 0..<channels {
                row.append(decodeCell(b, at: offset + (r * channels + c) * 4))
            }
            rows.append(row)
        }
        return rows
    }

    @inline(__always)
    private static func decodeCell(_ b: [UInt8], at i: Int) -> MODCell {
        MODCell(
            period: UInt16(b[i] & 0x0F) << 8 | UInt16(b[i + 1]),
            sampleNumber: (b[i] & 0xF0) | (b[i + 2] >> 4),
            effect: b[i + 2] & 0x0F,
            effectParam: b[i + 3]
        )
    }

    // MARK: - 15-sample validation

    /// Structural checks for a tag-less file. Random or foreign data
    /// fails at least one of these with overwhelming probability.
    private static func looksLikeSoundtracker(_ b: [UInt8]) -> Bool {
        guard b.count >= 600 + 1024 else { return false }
        let songLength = Int(b[470])
        guard (1...128).contains(songLength) else { return false }
        let orders = b[472..<600]
        guard orders.allSatisfy({ $0 < 128 }) else { return false }

        var sampleBytes = 0
        for i in 0..<15 {
            let base = 20 + i * 30
            let words = Int(readUInt16BE(b, base + 22))
            guard words <= 32768, b[base + 25] <= 64 else { return false }
            sampleBytes += words * 2
        }

        let maxUsed = Int(orders.prefix(songLength).max() ?? 0)
        let patternsEnd = 600 + (maxUsed + 1) * 1024
        guard patternsEnd <= b.count else { return false }

        // Every cell must reference sample 0...15 and carry either no
        // period or one inside (a slightly widened) ProTracker range.
        var i = 600
        while i < patternsEnd {
            guard b[i] & 0xF0 == 0 else { return false }
            let period = Int(b[i] & 0x0F) << 8 | Int(b[i + 1])
            guard period == 0 || (100...1000).contains(period) else { return false }
            i += 4
        }
        // Allow lossy truncation of the sample area, but reject files
        // that carry far more data than the headers describe.
        let maxAll = Int(orders.max() ?? 0)
        return b.count <= 600 + (maxAll + 1) * 1024 + sampleBytes + 4096
    }

    // MARK: - Byte helpers

    @inline(__always)
    static func readUInt16BE(_ b: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
    }

    /// Decode `count` bytes at `offset`: stop at the first NUL, strip
    /// trailing spaces/control bytes, decode ASCII or else Latin-1.
    static func readString(_ b: [UInt8], _ offset: Int, _ count: Int) -> String {
        var bytes = Array(b[offset..<(offset + count)].prefix { $0 != 0 })
        while let last = bytes.last, last <= 0x20 || last == 0x7F {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .ascii)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? ""
    }
}
