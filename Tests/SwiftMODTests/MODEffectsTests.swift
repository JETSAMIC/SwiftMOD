// MODEffectsTests.swift
//
// Effect semantics against ProTracker 2.x behaviour, driven through the
// replayer with hand-built modules. Ported from the original dispatcher
// tests; the two that asserted non-ProTracker behaviour are corrected
// (A00 has no memory in ProTracker; 9xx applies to the note it shares a
// row with, not to the currently playing position).

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD effects (ProTracker semantics)")
struct MODEffectsTests {

    private func builder(_ rows: (inout ModBuilder) -> Void) -> ModBuilder {
        var b = ModBuilder()
        b.samples[1] = ModBuilder.ramp(16384)
        rows(&b)
        return b
    }

    // MARK: Tick-0 commands

    @Test("Cxx sets the channel volume on tick 0")
    func setVolume() throws {
        var r = try builder { $0.set(row: 0, period: 428, sample: 1, fx: 0xC, param: 32) }.replayer()
        r.tick()
        #expect(r.channels[0].volume == 32)
        #expect(r.voices[0].volume == 32)
    }

    @Test("Cxx with param > 64 clamps to 64")
    func setVolumeClamp() throws {
        var r = try builder { $0.set(row: 0, fx: 0xC, param: 99) }.replayer()
        r.tick()
        #expect(r.channels[0].volume == 64)
    }

    @Test("9xx starts the note at param × 256 and is applied twice (PT quirk)")
    func sampleOffset() throws {
        var r = try builder { $0.set(row: 0, period: 428, sample: 1, fx: 0x9, param: 0x10) }.replayer()
        r.tick()
        #expect(r.voices[0].position == 0x1000)
        // ProTracker adds the offset to n_start again after triggering,
        // so a later note without a sample number starts at 0x2000.
        #expect(r.channels[0].start == 0x2000)
    }

