// MODMixerTests.swift
//
// Build a minimal one-channel-equivalent .mod (4-channel M.K. with
// silent cells on channels 1..3), give channel 0 a single sample +
// `Cxx` volume on row 0, render a chunk, and assert audible output
// on the left channel only (hard-pan policy puts channel 0 left).

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD mixer rendering")
struct MODMixerTests {

    // MARK: Fixture builder

    /// Build a synthetic M.K. file with one non-empty sample and one
    /// pattern whose row 0 channel 0 cell triggers the sample at
    /// period 428 (C-2) with `Cxx` set-volume 32.
    private func buildSineMOD(
        sampleLength: Int = 512,
        period: UInt16 = 428,
        volume: UInt8 = 32
    ) -> Data {
        // Layout: 1084 header + 1024 pattern + sampleLength sample body.
        var data = Data(repeating: 0, count: 1084 + 1024 + sampleLength)

        // Title.
        let title = "mixertest".utf8
        for (i, b) in title.enumerated() { data[i] = b }

        // Sample 1 header at offset 20:
        //  22 bytes name, 2 bytes length-in-words, 1 byte finetune,
        //  1 byte volume, 2 bytes loopStart-in-words, 2 bytes loopLength.
        let words = sampleLength / 2
        data[20 + 22]     = UInt8((words >> 8) & 0xFF)
        data[20 + 22 + 1] = UInt8(words & 0xFF)
        data[20 + 24] = 0          // finetune 0
        data[20 + 25] = 64         // default volume (the cell overrides)
        // Non-looping (loopLength <= 2).
        data[20 + 26] = 0
        data[20 + 27] = 0
        data[20 + 28] = 0
        data[20 + 29] = 1          // 1 word = 2 bytes → "no loop"

        // Song length / restart / order.
        data[0x3B6] = 1
        data[0x3B7] = 0x7F
        // order[0] = 0 (already zero).

        // Signature.
        let mk: [UInt8] = [0x4D, 0x2E, 0x4B, 0x2E]
        for (i, b) in mk.enumerated() { data[1080 + i] = b }

        // Pattern row 0, channel 0:
        //   byte 0: sample-hi-nibble (sample 1 → 0) | period-hi
        //   byte 1: period-lo
        //   byte 2: sample-lo-nibble (sample 1 → 0x10) | effect (0xC)
        //   byte 3: param (volume)
        let patternBase = 1084
        let sample: UInt8 = 1
        data[patternBase + 0] = (sample & 0xF0) | UInt8((period >> 8) & 0x0F)
        data[patternBase + 1] = UInt8(period & 0xFF)
        data[patternBase + 2] = ((sample & 0x0F) << 4) | 0x0C
        data[patternBase + 3] = volume

        // Fill sample body with a half-positive ramp so RMS is
        // predictable and non-zero.
        let bodyBase = 1084 + 1024
        for i in 0..<sampleLength {
            // 0..127, 127..0 sawtooth (just need non-zero samples).
            let v = Int8((i & 0x7F))
            data[bodyBase + i] = UInt8(bitPattern: v)
        }

        return data
    }

    // MARK: Tests

    @Test("Mixer renders non-zero left channel for channel-0 hard-pan")
    func leftChannelAudible() throws {
        let mod = try MODFile(data: buildSineMOD(sampleLength: 2048))
        let mixer = MODMixer(file: mod, sampleRate: 44_100)

        // 1024 frames ≈ ~23 ms at 44.1 kHz — well within the first
        // tick (one tick at default speed/tempo is 20 ms).
        let frames = mixer.renderFrames(count: 1024)
        #expect(frames.count == 2048)

        var leftEnergy: Float = 0
        var rightEnergy: Float = 0
        for i in stride(from: 0, to: frames.count, by: 2) {
            leftEnergy  += frames[i]     * frames[i]
            rightEnergy += frames[i + 1] * frames[i + 1]
        }
        #expect(leftEnergy > 0)
        #expect(rightEnergy == 0)   // channel 0 = hard left
    }

    @Test("Rendered RMS scales with Cxx volume parameter")
    func volumeAffectsRMS() throws {
        let modHi = try MODFile(data: buildSineMOD(sampleLength: 2048,
                                                   volume: 64))
        let modLo = try MODFile(data: buildSineMOD(sampleLength: 2048,
                                                   volume: 16))
        let mixHi = MODMixer(file: modHi, sampleRate: 44_100)
        let mixLo = MODMixer(file: modLo, sampleRate: 44_100)

        let framesHi = mixHi.renderFrames(count: 512)
        let framesLo = mixLo.renderFrames(count: 512)

        let rmsHi = rms(framesHi)
        let rmsLo = rms(framesLo)
        #expect(rmsHi > 0)
        #expect(rmsLo > 0)
        // Volume 64 should be ~4x volume 16 RMS, allowing a margin
        // for interpolation noise and the soft clipper.
        #expect(rmsHi > rmsLo * 2.5)
    }

    @Test("Mixer with no sample / no period emits silence")
    func silentByDefault() {
        // Build a completely empty M.K. file (no triggered note).
        var data = Data(repeating: 0, count: 1084 + 1024)
        data[0x3B6] = 1
        data[0x3B7] = 0x7F
        let mk: [UInt8] = [0x4D, 0x2E, 0x4B, 0x2E]
        for (i, b) in mk.enumerated() { data[1080 + i] = b }

        let file = try! MODFile(data: data)
        let mixer = MODMixer(file: file, sampleRate: 44_100)
        let frames = mixer.renderFrames(count: 512)
        #expect(frames.allSatisfy { $0 == 0 })
    }

    @Test("Mixer finishes when song length runs out")
    func mixerFinishes() throws {
        // 1-row pattern, songLength=1, restartByte=0x7F (play once).
        // Render long enough to exhaust the single row at default
        // 6 ticks × 20 ms per tick = 120 ms.
        let file = try MODFile(data: buildSineMOD(sampleLength: 256))
        let mixer = MODMixer(file: file, sampleRate: 44_100)
        // Render ~10 seconds — far more than the song lasts.
        _ = mixer.renderFrames(count: 44_100 * 10)
        #expect(mixer.isFinished == true)
    }

    // MARK: Helper

    private func rms(_ buf: [Float]) -> Float {
        guard !buf.isEmpty else { return 0 }
        var s: Float = 0
        for v in buf { s += v * v }
        return (s / Float(buf.count)).squareRoot()
    }
}
