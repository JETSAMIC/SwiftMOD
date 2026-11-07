/// MODReplayer.swift
///
/// The tick-level sequencer and effect engine. It models ProTracker
/// 2.x's replay routine as a state machine — per-channel "n_" state,
/// the song-position / pattern-position / break / jump / delay flags —
/// and drives a set of emulated Paula voices (`PaulaVoice`). The mixer
/// only reads the voices' period, volume and DMA state.
///
/// Behaviour follows ProTracker (the de-facto reference for 4-channel
/// MODs), including its well-known quirks, documented in
/// `Reference/MOD-Format.md` → "ProTracker playback semantics":
///
/// - Note periods are quantised to the finetune-0 table, then re-read
///   from the channel's finetune row.
/// - Only `3xx`, `4xy`, `7xy` and `9xx` have parameter memory.
/// - `Exx` commands are evaluated on every tick, and on every
///   repetition of an `EEx` pattern delay (fine slides repeat).
/// - A sample number without a note sets volume/finetune immediately
///   but the new sample is only heard when the current one reaches its
///   loop end (Paula loop-register swap).
/// - `9xx` adjusts the channel's start pointer and is applied twice when
///   it shares a row with a note; the offset persists for later notes
///   that have no sample number.
/// - `Bxx` clears a `Dxx` break row set by a channel to its left.
///
/// The replayer never traps on file data: every table, sample and
/// pattern access is bounds-checked, and song looping is detected so
/// playback of B/D/E6 loops terminates.
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker was
/// consulted while writing this file.

import Foundation

// MARK: - Paula voice

/// Emulated Paula channel: period/volume registers, the DMA fetch
/// cursor, and the latched loop registers that are reloaded whenever
/// the current segment ends.
struct PaulaVoice: Sendable {
    /// Period register. `0` behaves like 65536 (effectively silent).
    var period: Int = 0
    /// Volume register `0...64`.
    var volume: Int = 0

    /// `true` once DMA has been started by a note. Before that the
    /// voice ignores loop-register writes.
    var dmaOn = false
    /// `true` while fetching a real segment; `false` once a one-shot
    /// sample has run out (Paula would be cycling a silent word).
    var active = false
    /// Index into the replayer's sample data of the segment being played.
    var sample = -1
    /// Integer byte position and fractional part.
    var position = 0
    var fraction = 0.0
    /// Exclusive end of the current segment.
    var end = 0

    /// Loop registers: what the voice continues with at segment end.
    var loopSample = -1
    var loopStart = 0
    var loopLength = 0

    /// Restart DMA on `[start, start + length)` of `sample`.
    mutating func trigger(sample: Int, start: Int, length: Int, data: [[Int8]]) {
        dmaOn = true
        self.sample = sample
        position = start
        fraction = 0
        end = start + length
        if sample >= 0, sample < data.count, start < data[sample].count, length > 0 {
            end = min(end, data[sample].count)
            active = true
        } else {
            reload(overshoot: 0, data: data)
        }
    }

    /// Write the loop registers. An idle (one-shot finished) voice picks
    /// a valid new loop up immediately, as Paula would on its next
    /// silent-word reload.
    mutating func setLoop(sample: Int, start: Int, length: Int, data: [[Int8]]) {
        loopSample = sample
        loopStart = start
        loopLength = length
        if dmaOn && !active { reload(overshoot: 0, data: data) }
    }

    /// Segment ended: continue with the loop registers, or go idle when
    /// the loop is a one-shot placeholder (≤ 1 word).
    mutating func reload(overshoot: Int, data: [[Int8]]) {
        guard loopLength > 2, loopSample >= 0, loopSample < data.count,
              loopStart < data[loopSample].count else {
            active = false
            return
        }
        sample = loopSample
        end = min(loopStart + loopLength, data[loopSample].count)
        let span = end - loopStart
        position = loopStart + (span > 0 ? overshoot % span : 0)
        active = span > 0
    }
}

// MARK: - Channel state

/// ProTracker per-channel state (the `n_*` variables).
struct MODChannelState: Sendable {
    // Current cell.
    var notePeriod = 0          // n_note & 0x0FFF
    var noteWord = 0            // n_note including sample high nibble
    var command: UInt8 = 0
    var param: UInt8 = 0        // n_cmdlo (tone portamento clears it)
    var cellEmpty = true        // previous cell was all zero

