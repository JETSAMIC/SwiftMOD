// MODPatternTests.swift
//
// Encode known pattern cells by hand, parse through `MODFile`,
// and confirm period / sample / effect / param all round-trip
// through the bit-packing.

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD pattern cell decoding")
struct MODPatternTests {

    /// Build a minimal M.K. file as in `MODHeaderTests`, but caller
    /// can stamp custom cells into the first pattern.
    private func buildMK(cells: [(channel: Int, row: Int, bytes: [UInt8])]) -> Data {
        var data = Data(repeating: 0, count: 1084 + 1024)
        data[0x3B6] = 1
        data[0x3B7] = 0x7F
        let mk: [UInt8] = [0x4D, 0x2E, 0x4B, 0x2E]
        for (i, b) in mk.enumerated() {
            data[1080 + i] = b
        }
        // Pattern base = 1084. Each row is 4ch × 4 bytes = 16 bytes.
        for cell in cells {
            let base = 1084 + cell.row * 16 + cell.channel * 4
            for (i, b) in cell.bytes.enumerated() {
                data[base + i] = b
            }
        }
        return data
    }

    /// Encode a `(period, sample, effect, param)` tuple into the
    /// four-byte cell representation per the spec.
    private func encode(period: UInt16, sample: UInt8,
                        effect: UInt8, param: UInt8) -> [UInt8] {
        let sampleHi = sample & 0xF0
        let sampleLo = sample & 0x0F
        let periodHi = UInt8((period >> 8) & 0x0F)
        let periodLo = UInt8(period & 0xFF)
        let b0 = sampleHi | periodHi
        let b1 = periodLo
        let b2 = (sampleLo << 4) | (effect & 0x0F)
        let b3 = param
        return [b0, b1, b2, b3]
    }

    @Test("period 428 + sample 5 + Cxx volume 32 round-trips")
    func roundTripCxxVolume32() throws {
        // Period 428 = C-2 in finetune 0.
        let bytes = encode(period: 428, sample: 5,
                           effect: 0xC, param: 0x20)
        let data = buildMK(cells: [(channel: 0, row: 0, bytes: bytes)])
        let file = try MODFile(data: data)
        let cell = file.patterns[0].rows[0][0]
        #expect(cell.period == 428)
        #expect(cell.sampleNumber == 5)
        #expect(cell.effect == 0xC)
        #expect(cell.effectParam == 0x20)
        #expect(cell.note?.name == "C-2")
    }

    @Test("Sample > 15 — high nibble survives")
    func sampleHighNibble() throws {
        // Sample 17 = 0x11, so sampleHi nibble = 0x10, sampleLo = 1.
        let bytes = encode(period: 1079, sample: 17, effect: 0, param: 0)
        let data = buildMK(cells: [(channel: 2, row: 5, bytes: bytes)])
        let file = try MODFile(data: data)
        let cell = file.patterns[0].rows[5][2]
        #expect(cell.sampleNumber == 17)
        #expect(cell.period == 1079)
    }

    @Test("Effect with no period or sample (Axx volume slide)")
    func volumeSlideEffectOnly() throws {
        let bytes = encode(period: 0, sample: 0,
                           effect: 0xA, param: 0x42)
        let data = buildMK(cells: [(channel: 3, row: 10, bytes: bytes)])
        let file = try MODFile(data: data)
        let cell = file.patterns[0].rows[10][3]
        #expect(cell.period == 0)
        #expect(cell.sampleNumber == 0)
        #expect(cell.effect == 0xA)
        #expect(cell.effectParam == 0x42)
        #expect(cell.note == nil)
    }

    @Test("Empty cell decodes as all-zero")
    func emptyCell() throws {
        let data = buildMK(cells: [])
        let file = try MODFile(data: data)
        let cell = file.patterns[0].rows[0][0]
        #expect(cell.period == 0)
        #expect(cell.sampleNumber == 0)
        #expect(cell.effect == 0)
        #expect(cell.effectParam == 0)
    }

    @Test("Pattern grid sized to channelCount for 8CHN")
    func eightChannelGrid() throws {
        // Build a minimal 8CHN file — header + 2048-byte pattern.
        var data = Data(repeating: 0, count: 1084 + 64 * 8 * 4)
        data[0x3B6] = 1
        data[0x3B7] = 0x7F
        let tag: [UInt8] = [0x38, 0x43, 0x48, 0x4E]  // "8CHN"
        for (i, b) in tag.enumerated() { data[1080 + i] = b }

        let file = try MODFile(data: data)
        #expect(file.signature == .eightCHN)
        #expect(file.channelCount == 8)
        #expect(file.patterns[0].rows[0].count == 8)
    }

    @Test("Period table lookup returns C-1 at noteIndex 0")
    func periodTableLookup() {
        #expect(MODPeriod.period(noteIndex: 0, finetune: 0) == 856)
        #expect(MODPeriod.period(noteIndex: 35, finetune: 0) == 113)
        // Finetune +1 → period for C-1 drops to 850.
        #expect(MODPeriod.period(noteIndex: 0, finetune: 1) == 850)
    }

    @Test("MODNote.from(period:) is tolerant of ±1 rounding")
    func noteFromPeriodTolerance() {
        #expect(MODNote.from(period: 856)?.name == "C-1")
        #expect(MODNote.from(period: 857)?.name == "C-1")
        #expect(MODNote.from(period: 855)?.name == "C-1")
        #expect(MODNote.from(period: 113)?.name == "B-3")
        #expect(MODNote.from(period: 0) == nil)
    }
}
