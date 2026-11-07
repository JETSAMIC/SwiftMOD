/// MODMixer.swift
///
/// Software mixer for parsed modules. Drives `MODReplayer` at the
/// module's tick rate and renders its Paula voices to interleaved
/// stereo `Float` PCM at any output sample rate.
///
/// No source code from libxmp, OpenMPT, MikMod, or Schism Tracker was
/// consulted while writing this file.

import Foundation

/// Renders a ``MODFile`` to interleaved stereo 32-bit float PCM.
///
/// ```swift
/// let file = try MODFile(data: data)
/// let mixer = MODMixer(file: file, sampleRate: 48_000)
/// while !mixer.isFinished {
///     let frames = mixer.renderFrames(count: 1024)   // [L, R, L, R, …]
///     // hand `frames` to your audio output
/// }
/// ```
///
/// ## Playback model
///
/// Effects and timing follow ProTracker 2.x: speed (ticks per row,
/// default 6) and tempo (BPM, default 125, tick rate = BPM × 0.4 Hz)
/// are changed by `Fxx`; a tempo change takes effect after the tick
/// that sets it. Voices play at `PAL clock / period` with linear
/// interpolation and the Amiga's hard left/right/right/left panning
/// (repeating every four channels for multichannel modules).
///
/// ## Termination
///
/// A module never "ends" on real hardware — ProTracker wraps to order 0
/// and `Bxx`/`Dxx` can loop forever. The mixer finishes (``isFinished``
/// becomes `true`) when:
///
/// - playback is about to repeat an order/row it has already played
///   (the natural end of the order list, or a backwards `Bxx`/`Dxx`
///   jump), unless ``Options/loopSong`` is set;
/// - an `F00` command stops the song;
/// - ``Options/maximumDuration`` of audio has been rendered.
///
/// `E6x` pattern loops are allowed to replay rows; a pathological set of
/// interlocking pattern loops is still bounded by
/// ``Options/maximumDuration``.
///
/// ## Threading
///
/// `MODMixer` is a mutable reference type and is not `Sendable`: use
/// each instance from one thread (typically your audio render thread)
/// at a time. ``render(into:)`` performs no allocation, except a
/// one-time copy of a sample's PCM if the module uses `EFx` (invert
/// loop), which rewrites sample data.
public final class MODMixer {

    /// Playback options.
    public struct Options: Sendable, Equatable {

        /// When `true`, the song restarts instead of finishing: at the
        /// end of the order list playback continues from the restart
        /// byte (if it is `< songLength`, otherwise order 0), and loops
        /// created by jumps keep playing. Default `false`.
        public var loopSong: Bool

        /// Hard cap on rendered audio, in seconds; the mixer finishes
        /// once this much has been produced. `nil` removes the cap
        /// (then a looping song renders forever). Default `3600`.
        public var maximumDuration: Double?

        /// Create options.
        /// - Parameters:
        ///   - loopSong: Restart at song end instead of finishing.
        ///   - maximumDuration: Cap on rendered audio in seconds, or `nil`.
        public init(loopSong: Bool = false, maximumDuration: Double? = 3600) {
            self.loopSong = loopSong
            self.maximumDuration = maximumDuration
        }
    }

    // MARK: Public state

    /// The module being played.
    public let file: MODFile

    /// Output sample rate in Hz.
    public let sampleRate: Double

    /// The options the mixer was created with.
    public let options: Options

    /// `true` once playback has ended; further renders produce silence.
    public private(set) var isFinished = false

    /// Order position (`0..<songLength`) of the row currently playing.
    public var currentOrder: Int { replayer.currentOrder }

    /// Row (`0..<64`) currently playing.
    public var currentRow: Int { replayer.currentRow }

    /// Current speed in ticks per row.
    public var speed: Int { replayer.speed }

    /// Current tempo in BPM.
    public var tempo: Int { replayer.tempo }

    /// Number of stereo frames rendered so far (excluding the silent
    /// padding produced after the end).
    public private(set) var renderedFrames = 0

    // MARK: Init

