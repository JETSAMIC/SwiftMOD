# SwiftMOD

Pure-Swift decoder and ProTracker-accurate software mixer for Amiga `.mod` modules (Soundtracker, NoiseTracker, ProTracker, StarTrekker and the multichannel `xCHN`/`xxCH` family).

- `MODFile` parses untrusted bytes into an immutable, `Sendable` model and throws a typed `MODError` for anything malformed — it never traps.
- `MODMixer` renders interleaved stereo `Float` PCM at any sample rate, following ProTracker 2.x playback (period table, finetune, every effect and its quirks, Paula sample swapping).
- Songs that loop forever (`Bxx`, `Dxx`, `E6x`) are detected, so rendering always terminates.
- No dependencies beyond Foundation.

## Requirements

- Swift 6.0+ / Xcode 16+
- iOS 17+, macOS 14+, tvOS 17+, watchOS 10+, visionOS 1+ (verified against the 27.3 SDKs)

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/JETSAMIC/SwiftMOD.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SwiftMOD", package: "SwiftMOD")
    ])
]
```

## Quick start

```swift
import SwiftMOD

let data = try Data(contentsOf: url)
let file = try MODFile(data: data)
print(file.title, file.signature, file.channelCount, file.orderCount)

let mixer = MODMixer(file: file, sampleRate: 44_100)
var buffer = [Float](repeating: 0, count: 1024 * 2)   // interleaved L, R
while !mixer.isFinished {
    let frames = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
    _ = frames   // hand buffer[0 ..< frames * 2] to your audio output
}
```

`render(into:)` never allocates (except a one-time copy of a sample if the module uses `EFx`, which rewrites sample data) and returns the number of frames of song audio written; the rest of the buffer is zero-filled. `renderFrames(count:)` is an allocating convenience.

### Errors

```swift
do {
    _ = try SwiftMOD.decode(data)
} catch let error as MODError {
    print(error.localizedDescription)
}
```

| Case | Meaning |
|------|---------|
| `.truncated(.header)` / `.truncated(.patterns)` | The file ends before the header or pattern data is complete |
| `.unrecognizedFormat` | No known signature, and the data does not validate as a 15-sample Soundtracker module |
| `.invalidSongLength(n)` | Song-length byte outside `1...128` |

A file that ends inside the sample bodies (common in old archives) still loads, with the affected samples shortened and `MODFile.isTruncated == true`.

### Looping and termination

By default the mixer finishes when playback is about to repeat an order/row it has already played (end of the order list, or a backwards `Bxx`/`Dxx`), on `F00`, or after one hour of audio. `E6x` pattern loops do not count as a repeat.

```swift
let options = MODMixer.Options(loopSong: true, maximumDuration: 600)
let mixer = SwiftMOD.mixer(for: file, sampleRate: 48_000, options: options)
```

With `loopSong` the song restarts from the restart byte (if `< songLength`, else order 0). `maximumDuration: nil` removes the cap.

### AVAudioEngine

```swift
import AVFoundation
import SwiftMOD

final class MODPlayer {
    private let engine = AVAudioEngine()

    init(file: MODFile) throws {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let renderer = MixerBox(MODMixer(file: file, sampleRate: sampleRate))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 2, interleaved: true)!
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let raw = buffers[0].mData else { return noErr }
            let samples = UnsafeMutableBufferPointer(
                start: raw.assumingMemoryBound(to: Float.self), count: Int(frameCount) * 2)
            renderer.mixer.render(into: samples)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}