    // Sample pointers (bytes).
    var sample = -1             // 0-based index of the selected sample
    var start = 0               // n_start
    var length = 0              // n_length
    var loopStart = 0           // n_loopstart
    var loopLength = 0          // n_replen
    var waveStart = 0           // n_wavestart (EFx funk)

    // Pitch / volume.
    var period = 0              // n_period
    var finetune = 0            // nibble 0...15 = row of the period table
    var volume = 0              // n_volume
    var wantedPeriod = 0        // tone-portamento target
    var tonePortUp = false      // direction: true = period decreasing
    var tonePortSpeed = 0

    // Oscillators.
    var vibratoCommand: UInt8 = 0
    var vibratoPosition: UInt8 = 0
    var tremoloCommand: UInt8 = 0
    var tremoloPosition: UInt8 = 0
    var waveControl: UInt8 = 0  // low nibble vibrato, high nibble tremolo

    // Misc.
    var glissFunk: UInt8 = 0    // low nibble glissando, high nibble funk speed
    var funkOffset: UInt8 = 0
    var sampleOffset: UInt8 = 0 // 9xx memory
    var loopRow = 0             // E60 row (n_pattpos)
    var loopCount = 0
}

// MARK: - Replayer

struct MODReplayer: Sendable {

    let file: MODFile
    /// Sample PCM, mutable because `EFx` (invert loop) rewrites it.
    var sampleData: [[Int8]]
    var channels: [MODChannelState]
    var voices: [PaulaVoice]

    // Song state.
    var speed = 6
    var tempo = 125
    var counter: Int
    var songPosition = 0
    var patternPosition = 0     // row
    var breakPosition = 0       // mt_PBreakPos
    var positionJump = false    // mt_PosJumpFlag
    var breakFlag = false       // mt_PBreakFlag (E6x)
    var patternDelay = 0        // mt_PattDelTime
    var patternDelayRemaining = 0 // mt_PattDelTime2
    /// Row currently being played (for reporting).
    var currentOrder = 0
    var currentRow = 0

    /// When `true`, song end restarts instead of finishing.
    let loopSong: Bool
    /// Set when the song ended (`F00`, or a row is about to repeat).
    var ended = false
    /// Order/row pairs already played, for loop detection.
    private var visited: [Bool]

    /// `true` for 4-channel modules: ProTracker's 113...856 limits.
    /// Other channel counts (FastTracker-era formats) keep notes
    /// outside C-1...B-3 and slide within 28...6848.
    let amigaLimits: Bool
    private let periodFloor: Int
    private let periodCeiling: Int

    static let funkTable: [UInt8] = [0, 5, 6, 7, 8, 10, 11, 13, 16, 19, 22, 26, 32, 43, 64, 128]
    static let sineTable: [Int] = [
          0,  24,  49,  74,  97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
        255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120,  97,  74,  49,  24
    ]

    init(file: MODFile, loopSong: Bool) {
        self.file = file
        self.loopSong = loopSong
        sampleData = file.samples.map(\.data)
        let count = max(file.channelCount, 1)
        channels = Array(repeating: MODChannelState(), count: count)
        voices = Array(repeating: PaulaVoice(), count: count)
        counter = speed - 1     // first tick() starts row 0 immediately
        visited = Array(repeating: false, count: 128 * 64)
        amigaLimits = file.channelCount == 4
        periodFloor = amigaLimits ? Int(MODPeriod.minPeriod) : 28
        periodCeiling = amigaLimits ? Int(MODPeriod.maxPeriod) : 6848
    }

    // MARK: Tick driver (mt_music)

    /// Advance one tick.
    mutating func tick() {
        guard !ended else { return }
        counter += 1
        if counter >= speed {
            counter = 0
            if patternDelayRemaining == 0 {
                getNewNote()
                if ended { return }
            } else {
                for c in channels.indices { checkEffects(c) }
            }
            endOfRow()
        } else {
            for c in channels.indices { checkEffects(c) }
            while positionJump { nextPosition() }
        }
    }

