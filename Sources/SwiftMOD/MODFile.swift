/// MODFile.swift
///
/// Public surface types for the SwiftMOD parser. Mirrors the shape of
/// `SwiftS3M.S3MFile` so downstream consumers (Relical's `MODPlayer`)
/// can adopt the same two-call constructor pattern used for `.s3m`,
/// `.xm`, and `.it` modules.
///
/// File layout reference: `Reference/MOD-Format.md` (clean-room spec).
///
/// ```
/// 0x000  20 bytes   Song title (ASCII, NUL-padded)
/// 0x014 930 bytes   31 sample headers × 30 bytes each
/// 0x3B6  1 byte     Song length (1..128)
/// 0x3B7  1 byte     Restart byte
/// 0x3B8 128 bytes   Pattern order table
/// 0x438  4 bytes    Format signature (M.K. / M!K! / FLT4 / …)
/// 0x43C  …          Pattern data — numPatterns × channels × 64 × 4
/// (then) …          Sample bodies (signed 8-bit PCM)
/// ```
///
/// The pre-`M.K.` 15-sample Ultimate Soundtracker variant uses a
/// 600-byte header instead of 1084 bytes and has no signature.
///
/// ## Two-call constructor pattern
///
/// ```swift
/// let file = try MODFile(data: data)
/// let mixer = MODMixer(file: file, sampleRate: 48_000)
/// ```

import Foundation

// MARK: - MODFile

/// In-memory representation of a parsed `.mod` module.
///
/// The struct is `Sendable`: every stored property is a value type
/// or a deeply-immutable array of value types. Safe to hand off to
/// the audio thread alongside the mixer.
public struct MODFile: Sendable {

    // MARK: Public header fields

    /// Song title (offset `0x000`, 20 bytes). Trimmed of trailing
    /// NUL / non-printable bytes.
    public let title: String

    /// Format signature detected at offset `0x438`. For the
    /// 15-sample Ultimate Soundtracker variant this is
    /// `.noSignature15Sample` and the file uses a 600-byte header.
    public let signature: MODSignature

    /// Number of mixer channels implied by `signature`.
    public let channelCount: Int

    /// Sample table (31 entries for modern variants, 15 for the
    /// no-signature variant). Sample 0 is conventionally empty; the
    /// array is 0-indexed but pattern cells reference samples
    /// 1-based.
    public let samples: [MODSample]

    /// Used order-table length. `1..128`.
    public let songLength: Int

    /// Restart byte (CIAA timer / loop-back position). ProTracker
    /// hard-codes this to `0x7F`. A robust player treats values
    /// `>= songLength` as "restart at 0."
    public let restartByte: UInt8

    /// Full 128-byte order table — `patternOrder[i]` for `i <
    /// songLength` selects the pattern at order position `i`.
    public let patternOrder: [UInt8]

    /// Decoded patterns, length = `max(patternOrder[0..<songLength])
    /// + 1`. Indexed by pattern number, not by order position.
    public let patterns: [MODPattern]

    // MARK: Player-facing aliases

    /// Default ticks-per-row. MOD has no header field for this — the
    /// constant `6` is the ProTracker default, set via effect `Fxx`
    /// at runtime if the song needs a different value. Exposed as a
    /// `UInt8` to mirror `S3MFile.initialSpeed`.
    public var initialSpeed: UInt8 { 6 }

    /// Default tempo in BPM-derived units. Same story as
    /// `initialSpeed` — the canonical ProTracker default is `125`.
    public var initialTempo: UInt8 { 125 }

    /// Convenience alias used by Relical's `MODPlayer` to compute
    /// estimated duration without poking at the order array.
    public var orderCount: Int { songLength }

    // MARK: Init

    /// Parse a `.mod` byte stream. Delegates to `MODParser.parse`.
    public init(data: Data) throws {
        let parsed = try MODParser.parse(data)
        self = parsed
    }

    /// Internal initializer used by `MODParser`. Public types are
    /// `let`s so the parser builds the value once and hands it back.
    init(
        title: String,
        signature: MODSignature,
        channelCount: Int,
        samples: [MODSample],
        songLength: Int,
        restartByte: UInt8,
        patternOrder: [UInt8],
        patterns: [MODPattern]
    ) {
        self.title = title
        self.signature = signature
        self.channelCount = channelCount
        self.samples = samples
        self.songLength = songLength
        self.restartByte = restartByte
        self.patternOrder = patternOrder
        self.patterns = patterns
    }
}

// MARK: - MODSample

/// One entry from the 30-byte sample-header table, plus its raw
/// PCM body. Lengths are byte counts (the file stores word counts;
/// the parser does the `× 2` conversion).
public struct MODSample: Sendable {

    /// Sample name (22 bytes, ASCII / Latin-1, NUL-padded).
    public let name: String

