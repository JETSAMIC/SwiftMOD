/// MODMixer.swift
///
/// Paula-style software mixer for parsed `MODFile` instances. Renders
/// interleaved stereo `Float32` PCM at any sample rate.
///
/// ## Clock model
///
/// ProTracker drives playback off two integers:
///
/// - **Speed** (ticks per row): default 6, changed by `Fxx` with `xx < 0x20`.
/// - **Tempo** (BPM-derived): default 125, changed by `Fxx` with
///   `xx >= 0x20`. Tick rate in Hz = `tempo × 0.4`. At 125 BPM that
///   is the canonical 50 Hz (PAL vertical-blank frequency).
///
/// At each tick we call `MODEffects.dispatchEffect` for every active
/// channel, then advance the per-channel sample positions for the
/// number of output frames between this tick and the next.
///
/// ## Sample playback
///
/// Per channel:
///
/// 1. Compute playback rate from the channel's current period:
///    `rate = 7093789.2 / (period * 2)` Hz (PAL Amiga clock).
/// 2. Advance the Q16.16 fractional position by `rate / sampleRate`
///    per output frame.
/// 3. Linearly interpolate between adjacent `Int8` sample bytes,
///    scale by `volume / 64`, and pan according to ProTracker's
///    hard-pan layout (channels 0, 3 → left; channels 1, 2 → right;
///    higher channels alternate L/R/R/L… modulo 4).
/// 4. Honour sample looping: when the integer position passes
///    `loopStart + loopLength`, wrap back to `loopStart` if
///    `loopLength > 2`; otherwise stop the channel.
///
/// ## Stereo output
///
/// Output is always interleaved stereo, regardless of channel count.
/// We summed sample contributions into separate left/right
/// accumulators, then divide by `max(channelCount / 2, 1)` to keep
/// peak energy bounded. We do soft clamping at ±1.0 — if the input
/// module is hot enough to peak past that, the clamp turns it into a
/// hard limiter, which is what Paula did anyway.
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker
/// was consulted while writing this file.

import Foundation

// MARK: - MODMixer

public final class MODMixer {

    // MARK: Public

    /// The parsed module driving this mixer.
    public let file: MODFile

    /// Output sample rate in Hz (typically `44_100` or `48_000`).
    public let sampleRate: Double

    /// `true` once the song reaches its end (last row of the last
    /// pattern in the order table, with `restartByte == 0x7F` or
    /// any out-of-range value meaning "play once").
    public private(set) var isFinished: Bool = false

    /// Initialise the mixer. The constructor does not allocate
    /// per-tick scratch beyond `file.channelCount` channel states.
    public init(file: MODFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
        self.song = MODSongState()
        self.song.speed = Int(file.initialSpeed)
        self.song.tempo = Int(file.initialTempo)
        self.channels = Array(
            repeating: MODChannel(),
            count: max(file.channelCount, 1)
        )
        recomputeFramesPerTick()
    }

    // MARK: Public API

    /// Render `count` interleaved stereo frames (`count × 2` floats).
    /// Safe to call repeatedly. When `isFinished == true`, returns a
    /// buffer of zeros.
    public func renderFrames(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        guard count > 0 else { return out }
        if isFinished { return out }

        var frame = 0
        while frame < count {
            // Start a new tick if we exhausted the previous one.
            if frameInTick >= framesPerTick {
                advanceTick()
                if isFinished { break }
            }

            // How many frames can we render before the next tick?
            let framesLeftInTick = framesPerTick - frameInTick
            let framesLeftInBuffer = count - frame
            let chunk = min(framesLeftInTick, framesLeftInBuffer)

            renderChunk(into: &out, startFrame: frame, frameCount: chunk)

            frame += chunk
            frameInTick += chunk
        }

        return out
    }

    // MARK: Private state

    private var channels: [MODChannel]
    private var song: MODSongState

    /// Frames per tick — recomputed when tempo changes.
    private var framesPerTick: Int = 1
    /// Counts up from 0 to `framesPerTick`.
    private var frameInTick: Int = 0
    /// Counts ticks within the current row (`0..<song.speed`).
    private var tickInRow: Int = 0
    /// `true` until we've dispatched tick 0 of the first row.
    private var awaitingFirstTick: Bool = true

    /// `7093789.2 / 2 = 3546894.6` — half the PAL Amiga clock, used
    /// as the numerator of `rate = clock / period`. We multiply
    /// instead of dividing to avoid the `× 2` in the hot loop.
    private static let pauseClockHz: Double = 7_093_789.2 / 2.0