    private mutating func getNewNote() {
        let order = songPosition
        let row = patternPosition
        let key = order * 64 + row
        if key < visited.count {
            if visited[key] {
                guard loopSong else { ended = true; return }
                visited = Array(repeating: false, count: visited.count)
            }
            visited[key] = true
        }
        currentOrder = order
        currentRow = row

        let patternIndex = order < file.patternOrder.count ? Int(file.patternOrder[order]) : -1
        let cells: MODRow? = (0..<file.patterns.count).contains(patternIndex)
            && row < file.patterns[patternIndex].rows.count
            ? file.patterns[patternIndex].rows[row] : nil

        for c in channels.indices {
            let cell = cells.flatMap { c < $0.count ? $0[c] : nil }
                ?? MODCell(period: 0, sampleNumber: 0, effect: 0, effectParam: 0)
            playVoice(c, cell)
        }
        // mt_SetDMA: latch every channel's loop registers.
        for c in channels.indices {
            let ch = channels[c]
            voices[c].setLoop(sample: ch.sample, start: ch.loopStart,
                              length: ch.loopLength, data: sampleData)
        }
    }

    /// mt_dskip and what follows: advance the row, apply pattern delay,
    /// in-pattern loop jumps, pattern breaks and position jumps.
    private mutating func endOfRow() {
        patternPosition += 1
        if patternDelay != 0 {
            patternDelayRemaining = patternDelay
            patternDelay = 0
        }
        if patternDelayRemaining != 0 {
            patternDelayRemaining -= 1
            if patternDelayRemaining != 0 { patternPosition -= 1 }
        }
        if breakFlag {
            breakFlag = false
            patternPosition = breakPosition
            breakPosition = 0
            // A pattern loop legitimately replays rows of this order.
            let base = songPosition * 64
            if base + 64 <= visited.count {
                for i in base..<(base + 64) { visited[i] = false }
            }
        }
        if patternPosition >= 64 { nextPosition() }
        while positionJump { nextPosition() }
    }

    private mutating func nextPosition() {
        patternPosition = breakPosition
        breakPosition = 0
        positionJump = false
        songPosition = (songPosition + 1) & 0x7F
        if songPosition >= file.songLength {
            let restart = Int(file.restartByte)
            songPosition = loopSong && restart < file.songLength ? restart : 0
        }
    }

    // MARK: Row processing (mt_PlayVoice / mt_SetRegs)

    private mutating func playVoice(_ c: Int, _ cell: MODCell) {
        if channels[c].cellEmpty { perNop(c) }

        channels[c].notePeriod = Int(cell.period)
        channels[c].noteWord = Int(cell.sampleNumber & 0xF0) << 8 | Int(cell.period)
        channels[c].command = cell.effect
        channels[c].param = cell.effectParam
        channels[c].cellEmpty = cell.isEmpty

        let number = Int(cell.sampleNumber)
        if number >= 1, number <= file.samples.count {
            let s = file.samples[number - 1]
            var ch = channels[c]
            ch.sample = number - 1
            ch.start = 0
            ch.length = s.length
            ch.finetune = Int(UInt8(bitPattern: s.finetune) & 0x0F)
            ch.volume = Int(s.volume)
            if s.loops {
                ch.loopStart = s.loopStart
                ch.loopLength = s.loopLength
                // A loop starting after 0 truncates playback at the loop
                // end; with loop start 0 the whole sample plays first.
                if s.loopStart > 0 { ch.length = s.loopStart + s.loopLength }
            } else {
                ch.loopStart = 0
                ch.loopLength = 2
            }
            ch.waveStart = ch.loopStart
            channels[c] = ch
            voices[c].volume = ch.volume
        }

        // mt_SetRegs
        guard channels[c].notePeriod != 0 else {
            checkMoreEffects(c)
            return
        }
        let cmd = channels[c].command
        let param = channels[c].param
        if cmd == 0xE && param & 0xF0 == 0x50 {
            channels[c].finetune = Int(param & 0x0F)
            setPeriod(c)
        } else if cmd == 0x3 || cmd == 0x5 {
            setTonePortamento(c)
            checkMoreEffects(c)
        } else if cmd == 0x9 {
            checkMoreEffects(c)
            setPeriod(c)
        } else {
            setPeriod(c)
        }
    }

    /// Quantise the cell's period to a note, re-read it at the channel's
    /// finetune, and (unless delayed by `EDx`) trigger the sample.
    private mutating func setPeriod(_ c: Int) {
        let note = channels[c].notePeriod
        if !amigaLimits && (note > 907 || note < 108) {
            channels[c].period = note
        } else {
            var i = 0
            while i < 36 && MODPeriod.flat(i) > note { i += 1 }
            channels[c].period = MODPeriod.flat(channels[c].finetune * MODPeriod.rowStride + i)
        }

        if channels[c].command == 0xE && channels[c].param & 0xF0 == 0xD0 {
            checkMoreEffects(c)
            return
        }
        if channels[c].waveControl & 0x04 == 0 { channels[c].vibratoPosition = 0 }
        if channels[c].waveControl & 0x40 == 0 { channels[c].tremoloPosition = 0 }
        triggerVoice(c)
        checkMoreEffects(c)
    }

