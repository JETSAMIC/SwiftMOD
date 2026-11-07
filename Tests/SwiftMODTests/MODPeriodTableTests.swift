// MODPeriodTableTests.swift
//
// Pin the ProTracker period table entries that are NOT exact octave
// halvings — a computed table gets these wrong by one.

import Testing
@testable import SwiftMOD

@Suite("ProTracker period table")
struct MODPeriodTableTests {

    @Test("Non-halving entries match ProTracker exactly")
    func irregularEntries() {
        // Finetune 0: B-2 is 226 (853/2 rounds to 227 — wrong).
        #expect(MODPeriod.period(noteIndex: 23, finetune: 0) == 226)
        // Finetune -8: F-2 is 340.
        #expect(MODPeriod.period(noteIndex: 17, finetune: -8) == 340)
        // Finetune -7: F-1 675, F#-1 636.
        #expect(MODPeriod.period(noteIndex: 5, finetune: -7) == 675)
        #expect(MODPeriod.period(noteIndex: 6, finetune: -7) == 636)
        // Finetune -4: A#-1 494.
        #expect(MODPeriod.period(noteIndex: 10, finetune: -4) == 494)
        // Finetune +7: B-3 108.
        #expect(MODPeriod.period(noteIndex: 35, finetune: 7) == 108)
        // Finetune -1: C#-3 203.
        #expect(MODPeriod.period(noteIndex: 25, finetune: -1) == 203)
    }

    @Test("Table shape: 16 rows × 37 entries with trailing zero")
    func shape() {
        #expect(MODPeriod.protrackerPeriods.count == 16 * 37)
        for row in 0..<16 {
            #expect(MODPeriod.protrackerPeriods[row * 37 + 36] == 0)
            // Each row strictly descends across its 36 notes.
            for i in 1..<36 {
                #expect(MODPeriod.protrackerPeriods[row * 37 + i]
                        < MODPeriod.protrackerPeriods[row * 37 + i - 1])
            }
        }
    }

    @Test("Out-of-range lookups return 0")
    func outOfRange() {
        #expect(MODPeriod.period(noteIndex: 36, finetune: 0) == 0)
        #expect(MODPeriod.period(noteIndex: -1, finetune: 0) == 0)
        #expect(MODPeriod.period(noteIndex: 0, finetune: 8) == 0)
        #expect(MODPeriod.period(noteIndex: 0, finetune: -9) == 0)
    }

    @Test("Reverse lookup prefers finetune 0, falls back to other rows")
    func reverse() {
        #expect(MODPeriod.note(forPeriod: 428)?.noteIndex == 12)
        #expect(MODPeriod.note(forPeriod: 428)?.finetune == 0)
        // 907 only exists in the finetune -8 row.
        #expect(MODPeriod.note(forPeriod: 907)?.finetune == -8)
        #expect(MODPeriod.note(forPeriod: 0) == nil)
        #expect(MODPeriod.note(forPeriod: 4000) == nil)
    }
}