/// The mixer is only ever touched from the audio render thread.
private final class MixerBox: @unchecked Sendable {
    let mixer: MODMixer
    init(_ mixer: MODMixer) { self.mixer = mixer }
}
```

`MODMixer` is a non-`Sendable` reference type with no internal locking: use each instance from one thread at a time. All README snippets are compiled by the test suite (`READMEExampleTests.swift`).

## Spec coverage

Reference: [`Reference/MOD-Format.md`](Reference/MOD-Format.md). Playback follows ProTracker 2.x; see "ProTracker playback semantics" in that document for every quirk implemented.

### Container

| Feature | Status |
|---------|--------|
| 31-sample header (title, sample headers, song length, restart, 128-entry order table) | Supported |
| 15-sample Ultimate Soundtracker layout (600-byte header, validated detection) | Supported (UST byte-based loop start handled; ST-specific effect semantics and tempo byte are not) |
| `M.K.` `M!K!` `M&K!` `N.T.` `FLT4` `EXO4` | Supported (4 channels) |
| `FLT8` paired 4-channel patterns | Supported (orders halved, pairs reassembled) |
| `1CHN`–`9CHN`, `01CH`–`32CH`, `01CN`–`32CN`, `TDZ1`–`TDZ3`, `OCTA` `OKTA` `CD61` `CD81` `EXO8` | Supported |
| `FA04` / `FA06` / `FA08` (Digital Tracker) | Partial — parsed with the standard layout; Digital Tracker extensions are not verified |
| Pattern count from all 128 order entries (fallback to used entries) | Supported |
| Sample length / loop start / loop length in words, loop length ≤ 1 word = no loop | Supported |
| Loop bounds validated against the sample; truncated sample bodies | Supported (lenient, `isTruncated`) |
| Finetune nibble, volume clamp to 64 | Supported |

### Playback

| Feature | Status |
|---------|--------|
| Exact ProTracker period table (16 finetunes × 36 notes), note quantisation | Supported |
| Amiga period limits 113–856 (4-channel) | Supported; multichannel modules use 28–6848 and keep notes outside C-1…B-3 |
| Speed (`F01`–`F1F`) vs BPM (`F20`–`FFF`), `F00` stops | Supported |
| `0xy` arpeggio (incl. table overflow) | Supported |
| `1xx` `2xx` portamento, `3xx` tone portamento, `5xy` | Supported |
| `4xy` vibrato, `6xy`, `7xy` tremolo; sine / ramp-down / square waveforms | Supported (waveform 3 plays square, as in ProTracker) |
| `9xx` sample offset (memory, double-apply quirk, offset past end) | Supported |
| `Axy` `Cxx` volume | Supported |
| `Bxx` position jump, `Dxx` pattern break (decimal, > 63 → 0, B/D ordering) | Supported |
| `E1x` `E2x` `EAx` `EBx` fine slides | Supported |
| `E3x` glissando, `E4x` `E7x` waveform control, `E5x` finetune | Supported |
| `E6x` pattern loop (per channel), `EEx` pattern delay (incl. D/E6/fine-slide interactions) | Supported |
| `E9x` retrigger, `ECx` note cut, `EDx` note delay | Supported |
| `EFx` invert loop (funk repeat) | Supported |
| Sample number without note (Paula loop-register swap), loop-start-0 behaviour | Supported |
| `E0x` Amiga LED filter | Not supported (ignored) |
| `8xx` / `E8x` panning | Not supported (ignored, as in ProTracker) |
| Song-end detection for `Bxx`/`Dxx` loops, duration cap | Supported |
| Output: hard LRRL panning, linear interpolation, PAL clock | Supported (no Paula BLEP synthesis or A500/A1200 RC filters) |

## Limitations

- Interpolation is linear; there is no emulation of Paula's analogue output stage, the LED filter (`E0x`) or band-limited step synthesis.
- `8xx`/`E8x` panning is ignored, matching ProTracker but not FastTracker-era multichannel players.
- 15-sample modules are played with ProTracker effect semantics; Ultimate Soundtracker's different effect numbering and its tempo byte are not interpreted.
- Interlocking `E6x` loops across channels can loop forever in ProTracker; the mixer bounds these only through `Options.maximumDuration`.
- Playback has been verified against hand-built modules derived from the specification, not against a reference renderer on a real-world corpus.

## References

- [`Reference/MOD-Format.md`](Reference/MOD-Format.md) — the byte-level specification this package implements, with its source list (ProTracker 2.x manual, FireLight `MODFIL10.TXT`, Amiga Hardware Reference Manual, OpenMPT wiki prose).
- No source code from libxmp, OpenMPT, MikMod or Schism Tracker was consulted.

## License

MIT — see [`LICENSE`](LICENSE).
