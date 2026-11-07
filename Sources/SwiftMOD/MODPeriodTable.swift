/// MODPeriodTable.swift
///
/// The canonical ProTracker Amiga period table: 16 finetune rows ×
/// 36 notes (3 octaves × 12 semitones).
///
/// The values are the published ProTracker 2.x constants, including
/// the handful of entries that are *not* exact halvings of the octave
/// above (for example finetune 0, B-2 is `226`, not `227`; finetune
/// -8, F-2 is `340`; finetune -7, F-1/F#-1 are `675`/`636`; finetune
/// -4, A#-1 is `494`). Playback pitch, arpeggio and glissando all read
/// this table, so it must be bit-exact.
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker was
/// consulted in producing this table.

import Foundation

// MARK: - Public lookup

/// Amiga period lookups against the ProTracker period table.
///
/// A *period* is the divisor written to the Paula chip's per-channel
/// period register: playback rate in Hz is `paulaClock / period`, so a
/// larger period is a lower pitch.
public enum MODPeriod {

    /// Lowest period ProTracker's slides allow (B-3, finetune 0).
    /// Portamento up (`1xx`, `E1x`) clamps here.
    public static let minPeriod: UInt16 = 113

    /// Highest period ProTracker's slides allow (C-1, finetune 0).
    /// Portamento down (`2xx`, `E2x`) clamps here.
    public static let maxPeriod: UInt16 = 856

    /// PAL Paula clock in Hz (`7_093_789.2 / 2`). Playback rate for a
    /// period `p` is `palClock / p`.
    public static let palClock: Double = 3_546_894.6

    /// NTSC Paula clock in Hz (`7_159_090.5 / 2`).
    public static let ntscClock: Double = 3_579_545.25

    /// Look up the period for a note at a given finetune.
    ///
    /// - Parameters:
    ///   - noteIndex: Note index `0..<36`, where `0` is C-1 and `35` is B-3.
    ///   - finetune: Signed finetune `-8...7`.
    /// - Returns: The ProTracker period, or `0` when either argument
    ///   is out of range.
    public static func period(noteIndex: Int, finetune: Int8) -> UInt16 {
        guard (0..<36).contains(noteIndex), (-8...7).contains(finetune) else { return 0 }
        let row = Int(UInt8(bitPattern: finetune) & 0x0F)
        return protrackerPeriods[row * rowStride + noteIndex]
    }

    /// Reverse lookup: find the note and finetune whose table period
    /// is within ±1 of `period`.
    ///
    /// The finetune-0 row is searched first (it covers the vast
    /// majority of real modules), then the remaining rows from
    /// finetune `-8` up to `+7`.
    ///
    /// - Parameter period: An Amiga period.
    /// - Returns: `(noteIndex, finetune)`, or `nil` for `0` or a
    ///   period that matches no table entry.
    public static func note(forPeriod period: UInt16) -> (noteIndex: Int, finetune: Int8)? {
        guard period != 0 else { return nil }
        let target = Int(period)
        for finetune in [Int8(0)] + (Int8(-8)...Int8(7)).filter({ $0 != 0 }) {
            for i in 0..<36 where abs(Int(Self.period(noteIndex: i, finetune: finetune)) - target) <= 1 {
                return (i, finetune)
            }
        }
        return nil
    }

    // MARK: Internal ProTracker-ordered table

    /// Entries per finetune row in ProTracker's in-memory table: 36
    /// notes plus a trailing `0`. Arpeggio and tone-portamento search
    /// across this stride, and arpeggio overflow reads into the next
    /// row exactly as ProTracker does.
    static let rowStride = 37