    @Test("9xx with zero param replays the last non-zero offset")
    func sampleOffsetMemory() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0x9, param: 0x20)
            $0.set(row: 1, period: 428, sample: 1, fx: 0x9, param: 0x00)
        }.replayer()
        r.ticks(7)
        #expect(r.currentRow == 1)
        #expect(r.voices[0].position == 0x2000)
    }

    @Test("9xx past the sample end plays nothing for a one-shot sample")
    func sampleOffsetBeyondEnd() throws {
        var b = ModBuilder()
        b.samples[1] = ModBuilder.ramp(512)
        b.set(row: 0, period: 428, sample: 1, fx: 0x9, param: 0x04)
        var r = try b.replayer()
        r.tick()
        // n_length becomes one word: two bytes at the start, then idle.
        #expect(r.voices[0].end - r.voices[0].position == 2)
    }

    @Test("Fxx with param < 0x20 sets speed; F1F is still speed")
    func setSpeed() throws {
        var r = try builder { $0.set(row: 0, fx: 0xF, param: 0x1F) }.replayer()
        r.tick()
        #expect(r.speed == 31)
        #expect(r.tempo == 125)
    }

    @Test("Fxx with param >= 0x20 sets tempo; F20 is BPM 32")
    func setTempo() throws {
        var r = try builder { $0.set(row: 0, fx: 0xF, param: 0x20) }.replayer()
        r.tick()
        #expect(r.tempo == 32)
        #expect(r.speed == 6)
    }

    @Test("F00 stops the song")
    func f00Stops() throws {
        var r = try builder { $0.set(row: 0, fx: 0xF, param: 0) }.replayer()
        r.tick()
        #expect(r.ended)
    }

    @Test("Bxx jumps to the order at the end of the row")
    func positionJump() throws {
        var r = try builder {
            $0.songLength = 4; $0.orders = [0, 0, 0, 0]
            $0.set(row: 0, fx: 0xB, param: 3)
        }.replayer()
        r.ticks(7)
        #expect(r.currentOrder == 3)
        #expect(r.currentRow == 0)
    }

    @Test("Dxx decodes its parameter as decimal (D32 → row 32)")
    func patternBreak() throws {
        var r = try builder {
            $0.songLength = 2; $0.orders = [0, 0]
            $0.set(row: 0, fx: 0xD, param: 0x32)
        }.replayer()
        r.ticks(7)
        #expect(r.currentOrder == 1)
        #expect(r.currentRow == 32)
    }

    @Test("Dxx with a row above 63 breaks to row 0")
    func patternBreakOverflow() throws {
        var r = try builder {
            $0.songLength = 2; $0.orders = [0, 0]
            $0.set(row: 0, fx: 0xD, param: 0x70)
        }.replayer()
        r.ticks(7)
        #expect(r.currentOrder == 1)
        #expect(r.currentRow == 0)
    }

    @Test("Bxx cancels a Dxx to its left; Dxx to its right keeps its row")
    func breakJumpOrdering() throws {
        var r = try builder {
            $0.songLength = 3; $0.orders = [0, 0, 0]
            $0.set(row: 0, ch: 0, fx: 0xD, param: 0x10)
            $0.set(row: 0, ch: 1, fx: 0xB, param: 2)
        }.replayer()
        r.ticks(7)
        #expect(r.currentOrder == 2 && r.currentRow == 0)

        var s = try builder {
            $0.songLength = 3; $0.orders = [0, 0, 0]
            $0.set(row: 0, ch: 0, fx: 0xB, param: 2)
            $0.set(row: 0, ch: 1, fx: 0xD, param: 0x10)
        }.replayer()
        s.ticks(7)
        #expect(s.currentOrder == 2 && s.currentRow == 10)
    }

    @Test("E5x sets finetune; a note on the same row uses it")
    func setFinetune() throws {
        var r = try builder { $0.set(row: 0, period: 428, sample: 1, fx: 0xE, param: 0x5D) }.replayer()
        r.tick()
        #expect(r.channels[0].finetune == 0xD)          // nibble D = -3
        #expect(r.channels[0].period == 437)            // C-2 at finetune -3
    }

    @Test("Sample finetune re-reads the note from its finetune row")
    func sampleFinetune() throws {
        var b = ModBuilder()
        b.samples[1] = ModBuilder.ramp(1024)
        b.samples[1]?.finetuneNibble = 0x8             // -8
        b.set(row: 0, period: 856, sample: 1)
        var r = try b.replayer()
        r.tick()
        #expect(r.channels[0].period == 907)
    }

    @Test("E7x sets tremolo waveform + retain bit")
    func setTremoloWaveform() throws {
        var r = try builder { $0.set(row: 0, fx: 0xE, param: 0x76) }.replayer()
        r.tick()
        #expect(r.channels[0].waveControl >> 4 == 6)
    }

    // MARK: Continuous commands

    @Test("Arpeggio 0xy: base, +x, +y, base on ticks 0-3")
    func arpeggio() throws {
        var r = try builder { $0.set(row: 0, period: 428, sample: 1, fx: 0x0, param: 0x47) }.replayer()
        r.tick(); #expect(r.voices[0].period == 428)
        r.tick(); #expect(r.voices[0].period == 339)
        r.tick(); #expect(r.voices[0].period == 285)
        r.tick(); #expect(r.voices[0].period == 428)
        #expect(r.channels[0].period == 428)
    }

    @Test("Arpeggio past B-3 reads ProTracker's trailing 0 period")
    func arpeggioOverflow() throws {
        var r = try builder { $0.set(row: 0, period: 113, sample: 1, fx: 0x0, param: 0x10) }.replayer()
        r.ticks(2)
        #expect(r.voices[0].period == 0)
    }

    @Test("1xx portamento up subtracts per tick, clamps at 113")
    func portamentoUp() throws {
        var r = try builder {
            $0.set(row: 0, period: 508, sample: 1, fx: 0x1, param: 5)
            $0.set(row: 1, fx: 0x1, param: 0xFF)
        }.replayer()
        r.ticks(2); #expect(r.channels[0].period == 503)
        r.tick();   #expect(r.channels[0].period == 498)
        r.ticks(6); #expect(r.channels[0].period == 113)   // 483 → 228 → 113
    }

    @Test("2xx portamento down adds per tick, clamps at 856")
    func portamentoDown() throws {
        var r = try builder {
            $0.set(row: 0, period: 508, sample: 1, fx: 0x2, param: 5)
            $0.set(row: 1, fx: 0x2, param: 0xFF)
        }.replayer()
        r.ticks(2); #expect(r.channels[0].period == 513)
        r.ticks(7); #expect(r.channels[0].period == 856)   // 533 → 788 → 856
    }

    @Test("100 / 200 do nothing (no memory in ProTracker)")
    func portamentoNoMemory() throws {
        var r = try builder {
            $0.set(row: 0, period: 508, sample: 1, fx: 0x1, param: 5)
            $0.set(row: 1, fx: 0x1, param: 0)
        }.replayer()
        r.ticks(6)
        let p = r.channels[0].period
        r.ticks(6)
        #expect(r.channels[0].period == p)
    }

    @Test("3xx tone portamento slides toward the note without retriggering")
    func tonePortamento() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1)
            $0.set(row: 1, period: 339, fx: 0x3, param: 10)
        }.replayer()
        r.ticks(6)
        let pos = r.voices[0].position
        r.tick()
        #expect(r.channels[0].wantedPeriod == 339)
        #expect(r.channels[0].period == 428)
        #expect(r.voices[0].position == pos)            // not retriggered
        r.tick()
        #expect(r.channels[0].period == 418)
    }

    @Test("300 continues with the remembered speed and stops at the target")
    func tonePortamentoMemory() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1)
            $0.set(row: 1, period: 404, fx: 0x3, param: 10)
            $0.set(row: 2, fx: 0x3, param: 0)
        }.replayer()
        r.ticks(12)                                      // rows 0,1 → 428-50=378 clamps at 404
        #expect(r.channels[0].period == 404)
        #expect(r.channels[0].wantedPeriod == 0)
        r.ticks(6)
        #expect(r.channels[0].period == 404)
    }

    @Test("E3x glissando rounds the output period to semitones")
    func glissando() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xE, param: 0x31)
            $0.set(row: 1, period: 339, fx: 0x3, param: 4)
        }.replayer()
        r.ticks(8)                                       // row 1, tick 1: n_period 424
        #expect(r.channels[0].period == 424)
        #expect(r.voices[0].period == 404)               // first note ≤ 424 is C#-2
    }

    @Test("Axy slides volume on ticks 1+; A00 has no memory")
    func volumeSlide() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xC, param: 32)
            $0.set(row: 1, fx: 0xA, param: 0x02)
            $0.set(row: 2, fx: 0xA, param: 0x00)
        }.replayer()
        r.ticks(7)
        #expect(r.channels[0].volume == 32)              // tick 0 of row 1
        r.tick()
        #expect(r.channels[0].volume == 30)
        r.ticks(4)
        #expect(r.channels[0].volume == 22)
        r.ticks(6)
        #expect(r.channels[0].volume == 22)              // A00: nothing
    }

    @Test("Axy with both nibbles slides up only")
    func volumeSlideUpWins() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xC, param: 10)
            $0.set(row: 1, fx: 0xA, param: 0x23)
        }.replayer()
        r.ticks(8)
        #expect(r.channels[0].volume == 12)
    }

    @Test("4xy vibrato is not applied on tick 0, then follows the sine table")
    func vibrato() throws {
        var r = try builder { $0.set(row: 0, period: 428, sample: 1, fx: 0x4, param: 0x48) }.replayer()
        r.tick(); #expect(r.voices[0].period == 428)
        r.tick(); #expect(r.voices[0].period == 428)     // sine[0] = 0
        r.tick(); #expect(r.voices[0].period == 428 + (97 * 8) >> 7)
        #expect(r.channels[0].period == 428)
    }

    @Test("E42 square vibrato and E41 ramp-down vibrato")
    func vibratoWaveforms() throws {
        var sq = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xE, param: 0x42)
            $0.set(row: 1, fx: 0x4, param: 0x18)
        }.replayer()
        sq.ticks(8)
        #expect(sq.voices[0].period == 428 + (255 * 8) >> 7)

        var ramp = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xE, param: 0x41)
            $0.set(row: 1, fx: 0x4, param: 0x48)
        }.replayer()
        ramp.ticks(9)                                    // positions 0, 16 → index 4 → 32
        #expect(ramp.voices[0].period == 428 + (32 * 8) >> 7)
    }

    @Test("7xy tremolo modulates output volume, not channel volume")
    func tremolo() throws {
        var r = try builder { $0.set(row: 0, period: 428, sample: 1, fx: 0x7, param: 0x48) }.replayer()
        r.ticks(3)
        #expect(r.voices[0].volume == 64)                // clamp at 64
        #expect(r.channels[0].volume == 64)
        var d = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xC, param: 32)
            $0.set(row: 1, fx: 0x7, param: 0x48)
        }.replayer()
        d.ticks(9)
        #expect(d.voices[0].volume == 32 + (97 * 8) >> 6)
        #expect(d.channels[0].volume == 32)
    }

    @Test("E1x fine portamento up applies on tick 0 only")
    func finePortaUp() throws {
        var r = try builder {
            $0.set(row: 0, period: 508, sample: 1)
            $0.set(row: 1, fx: 0xE, param: 0x14)
        }.replayer()
        r.ticks(7); #expect(r.channels[0].period == 504)
        r.tick();   #expect(r.channels[0].period == 504)
    }

    @Test("EAx / EBx fine volume slides apply on tick 0 only")
    func fineVolume() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xC, param: 30)
            $0.set(row: 1, fx: 0xE, param: 0xA4)
            $0.set(row: 2, fx: 0xE, param: 0xB9)
        }.replayer()
        r.ticks(12); #expect(r.channels[0].volume == 34)
        r.ticks(6);  #expect(r.channels[0].volume == 25)
    }

    @Test("ECx note cut zeroes volume on tick x")
    func noteCut() throws {
        var b = ModBuilder()
        b.samples[1] = ModBuilder.ramp(4096, volume: 50)
        b.set(row: 0, period: 428, sample: 1, fx: 0xE, param: 0xC2)
        var r = try b.replayer()
        r.tick(); #expect(r.channels[0].volume == 50)
        r.tick(); #expect(r.channels[0].volume == 50)
        r.tick(); #expect(r.channels[0].volume == 0)
    }

    @Test("EDx delays the trigger to tick x; period is latched on tick 0")
    func noteDelay() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1)
            $0.set(row: 1, period: 214, sample: 1, fx: 0xE, param: 0xD3)
        }.replayer()
        r.ticks(7)
        #expect(r.channels[0].period == 214)
        #expect(r.voices[0].period == 428)
        r.voices[0].position = 500                       // pretend the old note played on
        r.ticks(2)
        #expect(r.voices[0].position == 500)
        r.tick()                                         // tick 3
        #expect(r.voices[0].position == 0)
        #expect(r.voices[0].period == 214)
    }

    @Test("EDx beyond speed never triggers; next row picks up the period")
    func noteDelayPastRow() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1)
            $0.set(row: 1, period: 214, sample: 1, fx: 0xE, param: 0xD9)
        }.replayer()
        r.ticks(12)
        #expect(r.voices[0].period == 428)
        r.tick()                                         // row 2, tick 0
        #expect(r.voices[0].period == 214)
    }

    @Test("E9x retriggers every x ticks, not on tick 0 with a note")
    func retrigger() throws {
        var r = try builder { $0.set(row: 0, period: 428, sample: 1, fx: 0xE, param: 0x93) }.replayer()
        r.ticks(3)
        r.voices[0].position = 1000
        r.tick()                                         // tick 3 → retrigger
        #expect(r.voices[0].position == 0)
        r.voices[0].position = 1000
        r.ticks(2)                                       // ticks 4, 5: no retrigger
        #expect(r.voices[0].position == 1000)
        r.tick()                                         // next row, tick 0: no E9x
        #expect(r.voices[0].position == 1000)
    }

    @Test("EEx repeats the row x extra times")
    func patternDelay() throws {
        var r = try builder { $0.set(row: 0, fx: 0xE, param: 0xE3) }.replayer()
        r.ticks(24)
        #expect(r.currentRow == 0)
        r.tick()
        #expect(r.currentRow == 1)
    }

    @Test("EEx repeats fine slides on each repetition")
    func patternDelayFineSlides() throws {
        var r = try builder {
            $0.set(row: 0, period: 428, sample: 1, fx: 0xC, param: 10)
            $0.set(row: 1, ch: 0, fx: 0xE, param: 0xA2)
            $0.set(row: 1, ch: 1, fx: 0xE, param: 0xE2)
        }.replayer()
        r.ticks(6 + 18)
        #expect(r.channels[0].volume == 16)
    }

    @Test("EEx + Dxx on the same row skips the break's target row")
    func delayBreak() throws {
        var r = try builder {
            $0.songLength = 2; $0.orders = [0, 0]
            $0.set(row: 0, ch: 0, fx: 0xE, param: 0xE1)
            $0.set(row: 0, ch: 1, fx: 0xD, param: 0x05)
        }.replayer()
        r.ticks(13)
        #expect(r.currentOrder == 1)
        #expect(r.currentRow == 6)
    }

    @Test("E60 / E6x loop a block of rows x extra times")
    func patternLoop() throws {
        var r = try builder {
            $0.set(row: 1, fx: 0xE, param: 0x60)
            $0.set(row: 2, fx: 0xE, param: 0x62)
        }.replayer()
        var rows: [Int] = []
        for _ in 0..<8 {
            r.tick()
            rows.append(r.currentRow)
            r.ticks(5)
        }
        #expect(rows == [0, 1, 2, 1, 2, 1, 2, 3])
    }

    @Test("Sample number without note swaps the sample at the loop end")
    func instrumentSwap() throws {
        var b = ModBuilder()
        var looped = ModBuilder.ramp(64)
        looped.loopStartWords = 0; looped.loopLengthWords = 32
        b.samples[1] = looped
        var other = ModBuilder.ramp(256, volume: 20)
        other.loopStartWords = 64; other.loopLengthWords = 32
        b.samples[2] = other
        b.set(row: 0, period: 428, sample: 1)
        b.set(row: 1, sample: 2)
        var r = try b.replayer()
        r.ticks(7)
        #expect(r.voices[0].volume == 20)                // volume applies now
        #expect(r.voices[0].sample == 0)                 // still sample 1
        #expect(r.voices[0].loopSample == 1)
        r.voices[0].reload(overshoot: 0, data: r.sampleData)
        #expect(r.voices[0].sample == 1)
        #expect(r.voices[0].position == 128)
        #expect(r.voices[0].end == 192)
    }

    @Test("Loop start 0 plays the whole sample once; loop start > 0 cuts at loop end")
    func loopStartQuirk() throws {
        var b = ModBuilder()
        var a = ModBuilder.ramp(200); a.loopStartWords = 0; a.loopLengthWords = 10
        var c = ModBuilder.ramp(200); c.loopStartWords = 10; c.loopLengthWords = 10
        b.samples[1] = a; b.samples[2] = c
        b.set(row: 0, ch: 0, period: 428, sample: 1)
        b.set(row: 0, ch: 1, period: 428, sample: 2)
        var r = try b.replayer()
        r.tick()
        #expect(r.voices[0].end == 200)
        #expect(r.voices[1].end == 40)
    }

    @Test("Soundtracker modules play only the looped part of a looped sample")
    func soundtrackerLoopOnly() throws {
        // Spec §3.4 / §6.4: a 15-sample module plays [loopStart, loopEnd)
        // from the first tick, whether the loop starts at 0 or later.
        var b = ModBuilder()
        b.tag = nil
        var a = ModBuilder.ramp(200); a.loopStartWords = 0; a.loopLengthWords = 10
        var c = ModBuilder.ramp(200); c.loopStartWords = 50; c.loopLengthWords = 10   // 50 bytes
        b.samples[1] = a; b.samples[2] = c; b.samples[3] = ModBuilder.ramp(200)
        b.set(row: 0, ch: 0, period: 428, sample: 1)
        b.set(row: 0, ch: 1, period: 428, sample: 2)
        b.set(row: 0, ch: 2, period: 428, sample: 3)
        var r = try b.replayer()
        r.tick()
        #expect(r.voices[0].position == 0 && r.voices[0].end == 20)
        #expect(r.voices[1].position == 50 && r.voices[1].end == 70)
        // A one-shot sample still plays from its start to its end.
        #expect(r.voices[2].position == 0 && r.voices[2].end == 200)
    }

    @Test("Multichannel modules keep periods outside C-1...B-3")
    func extendedRange() throws {
        var b = ModBuilder()
        b.tag = "8CHN"; b.channels = 8
        b.samples[1] = ModBuilder.ramp(1024)
        b.set(row: 0, period: 1712, sample: 1)
        var r = try b.replayer()
        r.tick()
        #expect(r.channels[0].period == 1712)

        var pt = ModBuilder()
        pt.samples[1] = ModBuilder.ramp(1024)
        pt.set(row: 0, period: 1712, sample: 1)
        var p = try pt.replayer()
        p.tick()
        #expect(p.channels[0].period == 856)             // ProTracker clamps to C-1
    }
}