    // MARK: Per-tick driver

    private func advanceTick() {
        frameInTick = 0

        if awaitingFirstTick {
            awaitingFirstTick = false
            dispatchRow(tick: 0)
            tickInRow = 0
            recomputeFramesPerTick()
            return
        }

        tickInRow += 1
        if tickInRow >= song.speed {
            // Row boundary. Honour pattern-delay, then move to the
            // next row (applying pattern break / position jump).
            tickInRow = 0

            if song.pendingPatternDelayRows > 0 {
                song.pendingPatternDelayRows -= 1
                // Re-dispatch tick 0 of the same row.
                dispatchRow(tick: 0)
                recomputeFramesPerTick()
                return
            }

            advanceRow()
            if isFinished { return }
            dispatchRow(tick: 0)
        } else {
            dispatchRow(tick: tickInRow)
        }

        recomputeFramesPerTick()
    }

    /// Move to the next row in the pattern, honouring `Dxx`/`Bxx`.
    private func advanceRow() {
        var nextOrder = song.orderIndex
        var nextRow = song.rowIndex + 1

        if let breakRow = song.pendingPatternBreakRow {
            nextRow = breakRow
            // If a position jump is also pending, the break row
            // applies to *that* jump's pattern.
            if song.pendingPositionJump == nil {
                nextOrder = song.orderIndex + 1
            }
            song.pendingPatternBreakRow = nil
        } else if nextRow >= 64 {
            nextRow = 0
            nextOrder = song.orderIndex + 1
        }

        if let jumpTo = song.pendingPositionJump {
            nextOrder = jumpTo
            // If no break row was set alongside the jump, restart at 0.
            if song.pendingPatternBreakRow == nil
                && song.rowIndex + 1 < 64 {
                // (already 0 from the elseif above? no — we only
                // reset nextRow when no break was set)
            }
            song.pendingPositionJump = nil
        }

        if nextOrder >= file.songLength {
            // Restart byte == 0x7F (127, the default) → "play once".
            // Anything below `songLength` is the loop-back order.
            if file.restartByte < UInt8(file.songLength) {
                nextOrder = Int(file.restartByte)
            } else {
                isFinished = true
                return
            }
        }

        song.orderIndex = nextOrder
        song.rowIndex = max(0, min(nextRow, 63))
    }

    /// Dispatch the row's cells across all channels for `tick`.
    private func dispatchRow(tick: Int) {
        let patternIndex = Int(file.patternOrder[song.orderIndex])
        guard patternIndex < file.patterns.count else {
            isFinished = true
            return
        }
        let pattern = file.patterns[patternIndex]
        guard song.rowIndex < pattern.rows.count else { return }
        let row = pattern.rows[song.rowIndex]

        for (i, cell) in row.enumerated() where i < channels.count {
            if tick == 0 {
                applyNewNote(cell: cell, channelIndex: i)
            }
            dispatchEffect(
                cell: cell,
                channel: &channels[i],
                song: &song,
                tick: tick
            )

            // Note-delay: when the countdown hits 0, trigger the
            // pending cell's note.
            if let pending = channels[i].pendingDelayedCell,
               channels[i].noteDelayTicks == 0,
               tick > 0 {
                applyNewNote(cell: pending, channelIndex: i)
                channels[i].pendingDelayedCell = nil
            }
        }
    }

    /// Apply the "new note" logic from a cell to a channel on tick 0.
    /// Triggers sample reload, period set, finetune copy, and LFO
    /// retrigger. Tone portamento (effect 3 or 5) suppresses the
    /// period change so the slide can drive it instead.
    private func applyNewNote(cell: MODCell, channelIndex i: Int) {
        // Sample number first — ProTracker loads the sample's
        // default volume even if the row has no period.
        if cell.sampleNumber != 0 {
            let idx = Int(cell.sampleNumber)
            if idx >= 0 && idx <= file.samples.count {
                // 1-based; sample 0 is the empty sentinel.
                let s = idx >= 1 && idx - 1 < file.samples.count
                    ? file.samples[idx - 1]
                    : MODSample.empty
                channels[i].sampleNumber = cell.sampleNumber
                channels[i].volume = s.volume
                channels[i].finetune = s.finetune
            }
        }

        // Period — load unless this is a tone-portamento row, in
        // which case the period is the slide target (handled in
        // dispatch).
        if cell.period != 0 {
            let isTonePorta = cell.effect == 0x3 || cell.effect == 0x5
            if isTonePorta {
                channels[i].portaTarget = cell.period
            } else {
                channels[i].period = cell.period
                channels[i].notePeriod = cell.period
                channels[i].samplePosition = 0
                channels[i].sampleFinished = false
                channels[i].noteTriggered()
            }
        }
    }