    /// The 16 × 37 ProTracker table, rows in ProTracker's order:
    /// finetune nibble `0...7` (finetune `0...+7`) then `8...15`
    /// (finetune `-8...-1`), so a sample's raw finetune nibble is the
    /// row index.
    static let protrackerPeriods: [UInt16] = [
        // Finetune 0
        856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
        428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
        214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113, 0,
        // Finetune +1
        850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477, 450,
        425, 401, 379, 357, 337, 318, 300, 284, 268, 253, 239, 225,
        213, 201, 189, 179, 169, 159, 150, 142, 134, 126, 119, 113, 0,
        // Finetune +2
        844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, 447,
        422, 398, 376, 355, 335, 316, 298, 282, 266, 251, 237, 224,
        211, 199, 188, 177, 167, 158, 149, 141, 133, 125, 118, 112, 0,
        // Finetune +3
        838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470, 444,
        419, 395, 373, 352, 332, 314, 296, 280, 264, 249, 235, 222,
        209, 198, 187, 176, 166, 157, 148, 140, 132, 125, 118, 111, 0,
        // Finetune +4
        832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467, 441,
        416, 392, 370, 350, 330, 312, 294, 278, 262, 247, 233, 220,
        208, 196, 185, 175, 165, 156, 147, 139, 131, 124, 117, 110, 0,
        // Finetune +5
        826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, 437,
        413, 390, 368, 347, 328, 309, 292, 276, 260, 245, 232, 219,
        206, 195, 184, 174, 164, 155, 146, 138, 130, 123, 116, 109, 0,
        // Finetune +6
        820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460, 434,
        410, 387, 365, 345, 325, 307, 290, 274, 258, 244, 230, 217,
        205, 193, 183, 172, 163, 154, 145, 137, 129, 122, 115, 109, 0,
        // Finetune +7
        814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, 431,
        407, 384, 363, 342, 323, 305, 288, 272, 256, 242, 228, 216,
        204, 192, 181, 171, 161, 152, 144, 136, 128, 121, 114, 108, 0,
        // Finetune -8
        907, 856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480,
        453, 428, 404, 381, 360, 340, 320, 302, 285, 269, 254, 240,
        226, 214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 0,
        // Finetune -7
        900, 850, 802, 757, 715, 675, 636, 601, 567, 535, 505, 477,
        450, 425, 401, 379, 357, 337, 318, 300, 284, 268, 253, 238,
        225, 212, 200, 189, 179, 169, 159, 150, 142, 134, 126, 119, 0,
        // Finetune -6
        894, 844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474,
        447, 422, 398, 376, 355, 335, 316, 298, 282, 266, 251, 237,
        223, 211, 199, 188, 177, 167, 158, 149, 141, 133, 125, 118, 0,
        // Finetune -5
        887, 838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470,
        444, 419, 395, 373, 352, 332, 314, 296, 280, 264, 249, 235,
        222, 209, 198, 187, 176, 166, 157, 148, 140, 132, 125, 118, 0,
        // Finetune -4
        881, 832, 785, 741, 699, 660, 623, 588, 555, 524, 494, 467,
        441, 416, 392, 370, 350, 330, 312, 294, 278, 262, 247, 233,
        220, 208, 196, 185, 175, 165, 156, 147, 139, 131, 123, 117, 0,
        // Finetune -3
        875, 826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463,
        437, 413, 390, 368, 347, 328, 309, 292, 276, 260, 245, 232,
        219, 206, 195, 184, 174, 164, 155, 146, 138, 130, 123, 116, 0,
        // Finetune -2
        868, 820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460,
        434, 410, 387, 365, 345, 325, 307, 290, 274, 258, 244, 230,
        217, 205, 193, 183, 172, 163, 154, 145, 137, 129, 122, 115, 0,
        // Finetune -1
        862, 814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457,
        431, 407, 384, 363, 342, 323, 305, 288, 272, 256, 242, 228,
        216, 203, 192, 181, 171, 161, 152, 144, 136, 128, 121, 114, 0
    ]

    /// Read the ProTracker table at a flat index, returning `0` past
    /// the end (mirrors ProTracker reading beyond its table on
    /// arpeggio overflow, where the result is an effectively silent
    /// period).
    @inline(__always)
    static func flat(_ index: Int) -> Int {
        guard index >= 0, index < protrackerPeriods.count else { return 0 }
        return Int(protrackerPeriods[index])
    }
}
