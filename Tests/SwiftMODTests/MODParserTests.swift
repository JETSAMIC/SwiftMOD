// MODParserTests.swift
//
// Structural parsing rules from Reference/MOD-Format.md, each driven by
// hand-built bytes, plus robustness: truncation at every byte offset of
// a valid module and a seeded mutation fuzz.

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD parser")
struct MODParserTests {

    /// A small but feature-rich valid module: 2 orders, 2 patterns, a
    /// looped and a one-shot sample, assorted effects.
    static func fixture() -> ModBuilder {
        var b = ModBuilder()
        b.title = "fixture"
        b.songLength = 2
        b.orders = [0, 1]
        var looped = ModBuilder.ramp(64)
        looped.loopStartWords = 8; looped.loopLengthWords = 16
        looped.finetuneNibble = 0xF
        b.samples[1] = looped
        b.samples[2] = ModBuilder.ramp(32, volume: 40)
        b.set(0, row: 0, ch: 0, period: 428, sample: 1, fx: 0xC, param: 0x20)
        b.set(0, row: 1, ch: 1, period: 339, sample: 2, fx: 0x4, param: 0x48)
        b.set(0, row: 2, ch: 2, fx: 0xE, param: 0x61)
        b.set(1, row: 0, ch: 3, period: 214, sample: 1, fx: 0xB, param: 0x00)
        return b
    }

    // MARK: Header fields

    @Test("Fixture parses with expected fields")
    func fixtureParses() throws {
        let file = try Self.fixture().file()
        #expect(file.title == "fixture")
        #expect(file.signature == .mk)
        #expect(file.songLength == 2)
        #expect(file.patterns.count == 2)
        #expect(file.samples.count == 31)
        #expect(file.samples[0].finetune == -1)
        #expect(file.samples[0].loopStart == 16)
        #expect(file.samples[0].loopLength == 32)
        #expect(file.samples[1].volume == 40)
        #expect(file.samples[1].loops == false)
        #expect(file.isTruncated == false)
        #expect(file.patterns[1].rows[0][3].effect == 0xB)
    }

    @Test("Song length 0 and > 128 throw invalidSongLength")
    func songLengthBounds() {
        var b = Self.fixture()
        b.songLength = 0
        #expect(throws: MODError.invalidSongLength(0)) { try b.file() }
        b.songLength = 129
        #expect(throws: MODError.invalidSongLength(129)) { try b.file() }
    }

    @Test("Volume above 64 clamps; finetune uses only the low nibble")
    func headerClamps() throws {
        var b = Self.fixture()
        b.samples[2]?.volume = 0xFF
        b.samples[2]?.finetuneNibble = 0x97   // high nibble garbage, +7
        let s = try b.file().samples[1]
        #expect(s.volume == 64)
        #expect(s.finetune == 7)
    }

    // MARK: Loop validation (words → bytes, loop-length-1 quirk)

    @Test("Loop length 0 or 1 word means no loop")
    func loopLengthOneWord() throws {
        for words: UInt16 in [0, 1] {
            var b = Self.fixture()
            b.samples[1]?.loopStartWords = 4
            b.samples[1]?.loopLengthWords = words
            let s = try b.file().samples[0]
            #expect(s.loops == false)
            #expect(s.loopStart == 0 && s.loopLength == 0)
        }
    }

    @Test("Loop past the sample end is clamped; loop start past it disables the loop")
    func loopClamp() throws {
        var b = Self.fixture()
        b.samples[1]?.loopStartWords = 24          // 48 bytes of 64
        b.samples[1]?.loopLengthWords = 100
        var s = try b.file().samples[0]
        #expect(s.loopStart == 48 && s.loopLength == 16)

        b.samples[1]?.loopStartWords = 40          // 80 bytes > 64
        s = try b.file().samples[0]
        #expect(s.loops == false)
    }

    // MARK: Pattern count

    @Test("Pattern count spans all 128 order entries when the data is present")
    func patternCountAllOrders() throws {
        var b = Self.fixture()
        b.orders = [0, 1, 0, 0, 0, 2]              // order[5] beyond songLength
        b.set(2, row: 0, ch: 0, period: 856)
        let file = try b.file()
        #expect(file.patterns.count == 3)
        // Sample bodies come after all 3 patterns.
        #expect(file.samples[0].data == ModBuilder.ramp(64).data)
    }

    @Test("Garbage order entries past songLength fall back to the used range")
    func patternCountGarbageOrders() throws {
        var b = Self.fixture()
        b.orders = [0, 1] + [UInt8](repeating: 0xFF, count: 126)
        b.patternCount = 2
        let file = try b.file()
        #expect(file.patterns.count == 2)
        #expect(file.samples[1].data == ModBuilder.ramp(32, volume: 40).data)
    }

    // MARK: Variants

    @Test("FLT8 reassembles paired 4-channel patterns and halves orders")
    func flt8() throws {
        var b = ModBuilder()
        b.tag = "FLT8"; b.channels = 8
        b.songLength = 2; b.orders = [0, 2]
        b.patternCount = 4                         // 2 pairs of 4-channel blocks
        b.set(1, row: 3, ch: 2, period: 428, sample: 1)   // pair 0, channel 6
        b.set(2, row: 0, ch: 0, period: 214)              // pair 1, channel 0
        let file = try b.file()
        #expect(file.channelCount == 8)
        #expect(Array(file.patternOrder.prefix(2)) == [0, 1])
        #expect(file.patterns.count == 2)
        #expect(file.patterns[0].rows[3].count == 8)
        #expect(file.patterns[0].rows[3][6].period == 428)
        #expect(file.patterns[1].rows[0][0].period == 214)
    }