    /// Create a mixer positioned at the start of the song.
    ///
    /// - Parameters:
    ///   - file: The module to play.
    ///   - sampleRate: Output rate in Hz, `1...1_000_000` (typically
    ///     `44_100` or `48_000`). Values outside that range are a
    ///     programming error and trap.
    ///   - options: Looping and duration options.
    public init(file: MODFile, sampleRate: Double, options: Options = Options()) {
        precondition((1...1_000_000).contains(sampleRate), "sampleRate must be within 1...1_000_000 Hz")
        self.file = file
        self.sampleRate = sampleRate
        self.options = options
        self.replayer = MODReplayer(file: file, loopSong: options.loopSong)
        if let limit = options.maximumDuration {
            let frames = max(limit, 0) * sampleRate
            maximumFrames = frames >= Double(Int.max) ? Int.max : Int(frames)
        } else {
            maximumFrames = Int.max
        }
    }

    // MARK: Rendering

    /// Render `count` stereo frames.
    ///
    /// - Parameter count: Number of frames; negative values are treated as `0`.
    /// - Returns: `count × 2` interleaved samples (`L, R, …`) in `-1...1`.
    ///   Frames after the end of the song are zero.
    public func renderFrames(count: Int) -> [Float] {
        let n = max(count, 0)
        var out = [Float](repeating: 0, count: n * 2)
        out.withUnsafeMutableBufferPointer { _ = render(into: $0) }
        return out
    }

    /// Render into a caller-provided interleaved stereo buffer without
    /// allocating.
    ///
    /// - Parameter buffer: Destination for `buffer.count / 2` frames
    ///   (`L, R, …`). It is overwritten; frames after the end of the
    ///   song are zero-filled. A trailing odd element is zeroed.
    /// - Returns: The number of frames of song audio written (less than
    ///   the buffer's frame capacity once the song has finished).
    @discardableResult
    public func render(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        base.update(repeating: 0, count: buffer.count)
        let frameCount = buffer.count / 2
        var frame = 0
        while frame < frameCount && !isFinished {
            if framesLeftInTick == 0 {
                let tempoBefore = replayer.tempo
                replayer.tick()
                if replayer.ended {
                    isFinished = true
                    break
                }
                let exact = sampleRate * 2.5 / Double(max(tempoBefore, 1)) + tickRemainder
                let whole = max(Int(exact), 1)
                tickRemainder = exact - Double(whole)
                framesLeftInTick = whole
            }
            var chunk = min(framesLeftInTick, frameCount - frame)
            chunk = min(chunk, maximumFrames - renderedFrames)
            if chunk <= 0 {
                isFinished = true
                break
            }
            mix(into: base + frame * 2, frames: chunk)
            frame += chunk
            framesLeftInTick -= chunk
            renderedFrames += chunk
        }
        return frame
    }

    // MARK: Private

    private var replayer: MODReplayer
    private let maximumFrames: Int
    private var framesLeftInTick = 0
    private var tickRemainder = 0.0

    private func mix(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let voiceCount = replayer.voices.count
        let norm = Float(max(1, (voiceCount + 1) / 2))
        let data = replayer.sampleData

        for c in 0..<voiceCount {
            var v = replayer.voices[c]
            guard v.active else { continue }
            let period = v.period > 0 ? Double(v.period) : 65536
            let step = MODPeriod.palClock / (period * sampleRate)
            let gain = Float(min(max(v.volume, 0), 64)) / (64 * 128 * norm)
            let left = c & 3 == 0 || c & 3 == 3

            var pcm = data[v.sample]
            var f = 0
            while f < frames {
                let s0 = Float(pcm[v.position])
                let s1: Float
                if v.position + 1 < v.end {
                    s1 = Float(pcm[v.position + 1])
                } else if v.loopLength > 2, v.loopSample >= 0, v.loopSample < data.count,
                          v.loopStart < data[v.loopSample].count {
                    s1 = Float(data[v.loopSample][v.loopStart])
                } else {
                    s1 = s0
                }
                let s = (s0 + (s1 - s0) * Float(v.fraction)) * gain
                out[f * 2 + (left ? 0 : 1)] += s

                v.fraction += step
                let advance = Int(v.fraction)
                v.fraction -= Double(advance)
                v.position += advance
                if v.position >= v.end {
                    v.reload(overshoot: v.position - v.end, data: data)
                    guard v.active else { break }
                    pcm = data[v.sample]
                }
                f += 1
            }
            replayer.voices[c] = v
        }

        for i in 0..<(frames * 2) {
            out[i] = min(max(out[i], -1), 1)
        }
    }
}
