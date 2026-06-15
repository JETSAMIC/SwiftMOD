/// MODParser.swift
///
/// Pure-Swift decoder for Amiga `.mod` module files. Reads:
///
/// 1. 4-byte format signature at offset 1080 (fall back to the
///    15-sample no-signature variant if absent).
/// 2. 20-byte song title at offset 0.
/// 3. 31 (or 15) sample headers × 30 bytes — name, length-in-words,
///    finetune nibble, default volume, loop start, loop length.
/// 4. Song length byte, restart byte, 128-byte order table.
/// 5. Pattern data — each pattern = 64 rows × `channelCount` × 4
///    bytes; cell encoding per the spec.
/// 6. Signed-8-bit PCM sample bodies, concatenated in sample-index
///    order.
///
/// Numbers in sample headers are **big-endian** (the Amiga is
/// big-endian); we use the helpers in `Data+MODReader.swift`.
///
/// **Not** implemented in this commit:
///
/// - FLT8 "paired pattern" assembly (the parser reports
///   `signature == .flt8` and `channelCount == 8`; pattern data is
///   read as two 4-channel patterns and stitched into 8-channel
///   patterns of half the count). See the spec doc for the rule.
/// - Sample-body overlap validation. We compute the expected total
///   length and only throw `sampleOverrun` when an individual
///   sample would read past `data.endIndex`.
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker
/// was consulted in writing this parser.

import Foundation

enum MODParser {

    // MARK: - Entry point

    static func parse(_ data: Data) throws -> MODFile {

        // Detect signature first — that determines header size and
        // channel count, which we need before we can read anything
        // else with confidence.
        let signature = MODSignature.detect(in: data) ?? .noSignature15Sample

        if case .noSignature15Sample = signature {
            return try parse15SampleVariant(data: data)
        }
        return try parse31SampleVariant(data: data, signature: signature)
    }

    // MARK: - 31-sample variant

    private static func parse31SampleVariant(
        data: Data,
        signature: MODSignature
    ) throws -> MODFile {

        let channelCount = signature.channelCount
        let sampleSlots = 31
        let headerSize = 1084

        guard data.count >= headerSize else {
            throw MODError.truncated(stage: "header")
        }

        // 1. Title (offset 0, 20 bytes).
        let title = readASCII(data, range: 0..<20)

        // 2. Sample headers (31 × 30 bytes, starting at offset 20).
        // Header-only fields here; bodies are read later, once we
        // know the offset.
        var sampleHeaders: [(name: String,
                             byteLength: Int,
                             finetune: Int8,
                             volume: UInt8,
                             loopStart: Int,
                             loopLength: Int)] = []
        sampleHeaders.reserveCapacity(sampleSlots)

        for i in 0..<sampleSlots {
            let base = 20 + i * 30
            guard base + 30 <= data.count else {
                throw MODError.truncated(stage: "sample-header")
            }
            let name = readASCII(data, range: base..<(base + 22))
            let wordLength = Int(readUInt16BE(data, at: base + 22))
            let finetuneNibble = data[data.startIndex + base + 24] & 0x0F
            let finetune: Int8 = finetuneNibble >= 8
                ? Int8(Int(finetuneNibble) - 16)
                : Int8(finetuneNibble)
            let volume = min(data[data.startIndex + base + 25], 64)
            let loopStartWords = Int(readUInt16BE(data, at: base + 26))
            let loopLengthWords = Int(readUInt16BE(data, at: base + 28))

            sampleHeaders.append((
                name: name,
                byteLength: wordLength * 2,
                finetune: finetune,
                volume: volume,
                loopStart: loopStartWords * 2,
                loopLength: loopLengthWords * 2
            ))
        }

        // 3. Song length + restart byte (offsets 0x3B6 / 0x3B7).
        let songLengthRaw = Int(data[data.startIndex + 0x3B6])
        let songLength = max(1, min(songLengthRaw, 128))
        let restartByte = data[data.startIndex + 0x3B7]

        // 4. Order table (128 bytes at 0x3B8).
        var patternOrder = [UInt8](repeating: 0, count: 128)
        for i in 0..<128 {
            patternOrder[i] = data[data.startIndex + 0x3B8 + i]
        }

        // 5. Pattern count = max(orderTable[0..<songLength]) + 1.
        let usedOrders = patternOrder.prefix(songLength)
        let maxOrder = usedOrders.max() ?? 0
        let patternCount = Int(maxOrder) + 1

        // 6. Pattern data — each pattern is 64 × channelCount × 4.
        let patternBytes = 64 * channelCount * 4
        let patternsBase = headerSize
        let patternsEnd = patternsBase + patternCount * patternBytes
        guard patternsEnd <= data.count else {
            throw MODError.truncated(stage: "pattern")
        }

        var patterns: [MODPattern] = []
        patterns.reserveCapacity(patternCount)
        for p in 0..<patternCount {
            let patBase = patternsBase + p * patternBytes
            patterns.append(try decodePattern(
                data: data,
                at: patBase,
                channelCount: channelCount
            ))
        }

        // 7. Sample bodies — concatenated immediately after the
        // pattern block.
        var samples: [MODSample] = []
        samples.reserveCapacity(sampleSlots)
        var bodyCursor = patternsEnd

        for header in sampleHeaders {
            let len = header.byteLength
            var pcm: [Int8] = []
            if len > 0 {
                let bodyEnd = bodyCursor + len
                // Tolerate truncation at the file's tail — many
                // real `.mod` files in the wild are truncated by a
                // few bytes from sample-trailing silence having
                // been trimmed by lossy archivers.
                let safeEnd = min(bodyEnd, data.count)
                guard bodyCursor <= data.count else {
                    throw MODError.sampleOverrun
                }
                pcm.reserveCapacity(safeEnd - bodyCursor)
                for i in bodyCursor..<safeEnd {
                    pcm.append(Int8(bitPattern: data[data.startIndex + i]))
                }
                // Pad if the file was short — gives the mixer a
                // predictable buffer.
                if safeEnd < bodyEnd {
                    pcm.append(contentsOf: Array(repeating: Int8(0),
                                                 count: bodyEnd - safeEnd))
                }
                bodyCursor = bodyEnd
            }
            samples.append(MODSample(
                name: header.name,
                length: header.byteLength,
                finetune: header.finetune,
                volume: header.volume,
                loopStart: header.loopStart,
                loopLength: header.loopLength,
                data: pcm
            ))
        }

        return MODFile(
            title: title,
            signature: signature,
            channelCount: channelCount,
            samples: samples,
            songLength: songLength,
            restartByte: restartByte,
            patternOrder: patternOrder,
            patterns: patterns
        )
    }

