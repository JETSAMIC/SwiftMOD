// MODHeaderTests.swift
//
// Synthesize a minimal 1084-byte M.K. header (plus one empty
// 4-channel pattern and zero sample bodies), parse it through
// `MODFile(data:)`, and assert the public fields round-trip.

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD header parsing")
struct MODHeaderTests {

    /// Build a minimal valid M.K. file:
    /// - title bytes 0..<20
    /// - 31 empty sample headers
    /// - songLength = 1, restart = 0x7F
    /// - order[0] = 0, rest 0
    /// - 1 pattern × 4 channels × 64 rows × 4 bytes = 1024 bytes
    /// - no sample bodies
    private func buildMinimalMK(title: String = "test") -> Data {
        var data = Data(repeating: 0, count: 1084 + 1024)

        // Title.
        let titleBytes = Array(title.utf8).prefix(20)
        for (i, b) in titleBytes.enumerated() {
            data[i] = b
        }

        // Song length + restart.
        data[0x3B6] = 1
        data[0x3B7] = 0x7F

        // Order[0] = 0 — already 0.

        // Signature M.K.
        let mk: [UInt8] = [0x4D, 0x2E, 0x4B, 0x2E]
        for (i, b) in mk.enumerated() {
            data[1080 + i] = b
        }

        // Pattern data is already all zeros (empty cells).
        return data
    }

    @Test("Minimal M.K. file parses with empty pattern")
    func parseMinimalMK() throws {
        let data = buildMinimalMK(title: "hello")
        let file = try MODFile(data: data)

        #expect(file.title == "hello")
        #expect(file.signature == .mk)
        #expect(file.channelCount == 4)
        #expect(file.samples.count == 31)
        #expect(file.songLength == 1)
        #expect(file.restartByte == 0x7F)
        #expect(file.patternOrder.count == 128)
        #expect(file.patterns.count == 1)
        #expect(file.patterns[0].rows.count == 64)
        #expect(file.patterns[0].rows[0].count == 4)
    }

    @Test("Sample header fields round-trip")
    func sampleHeaderRoundTrip() throws {
        var data = buildMinimalMK()

        // Sample 1 = first sample header at offset 20.
        // Layout: 22 bytes name, 2 bytes length (words, BE),
        //         1 byte finetune nibble, 1 byte volume,
        //         2 bytes loopStart (words, BE),
        //         2 bytes loopLength (words, BE).
        let name = "kick".utf8
        for (i, b) in name.enumerated() {
            data[20 + i] = b
        }
        // Length = 0x0100 words = 512 bytes.
        data[20 + 22]     = 0x01
        data[20 + 22 + 1] = 0x00
        // Finetune = -3 → nibble 0xD.
        data[20 + 24] = 0x0D
        // Volume = 48.
        data[20 + 25] = 48
        // loopStart = 0x0010 words = 32 bytes.
        data[20 + 26] = 0x00
        data[20 + 27] = 0x10
        // loopLength = 0x0080 words = 256 bytes.
        data[20 + 28] = 0x00
        data[20 + 29] = 0x80

        // Append 512 bytes of sample data after the pattern block.
        data.append(contentsOf: repeatElement(UInt8(0x42), count: 512))

        let file = try MODFile(data: data)
        let s1 = file.samples[0]
        #expect(s1.name == "kick")
        #expect(s1.length == 512)
        #expect(s1.finetune == -3)
        #expect(s1.volume == 48)
        #expect(s1.loopStart == 32)
        #expect(s1.loopLength == 256)
        #expect(s1.data.count == 512)
        #expect(s1.data.first == 0x42)  // 0x42 is positive Int8 → 66
        #expect(s1.loops == true)
    }

    @Test("Order table beyond songLength still readable")
    func orderTableSize() throws {
        var data = buildMinimalMK()
        // Stash a stray byte at order[64] — should be ignored by
        // patternCount math but still readable in patternOrder.
        data[0x3B8 + 64] = 0xFE
        let file = try MODFile(data: data)
        #expect(file.patternOrder[64] == 0xFE)
        #expect(file.patterns.count == 1)  // max in 0..<1 == 0
    }

    @Test("Too-short data throws .truncated")
    func tooShortRejected() {
        let data = Data(repeating: 0, count: 100)
        #expect(throws: MODError.self) {
            try MODFile(data: data)
        }
    }
}
