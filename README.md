# SwiftMOD

A pure-Swift decoder and software mixer for Amiga-tradition `.mod` module files — Ultimate Soundtracker, NoiseTracker, ProTracker, and their multichannel descendants. No external dependencies. Foundation only. The mixer renders interleaved stereo `Float32` PCM into a caller-provided buffer, so it drops straight into `AVAudioEngine`, `AVAudioSourceNode`, or any other audio host you can hand a pointer to.

```swift
let file = try MODFile(data: data)
let mixer = MODMixer(file: file, sampleRate: 44_100)
```

That's the whole API surface, roughly.

---

## Contents

- [What this is](#what-this-is)
- [A short history of MOD](#a-short-history-of-mod)
- [Supported variants](#supported-variants)
- [The MOD file format](#the-mod-file-format)
- [Timing model](#timing-model)
- [Installation](#installation)
- [Quick start](#quick-start)
- [AVAudioEngine bridge](#avaudioengine-bridge)
- [Status](#status)
- [Reference](#reference)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [License](#license)

---

## What this is

`SwiftMOD` is a from-scratch reader for the Amiga `.mod` module format plus a Paula-style software mixer that turns the parsed data into PCM. It targets modern Swift (6.0, strict concurrency on) and ships as a single library product. There is no UI, no playback engine, no file-format autodetection. Just `MODFile` (the parser) and `MODMixer` (the renderer). Hook the mixer up to whatever audio host you like.

The design constraint is "give me frames when I ask, don't allocate on the audio thread, don't pretend to be a player." Everything that isn't strictly necessary to produce samples lives outside the library.

The implementation is clean-room: no source code from libxmp, OpenMPT, MikMod, or Schism Tracker was read or copied. The behavior is reconstructed from public-domain specifications (the ProTracker user manual, the FireLight `MODFIL10.TXT` technote, the Amiga Hardware Reference Manual) — see [Reference](#reference) for the full citation list.

## A short history of MOD

The Amiga `.mod` file is the original multichannel tracker module. Karsten Obarski's [Ultimate Soundtracker](https://en.wikipedia.org/wiki/Ultimate_Soundtracker) shipped in 1987 on the Commodore Amiga and defined the layout: a fixed sample table, a pattern grid, an order list, and 8-bit signed PCM samples played through the Amiga's [Paula](https://en.wikipedia.org/wiki/Original_Amiga_chipset#Paula) custom chip. Within a couple of years the format had been extended by NoiseTracker (Mahoney & Kaktus, 1989) — which bumped the sample table from 15 to 31 entries and added the `M.K.` signature — and then again by ProTracker (Lars Hamre and the Amiga Freelancers, 1990), which finalized the effect command set still in use today.

Beyond the canonical 4-channel ProTracker variant, the demoscene produced a string of multichannel extensions in the early '90s: StarTrekker's `FLT8`, TakeTracker's `xCHN` family (6, 8, … 32 channels), Oktalyzer's `OCTA`, and the obscure Falcon-targeted `FA0x` group. SwiftMOD reads the ones that saw real-world use; see [Supported variants](#supported-variants).

The format predates every other tracker module in this lineage — `.s3m`, `.xm`, `.it` are all conceptually downstream of `.mod`. The Amiga period table, the row-and-tick timing model, and the `0..F` effect numbering all originate here.

## Supported variants

| Signature | Channels | Pattern count | Notes |
|-----------|---------:|--------------:|-------|
| (none)    | 4        | up to 64      | Ultimate Soundtracker / 15-sample format |
| `M.K.`    | 4        | up to 64      | NoiseTracker / ProTracker, the canonical 31-sample format |
| `M!K!`    | 4        | up to 128     | ProTracker, extended pattern table |
| `FLT4`    | 4        | up to 64      | StarTrekker 4-channel |
| `FLT8`    | 8        | up to 64      | StarTrekker 8-channel (paired patterns) |
| `2CHN`    | 2        | up to 64      | FastTracker stereo cut-down |
| `6CHN`    | 6        | up to 64      | TakeTracker / FastTracker 6-channel |
| `8CHN`    | 8        | up to 64      | TakeTracker / FastTracker 8-channel |
| `xxCH`    | 10..32   | up to 64      | TakeTracker generalized (e.g. `16CH`, `32CH`) |
| `OCTA`    | 8        | up to 64      | Oktalyzer 8-channel |
| `CD81`    | 8        | up to 64      | Falcon CD81 player 8-channel |
| `FA04`    | 4        | up to 64      | DigitalSound Falcon 4-channel |
| `FA06`    | 6        | up to 64      | DigitalSound Falcon 6-channel |
| `FA08`    | 8        | up to 64      | DigitalSound Falcon 8-channel |

The 15-sample no-signature variant is detected by file length — the parser falls back to it when the bytes at offset 1080 don't match any known signature and the file's overall size is consistent with the 15-sample header layout.

## The MOD file format

MOD is a fixed-layout binary container, not a chunked one. There are no parapointers, no offsets, no length prefixes — every byte position is computed from the file's signature and the order list.

### Header (1084 bytes for the 31-sample variants)

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x000` | 20   | Song name, ASCII, NUL-padded |
| `0x014` | 930  | 31 sample headers × 30 bytes |
| `0x3B6` | 1    | Song length (number of used order positions, 1..128) |
| `0x3B7` | 1    | Restart byte / CIAA timer (legacy, usually `0x7F`) |
| `0x3B8` | 128  | Pattern order table |
| `0x438` | 4    | Format signature (`M.K.`, `M!K!`, `FLT4`, etc) |

For the 15-sample no-signature variant the header is 600 bytes (20-byte name + 15 × 30-byte sample headers + 1-byte song length + 1-byte restart + 128-byte order list), with pattern data starting immediately after.

### Sample header (30 bytes)

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x00` | 22   | Sample name, ASCII, NUL-padded |
| `0x16` | 2    | Sample length in **words** (big-endian; multiply by 2 for byte length) |
| `0x18` | 1    | Finetune (low 4 bits, signed -8..+7) |
| `0x19` | 1    | Default volume (0..64) |
| `0x1A` | 2    | Loop start in words (big-endian) |
| `0x1C` | 2    | Loop length in words (big-endian; ≤ 1 word means "no loop") |

### Pattern data

After the header, each pattern is exactly `channels × 64 × 4` bytes, in row-major order. A single 4-byte cell encodes one note for one channel:

```
byte 0:  sssspppp
byte 1:  pppppppp        period = (byte0 & 0x0F) << 8 | byte1     (12 bits)
byte 2:  ssssCCCC        sample = (byte0 & 0xF0) | (byte2 >> 4)   (8 bits)
byte 3:  pppppppp        effect = byte2 & 0x0F                    (4 bits)
                         param  = byte3                           (8 bits)
```

A period of `0` means "no note this cell." The sample, effect, and parameter fields can still be set independently — that's how MOD encodes volume changes, slides, and pattern jumps without retriggering the sample.

### Sample bodies

Immediately after the pattern data, the raw 8-bit signed PCM for each sample is laid down in order, with no separator. Sample N's bytes occupy `samples[N].lengthBytes` consecutive bytes; sample 0 is conventionally empty (`length == 0`) and produces no bytes.

The full byte-level layout is documented in [`Reference/MOD-Format.md`](Reference/MOD-Format.md).

## Timing model

MOD has two timing knobs that together determine playback rate, both set via effect `F`:

- **`speed`**: number of ticks per row. Default 6. Set with `Fxx` where `xx ≤ 0x1F`.
- **`tempo`**: tick rate in BPM-derived units. Default 125. Set with `Fxx` where `xx ≥ 0x20`.

The conversion (same as every downstream tracker format) is:

```
tickRateHz     = tempo * 2 / 5
samplesPerTick = sampleRate / tickRateHz
samplesPerRow  = samplesPerTick * speed
```

At the defaults (`speed = 6`, `tempo = 125`, `sampleRate = 44100`) you get a 50 Hz tick (PAL VBL rate) and 882 samples per tick — the canonical Amiga timing.

Sample playback rate is derived from the Amiga Paula clock. For PAL the audio clock is `7093789.2 Hz / 2 = 3546894.6 Hz`; the per-sample step is computed as `paulaClockHz / period`, where `period` ranges from 113 (highest note, B-3 with finetune +7) to 856 (lowest note, C-1 with finetune -8).

Effects evaluate **once per tick**. Note triggers and tick-0-only effects (sample offset, set volume, position jump) fire on tick 0; continuous slides and modulation apply on every tick. The full effect set is documented in the [reference](#reference).

## Installation

Swift Package Manager. Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/antisynthesis/SwiftMOD", from: "0.1.0")
]
```

Then depend on the `SwiftMOD` product from your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftMOD", package: "SwiftMOD")
    ]
)
```

For local development:

```swift
dependencies: [
    .package(path: "../SwiftMOD")
]
```

## Quick start

```swift
import SwiftMOD

let data = try Data(contentsOf: url)
let file = try MODFile(data: data)

print(file.title)         // e.g. "stardstm.mod"
print(file.channelCount)  // 4 for M.K., 8 for FLT8, etc
print(file.orderCount)    // e.g. 16

let mixer = MODMixer(file: file, sampleRate: 44_100)

let frames = 1024
var buffer = [Float](repeating: 0, count: frames * 2) // interleaved L R
buffer.withUnsafeMutableBufferPointer { ptr in
    _ = mixer.render(into: ptr.baseAddress!, frames: frames)
}

if mixer.finished {
    // Order list exhausted. Song has ended.
}
```

`render(into:frames:)` returns the number of frames actually written. A short return means the song ended mid-buffer; the tail is zero-filled.

## AVAudioEngine bridge

Drop the mixer into an `AVAudioSourceNode` to play back on any Apple platform:

```swift
import AVFoundation
import SwiftMOD

final class MODPlayer {
    private let engine = AVAudioEngine()
    private let mixer: MODMixer
    private var sourceNode: AVAudioSourceNode!

    init(file: MODFile) throws {
        let output = engine.outputNode
        let sampleRate = output.inputFormat(forBus: 0).sampleRate
        self.mixer = MODMixer(file: file, sampleRate: sampleRate)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        )!

        self.sourceNode = AVAudioSourceNode(format: format) {
            [mixer] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let raw = ablPointer[0].mData else { return noErr }
            let ptr = raw.assumingMemoryBound(to: Float.self)
            _ = mixer.render(into: ptr, frames: Int(frameCount))
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws { try engine.start() }
    func stop()         { engine.stop() }
}
```

The render callback runs on the audio thread. `MODMixer` is `@unchecked Sendable` precisely because the host is expected to park it on one thread and never touch it elsewhere. There is no internal locking and concurrent renders will corrupt voice state.

## Status

**Alpha.** The package scaffold is in place; the parser, effect engine, and mixer are being implemented from spec in subsequent commits. Public API is the two-call `MODFile(data:) → MODMixer(file:sampleRate:)` pair documented above and is expected to remain stable through the alpha cycle. Track progress against [`Reference/MOD-Format.md`](Reference/MOD-Format.md) — every documented effect command and every variant signature is a known target.

Tagged 0.1.0 will gate on:

- All 31-sample variants in [Supported variants](#supported-variants) parsing cleanly
- Full ProTracker effect set 0..F including the `Exx` subgroup
- StarTrekker `FLT8` paired-pattern decoding
- Synthetic-fixture test coverage for parser edge cases and per-effect mixer behavior
- Smoke tests on a corpus of public-domain MOD files

## Reference

Byte-level format documentation, the Amiga period table, the full effect command catalog, and Paula chip behavior notes live in [`Reference/MOD-Format.md`](Reference/MOD-Format.md). That document also lists the public-domain specs SwiftMOD was implemented against.

## Requirements

- Swift **6.0** or later
- Xcode **16** or later
- Platforms: **iOS 17+**, **macOS 14+**, **tvOS 17+**, **watchOS 10+**, **visionOS 1+**

No third-party dependencies. Foundation only.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Patches that match the "ships clean, doesn't regress, stays minimal" bar are welcome; large changes should open an issue first.

## License

MIT. See [`LICENSE`](LICENSE).
