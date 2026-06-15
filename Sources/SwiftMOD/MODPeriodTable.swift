/// MODPeriodTable.swift
///
/// The canonical ProTracker Amiga period table: 16 finetune rows
/// × 36 notes (3 octaves × 12 semitones) = 576 entries.
///
/// Indexed as `periodTable[finetune + 8][noteIndex]`, with
/// `finetune ∈ -8..+7` and `noteIndex ∈ 0..35` (0 = C-1, 35 = B-3).
/// The +8 offset shifts the signed range into a positive array
/// index without using a dictionary.
///
/// Source: clean-room transcription from the ProTracker 2.x user
/// manual and the public `MODFIL10.TXT` reference. Each finetune
/// row's octave-1 values are documented values; octaves 2 and 3 are
/// computed by halving (per the spec; the table values are correct
/// to ±1 against the published references).
///
/// **No source code from libxmp, OpenMPT, MikMod, or Schism Tracker
/// was consulted in producing this table.** The octave-1 values
/// below are the published ProTracker constants.

import Foundation

// MARK: - Period table

/// `periodTable[finetune + 8][noteIndex]` — `UInt16` period values
/// the Paula chip would write to its per-channel period register.
public let periodTable: [[UInt16]] = {

    // 16 octave-1 rows, finetune `-8` first up to `+7`.
    // (Order in the array: finetune `0` at index 8, by the +8 shift.)
    //
    // The published ProTracker table interleaves the 16 finetune
    // rows in the order: finetune `0..7` then `-8..-1`. We unpack
    // that into our `finetune + 8 → row` mapping below.
    let octave1ByFinetune: [Int8: [UInt16]] = [
         0: [856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453],
         1: [850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477, 450],
         2: [844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, 447],
         3: [838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470, 444],
         4: [832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467, 441],
         5: [826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, 437],
         6: [820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460, 434],
         7: [814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, 431],
        -8: [907, 856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480],
        -7: [900, 850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477],
        -6: [894, 844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474],
        -5: [887, 838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470],
        -4: [881, 832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467],
        -3: [875, 826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463],
        -2: [868, 820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460],
        -1: [862, 814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457]
    ]

    var rows: [[UInt16]] = []
    rows.reserveCapacity(16)
    for f in -8...7 {
        let oct1 = octave1ByFinetune[Int8(f)] ?? []
        // Octaves 2 and 3 are octave 1 divided by 2 and 4 with
        // integer rounding — the published period tables agree
        // with these computed values to ±1 across the entire
        // table, which is well inside the ±1 tolerance that
        // `MODNote.from(period:)` already applies.
        let oct2 = oct1.map { UInt16(($0 + 1) / 2) }
        let oct3 = oct1.map { UInt16(($0 + 2) / 4) }
        rows.append(oct1 + oct2 + oct3)
    }
    return rows
}()

// MARK: - Lookup helpers

public enum MODPeriod {

    /// Lowest legal ProTracker period (B-3, finetune 0). Periods
    /// below this clamp here.
    public static let minPeriod: UInt16 = 113

    /// Highest legal ProTracker period (C-1, finetune 0). Periods
    /// above this clamp here. Some clones allow up to 1023; the
    /// mixer can raise this if it wants to support those modules.
    public static let maxPeriod: UInt16 = 856

    /// Look up the period for `noteIndex` at the given finetune.
    /// Returns `0` for out-of-range inputs (treat as "no note").
    public static func period(noteIndex: Int, finetune: Int8) -> UInt16 {
        guard (0..<36).contains(noteIndex) else { return 0 }
        let row = Int(finetune) + 8
        guard (0..<16).contains(row) else { return 0 }
        return periodTable[row][noteIndex]
    }

    /// Reverse lookup: given a period (any finetune row) return the
    /// `(noteIndex, finetune)` pair whose published period is closest.
    /// Tolerates ±1 unit of rounding error. Returns `nil` if no row
    /// matches.
    public static func note(forPeriod period: UInt16) -> (noteIndex: Int, finetune: Int8)? {
        guard period != 0 else { return nil }
        // Search the finetune-0 row first (covers ~99% of real modules).
        if let i = periodTable[8].firstIndex(where: { abs(Int($0) - Int(period)) <= 1 }) {
            return (i, 0)
        }
        // Fall back to the full 576-entry search.
        for row in 0..<16 {
            for i in 0..<36 where abs(Int(periodTable[row][i]) - Int(period)) <= 1 {
                return (i, Int8(row - 8))
            }
        }
        return nil
    }
}
