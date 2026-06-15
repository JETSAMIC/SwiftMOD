/// MODEffects.swift
///
/// ProTracker effect command dispatcher. Driven by `MODMixer` once
/// per tick (tick 0 = the row's first tick, ticks `1..speed-1` are
/// continuous ticks).
///
/// ## Effect families
///
/// Primary commands (high nibble `0..F`):
///
/// - `0xy` arpeggio (continuous; tick `% 3` selects base / +x semi / +y semi)
/// - `1xx` portamento up (continuous; subtract `xx` from period per tick)
/// - `2xx` portamento down (continuous; add `xx` to period per tick)
/// - `3xx` tone portamento (continuous; slide period toward `portaTarget`
///   by `xx` units; memory = last non-zero `xx`)
/// - `4xy` vibrato (continuous; speed `x`, depth `y`; param 0 = last)
/// - `5xy` tone porta + volume slide (= `3xx` then `Axy`; memory shared)
/// - `6xy` vibrato + volume slide
/// - `7xy` tremolo
/// - `8xx` set fine pan (not in vanilla ProTracker; treated as set-pan
///   on tick 0 for tracker compatibility — we store but do not apply)
/// - `9xx` sample offset (tick 0; param 0 = last)
/// - `Axy` volume slide (continuous; `x` up, `y` down; param 0 = last)
/// - `Bxx` position jump (tick 0; jump to order `xx`)
/// - `Cxx` set volume (tick 0; clamp at 64)
/// - `Dxx` pattern break (tick 0; advance to row `xx` of next pattern;
///   `xx` is in BCD-ish layout — high nibble × 10 + low nibble)
/// - `Exx` extended (low nibble selects sub-command; see below)
/// - `Fxx` set speed (`xx < 0x20`) or set tempo (`xx >= 0x20`) — tick 0
///
/// Extended commands `Exx` (E0..EF):
///
/// - `E0x` set filter (Amiga LED — ignored; no-op)
/// - `E1x` fine portamento up (tick 0; subtract `x` from period; memory)
/// - `E2x` fine portamento down (tick 0; add `x` to period; memory)
/// - `E3x` glissando control (we don't quantise to notes mid-portamento;
///   the bit is stored but not enforced — most modules never set it)
/// - `E4x` set vibrato waveform (low 2 bits = waveform; bit 2 = retain pos)
/// - `E5x` set finetune (override the sample's finetune for this note)
/// - `E6x` pattern loop (anchor or jump-back; counter lives on channel)
/// - `E7x` set tremolo waveform (analogous to `E4x`)
/// - `E8x` (S3M pan / unused in ProTracker; no-op)
/// - `E9x` note retrigger (every `x` ticks)
/// - `EAx` fine volume slide up (tick 0; param 0 = last)
/// - `EBx` fine volume slide down (tick 0; param 0 = last)
/// - `ECx` note cut (zero volume on tick `x`)
/// - `EDx` note delay (delay note trigger by `x` ticks)
/// - `EEx` pattern delay (repeat current row `x` times — song-level, not
///   channel-level; handled at the row-boundary tick by `MODMixer`)
/// - `EFx` invert loop (vanilla ProTracker only; no-op)
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker
/// was consulted while writing this file.

import Foundation

// MARK: - Song-wide mutable state

/// Player-global state mutated by `Fxx`, `Bxx`, `Dxx`, `EEx`.
public struct MODSongState: Sendable {

    /// Ticks per row (`Fxx` with `xx < 0x20`, default 6).
    public var speed: Int = 6

    /// BPM-derived tempo (`Fxx` with `xx >= 0x20`, default 125).
    /// Tick frequency in Hz = `tempo × 0.4` (50 Hz at 125 BPM).
    public var tempo: Int = 125

    /// Current order index `0..<songLength`.
    public var orderIndex: Int = 0

    /// Current row within the active pattern, `0..63`.
    public var rowIndex: Int = 0

    /// Set by `Bxx`. The mixer applies this at the next row boundary.
    public var pendingPositionJump: Int? = nil

    /// Set by `Dxx`. The mixer applies this at the next row boundary.
    public var pendingPatternBreakRow: Int? = nil

