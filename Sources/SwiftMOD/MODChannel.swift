/// MODChannel.swift
///
/// Per-hardware-channel runtime state for the SwiftMOD effect engine
/// and Paula mixer. One `MODChannel` instance exists per channel
/// declared by the file's signature (4 for `M.K.`, 6 for `6CHN`,
/// 8 for `8CHN` / `FLT8` / `OCTA`, etc).
///
/// ## Effect parameter memory (ProTracker semantics)
///
/// Many ProTracker commands implement "memory": dispatching `Axx`
/// (volume slide) with a zero parameter re-uses the *last non-zero*
/// `Axx` parameter, and the same goes for `1xx`/`2xx` portamentos,
/// `3xx` tone portamento, `4xy` vibrato, `7xy` tremolo, `9xx` sample
/// offset, and `Exx` extended commands. We store one memory slot per
/// command family on the channel so dispatch can resolve `param == 0`
/// to "repeat last".
///
/// ## Vibrato / tremolo waveform state
///
/// ProTracker's vibrato/tremolo each have:
///   - waveform (`E4x` / `E7x` low nibble: 0 sine, 1 ramp-down, 2 square,
///     3 random; +4 disables the "reset on new note" behaviour)
///   - depth (low nibble of `4xy` / `7xy`)
///   - speed (high nibble of `4xy` / `7xy`)
///   - position (`0..63`, wraps; advances by `speed` per tick after tick 0)
///
/// ## Pattern-loop counter
///
/// `E6x` pattern loop sets the loop start (param = 0) or jumps back
/// `param` times. The counter lives on the channel because each channel
/// is allowed to drive its own loop (rarely useful but spec-correct).
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker was
/// consulted while writing this file.

import Foundation

// MARK: - Vibrato / tremolo waveform

/// Low nibble of `E4x` / `E7x` selects one of four waveforms. The
/// high bit (+4) toggles "do NOT reset position on new note." We
/// store the bare waveform plus the retrigger flag separately.
public enum MODOscillatorWaveform: UInt8, Sendable {
    case sine = 0
    case rampDown = 1
    case square = 2
    case random = 3
}

/// Holds the runtime state for one of the two LFOs (vibrato or
/// tremolo). The "speed" and "depth" nibbles are set by the
/// effect command on tick 0; "position" advances on every
/// continuous tick.
public struct MODOscillator: Sendable {
    public var waveform: MODOscillatorWaveform = .sine
    /// `true` = keep position across new notes (the `+4` bit of `E4x`/`E7x`).
    public var retainPosition: Bool = false
    /// Step per continuous tick. High nibble of `4xy` / `7xy`.
    public var speed: UInt8 = 0
    /// Amplitude. Low nibble of `4xy` / `7xy`.
    public var depth: UInt8 = 0
    /// Phase, `0..63`. Wraps modulo 64.
    public var position: Int = 0

    /// Reset on a new note (unless `retainPosition` is set).
    public mutating func noteRetriggered() {
        if !retainPosition {
            position = 0
        }
    }

    /// Sine/ramp/square sample for the current `position`. Returns a
    /// signed value in roughly `-255..+255` before scaling by depth
    /// and the command's divisor (vibrato divides by 128, tremolo
    /// divides by 64 — those scalings happen in the dispatcher).
    public func currentSample() -> Int {
        let pos = position & 0x3F
        switch waveform {
        case .sine:
            // ProTracker's sine table (clean-room: standard
            // `round(sin(pi * pos / 32) * 255)` over a quarter wave,
            // mirrored). 32 entries cover a quarter-cycle; the full
            // 64-entry waveform is built by symmetry below.
            let sineQuarter: [Int] = [
                  0,  24,  49,  74,  97, 120, 141, 161,
                180, 197, 212, 224, 235, 244, 250, 253,
                255, 253, 250, 244, 235, 224, 212, 197,
                180, 161, 141, 120,  97,  74,  49,  24
            ]
            let half = pos & 0x1F      // 0..31
            let magnitude = sineQuarter[half]
            return pos < 32 ? magnitude : -magnitude
        case .rampDown:
            // 255 → -255 across 64 steps.
            return 255 - (pos * 8)
        case .square:
            return pos < 32 ? 255 : -255
        case .random:
            // The "random" waveform in ProTracker is closer to
            // "downward ramp with rapid retrigger" in practice; we
            // approximate by mixing position-driven pseudo-random.
            // Bit-mash the position to get a stable byte without an
            // RNG (call-site doesn't have one).
            let mash = Int((UInt32(pos) &* 1103515245 &+ 12345) >> 16) & 0xFF
            return mash - 128
        }
    }
}

