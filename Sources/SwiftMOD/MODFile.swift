/// MODFile.swift
///
/// Public model types for a parsed module. File layout reference:
/// `Reference/MOD-Format.md`.
///
/// ```
/// 0x000  20 bytes   Song title (ASCII, NUL-padded)
/// 0x014 930 bytes   31 sample headers × 30 bytes each
/// 0x3B6  1 byte     Song length (1...128)
/// 0x3B7  1 byte     Restart byte
/// 0x3B8 128 bytes   Pattern order table
/// 0x438  4 bytes    Format signature (M.K. / M!K! / FLT4 / …)
/// 0x43C  …          Pattern data — numPatterns × channels × 64 × 4
/// (then) …          Sample bodies (signed 8-bit PCM)
/// ```
///
/// The 15-sample Ultimate Soundtracker variant uses a 600-byte header
/// (15 sample headers, no signature).

import Foundation

// MARK: - MODFile

/// An immutable, fully parsed `.mod` module.
///
/// Create one from bytes with ``init(data:)`` (or ``SwiftMOD/decode(_:)``)
/// and play it with ``MODMixer``. The value is `Sendable` and can be
/// shared freely across threads.
public struct MODFile: Sendable, Equatable {

    /// Song title (offset `0x000`, 20 bytes), cut at the first NUL with
    /// trailing spaces/control bytes removed. Bytes outside ASCII are
    /// decoded as ISO Latin-1.
    public let title: String

    /// The format signature at offset `0x438`, or
    /// ``MODSignature/noSignature15Sample`` for 15-sample modules.
    public let signature: MODSignature

    /// Number of pattern channels (`1...32`), implied by ``signature``.
    public let channelCount: Int

    /// Sample slots: 31 for tagged modules, 15 for Soundtracker
    /// modules. Pattern cells reference samples 1-based, so cell
    /// sample number `n` is `samples[n - 1]`.
    public let samples: [MODSample]

    /// Number of used order positions, `1...128`.
    public let songLength: Int

    /// The restart byte at `0x3B7`. ProTracker writes `0x7F` and
    /// ignores it; NoiseTracker used it as the restart order. The mixer
    /// honours it only when looping (`MODMixer.Options.loopSong`) and
    /// only if it is `< songLength`.
    public let restartByte: UInt8

    /// The full 128-entry order table. Only `patternOrder[0..<songLength]`
    /// is played; entries past `songLength` are unused padding and may
    /// reference patterns that are not stored. For `FLT8` modules the
    /// stored values are halved so they index ``patterns`` directly.
    public let patternOrder: [UInt8]

    /// Decoded patterns, indexed by pattern number (the values in
    /// ``patternOrder``), each 64 rows × ``channelCount`` cells.
    public let patterns: [MODPattern]

    /// `true` when the file ended before all sample bodies were read.
    /// Such files are common in the wild and are loaded leniently: the
    /// affected samples are shortened to the bytes actually present.
    public let isTruncated: Bool

    // MARK: Player-facing constants

    /// Initial ticks per row. MOD has no header field for this; it is
    /// always ProTracker's default `6` until an `Fxx` command changes it.
    public var initialSpeed: UInt8 { 6 }

    /// Initial tempo in BPM (tick rate = BPM × 0.4 Hz). Always
    /// ProTracker's default `125` (50 Hz ticks) until `Fxx` (`xx ≥ 0x20`)
    /// changes it.
    public var initialTempo: UInt8 { 125 }

    /// Alias of ``songLength``.
    public var orderCount: Int { songLength }

    // MARK: Init

    /// Parse a module from its bytes.
    ///
    /// Tagged 31-sample modules are recognised by their signature; data
    /// without a known tag is accepted as a 15-sample Soundtracker
    /// module only if its header, order table and pattern data pass
    /// validation.
    ///
    /// - Parameter data: The complete file contents.
    /// - Throws: ``MODError`` if the data is not a module or is cut short
    ///   before the end of the pattern data. A file truncated inside the
    ///   sample bodies loads successfully with ``isTruncated`` set.
    public init(data: Data) throws {
        self = try MODParser.parse(data)
    }

    init(
        title: String,
        signature: MODSignature,
        channelCount: Int,
        samples: [MODSample],
        songLength: Int,
        restartByte: UInt8,
        patternOrder: [UInt8],
        patterns: [MODPattern],
        isTruncated: Bool
    ) {
        self.title = title
        self.signature = signature
        self.channelCount = channelCount
        self.samples = samples
        self.songLength = songLength
        self.restartByte = restartByte
        self.patternOrder = patternOrder
        self.patterns = patterns
        self.isTruncated = isTruncated
    }
}

// MARK: - MODSample

/// One sample slot: its 30-byte header plus its signed 8-bit PCM body.
///
/// All lengths and offsets are in **bytes** (the file stores 16-bit
/// words; the parser doubles them). The loop fields are validated:
/// whenever ``loops`` is `true`, `loopStart + loopLength <= length`.
public struct MODSample: Sendable, Equatable {

    /// Sample name (22 bytes, NUL-padded; trailing spaces removed).
    public let name: String

    /// Length in bytes; always equal to `data.count`.
    public let length: Int

    /// Finetune `-8...+7` (eighths of a semitone), from the low nibble
    /// of header byte 24. Always `0` for 15-sample modules.
    public let finetune: Int8

    /// Default volume `0...64` (header values above 64 are clamped).
    public let volume: UInt8

    /// Loop start in bytes. `0` when the sample does not loop.
    public let loopStart: Int

    /// Loop length in bytes. `0` when the sample does not loop.
    ///
    /// ProTracker stores a loop length of 1 word (2 bytes) for one-shot
    /// samples, because Paula always loops; a stored length of 0 or 1
    /// word therefore means "no loop" and is reported here as `0`.
    public let loopLength: Int