    /// Set by `EEx`. The mixer holds the current row for this many
    /// extra repetitions. Decrements at every row boundary.
    public var pendingPatternDelayRows: Int = 0

    /// `true` once the song has rolled past the last order and the
    /// restart byte sequencing has settled — the mixer flips this.
    public var finished: Bool = false

    public init() {}
}

// MARK: - Dispatcher

/// Tick-zero / continuous-tick effect dispatch.
///
/// - parameter cell: the pattern cell on this tick's row for this channel.
/// - parameter channel: per-channel mutable state.
/// - parameter song: song-wide mutable state.
/// - parameter tick: `0` on the row's first tick, `1..<song.speed`
///   otherwise.
public func dispatchEffect(
    cell: MODCell,
    channel: inout MODChannel,
    song: inout MODSongState,
    tick: Int
) {
    let effect = cell.effect
    let param = cell.effectParam

    if tick == 0 {
        dispatchTickZero(
            effect: effect,
            param: param,
            cell: cell,
            channel: &channel,
            song: &song
        )
    } else {
        dispatchContinuous(
            effect: effect,
            param: param,
            channel: &channel,
            song: &song,
            tick: tick
        )
    }
}

// MARK: - Tick 0

/// Tick-0 dispatch — the "set" half of the table. Anything that
/// also has a continuous component (portamentos, vibrato) latches
/// its parameter here but takes no audible effect until tick 1.
private func dispatchTickZero(
    effect: UInt8,
    param: UInt8,
    cell: MODCell,
    channel: inout MODChannel,
    song: inout MODSongState
) {
    // Latch the row's effect so continuous ticks can re-read.
    channel.currentEffect = effect
    channel.currentEffectParam = param

    switch effect {
    case 0x0:
        // Arpeggio "00" with param 0 is "no effect" — only a true
        // arpeggio param (non-zero) survives to continuous ticks.
        if param == 0 {
            // Clear so continuous ticks know there's nothing to do.
            channel.currentEffect = 0
        }

    case 0x1:
        // Portamento up. Param 0 → repeat last (memory).
        if param != 0 { channel.lastPortamentoUpParam = param }

    case 0x2:
        // Portamento down. Param 0 → repeat last.
        if param != 0 { channel.lastPortamentoDownParam = param }

    case 0x3:
        // Tone portamento — period in the cell becomes the target
        // (if a non-zero period was set). Param 0 → reuse last.
        if param != 0 { channel.lastTonePortamentoParam = param }
        if cell.period != 0 {
            channel.portaTarget = cell.period
        }

    case 0x4:
        // Vibrato `4xy`. Either nibble being zero means "use last
        // non-zero value for that nibble".
        let speed = (param & 0xF0) >> 4
        let depth = param & 0x0F
        let lastSpeed = (channel.lastVibratoParam & 0xF0) >> 4
        let lastDepth = channel.lastVibratoParam & 0x0F
        let newSpeed = speed != 0 ? speed : lastSpeed
        let newDepth = depth != 0 ? depth : lastDepth
        channel.vibrato.speed = newSpeed
        channel.vibrato.depth = newDepth
        channel.lastVibratoParam = (newSpeed << 4) | newDepth

    case 0x5:
        // Tone porta + volume slide — parameter applies to the
        // volume slide; tone porta uses its own memory.
        if param != 0 { channel.lastVolumeSlideParam = param }

    case 0x6:
        // Vibrato + volume slide.
        if param != 0 { channel.lastVolumeSlideParam = param }

    case 0x7:
        // Tremolo `7xy`.
        let speed = (param & 0xF0) >> 4
        let depth = param & 0x0F
        let lastSpeed = (channel.lastTremoloParam & 0xF0) >> 4
        let lastDepth = channel.lastTremoloParam & 0x0F
        let newSpeed = speed != 0 ? speed : lastSpeed
        let newDepth = depth != 0 ? depth : lastDepth
        channel.tremolo.speed = newSpeed
        channel.tremolo.depth = newDepth
        channel.lastTremoloParam = (newSpeed << 4) | newDepth

    case 0x8:
        // Set pan (not vanilla ProTracker; tracker-extension hint).
        // No-op for hard-pan policy.
        break

    case 0x9:
        // Sample offset `9xx`. Param 0 → repeat last.
        let effective = param != 0 ? param : channel.lastSampleOffsetParam
        if param != 0 { channel.lastSampleOffsetParam = param }
        let byteOffset = Int(effective) * 256
        channel.samplePosition = UInt64(byteOffset) << 16

    case 0xA:
        // Volume slide. Param 0 → repeat last.
        if param != 0 { channel.lastVolumeSlideParam = param }

    case 0xB:
        // Position jump `Bxx`. Honoured at the next row boundary.
        song.pendingPositionJump = Int(param)

    case 0xC:
        // Set volume `Cxx`. Clamp at 64.
        channel.volume = min(param, 64)

    case 0xD:
        // Pattern break `Dxx`. Param decodes as `(hi × 10) + lo`
        // (BCD-ish layout from the tracker UI).
        let row = Int((param >> 4) & 0x0F) * 10 + Int(param & 0x0F)
        song.pendingPatternBreakRow = min(row, 63)

    case 0xE:
        // Extended.
        dispatchExtendedTickZero(
            param: param,
            channel: &channel,
            song: &song,
            cell: cell
        )

    case 0xF:
        // Set speed / tempo. `< 0x20` = ticks-per-row; `>= 0x20` =
        // BPM-derived tempo. Param 0 is undefined in spec — most
        // modules expect "ignore" or "stop"; we ignore.
        if param == 0 { break }
        if param < 0x20 {
            song.speed = Int(param)
        } else {
            song.tempo = Int(param)
        }

    default:
        break
    }
}

