// MODPlaybackTests.swift
//
// End-to-end render: build a multi-pattern, multi-effect synthetic
// .mod and render to completion. No public-domain `.mod` fixture is
// bundled with the repository (we don't want to redistribute even a
// permissively-licensed Amiga module via this test target without
// auditing each one), so this suite drives a hand-built fixture.

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD end-to-end playback")
struct MODPlaybackTests {

    /// Build a 2-order, 1-pattern .mod with assorted effects on
    /// channel 0 so we exercise tick-0 + continuous dispatch paths
    /// during a full song render.
    private func buildEndToEndMOD() -> Data {
        // 2 orders pointing at pattern 0 (so the song lasts twice
        // as long as the pattern). 4-channel M.K., 1 sample,
        // 64-row pattern with a few effect rows seeded.
        let sampleLength = 1024
        var data = Data(repeating: 0, count: 1084 + 1024 + sampleLength)

        // Sample header 1: length = 512 words, vol 64, no loop.
        let words = sampleLength / 2
        data[20 + 22]     = UInt8((words >> 8) & 0xFF)
        data[20 + 22 + 1] = UInt8(words & 0xFF)
        data[20 + 25] = 64
        data[20 + 29] = 1   // loopLength = 1 word = 2 bytes ("no loop")

        // Song header.
        data[0x3B6] = 2     // songLength
        data[0x3B7] = 0x7F  // restart byte (play once)
        // order[0] = 0, order[1] = 0 (already zero).

        // Signature.
        let mk: [UInt8] = [0x4D, 0x2E, 0x4B, 0x2E]
        for (i, b) in mk.enumerated() { data[1080 + i] = b }

        // Write a sequence of cells on channel 0:
        // row 0: trigger sample 1, period 428 (C-2), C20 set vol 32
        // row 4: 4xy vibrato 0x42 (speed 4, depth 2)
        // row 8: 0xy arpeggio 0x47
        // row 12: Cxx volume 48
        // row 16: F04 — set speed 4
        // row 32: D00 — pattern break to row 0 of next pattern
        let patternBase = 1084
        let cellSize = 4
        let rowBytes = 4 * cellSize

        func writeCell(row: Int, channel: Int,
                       period: UInt16, sample: UInt8,
                       effect: UInt8, param: UInt8) {
            let base = patternBase + row * rowBytes + channel * cellSize
            data[base + 0] = (sample & 0xF0) | UInt8((period >> 8) & 0x0F)
            data[base + 1] = UInt8(period & 0xFF)
            data[base + 2] = ((sample & 0x0F) << 4) | (effect & 0x0F)
            data[base + 3] = param
        }

        writeCell(row: 0,  channel: 0, period: 428, sample: 1, effect: 0xC, param: 32)
        writeCell(row: 4,  channel: 0, period: 0,   sample: 0, effect: 0x4, param: 0x42)
        writeCell(row: 8,  channel: 0, period: 0,   sample: 0, effect: 0x0, param: 0x47)
        writeCell(row: 12, channel: 0, period: 0,   sample: 0, effect: 0xC, param: 48)
        writeCell(row: 16, channel: 0, period: 0,   sample: 0, effect: 0xF, param: 4)
        writeCell(row: 32, channel: 0, period: 0,   sample: 0, effect: 0xD, param: 0x00)

        // Sample body — half-positive ramp.
        let bodyBase = 1084 + 1024
        for i in 0..<sampleLength {
            data[bodyBase + i] = UInt8(bitPattern: Int8(i & 0x7F))
        }

        return data
    }

    @Test("End-to-end render of a synthetic 2-order .mod completes without crash")
    func endToEnd() throws {
        let file = try MODFile(data: buildEndToEndMOD())
        let mixer = MODMixer(file: file, sampleRate: 44_100)

        // Render up to 30 seconds in 4096-frame chunks. Stop as
        // soon as the mixer reports it's finished.
        var totalFrames = 0
        let maxFrames = 44_100 * 30
        while totalFrames < maxFrames {
            let chunk = mixer.renderFrames(count: 4096)
            #expect(chunk.count == 4096 * 2)
            totalFrames += 4096
            if mixer.isFinished { break }
        }

        #expect(mixer.isFinished == true)
        #expect(totalFrames > 0)
        #expect(totalFrames < maxFrames)
    }

    @Test("SwiftMOD.decode + SwiftMOD.mixer facade renders without error")
    func facadeWorks() throws {
        let file = try SwiftMOD.decode(buildEndToEndMOD())
        let mixer = SwiftMOD.mixer(for: file, sampleRate: 48_000)
        let frames = mixer.renderFrames(count: 480)
        #expect(frames.count == 960)
    }
}