    // MARK: - 15-sample (Ultimate Soundtracker) variant

    /// Pre-NoiseTracker layout: 600-byte header, 15 sample slots,
    /// 4 channels, no signature.
    private static func parse15SampleVariant(data: Data) throws -> MODFile {
        let channelCount = 4
        let sampleSlots = 15
        let headerSize = 600

        guard data.count >= headerSize else {
            throw MODError.truncated(stage: "header")
        }

        let title = readASCII(data, range: 0..<20)

        var sampleHeaders: [(name: String,
                             byteLength: Int,
                             finetune: Int8,
                             volume: UInt8,
                             loopStart: Int,
                             loopLength: Int)] = []
        sampleHeaders.reserveCapacity(sampleSlots)

        for i in 0..<sampleSlots {
            let base = 20 + i * 30
            let name = readASCII(data, range: base..<(base + 22))
            let wordLength = Int(readUInt16BE(data, at: base + 22))
            // Finetune doesn't exist in the pre-NoiseTracker
            // header (the byte was a "repeat" hint); treat as 0.
            let finetune: Int8 = 0
            let volume = min(data[data.startIndex + base + 25], 64)
            let loopStartWords = Int(readUInt16BE(data, at: base + 26))
            let loopLengthWords = Int(readUInt16BE(data, at: base + 28))
            sampleHeaders.append((
                name: name,
                byteLength: wordLength * 2,
                finetune: finetune,
                volume: volume,
                loopStart: loopStartWords * 2,
                loopLength: loopLengthWords * 2
            ))
        }

        let songLengthRaw = Int(data[data.startIndex + 470])    // 0x1D6
        let songLength = max(1, min(songLengthRaw, 128))
        let restartByte = data[data.startIndex + 471]           // 0x1D7

        var patternOrder = [UInt8](repeating: 0, count: 128)
        for i in 0..<128 {
            patternOrder[i] = data[data.startIndex + 472 + i]   // 0x1D8
        }
        let maxOrder = patternOrder.prefix(songLength).max() ?? 0
        let patternCount = Int(maxOrder) + 1

        let patternBytes = 64 * channelCount * 4
        let patternsBase = headerSize
        let patternsEnd = patternsBase + patternCount * patternBytes
        guard patternsEnd <= data.count else {
            // 15-sample fallback never reached unless the
            // signature dispatch failed *and* this layout also
            // doesn't fit. Surface as unsupportedSignature with
            // the would-be tag bytes for diagnostics.
            let tag = data.count >= 1084
                ? String(bytes: data.subdata(in: 1080..<1084), encoding: .ascii) ?? "????"
                : "<short>"
            throw MODError.unsupportedSignature(tag)
        }

        var patterns: [MODPattern] = []
        for p in 0..<patternCount {
            let patBase = patternsBase + p * patternBytes
            patterns.append(try decodePattern(
                data: data,
                at: patBase,
                channelCount: channelCount
            ))
        }

        var samples: [MODSample] = []
        var bodyCursor = patternsEnd
        for header in sampleHeaders {
            let len = header.byteLength
            var pcm: [Int8] = []
            if len > 0 {
                let bodyEnd = bodyCursor + len
                let safeEnd = min(bodyEnd, data.count)
                pcm.reserveCapacity(safeEnd - bodyCursor)
                for i in bodyCursor..<safeEnd {
                    pcm.append(Int8(bitPattern: data[data.startIndex + i]))
                }
                if safeEnd < bodyEnd {
                    pcm.append(contentsOf: Array(repeating: Int8(0),
                                                 count: bodyEnd - safeEnd))
                }
                bodyCursor = bodyEnd
            }
            samples.append(MODSample(
                name: header.name,
                length: header.byteLength,
                finetune: header.finetune,
                volume: header.volume,
                loopStart: header.loopStart,
                loopLength: header.loopLength,
                data: pcm
            ))
        }

        return MODFile(
            title: title,
            signature: .noSignature15Sample,
            channelCount: channelCount,
            samples: samples,
            songLength: songLength,
            restartByte: restartByte,
            patternOrder: patternOrder,
            patterns: patterns
        )
    }