/// Tick-0 dispatch for `Exx`. The low nibble selects the
/// sub-command.
private func dispatchExtendedTickZero(
    param: UInt8,
    channel: inout MODChannel,
    song: inout MODSongState,
    cell: MODCell
) {
    let sub = (param & 0xF0) >> 4
    let x = param & 0x0F

    switch sub {
    case 0x0:
        // Filter toggle — no-op.
        break

    case 0x1:
        // Fine portamento up. Param 0 → memory.
        let amount = x != 0 ? x : channel.lastFinePortaUpParam
        if x != 0 { channel.lastFinePortaUpParam = x }
        if channel.period > UInt16(amount) {
            channel.period = max(channel.period - UInt16(amount),
                                 MODPeriod.minPeriod)
        }

    case 0x2:
        // Fine portamento down. Param 0 → memory.
        let amount = x != 0 ? x : channel.lastFinePortaDownParam
        if x != 0 { channel.lastFinePortaDownParam = x }
        channel.period = min(channel.period + UInt16(amount),
                             MODPeriod.maxPeriod)

    case 0x3:
        // Glissando control — stored, not enforced.
        break

    case 0x4:
        // Set vibrato waveform. Low 2 bits = waveform, bit 2 = retain.
        channel.vibrato.waveform =
            MODOscillatorWaveform(rawValue: x & 0x03) ?? .sine
        channel.vibrato.retainPosition = (x & 0x04) != 0

    case 0x5:
        // Set finetune. Low nibble is a signed-4 value: `0..7` map
        // to `0..+7`, `8..F` map to `-8..-1`.
        let signed: Int8 = x >= 8 ? Int8(Int(x) - 16) : Int8(x)
        channel.finetune = signed

    case 0x6:
        // Pattern loop. `E60` anchors; `E6x` (x > 0) jumps back.
        if x == 0 {
            channel.patternLoopRow = song.rowIndex
            channel.patternLoopArmed = true
        } else if channel.patternLoopArmed {
            if channel.patternLoopCount == 0 {
                channel.patternLoopCount = Int(x)
            } else {
                channel.patternLoopCount -= 1
            }
            if channel.patternLoopCount > 0 {
                song.pendingPatternBreakRow = channel.patternLoopRow
                // Pattern-loop is row-internal; cancel any external
                // position jump from this row.
                song.pendingPositionJump = nil
            }
        }

    case 0x7:
        // Set tremolo waveform.
        channel.tremolo.waveform =
            MODOscillatorWaveform(rawValue: x & 0x03) ?? .sine
        channel.tremolo.retainPosition = (x & 0x04) != 0

    case 0x8:
        // No-op for ProTracker.
        break

    case 0x9:
        // Retrigger memory. Param 0 → memory.
        if x != 0 { channel.lastRetriggerParam = x }

    case 0xA:
        // Fine volume slide up. Param 0 → memory.
        let amount = x != 0 ? x : channel.lastFineVolUpParam
        if x != 0 { channel.lastFineVolUpParam = x }
        channel.volume = min(channel.volume &+ amount, 64)

    case 0xB:
        // Fine volume slide down.
        let amount = x != 0 ? x : channel.lastFineVolDownParam
        if x != 0 { channel.lastFineVolDownParam = x }
        channel.volume = channel.volume > amount
            ? channel.volume - amount
            : 0

    case 0xC:
        // Note cut on tick `x` — handled on the corresponding
        // continuous tick. Latch the parameter via currentEffect.
        if x == 0 {
            channel.volume = 0
        }

    case 0xD:
        // Note delay — defer note trigger by `x` ticks. Stash the
        // cell on the channel for the mixer to consume.
        if x > 0 {
            channel.noteDelayTicks = Int(x)
            channel.pendingDelayedCell = cell
        }

    case 0xE:
        // Pattern delay — repeat current row `x` extra times.
        if x > 0 && song.pendingPatternDelayRows == 0 {
            song.pendingPatternDelayRows = Int(x)
        }

    case 0xF:
        // Invert loop — no-op.
        break

    default:
        break
    }
}