    private mutating func triggerVoice(_ c: Int) {
        let ch = channels[c]
        voices[c].trigger(sample: ch.sample, start: ch.start, length: ch.length, data: sampleData)
        voices[c].period = ch.period
        voices[c].setLoop(sample: ch.sample, start: ch.loopStart, length: ch.loopLength, data: sampleData)
    }

    private mutating func setTonePortamento(_ c: Int) {
        let note = channels[c].notePeriod
        let row = channels[c].finetune * MODPeriod.rowStride
        var i = 0
        while i < MODPeriod.rowStride && MODPeriod.flat(row + i) > note { i += 1 }
        if i >= MODPeriod.rowStride { i = 35 }
        if channels[c].finetune & 0x08 != 0 && i != 0 { i -= 1 }
        var wanted = MODPeriod.flat(row + i)
        if !amigaLimits && (note > 907 || note < 108) { wanted = note }

        channels[c].wantedPeriod = wanted
        channels[c].tonePortUp = false
        if wanted == channels[c].period {
            channels[c].wantedPeriod = 0
        } else if wanted < channels[c].period {
            channels[c].tonePortUp = true
        }
    }

    // MARK: Tick-0 effects (mt_CheckMoreEfx)

    private mutating func checkMoreEffects(_ c: Int) {
        updateFunk(c)
        switch channels[c].command {
        case 0x9: sampleOffset(c)
        case 0xB: positionJump(c)
        case 0xD: patternBreak(c)
        case 0xE: extendedCommand(c)
        case 0xC: setVolume(c)
        case 0xF: setSpeed(c)
        default: perNop(c)
        }
    }

    private mutating func perNop(_ c: Int) {
        voices[c].period = channels[c].period
    }

    private mutating func sampleOffset(_ c: Int) {
        if channels[c].param != 0 { channels[c].sampleOffset = channels[c].param }
        let offset = Int(channels[c].sampleOffset) * 256
        if offset < channels[c].length {
            channels[c].length -= offset
            channels[c].start += offset
        } else {
            channels[c].length = 2
        }
    }

    private mutating func positionJump(_ c: Int) {
        songPosition = Int(channels[c].param &- 1)
        breakPosition = 0
        positionJump = true
    }

    private mutating func patternBreak(_ c: Int) {
        let p = channels[c].param
        let row = Int(p >> 4) * 10 + Int(p & 0x0F)
        breakPosition = row > 63 ? 0 : row
        positionJump = true
    }

    private mutating func setVolume(_ c: Int) {
        channels[c].volume = min(Int(channels[c].param), 64)
        voices[c].volume = channels[c].volume
    }

    private mutating func setSpeed(_ c: Int) {
        let p = Int(channels[c].param)
        if p == 0 {
            ended = true            // F00: ProTracker stops the song
        } else if p >= 32 {
            tempo = p               // F20...FFF: BPM
        } else {
            speed = p               // F01...F1F: ticks per row
            counter = 0
        }
    }

    // MARK: Ticks 1... (mt_CheckEfx)

    private mutating func checkEffects(_ c: Int) {
        updateFunk(c)
        let cmd = channels[c].command
        if cmd == 0 && channels[c].param == 0 {
            perNop(c)
            return
        }
        switch cmd {
        case 0x0: arpeggio(c)
        case 0x1: portaUp(c, amount: Int(channels[c].param))
        case 0x2: portaDown(c, amount: Int(channels[c].param))
        case 0x3: tonePortamento(c)
        case 0x4: vibrato(c)
        case 0x5:
            tonePortamentoNoChange(c)
            volumeSlide(c)
        case 0x6:
            applyVibrato(c)
            volumeSlide(c)
        case 0xE: extendedCommand(c)
        default:
            perNop(c)
            if cmd == 0x7 { tremolo(c) }
            if cmd == 0xA { volumeSlide(c) }
        }
    }