    /// Sample length in **bytes** (file stores words; doubled).
    public let length: Int

    /// Finetune in `-8..+7` steps. Encoded in the file as a 4-bit
    /// signed nibble.
    public let finetune: Int8

    /// Default volume `0..64`.
    public let volume: UInt8

    /// Loop start in **bytes**.
    public let loopStart: Int

    /// Loop length in **bytes**. `≤ 2` means "no loop" (ProTracker
    /// stores `1 word = 2 bytes` to satisfy Paula's always-looping
    /// hardware).
    public let loopLength: Int

    /// Signed 8-bit PCM body. Empty for length-zero placeholders.
    public let data: [Int8]

    /// `true` when `loopLength > 2`. Convenience for mixer code.
    public var loops: Bool { loopLength > 2 }

    /// Empty sentinel — used for the conventional "sample 0" slot
    /// and for any sample whose header was zero-length.
    public static let empty = MODSample(
        name: "",
        length: 0,
        finetune: 0,
        volume: 0,
        loopStart: 0,
        loopLength: 0,
        data: []
    )
}

// MARK: - MODSignature

/// Four-byte format tag at offset `0x438`, mapped to a Swift case
/// per the [Format signature dispatch] table in the spec doc.
///
/// `noSignature15Sample` covers the pre-NoiseTracker Ultimate
/// Soundtracker variant, which had no signature and only 15
/// sample slots.
public enum MODSignature: Sendable, Equatable, Hashable {
    case mk             // "M.K."  — NoiseTracker / ProTracker canonical, 4ch
    case mkExtended     // "M!K!"  — ProTracker, 4ch, > 64 patterns
    case mAndK          // "M&K!"  — NoiseTracker variant, 4ch
    case nT             // "N.T."  — NoiseTracker original, 4ch
    case flt4           // "FLT4"  — StarTrekker 4-channel
    case flt8           // "FLT8"  — StarTrekker 8-channel paired
    case exo4           // "EXO4"  — StarTrekker EXO 4ch
    case exo8           // "EXO8"  — StarTrekker EXO 8ch
    case twoCHN         // "2CHN"
    case sixCHN         // "6CHN"
    case eightCHN       // "8CHN"
    case xxCH(Int)      // "10CH"..."32CH"
    case xxCN(Int)      // "10CN"..."32CN"
    case octa           // "OCTA"  — Oktalyzer 8ch
    case okta           // "OKTA"  — Oktalyzer 8ch alt tag
    case cd61           // "CD61"  — Falcon 6ch
    case cd81           // "CD81"  — Falcon 8ch
    case fa04           // "FA04"
    case fa06           // "FA06"
    case fa08           // "FA08"
    case tdz(Int)       // "TDZ1".."TDZ3"
    case noSignature15Sample

    /// Channels implied by the tag.
    public var channelCount: Int {
        switch self {
        case .mk, .mkExtended, .mAndK, .nT, .flt4, .exo4, .fa04:
            return 4
        case .flt8, .exo8, .eightCHN, .octa, .okta, .cd81, .fa08:
            return 8
        case .twoCHN:
            return 2
        case .sixCHN, .cd61, .fa06:
            return 6
        case .xxCH(let n), .xxCN(let n):
            return n
        case .tdz(let n):
            return n
        case .noSignature15Sample:
            return 4
        }
    }

    /// Sample-slot count implied by the tag. 31 for every modern
    /// variant; 15 for the no-signature legacy.
    public var sampleSlotCount: Int {
        self == .noSignature15Sample ? 15 : 31
    }

    /// Inspect the 4-byte slot at offset 1080 (or wherever the
    /// caller chooses — the parser slices the right window) and
    /// return the matching case, or `nil` if no known tag fits.
    public static func detect(in data: Data) -> MODSignature? {
        guard data.count >= 1084 else { return nil }
        let tag = data.subdata(in: 1080..<1084)
        return detect(tag: tag)
    }

    /// Same as `detect(in:)` but takes the raw 4-byte tag directly.
    /// Exposed for the test harness; the parser uses `detect(in:)`.
    public static func detect(tag: Data) -> MODSignature? {
        guard tag.count == 4 else { return nil }
        let bytes = Array(tag)
        let ascii = String(bytes: bytes, encoding: .ascii) ?? ""
        switch ascii {
        case "M.K.": return .mk
        case "M!K!": return .mkExtended
        case "M&K!": return .mAndK
        case "N.T.": return .nT
        case "FLT4": return .flt4
        case "FLT8": return .flt8
        case "EXO4": return .exo4
        case "EXO8": return .exo8
        case "2CHN": return .twoCHN
        case "6CHN": return .sixCHN
        case "8CHN": return .eightCHN
        case "OCTA": return .octa
        case "OKTA": return .okta
        case "CD61": return .cd61
        case "CD81": return .cd81
        case "FA04": return .fa04
        case "FA06": return .fa06
        case "FA08": return .fa08
        default: break
        }
        // Generalized "xxCH" / "xxCN" — two ASCII digits + suffix.
        if ascii.count == 4 {
            let prefix = String(ascii.prefix(2))
            let suffix = String(ascii.suffix(2))
            if let n = Int(prefix), n > 0, n <= 32 {
                if suffix == "CH" { return .xxCH(n) }
                if suffix == "CN" { return .xxCN(n) }
            }
            // TDZ1..TDZ9 — single digit, 1..3 useful.
            if ascii.hasPrefix("TDZ"), let n = Int(ascii.suffix(1)), n >= 1, n <= 9 {
                return .tdz(n)
            }
        }
        return nil
    }
}

