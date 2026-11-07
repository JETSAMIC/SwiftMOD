# Getting Started

Load a module, inspect it, and render it to PCM.

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/JETSAMIC/SwiftMOD.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftMOD"])
]
```

## Parse a module

``MODFile/init(data:)`` reads the whole file. It throws ``MODError`` for
data that is not a module or that ends before the pattern data does:

```swift
import SwiftMOD

let data = try Data(contentsOf: url)
do {
    let file = try MODFile(data: data)
    print(file.title, file.signature, file.channelCount)
    for (n, sample) in file.samples.enumerated() where sample.length > 0 {
        print(n + 1, sample.name, sample.length, sample.loops)
    }
} catch let error as MODError {
    print(error.localizedDescription)
}
```

Files whose sample data is cut short — common in old archives — still
load; ``MODFile/isTruncated`` tells you when that happened.

## Render audio

``MODMixer`` produces interleaved stereo `Float` samples in `-1...1` at any
sample rate. Use ``MODMixer/renderFrames(count:)`` for convenience, or
``MODMixer/render(into:)`` on an audio thread to avoid allocation:

```swift
let mixer = MODMixer(file: file, sampleRate: 44_100)
var buffer = [Float](repeating: 0, count: 512 * 2)
while !mixer.isFinished {
    let frames = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
    // consume `frames` stereo frames from `buffer`
}
```

A mixer is a mutable reference type; use each instance from one thread
at a time.

## Control looping

Tracker songs often loop forever. By default the mixer finishes when
playback would repeat a row it has already played, on `F00`, or after
one hour of audio. Pass ``MODMixer/Options`` to change that:

```swift
// Loop the song (from its restart position) for at most ten minutes.
let options = MODMixer.Options(loopSong: true, maximumDuration: 600)
let looping = MODMixer(file: file, sampleRate: 48_000, options: options)
```

Setting ``MODMixer/Options/maximumDuration`` to `nil` together with
``MODMixer/Options/loopSong`` renders indefinitely.