    private mutating func arpeggio(_ c: Int) {
        let p = channels[c].param
        let shift: Int
        switch counter % 3 {
        case 1: shift = Int(p >> 4)
        case 2: shift = Int(p & 0x0F)
        default:
            perNop(c)
            return
        }
        let period = channels[c].period
        let row = channels[c].finetune * MODPeriod.rowStride
        if !amigaLimits && (period > MODPeriod.flat(row) || period < MODPeriod.flat(row + 35)) {
            voices[c].period = Int((Double(period) / pow(2, Double(shift) / 12)).rounded())
            return
        }
        for i in 0..<MODPeriod.rowStride where period >= MODPeriod.flat(row + i) {
            // Overflow past note 35 reads on into the next row, as in
            // ProTracker (index 36 yields period 0).
            voices[c].period = MODPeriod.flat(row + i + shift)
            return
        }
    }

    private mutating func portaUp(_ c: Int, amount: Int) {
        channels[c].period = max(channels[c].period - amount, periodFloor)
        voices[c].period = channels[c].period
    }

    private mutating func portaDown(_ c: Int, amount: Int) {
        channels[c].period = min(channels[c].period + amount, periodCeiling)
        voices[c].period = channels[c].period
    }

    private mutating func tonePortamento(_ c: Int) {
        if channels[c].param != 0 {
            channels[c].tonePortSpeed = Int(channels[c].param)
            channels[c].param = 0
        }
        tonePortamentoNoChange(c)
    }

    private mutating func tonePortamentoNoChange(_ c: Int) {
        var ch = channels[c]
        guard ch.wantedPeriod != 0 else { return }
        if ch.tonePortUp {
            ch.period -= ch.tonePortSpeed
            if ch.period <= ch.wantedPeriod {
                ch.period = ch.wantedPeriod
                ch.wantedPeriod = 0
            }
        } else {
            ch.period += ch.tonePortSpeed
            if ch.period >= ch.wantedPeriod {
                ch.period = ch.wantedPeriod
                ch.wantedPeriod = 0
            }
        }
        var out = ch.period
        if ch.glissFunk & 0x0F != 0 {
            // Glissando: round to the nearest table note at or above
            // the current pitch.
            let row = ch.finetune * MODPeriod.rowStride
            var i = 0
            while i < MODPeriod.rowStride && MODPeriod.flat(row + i) > out { i += 1 }
            if i >= MODPeriod.rowStride { i = 35 }
            out = MODPeriod.flat(row + i)
        }
        channels[c] = ch
        voices[c].period = out
    }

    private mutating func vibrato(_ c: Int) {
        let p = channels[c].param
        if p != 0 {
            var cmd = channels[c].vibratoCommand
            if p & 0x0F != 0 { cmd = (cmd & 0xF0) | (p & 0x0F) }
            if p & 0xF0 != 0 { cmd = (cmd & 0x0F) | (p & 0xF0) }
            channels[c].vibratoCommand = cmd
        }
        applyVibrato(c)
    }

    private mutating func applyVibrato(_ c: Int) {
        let ch = channels[c]
        let value = Self.waveform(ch.waveControl & 0x03, position: ch.vibratoPosition,
                                  rampSign: ch.vibratoPosition)
        let delta = (value * Int(ch.vibratoCommand & 0x0F)) >> 7
        let out = ch.vibratoPosition & 0x80 == 0 ? ch.period + delta : ch.period - delta
        voices[c].period = out
        channels[c].vibratoPosition = ch.vibratoPosition &+ ((ch.vibratoCommand >> 2) & 0x3C)
    }

    private mutating func tremolo(_ c: Int) {
        let p = channels[c].param
        if p != 0 {
            var cmd = channels[c].tremoloCommand
            if p & 0x0F != 0 { cmd = (cmd & 0xF0) | (p & 0x0F) }
            if p & 0xF0 != 0 { cmd = (cmd & 0x0F) | (p & 0xF0) }
            channels[c].tremoloCommand = cmd
        }
        let ch = channels[c]
        // ProTracker quirk: the ramp-down tremolo tests the *vibrato*
        // position's sign.
        let value = Self.waveform((ch.waveControl >> 4) & 0x03, position: ch.tremoloPosition,
                                  rampSign: ch.vibratoPosition)
        let delta = (value * Int(ch.tremoloCommand & 0x0F)) >> 6
        let out = ch.tremoloPosition & 0x80 == 0 ? ch.volume + delta : ch.volume - delta
        voices[c].volume = min(max(out, 0), 64)
        channels[c].tremoloPosition = ch.tremoloPosition &+ ((ch.tremoloCommand >> 2) & 0x3C)
    }