    // MARK: - Pattern decoding

    /// Decode one `64 × channelCount × 4`-byte pattern block.
    private static func decodePattern(
        data: Data,
        at offset: Int,
        channelCount: Int
    ) throws -> MODPattern {
        let cellSize = 4
        let rowSize = channelCount * cellSize
        let patSize = 64 * rowSize

        guard offset + patSize <= data.count else {
            throw MODError.truncated(stage: "pattern")
        }

        var rows: [MODRow] = []
        rows.reserveCapacity(64)

        for r in 0..<64 {
            var cells: [MODCell] = []
            cells.reserveCapacity(channelCount)
            for c in 0..<channelCount {
                let base = offset + r * rowSize + c * cellSize
                let b0 = data[data.startIndex + base]
                let b1 = data[data.startIndex + base + 1]
                let b2 = data[data.startIndex + base + 2]
                let b3 = data[data.startIndex + base + 3]

                // Cell encoding (per spec):
                //   byte0: ssss pppp  (sample-hi nibble, period-hi nibble)
                //   byte1: pppp pppp  (period-lo byte)
                //   byte2: ssss eeee  (sample-lo nibble, effect)
                //   byte3: pppp pppp  (effect parameter)
                let periodHi = UInt16(b0 & 0x0F)
                let periodLo = UInt16(b1)
                let period = (periodHi << 8) | periodLo

                let sampleHi = b0 & 0xF0
                let sampleLo = (b2 >> 4) & 0x0F
                let sample = sampleHi | sampleLo

                let effect = b2 & 0x0F
                let param  = b3

                cells.append(MODCell(
                    period: period,
                    sampleNumber: sample,
                    effect: effect,
                    effectParam: param
                ))
            }
            rows.append(cells)
        }

        return MODPattern(rows: rows)
    }

    // MARK: - Byte helpers

    /// Read big-endian `UInt16` at the given offset, treating the
    /// offset as relative to the `Data`'s logical start (not
    /// `startIndex`). Sliced `Data` values keep their original
    /// indexing, so we explicitly add `startIndex`.
    static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let hi = UInt16(data[data.startIndex + offset])
        let lo = UInt16(data[data.startIndex + offset + 1])
        return (hi << 8) | lo
    }

    /// Read an ASCII string from `range`. Stops at the first NUL,
    /// drops trailing whitespace and non-printable bytes, and falls
    /// back to a best-effort Latin-1 decoding if ASCII fails (some
    /// Amiga modules use the upper 128 code points).
    static func readASCII(_ data: Data, range: Range<Int>) -> String {
        let lo = data.startIndex + range.lowerBound
        let hi = min(data.startIndex + range.upperBound, data.endIndex)
        guard lo < hi else { return "" }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hi - lo)
        for i in lo..<hi {
            let b = data[i]
            if b == 0 { break }
            bytes.append(b)
        }
        // Strip trailing non-printable / whitespace.
        while let last = bytes.last,
              last <= 0x20 || last == 0x7F {
            bytes.removeLast()
        }
        if let s = String(bytes: bytes, encoding: .ascii) { return s }
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}
