// READMEExampleTests.swift
//
// Compiles (and where practical runs) the code shown in README.md and
// the DocC articles, so the documentation cannot drift from the API.

import Foundation
import Testing
import SwiftMOD
#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation
#endif

@Suite("README examples")
struct READMEExampleTests {

    @Test("Quick start")
    func quickStart() throws {
        let data = MODParserTests.fixture().build()

        // --- README: Quick start ---
        let file = try MODFile(data: data)
        print(file.title, file.signature, file.channelCount, file.orderCount)

        let mixer = MODMixer(file: file, sampleRate: 44_100)
        var buffer = [Float](repeating: 0, count: 1024 * 2)   // interleaved L, R
        while !mixer.isFinished {
            let frames = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
            _ = frames   // hand buffer[0 ..< frames * 2] to your audio output
        }
        // --- end ---

        #expect(mixer.isFinished)
    }

    @Test("Error handling and options")
    func errorsAndOptions() throws {
        let data = Data(count: 10)
        // --- README: Errors ---
        do {
            _ = try SwiftMOD.decode(data)
        } catch let error as MODError {
            print(error.localizedDescription)
        }
        // --- end ---

        let file = try MODFile(data: MODParserTests.fixture().build())
        // --- README: Looping ---
        let options = MODMixer.Options(loopSong: true, maximumDuration: 600)
        let mixer = SwiftMOD.mixer(for: file, sampleRate: 48_000, options: options)
        // --- end ---
        #expect(mixer.options.loopSong)
    }
}

#if canImport(AVFoundation) && !os(watchOS)
// --- README: AVAudioEngine bridge ---
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
// --- end ---
#endif