// MARK: - MODChannel

/// One Paula channel. All fields are `var` so the effect engine and
/// mixer can mutate state in-place; the value is held by reference
/// only via `inout` on dispatch calls.
public struct MODChannel: Sendable {

    // MARK: Sample playback state

    /// 1-based sample index currently assigned to this channel.
    /// `0` means "no sample loaded yet."
    public var sampleNumber: UInt8 = 0

    /// Current play position in the sample, as a Q16.16 fixed-point
    /// offset in bytes. The integer part is the byte index; the
    /// fractional part drives linear interpolation.
    public var samplePosition: UInt64 = 0

    /// `true` once the play position has run past the end of the
    /// sample (or past `loopStart + loopLength` for a non-looping
    /// sample). The mixer stops emitting output for the channel.
    public var sampleFinished: Bool = false

    // MARK: Pitch state

    /// Current ProTracker period driving the channel's playback rate.
    /// `0` = silent (no note has ever been played).
    public var period: UInt16 = 0

    /// Target period for the `3xx` tone-portamento effect. When
    /// non-zero, `3xx` slides `period` toward this value.
    public var portaTarget: UInt16 = 0

    /// Latched period from the most recent pattern cell — used to
    /// reset `period` after arpeggio shifts (which only apply on
    /// continuous ticks).
    public var notePeriod: UInt16 = 0

    // MARK: Volume / pan state

    /// Current playback volume `0..64`. Clamped on assignment by
    /// callers (we don't enforce here; cheap clamp at mix time).
    public var volume: UInt8 = 0

    /// Sample-default finetune `-8..+7`, copied from the active
    /// `MODSample` when a new sample is triggered. `E5x` overrides
    /// this for the duration of the note.
    public var finetune: Int8 = 0

    // MARK: LFOs

    public var vibrato = MODOscillator()
    public var tremolo = MODOscillator()

    // MARK: Sample-offset cache (9xx memory)

    /// Last non-zero `9xx` parameter, replayed when `9xx` arrives
    /// with `0`. Stored in raw "× 256" form: index 0xC3 means byte
    /// offset 0xC300.
    public var lastSampleOffsetParam: UInt8 = 0

    // MARK: Effect parameter memory (per-family)

    public var lastVolumeSlideParam: UInt8 = 0          // Axx
    public var lastPortamentoUpParam: UInt8 = 0         // 1xx
    public var lastPortamentoDownParam: UInt8 = 0       // 2xx
    public var lastTonePortamentoParam: UInt8 = 0       // 3xx
    public var lastVibratoParam: UInt8 = 0              // 4xy (high=speed, low=depth)
    public var lastTremoloParam: UInt8 = 0              // 7xy
    public var lastRetriggerParam: UInt8 = 0            // E9x
    public var lastFineVolUpParam: UInt8 = 0            // EAx
    public var lastFineVolDownParam: UInt8 = 0          // EBx
    public var lastFinePortaUpParam: UInt8 = 0          // E1x
    public var lastFinePortaDownParam: UInt8 = 0        // E2x

    // MARK: Pattern-loop state

    /// Pattern row to loop back to (set by `E60`).
    public var patternLoopRow: Int = 0
    /// Remaining loops (set by `E6x` with `x > 0`).
    public var patternLoopCount: Int = 0
    /// `true` once an `E6x` loop is "armed" (we've seen at least one
    /// `E60`). Lets us ignore a stray `E6x` without an anchor.
    public var patternLoopArmed: Bool = false

    // MARK: Per-row scratch

    /// Effect from this row's cell (cached for tick > 0 dispatch).
    public var currentEffect: UInt8 = 0
    /// Effect parameter from this row's cell.
    public var currentEffectParam: UInt8 = 0

    /// Note-delay countdown (set by `EDx`). When > 0, the channel
    /// suppresses output and decrements per tick until the delayed
    /// note triggers.
    public var noteDelayTicks: Int = 0

    /// Pending cell for delayed-note triggering. `nil` once consumed.
    public var pendingDelayedCell: MODCell? = nil

    // MARK: Convenience

    public init() {}

    /// Reset the LFO positions after a new note (honours the
    /// "do not retrigger" bit on each oscillator).
    public mutating func noteTriggered() {
        vibrato.noteRetriggered()
        tremolo.noteRetriggered()
    }
}