// MARK: - Continuous ticks (1..speed-1)

private func dispatchContinuous(
    effect: UInt8,
    param: UInt8,
    channel: inout MODChannel,
    song: inout MODSongState,
    tick: Int
) {
    switch effect {
    case 0x0:
        // Arpeggio — only meaningful with a non-zero param. Cycle
        // base / +x / +y semitones across consecutive ticks.
        guard param != 0, channel.notePeriod != 0 else { break }
        let x = Int((param & 0xF0) >> 4)
        let y = Int(param & 0x0F)
        let phase = tick % 3
        let shift = phase == 0 ? 0 : (phase == 1 ? x : y)
        channel.period = arpeggioPeriod(
            base: channel.notePeriod,
            semitoneShift: shift,
            finetune: channel.finetune
        )

    case 0x1:
        // Portamento up — subtract per tick.
        let amount = param != 0 ? param : channel.lastPortamentoUpParam
        if channel.period > UInt16(amount) {
            channel.period = max(channel.period - UInt16(amount),
                                 MODPeriod.minPeriod)
        }

    case 0x2:
        // Portamento down — add per tick.
        let amount = param != 0 ? param : channel.lastPortamentoDownParam
        channel.period = min(channel.period + UInt16(amount),
                             MODPeriod.maxPeriod)

    case 0x3:
        // Tone portamento.
        let amount = param != 0 ? param : channel.lastTonePortamentoParam
        tonePortamentoStep(amount: UInt16(amount), channel: &channel)

    case 0x4:
        // Vibrato.
        applyVibrato(channel: &channel)
        channel.vibrato.position = (channel.vibrato.position
            + Int(channel.vibrato.speed)) & 0x3F

    case 0x5:
        // Tone porta + volume slide.
        let toneAmt = channel.lastTonePortamentoParam
        tonePortamentoStep(amount: UInt16(toneAmt), channel: &channel)
        applyVolumeSlide(
            param: channel.lastVolumeSlideParam,
            channel: &channel
        )

    case 0x6:
        // Vibrato + volume slide.
        applyVibrato(channel: &channel)
        channel.vibrato.position = (channel.vibrato.position
            + Int(channel.vibrato.speed)) & 0x3F
        applyVolumeSlide(
            param: channel.lastVolumeSlideParam,
            channel: &channel
        )

    case 0x7:
        // Tremolo.
        applyTremolo(channel: &channel)
        channel.tremolo.position = (channel.tremolo.position
            + Int(channel.tremolo.speed)) & 0x3F

    case 0xA:
        // Volume slide.
        let p = param != 0 ? param : channel.lastVolumeSlideParam
        applyVolumeSlide(param: p, channel: &channel)

    case 0xE:
        dispatchExtendedContinuous(
            param: param,
            channel: &channel,
            tick: tick
        )

    default:
        break
    }
}

