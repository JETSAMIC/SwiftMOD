# ``SwiftMOD``

Decode and play Amiga ProTracker `.mod` modules in pure Swift.

## Overview

SwiftMOD parses ProTracker, NoiseTracker, Soundtracker and StarTrekker
modules — plus the multichannel `xCHN` / `xxCH` descendants — into an
immutable, `Sendable` ``MODFile``, and renders them to interleaved stereo
`Float` PCM with ``MODMixer``.

Playback follows ProTracker 2.x, the de-facto reference for the format:
the exact period table and finetune rows, every `0`–`F` and `E0`–`EF`
effect with ProTracker's parameter-memory rules and quirks, and Paula's
sample-swap and loop behaviour. Parsing treats files as untrusted: every
malformed input throws a ``MODError`` instead of trapping, and playback
of songs that loop forever (via `Bxx`, `Dxx` or `E6x`) is bounded.

```swift
let file = try MODFile(data: data)
let mixer = MODMixer(file: file, sampleRate: 48_000)
while !mixer.isFinished {
    let frames = mixer.renderFrames(count: 1024)
    // feed `frames` (L, R, L, R, …) to your audio output
}
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``SwiftMOD/decode(_:)``
- ``SwiftMOD/mixer(for:sampleRate:options:)``
- ``SwiftMOD/version``

### Parsing

- ``MODFile``
- ``MODSignature``
- ``MODError``

### Module contents

- ``MODSample``
- ``MODPattern``
- ``MODRow``
- ``MODCell``
- ``MODNote``

### Playback

- ``MODMixer``
- ``MODMixer/Options``

### Amiga periods

- ``MODPeriod``