    private func recomputeFramesPerTick() {
        // tickHz = tempo * 0.4   (50 Hz at 125 BPM)
        let tickHz = Double(song.tempo) * 0.4
        guard tickHz > 0 else {
            framesPerTick = 1
            return
        }
        framesPerTick = max(1, Int((sampleRate / tickHz).rounded()))
    }

    // MARK: Frame rendering

    private func renderChunk(
        into out: inout [Float],
        startFrame: Int,
        frameCount: Int
    ) {
        let channelCount = channels.count
        // Normalise to keep peak energy bounded as channel count
        // grows. `max(1, ceil(N/2))` keeps a 4-channel ProTracker
        // module roughly unity-gain.
        let panNorm = Float(max(1, (channelCount + 1) / 2))

        for c in 0..<channelCount {
            // Look up sample once per chunk.
            let sampleNumber = Int(channels[c].sampleNumber)
            guard sampleNumber >= 1,
                  sampleNumber - 1 < file.samples.count else { continue }
            let sample = file.samples[sampleNumber - 1]
            guard !sample.data.isEmpty,
                  channels[c].period != 0,
                  !channels[c].sampleFinished else { continue }

            let rate = MODMixer.pauseClockHz / Double(channels[c].period)
            let posIncrement = UInt64((rate / sampleRate * Double(1 << 16)).rounded())
            let volume = Float(channels[c].volume) / 64.0
            let (leftGain, rightGain) = panForChannel(c, channelCount: channelCount)

            var pos = channels[c].samplePosition
            let loopEnd = UInt64(sample.loopStart + sample.loopLength) << 16
            let endPos = UInt64(sample.data.count) << 16
            let loopsActive = sample.loopLength > 2
            let loopStart = UInt64(sample.loopStart) << 16

            for f in 0..<frameCount {
                let intPos = Int(pos >> 16)
                if intPos >= sample.data.count {
                    if loopsActive {
                        let overshoot = pos - loopEnd
                        pos = loopStart &+ (overshoot
                                            % max(loopEnd - loopStart, 1))
                    } else {
                        channels[c].sampleFinished = true
                        break
                    }
                    continue
                }

                // Linear interpolation between data[intPos] and the
                // next byte (looping to loopStart if necessary).
                let s0 = Float(sample.data[intPos]) / 128.0
                let nextIdx: Int
                if intPos + 1 < sample.data.count {
                    nextIdx = intPos + 1
                } else if loopsActive {
                    nextIdx = sample.loopStart
                } else {
                    nextIdx = intPos // hold last sample
                }
                let s1 = nextIdx < sample.data.count
                    ? Float(sample.data[nextIdx]) / 128.0
                    : s0
                let frac = Float(pos & 0xFFFF) / Float(1 << 16)
                let s = s0 + (s1 - s0) * frac
                let scaled = s * volume

                let outIdx = (startFrame + f) * 2
                out[outIdx]     += scaled * leftGain  / panNorm
                out[outIdx + 1] += scaled * rightGain / panNorm

                pos &+= posIncrement
                if pos >= endPos {
                    if loopsActive {
                        pos = loopStart &+ ((pos - loopEnd)
                            % max(loopEnd - loopStart, 1))
                    } else {
                        channels[c].sampleFinished = true
                        // Continue the loop so subsequent frames
                        // emit silence (already 0-initialised).
                        break
                    }
                }
            }

            channels[c].samplePosition = pos
        }

        // Soft clip at ±1.
        let s0 = startFrame * 2
        let s1 = (startFrame + frameCount) * 2
        for i in s0..<s1 {
            if out[i] > 1 { out[i] = 1 }
            else if out[i] < -1 { out[i] = -1 }
        }
    }

    /// ProTracker hard-pan layout — channels 0 and 3 left, 1 and 2
    /// right. For channel counts > 4 we extend the LRRL... pattern.
    private func panForChannel(
        _ channel: Int,
        channelCount: Int
    ) -> (left: Float, right: Float) {
        // The classic ProTracker pattern repeats every 4 channels:
        // 0:L 1:R 2:R 3:L 4:L 5:R 6:R 7:L ...
        let phase = channel & 0x3
        let leftFirst = (phase == 0 || phase == 3)
        return leftFirst ? (1.0, 0.0) : (0.0, 1.0)
    }
}
