// MODTerminationTests.swift
//
// Song-end detection and bounded rendering: songs that loop forever via
// Bxx / Dxx, F00, the looping option, the duration cap, tick timing,
// and rendering of fuzzed modules.

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD playback termination and timing")
struct MODTerminationTests {

    private func render(_ mixer: MODMixer, limit: Int = 44_100 * 60) -> Int {
        var total = 0
        var buffer = [Float](repeating: 0, count: 4096 * 2)
        while !mixer.isFinished && total < limit {
            total += buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
        }
        return total
    }

    @Test("B00 on the only row loops forever in ProTracker; the mixer stops after one pass")
    func positionJumpLoop() throws {
        var b = ModBuilder()
        b.samples[1] = ModBuilder.ramp(2048)
        b.set(row: 0, period: 428, sample: 1, fx: 0xB, param: 0)
        let mixer = MODMixer(file: try b.file(), sampleRate: 44_100)
        #expect(render(mixer) == 6 * 882)
        #expect(mixer.isFinished)
    }

    @Test("A backwards Dxx/Bxx chain across orders terminates")
    func backwardsJump() throws {
        var b = ModBuilder()
        b.songLength = 3; b.orders = [0, 1, 2]
        b.set(0, row: 0, fx: 0xD, param: 0)        // → order 1 row 0
        b.set(1, row: 0, fx: 0xB, param: 2)        // → order 2
        b.set(2, row: 0, fx: 0xB, param: 0)        // → order 0: already played
        let mixer = MODMixer(file: try b.file(), sampleRate: 44_100)
        #expect(render(mixer) == 3 * 6 * 882)
    }

    @Test("E6x loops replay rows without ending the song")
    func patternLoopIsNotSongEnd() throws {
        var b = ModBuilder()
        b.set(row: 0, fx: 0xE, param: 0x60)
        b.set(row: 1, fx: 0xE, param: 0x63)
        b.set(row: 2, fx: 0xB, param: 0)
        let mixer = MODMixer(file: try b.file(), sampleRate: 44_100)
        // rows 0,1 ×4, then row 2 → 9 rows.
        #expect(render(mixer) == 9 * 6 * 882)
    }

    @Test("F00 stops immediately")
    func f00() throws {
        var b = ModBuilder()
        b.set(row: 1, fx: 0xF, param: 0)
        let mixer = MODMixer(file: try b.file(), sampleRate: 44_100)
        #expect(render(mixer) == 6 * 882)
    }

    @Test("loopSong keeps playing until maximumDuration")
    func loopSongCap() throws {
        var b = ModBuilder()
        b.set(row: 0, fx: 0xB, param: 0)
        let options = MODMixer.Options(loopSong: true, maximumDuration: 2)
        let mixer = MODMixer(file: try b.file(), sampleRate: 44_100, options: options)
        #expect(render(mixer) == 88_200)
        #expect(mixer.renderedFrames == 88_200)
    }

    @Test("loopSong honours a restart byte below songLength")
    func restartByte() throws {
        var b = ModBuilder()
        b.songLength = 2; b.orders = [0, 1]; b.restart = 1
        b.set(0, row: 0, fx: 0xD, param: 0)
        b.set(1, row: 0, fx: 0xD, param: 0)
        let mixer = MODMixer(file: try b.file(), sampleRate: 1_000,
                             options: .init(loopSong: true, maximumDuration: nil))
        var orders: [Int] = []
        for _ in 0..<4 {
            _ = mixer.renderFrames(count: 120)          // one row at 1 kHz
            orders.append(mixer.currentOrder)
        }
        #expect(orders == [0, 1, 1, 1])
    }

    @Test("Tempo change takes effect after the tick that sets it")
    func tempoTiming() throws {
        var b = ModBuilder()
        b.set(row: 0, fx: 0xF, param: 64)
        let mixer = MODMixer(file: try b.file(), sampleRate: 1_000)
        var frame = 0
        while mixer.currentRow == 0 {
            _ = mixer.renderFrames(count: 1)
            frame += 1
        }
        // Tick 0 at 125 BPM (20 frames) + 5 ticks at 64 BPM (39.0625 each).
        #expect(frame == 20 + 195 + 1)
        #expect(mixer.tempo == 64)
    }

    @Test("Speed change applies to the current row")
    func speedTiming() throws {
        var b = ModBuilder()
        b.set(row: 0, fx: 0xF, param: 2)
        let mixer = MODMixer(file: try b.file(), sampleRate: 1_000)
        var frame = 0
        while mixer.currentRow == 0 {
            _ = mixer.renderFrames(count: 1)
            frame += 1
        }
        #expect(frame == 2 * 20 + 1)
    }

    @Test("render(into:) zero-fills after the end and reports frames written")
    func renderIntoReportsFrames() throws {
        var b = ModBuilder()
        b.samples[1] = ModBuilder.ramp(4096)
        b.set(row: 0, period: 428, sample: 1, fx: 0xB, param: 0)
        let mixer = MODMixer(file: try b.file(), sampleRate: 44_100)
        var buffer = [Float](repeating: 9, count: 10_000 * 2 + 1)
        let n = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
        #expect(n == 6 * 882)
        #expect(buffer[(n * 2)...].allSatisfy { $0 == 0 })
        #expect(buffer[0..<(n * 2)].contains { $0 != 0 })
        #expect(mixer.renderFrames(count: 16).allSatisfy { $0 == 0 })
    }

    @Test("Output stays within -1...1 for a hot 32-channel module")
    func clipping() throws {
        var b = ModBuilder()
        b.tag = "32CH"; b.channels = 32
        var loud = ModBuilder.Sample(data: [Int8](repeating: 127, count: 512))
        loud.loopLengthWords = 256
        b.samples[1] = loud
        for c in 0..<32 { b.set(row: 0, ch: c, period: 428, sample: 1) }
        let frames = MODMixer(file: try b.file(), sampleRate: 48_000).renderFrames(count: 4800)
        #expect(frames.allSatisfy { (-1...1).contains($0) })
        #expect(frames.contains { $0 > 0.5 })
    }

    @Test("Fuzzed modules render without trapping")
    func renderFuzz() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let base = [UInt8](MODParserTests.fixture().build())
        var rendered = 0
        for _ in 0..<300 {
            var bytes = base
            for _ in 0..<Int(rng.next() % 24 + 1) {
                // Mutate mostly pattern and sample-header bytes.
                let i = Int(rng.next() % UInt64(bytes.count))
                bytes[i] = UInt8(truncatingIfNeeded: rng.next())
            }
            guard let file = try? MODFile(data: Data(bytes)) else { continue }
            let mixer = MODMixer(file: file, sampleRate: 8_000,
                                 options: .init(maximumDuration: 2))
            _ = render(mixer, limit: 8_000 * 3)
            #expect(mixer.isFinished)
            rendered += 1
        }
        #expect(rendered > 75)
    }
}
