// MODEffectsTests.swift
//
// Drive `dispatchEffect` directly against synthetic cells and check
// that the per-channel + song state changes line up with the
// ProTracker spec.

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD effect dispatch")
struct MODEffectsTests {

    // MARK: Helpers

    private func cell(
        period: UInt16 = 0,
        sample: UInt8 = 0,
        effect: UInt8,
        param: UInt8
    ) -> MODCell {
        MODCell(
            period: period,
            sampleNumber: sample,
            effect: effect,
            effectParam: param
        )
    }

    // MARK: Tick-0 "set" commands

    @Test("Cxx sets the channel volume on tick 0")
    func setVolume() {
        var ch = MODChannel()
        var song = MODSongState()
        let c = cell(effect: 0xC, param: 32)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.volume == 32)
    }

    @Test("Cxx with param > 64 clamps to 64")
    func setVolumeClamp() {
        var ch = MODChannel()
        var song = MODSongState()
        let c = cell(effect: 0xC, param: 99)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.volume == 64)
    }

    @Test("9xx sets sample offset to param × 256")
    func sampleOffset() {
        var ch = MODChannel()
        var song = MODSongState()
        let c = cell(effect: 0x9, param: 0x10)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        // 0x10 * 256 = 0x1000 in byte-space, Q16.16.
        #expect(ch.samplePosition == UInt64(0x1000) << 16)
    }

    @Test("9xx with zero param replays last non-zero offset")
    func sampleOffsetMemory() {
        var ch = MODChannel()
        var song = MODSongState()
        var c = cell(effect: 0x9, param: 0x20)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        // Reset position so we can see the memory recall.
        ch.samplePosition = 0
        c = cell(effect: 0x9, param: 0x00)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.samplePosition == UInt64(0x2000) << 16)
    }

    @Test("Fxx with param < 0x20 sets speed (ticks/row)")
    func setSpeed() {
        var ch = MODChannel()
        var song = MODSongState()
        let c = cell(effect: 0xF, param: 4)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(song.speed == 4)
        #expect(song.tempo == 125)
    }

    @Test("Fxx with param >= 0x20 sets tempo (BPM)")
    func setTempo() {
        var ch = MODChannel()
        var song = MODSongState()
        let c = cell(effect: 0xF, param: 160)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(song.tempo == 160)
        #expect(song.speed == 6)
    }

    @Test("Bxx queues a position jump")
    func positionJump() {
        var ch = MODChannel()
        var song = MODSongState()
        let c = cell(effect: 0xB, param: 3)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(song.pendingPositionJump == 3)
    }

    @Test("Dxx decodes BCD-ish row index for pattern break")
    func patternBreak() {
        var ch = MODChannel()
        var song = MODSongState()
        // Param 0x32 → row 32 (NOT 50 — ProTracker uses BCD-ish:
        // high × 10 + low).
        let c = cell(effect: 0xD, param: 0x32)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(song.pendingPatternBreakRow == 32)
    }

    @Test("E5x sets channel finetune (signed nibble)")
    func setFinetune() {
        var ch = MODChannel()
        var song = MODSongState()
        // E5D → finetune -3 (D = 13, signed-4 → -3).
        let c = cell(effect: 0xE, param: 0x5D)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.finetune == -3)
    }

    @Test("E7x sets tremolo waveform + retain bit")
    func setTremoloWaveform() {
        var ch = MODChannel()
        var song = MODSongState()
        // E7 6 → waveform 2 (square), bit 2 (retain) set.
        let c = cell(effect: 0xE, param: 0x76)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.tremolo.waveform == .square)
        #expect(ch.tremolo.retainPosition == true)
    }

    // MARK: Continuous-tick commands

    @Test("Arpeggio 0xy shifts period on ticks 1/2, restores on tick 3")
    func arpeggio() {
        var ch = MODChannel()
        var song = MODSongState()
        // Base note C-2 (period 428). Arpeggio +4 / +7 semitones.
        ch.period = 428
        ch.notePeriod = 428
        let c = cell(effect: 0x0, param: 0x47)

        // Tick 0 — latches, no change.
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.period == 428)

        // Tick 1 — +4 semitones from C-2 = E-2, period 339.
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.period == 339)

        // Tick 2 — +7 semitones from C-2 = G-2, period 285.
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 2)
        #expect(ch.period == 285)

        // Tick 3 — phase 0 again, restored to base.
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 3)
        #expect(ch.period == 428)
    }

    @Test("1xx portamento up subtracts param from period per tick")
    func portamentoUp() {
        var ch = MODChannel()
        var song = MODSongState()
        ch.period = 500
        let c = cell(effect: 0x1, param: 5)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.period == 495)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 2)
        #expect(ch.period == 490)
    }

    @Test("2xx portamento down adds param to period per tick")
    func portamentoDown() {
        var ch = MODChannel()
        var song = MODSongState()
        ch.period = 500
        let c = cell(effect: 0x2, param: 5)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.period == 505)
    }

    @Test("3xx tone portamento slides toward target per tick")
    func tonePortamento() {
        var ch = MODChannel()
        var song = MODSongState()
        ch.period = 428
        ch.portaTarget = 0
        // Tick 0 sets the target from the cell's period.
        let c = MODCell(period: 339, sampleNumber: 0, effect: 0x3, effectParam: 10)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.portaTarget == 339)
        // Tick 1 slides 10 units toward 339 (period > target, so
        // period -= 10).
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.period == 418)
    }

    @Test("Axx volume slide with zero param replays last")
    func volumeSlideMemory() {
        var ch = MODChannel()
        var song = MODSongState()
        ch.volume = 32
        // First Axx with non-zero param latches.
        var c = cell(effect: 0xA, param: 0x02)  // slide down 2
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.volume == 30)
        // Next Axx with zero param should replay "slide down 2".
        c = cell(effect: 0xA, param: 0x00)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.volume == 28)
    }

    @Test("E1x fine portamento up subtracts at tick 0 only")
    func finePortaUp() {
        var ch = MODChannel()
        var song = MODSongState()
        ch.period = 500
        let c = cell(effect: 0xE, param: 0x14)  // E1 4 → fine up by 4
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.period == 496)
        // Continuous ticks do nothing for E1x.
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.period == 496)
    }

    @Test("ECx note cut on tick x zeroes volume at the right tick")
    func noteCut() {
        var ch = MODChannel()
        var song = MODSongState()
        ch.volume = 50
        let c = cell(effect: 0xE, param: 0xC2) // cut on tick 2
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(ch.volume == 50)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 1)
        #expect(ch.volume == 50)
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 2)
        #expect(ch.volume == 0)
    }

    @Test("EE x pattern delay sets song repeat count once")
    func patternDelay() {
        var ch = MODChannel()
        var song = MODSongState()
        let c = cell(effect: 0xE, param: 0xE3) // delay 3 rows
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(song.pendingPatternDelayRows == 3)
        // Second dispatch on the same row must NOT add — pattern
        // delay only latches once per row.
        dispatchEffect(cell: c, channel: &ch, song: &song, tick: 0)
        #expect(song.pendingPatternDelayRows == 3)
    }
}