    /// ProTracker oscillator: 0 sine, 1 ramp down, 2 and 3 square
    /// (ProTracker's "random" setting plays a square wave).
    static func waveform(_ wave: UInt8, position: UInt8, rampSign: UInt8) -> Int {
        let index = Int(position >> 2) & 0x1F
        switch wave {
        case 0: return sineTable[index]
        case 1:
            let ramp = (index << 3) & 0xFF
            return rampSign & 0x80 != 0 ? 255 - ramp : ramp
        default: return 255
        }
    }

    private mutating func volumeSlide(_ c: Int) {
        let p = channels[c].param
        if p >> 4 != 0 {
            channels[c].volume = min(channels[c].volume + Int(p >> 4), 64)
        } else {
            channels[c].volume = max(channels[c].volume - Int(p & 0x0F), 0)
        }
        voices[c].volume = channels[c].volume
    }

    // MARK: Exy (mt_E_Commands) — runs on every tick

    private mutating func extendedCommand(_ c: Int) {
        let p = channels[c].param
        let x = Int(p & 0x0F)
        switch p >> 4 {
        case 0x0:
            break                   // E0x: Amiga LED filter — not emulated
        case 0x1:
            if counter == 0 { portaUp(c, amount: x) }
        case 0x2:
            if counter == 0 { portaDown(c, amount: x) }
        case 0x3:
            channels[c].glissFunk = (channels[c].glissFunk & 0xF0) | UInt8(x)
        case 0x4:
            channels[c].waveControl = (channels[c].waveControl & 0xF0) | UInt8(x)
        case 0x5:
            channels[c].finetune = x
        case 0x6:
            if counter == 0 { patternLoop(c, x) }
        case 0x7:
            channels[c].waveControl = (channels[c].waveControl & 0x0F) | UInt8(x << 4)
        case 0x8:
            break                   // E8x: unused by ProTracker playback
        case 0x9:
            retrigger(c, x)
        case 0xA:
            if counter == 0 {
                channels[c].volume = min(channels[c].volume + x, 64)
                voices[c].volume = channels[c].volume
            }
        case 0xB:
            if counter == 0 {
                channels[c].volume = max(channels[c].volume - x, 0)
                voices[c].volume = channels[c].volume
            }
        case 0xC:
            if counter == x {
                channels[c].volume = 0
                voices[c].volume = 0
            }
        case 0xD:
            if counter == x && channels[c].noteWord != 0 { retriggerVoice(c) }
        case 0xE:
            if counter == 0 && patternDelayRemaining == 0 { patternDelay = x + 1 }
        case 0xF:
            if counter == 0 {
                channels[c].glissFunk = (channels[c].glissFunk & 0x0F) | UInt8(x << 4)
                if x != 0 { updateFunk(c) }
            }
        default:
            break
        }
    }

    private mutating func patternLoop(_ c: Int, _ x: Int) {
        if x == 0 {
            channels[c].loopRow = patternPosition & 63
            return
        }
        if channels[c].loopCount == 0 {
            channels[c].loopCount = x
        } else {
            channels[c].loopCount -= 1
            if channels[c].loopCount == 0 { return }
        }
        breakPosition = channels[c].loopRow
        breakFlag = true
    }

    private mutating func retrigger(_ c: Int, _ x: Int) {
        guard x != 0 else { return }
        if counter == 0 && channels[c].notePeriod != 0 { return }
        if counter % x == 0 { retriggerVoice(c) }
    }

    /// mt_DoRetrg: restart DMA from the channel's (offset-adjusted)
    /// start pointer.
    private mutating func retriggerVoice(_ c: Int) {
        triggerVoice(c)
    }

    /// EFx "invert loop": every time the funk accumulator overflows,
    /// invert one byte of the loop, walking through it.
    private mutating func updateFunk(_ c: Int) {
        let speed = Int(channels[c].glissFunk >> 4)
        guard speed != 0 else { return }
        var ch = channels[c]
        ch.funkOffset = ch.funkOffset &+ Self.funkTable[speed]
        if ch.funkOffset & 0x80 != 0 {
            ch.funkOffset = 0
            if ch.loopLength > 2, ch.sample >= 0, ch.sample < sampleData.count {
                var w = ch.waveStart + 1
                if w >= ch.loopStart + ch.loopLength { w = ch.loopStart }
                ch.waveStart = w
                if w >= 0, w < sampleData[ch.sample].count {
                    sampleData[ch.sample][w] = ~sampleData[ch.sample][w]
                }
            }
        }
        channels[c] = ch
    }
}