    @Test("xCHN / xxCH / TDZx channel counts drive the pattern width")
    func multichannel() throws {
        for (tag, n) in [("6CHN", 6), ("12CH", 12), ("32CH", 32), ("TDZ3", 3), ("3CHN", 3)] {
            var b = ModBuilder()
            b.tag = tag; b.channels = n
            b.set(row: 63, ch: n - 1, period: 428)
            let file = try b.file()
            #expect(file.channelCount == n)
            #expect(file.patterns[0].rows[63][n - 1].period == 428)
        }
    }

    @Test("15-sample Soundtracker module parses with a 600-byte header")
    func soundtracker() throws {
        var b = ModBuilder()
        b.tag = nil
        b.title = "ust"
        b.samples[1] = ModBuilder.ramp(128)
        b.samples[1]?.finetuneNibble = 5      // ignored: not a finetune in UST
        b.samples[15] = ModBuilder.ramp(16, volume: 10)
        b.set(row: 0, period: 428, sample: 1)
        let file = try b.file()
        #expect(file.signature == .noSignature15Sample)
        #expect(file.samples.count == 15)
        #expect(file.samples[0].finetune == 0)
        #expect(file.samples[14].volume == 10)
        #expect(file.patterns[0].rows[0][0].sampleNumber == 1)
    }

    @Test("Soundtracker loop start stored in bytes is recognised")
    func soundtrackerByteLoop() throws {
        var b = ModBuilder()
        b.tag = nil
        var s = ModBuilder.ramp(100)
        s.loopStartWords = 60                 // 60 *bytes* in UST
        s.loopLengthWords = 10
        b.samples[1] = s
        let sample = try b.file().samples[0]
        #expect(sample.loopStart == 60)
        #expect(sample.loopLength == 20)
    }

    @Test("Soundtracker loop start is in bytes even when a word reading would fit")
    func soundtrackerByteLoopAlways() throws {
        // Spec §3.4: every Soundtracker version stores the loop start in
        // bytes. 10 read as words (20 bytes) would also fit the sample,
        // but the stored value is 10 bytes; odd byte offsets are legal.
        for (stored, expected) in [(UInt16(10), 10), (UInt16(7), 7)] {
            var b = ModBuilder()
            b.tag = nil
            var s = ModBuilder.ramp(100)
            s.loopStartWords = stored
            s.loopLengthWords = 10
            b.samples[1] = s
            let sample = try b.file().samples[0]
            #expect(sample.loopStart == expected)
            #expect(sample.loopLength == 20)
        }
        // 31-sample modules keep loop starts in words.
        var b = ModBuilder()
        var s = ModBuilder.ramp(100)
        s.loopStartWords = 10
        s.loopLengthWords = 10
        b.samples[1] = s
        #expect(try b.file().samples[0].loopStart == 20)
    }

    @Test("Untagged data that is not a Soundtracker module is rejected")
    func unrecognized() {
        var data = Data(repeating: 0x41, count: 4000)
        #expect(throws: MODError.unrecognizedFormat) { try MODFile(data: data) }
        // Plausible header but a cell references sample 0x10+.
        var b = ModBuilder()
        b.tag = nil
        b.set(row: 0, period: 428, sample: 0x21)
        data = b.build()
        #expect(throws: MODError.unrecognizedFormat) { try MODFile(data: data) }
    }

    // MARK: Truncation

    @Test("Truncated sample bodies load shortened and set isTruncated")
    func truncatedSamples() throws {
        let full = Self.fixture().build()
        let file = try MODFile(data: full.prefix(full.count - 40))
        #expect(file.isTruncated)
        #expect(file.samples[0].length == 56)
        #expect(file.samples[1].length == 0)
        #expect(file.samples[0].loopStart + file.samples[0].loopLength <= 56)
    }

    @Test("Truncation at every byte offset throws or succeeds, never traps")
    func truncationEveryOffset() throws {
        let full = Self.fixture().build()
        let patternsEnd = 1084 + 2 * 1024
        for n in 0..<full.count {
            let prefix = full.prefix(n)
            if n < 1084 {
                #expect(throws: MODError.truncated(.header)) { try MODFile(data: prefix) }
            } else if n < patternsEnd {
                #expect(throws: MODError.truncated(.patterns)) { try MODFile(data: prefix) }
            } else {
                let file = try MODFile(data: prefix)
                #expect(file.isTruncated == (n < full.count))
            }
        }
    }

    @Test("Sliced Data with a non-zero startIndex parses identically")
    func slicedData() throws {
        let full = Self.fixture().build()
        let padded = Data([1, 2, 3]) + full
        let slice = padded[3...]
        #expect(try MODFile(data: slice) == MODFile(data: full))
    }

    @Test("Seeded mutation fuzz: 3000 mutants throw or parse, never trap")
    func mutationFuzz() {
        var rng = SplitMix64(seed: 0x5EED_0D)
        let base = [UInt8](Self.fixture().build())
        var parsed = 0
        for _ in 0..<3000 {
            var bytes = base
            let edits = Int(rng.next() % 8) + 1
            for _ in 0..<edits {
                let i = Int(rng.next() % UInt64(bytes.count))
                switch rng.next() % 4 {
                case 0: bytes[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: bytes[i] ^= 1 << UInt8(rng.next() % 8)
                case 2: bytes[i] = 0xFF
                default: bytes.removeLast(Int(rng.next() % 64))
                }
            }
            if (try? MODFile(data: Data(bytes))) != nil { parsed += 1 }
        }
        #expect(parsed > 0)
    }
}

/// Deterministic PRNG for reproducible fuzzing.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