private func dispatchExtendedContinuous(
    param: UInt8,
    channel: inout MODChannel,
    tick: Int
) {
    let sub = (param & 0xF0) >> 4
    let x = Int(param & 0x0F)

    switch sub {
    case 0x9:
        // Retrigger every `x` ticks.
        let interval = x != 0 ? x : Int(channel.lastRetriggerParam)
        guard interval > 0 else { return }
        if tick % interval == 0 {
            channel.samplePosition = 0
            channel.sampleFinished = false
            channel.noteTriggered()
        }

    case 0xC:
        // Note cut on tick `x`.
        if tick == x {
            channel.volume = 0
        }

    case 0xD:
        // Note delay countdown handled by the mixer (triggers the
        // pending cell). The dispatcher itself just decrements.
        if channel.noteDelayTicks > 0 {
            channel.noteDelayTicks -= 1
        }

    default:
        break
    }
}

// MARK: - Helpers

/// Apply one vibrato step to `channel.period` (without advancing
/// position — the caller does that).
private func applyVibrato(channel: inout MODChannel) {
    guard channel.notePeriod != 0,
          channel.vibrato.depth != 0 else { return }
    let sample = channel.vibrato.currentSample()
    let delta = (sample * Int(channel.vibrato.depth)) / 128
    let shifted = Int(channel.notePeriod) + delta
    let clamped = max(Int(MODPeriod.minPeriod),
                      min(shifted, Int(MODPeriod.maxPeriod)))
    channel.period = UInt16(clamped)
}

/// Apply one tremolo step to `channel.volume` (without advancing
/// position).
private func applyTremolo(channel: inout MODChannel) {
    guard channel.tremolo.depth != 0 else { return }
    let sample = channel.tremolo.currentSample()
    let delta = (sample * Int(channel.tremolo.depth)) / 64
    let shifted = Int(channel.volume) + delta
    channel.volume = UInt8(max(0, min(shifted, 64)))
}

/// `Axy` / `5xy` / `6xy` volume slide. Upper nibble = up, lower
/// nibble = down. If both are set, ProTracker prioritises "up"
/// (NoiseTracker had a different rule; we follow PT 2.x).
private func applyVolumeSlide(param: UInt8, channel: inout MODChannel) {
    let up = (param & 0xF0) >> 4
    let down = param & 0x0F
    if up != 0 {
        channel.volume = min(channel.volume &+ up, 64)
    } else if down != 0 {
        channel.volume = channel.volume > down
            ? channel.volume - down
            : 0
    }
}

/// Slide `channel.period` toward `channel.portaTarget` by `amount`.
private func tonePortamentoStep(amount: UInt16, channel: inout MODChannel) {
    guard channel.portaTarget != 0, channel.period != 0 else { return }
    if channel.period < channel.portaTarget {
        let next = channel.period &+ amount
        channel.period = min(next, channel.portaTarget)
    } else if channel.period > channel.portaTarget {
        let next = channel.period > amount
            ? channel.period - amount
            : MODPeriod.minPeriod
        channel.period = max(next, channel.portaTarget)
    }
}

/// Resolve arpeggio "base + N semitones" by looking up the finetune
/// row in the canonical period table.
private func arpeggioPeriod(
    base: UInt16,
    semitoneShift: Int,
    finetune: Int8
) -> UInt16 {
    if semitoneShift == 0 { return base }
    guard let (noteIndex, _) = MODPeriod.note(forPeriod: base) else {
        return base
    }
    let shifted = noteIndex + semitoneShift
    guard (0..<36).contains(shifted) else { return base }
    let p = MODPeriod.period(noteIndex: shifted, finetune: finetune)
    return p == 0 ? base : p
}