    /// Signed 8-bit PCM, `-128...127`.
    public let data: [Int8]

    /// `true` when the sample has a loop longer than one word.
    public var loops: Bool { loopLength > 2 }

    /// An empty, silent sample slot.
    public static let empty = MODSample(
        name: "", length: 0, finetune: 0, volume: 0,
        loopStart: 0, loopLength: 0, data: []
    )

    init(name: String, length: Int, finetune: Int8, volume: UInt8,
         loopStart: Int, loopLength: Int, data: [Int8]) {
        self.name = name
        self.length = length
        self.finetune = finetune
        self.volume = volume
        self.loopStart = loopStart
        self.loopLength = loopLength
        self.data = data
    }
}

// MARK: - MODPattern + MODCell

/// One pattern: 64 rows of ``MODRow``.
public struct MODPattern: Sendable, Equatable {

    /// The 64 rows, in playback order. Each row has one cell per channel.
    public let rows: [MODRow]

    /// Create a pattern from its rows.
    /// - Parameter rows: Normally 64 rows of `channelCount` cells.
    public init(rows: [MODRow]) {
        self.rows = rows
    }
}

/// One pattern row: one ``MODCell`` per channel, in channel order.
public typealias MODRow = [MODCell]

/// One decoded 4-byte pattern cell.
///
/// ```
/// byte 0: ssss pppp   sample high nibble, period bits 11-8
/// byte 1: pppp pppp   period bits 7-0
/// byte 2: ssss eeee   sample low nibble, effect command
/// byte 3: xxxx yyyy   effect parameter
/// ```
public struct MODCell: Sendable, Equatable, Hashable {

    /// 12-bit Amiga period (`0...4095`); `0` means no note.
    public let period: UInt16

    /// 1-based sample number (`0...255` as stored); `0` means no sample
    /// change. Numbers beyond the module's sample count are ignored
    /// during playback.
    public let sampleNumber: UInt8

    /// Effect command `0x0...0xF`.
    public let effect: UInt8

    /// Effect parameter byte. For `Exy` commands the high nibble is the
    /// sub-command.
    public let effectParam: UInt8

    /// Create a cell.
    /// - Parameters:
    ///   - period: Amiga period, `0` for no note.
    ///   - sampleNumber: 1-based sample number, `0` for none.
    ///   - effect: Effect command nibble.
    ///   - effectParam: Effect parameter byte.
    public init(period: UInt16, sampleNumber: UInt8, effect: UInt8, effectParam: UInt8) {
        self.period = period
        self.sampleNumber = sampleNumber
        self.effect = effect
        self.effectParam = effectParam
    }

    /// `true` when all four bytes of the cell are zero.
    public var isEmpty: Bool {
        period == 0 && sampleNumber == 0 && effect == 0 && effectParam == 0
    }

    /// The note for ``period`` in the finetune-0 table (±1 tolerance),
    /// or `nil` for no note or a period outside C-1...B-3.
    public var note: MODNote? {
        guard period != 0 else { return nil }
        return MODNote.from(period: period)
    }
}

// MARK: - MODNote

/// A note in ProTracker's three-octave range.
public struct MODNote: Sendable, Equatable, Hashable {

    /// Note index `0..<36`: `0` is C-1, `12` is C-2, `35` is B-3.
    public let noteIndex: Int

    /// Create a note.
    /// - Parameter noteIndex: `0..<36`.
    /// - Returns: `nil` if `noteIndex` is out of range.
    public init?(noteIndex: Int) {
        guard (0..<36).contains(noteIndex) else { return nil }
        self.noteIndex = noteIndex
    }

    /// Tracker-style name: `"C-1"`, `"C#1"`, … `"B-3"`.
    public var name: String {
        let names = ["C-", "C#", "D-", "D#", "E-", "F-",
                     "F#", "G-", "G#", "A-", "A#", "B-"]
        return "\(names[noteIndex % 12])\(noteIndex / 12 + 1)"
    }

    /// The period of this note at the given finetune.
    /// - Parameter finetune: `-8...7`.
    /// - Returns: The ProTracker period, or `0` for an invalid finetune.
    public func period(finetune: Int8 = 0) -> UInt16 {
        MODPeriod.period(noteIndex: noteIndex, finetune: finetune)
    }

    /// Find the note whose finetune-0 period is within ±1 of `period`.
    /// - Parameter period: An Amiga period.
    /// - Returns: The note, or `nil` if no C-1...B-3 entry matches.
    public static func from(period: UInt16) -> MODNote? {
        for i in 0..<36 where abs(Int(MODPeriod.period(noteIndex: i, finetune: 0)) - Int(period)) <= 1 {
            return MODNote(noteIndex: i)
        }
        return nil
    }
}

// MARK: - MODError

/// Errors thrown while parsing a module.
public enum MODError: Error, Sendable, Equatable, LocalizedError {

    /// Regions of the file, used to report where data ran out.
    public enum Section: String, Sendable, Equatable {
        /// The fixed header (title, sample headers, order table, signature).
        case header
        /// The pattern data following the header.
        case patterns
    }

    /// The file ended inside `section`.
    case truncated(Section)

    /// No known signature at offset 1080, and the data does not
    /// validate as a 15-sample Soundtracker module.
    case unrecognizedFormat

    /// The song-length byte is outside `1...128`.
    case invalidSongLength(Int)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .truncated(let section):
            return "MOD file is truncated in the \(section.rawValue)."
        case .unrecognizedFormat:
            return "Data is not a recognised MOD module."
        case .invalidSongLength(let n):
            return "MOD song length \(n) is outside 1...128."
        }
    }
}
