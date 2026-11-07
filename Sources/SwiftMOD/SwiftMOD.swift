// SwiftMOD — pure-Swift decoder and software mixer for Amiga
// ProTracker / NoiseTracker / Soundtracker `.mod` modules and their
// multichannel descendants.

import Foundation

/// Namespace for package-level entry points.
///
/// ```swift
/// let file  = try SwiftMOD.decode(data)
/// let mixer = SwiftMOD.mixer(for: file, sampleRate: 48_000)
/// ```
public enum SwiftMOD {

    /// The library's semantic version.
    public static let version = "0.1.0"

    /// Decode a module. Equivalent to ``MODFile/init(data:)``.
    ///
    /// - Parameter data: The complete file contents.
    /// - Returns: The parsed module.
    /// - Throws: ``MODError`` if the data is not a valid module.
    public static func decode(_ data: Data) throws -> MODFile {
        try MODFile(data: data)
    }

    /// Create a mixer for a module. Equivalent to
    /// ``MODMixer/init(file:sampleRate:options:)``.
    ///
    /// - Parameters:
    ///   - file: The module to play.
    ///   - sampleRate: Output rate in Hz (finite, `> 0`).
    ///   - options: Looping and duration options.
    /// - Returns: A mixer positioned at the start of the song.
    public static func mixer(
        for file: MODFile,
        sampleRate: Double,
        options: MODMixer.Options = MODMixer.Options()
    ) -> MODMixer {
        MODMixer(file: file, sampleRate: sampleRate, options: options)
    }
}