// MARK: - MODPattern + MODCell

/// 64-row × N-channel grid of decoded pattern cells.
public struct MODPattern: Sendable {
    /// Row-major. `rows[r]` has `channelCount` cells.
    public let rows: [MODRow]

    public init(rows: [MODRow]) {
        self.rows = rows
    }
}

/// One row of a pattern — `channelCount` cells.
public typealias MODRow = [MODCell]

/// One decoded 4-byte pattern cell.
public struct MODCell: Sendable, Equatable, Hashable {
    /// 12-bit Amiga period. `0` = no note this cell.
    public let period: UInt16

    /// 1-based sample index (1..31). `0` = "continue previous
    /// sample." Some files store > 31; the parser leaves the raw
    /// value here.
    public let sampleNumber: UInt8

    /// Effect command nibble `0..F`.
    public let effect: UInt8

    /// Effect parameter byte. For most commands the upper / lower
    /// nibbles are independent (e.g. arpeggio `0xy`).
    public let effectParam: UInt8

    public init(period: UInt16, sampleNumber: UInt8, effect: UInt8, effectParam: UInt8) {
        self.period = period
        self.sampleNumber = sampleNumber
        self.effect = effect
        self.effectParam = effectParam
    }

    /// Resolve the period back to a note via the canonical
    /// finetune-0 period table. Returns `nil` for period `0`
    /// ("no note") or for periods outside the legal `113..856`
    /// range.
    public var note: MODNote? {
        guard period != 0 else { return nil }
        return MODNote.from(period: period)
    }
}

// MARK: - MODNote

/// Decoded note (octave + semitone) used for display and for
/// effect-target resolution. `noteIndex` is `0..35` over the
/// canonical 3-octave × 12-semitone table; `0` = C-1, `35` = B-3.
public struct MODNote: Sendable, Equatable, Hashable {
    public let noteIndex: Int

    /// Note name `"C-1"`, `"C#1"`, `"D-1"`, … `"B-3"`.
    public var name: String {
        let names = ["C-", "C#", "D-", "D#", "E-", "F-",
                     "F#", "G-", "G#", "A-", "A#", "B-"]
        let octave = (noteIndex / 12) + 1
        let semitone = noteIndex % 12
        return "\(names[semitone])\(octave)"
    }

    /// Look up a note by its period using the finetune-0 table.
    /// Tolerates ±1 (Amiga period rounding) — many trackers wrote
    /// periods that drifted by one between authoring sessions.
    public static func from(period: UInt16) -> MODNote? {
        // Finetune-0 table, octave 1 + octave 2 + octave 3.
        let table: [UInt16] = [
            856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
            428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
            214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113
        ]
        for (i, p) in table.enumerated() where abs(Int(p) - Int(period)) <= 1 {
            return MODNote(noteIndex: i)
        }
        return nil
    }
}

// MARK: - MODError

/// Throwing surface for the parser. Cases are deliberately granular
/// so callers can present meaningful errors (Relical's error UI does
/// this for `.s3m` and will do the same for `.mod`).
public enum MODError: Error, LocalizedError, Sendable {
    /// File ended mid-stage (`"header"`, `"sample-header"`,
    /// `"pattern"`, `"sample-body"`).
    case truncated(stage: String)

    /// 4-byte tag at offset 1080 doesn't match any known signature
    /// **and** the 15-sample fallback also failed to validate.
    case unsupportedSignature(String)

    /// A sample header's `length` would read past the end of `data`.
    case sampleOverrun

    /// Sample count outside `[15, 31]`. Defensive only — the
    /// dispatch table never produces other values.
    case invalidSampleCount(Int)

    public var errorDescription: String? {
        switch self {
        case .truncated(let stage):
            return "MOD file truncated during \(stage)."
        case .unsupportedSignature(let tag):
            return "MOD file has unsupported signature '\(tag)'."
        case .sampleOverrun:
            return "MOD sample body extends past end of file."
        case .invalidSampleCount(let n):
            return "MOD file declares an invalid sample count (\(n))."
        }
    }
}
