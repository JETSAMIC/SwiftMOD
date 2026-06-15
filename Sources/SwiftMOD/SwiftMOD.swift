// SwiftMOD — pure-Swift decoder and software mixer for ProTracker / NoiseTracker
// `.mod` module files in the Amiga tradition.
//
// This file is a placeholder shell for the public umbrella namespace. The
// concrete `MODFile` parser and `MODMixer` renderer land in follow-up phases.
// Keep this file lean — adding members here is a deliberate API decision, not
// a side effect of feature work.

import Foundation

/// Umbrella namespace for the SwiftMOD package.
///
/// Acts as the documented entry point for the library and as a stable home
/// for package-level constants (canonical Paula clock rates, supported
/// format signatures, library version) once the implementation lands.
///
/// The concrete types live alongside this namespace at file scope:
///
/// - `MODFile` — pure parser. Throws on malformed input. Exposes the
///   1084-byte header, the 31-entry sample table, the 128-byte order table,
///   the packed pattern grid, and the raw 8-bit signed PCM sample bodies.
/// - `MODMixer` — Paula-style software mixer. Renders interleaved stereo
///   `Float32` PCM into a caller-provided buffer at any sample rate. Does
///   not allocate on the audio thread.
/// - `MODError` — throwing surface for the parser. Cases mirror SwiftS3M's
///   `S3MError` shape (`tooShort`, `badSignature`, `truncatedPattern`, etc).
///
/// Two-call constructor pattern (matches SwiftS3M / SwiftIT / SwiftXM):
///
/// ```swift
/// let file = try MODFile(data: data)
/// let mixer = MODMixer(file: file, sampleRate: 48_000)
/// ```
public enum SwiftMOD {
    /// Semantic version of the SwiftMOD library. Bumped by hand alongside
    /// tag releases. The package itself does not consume this value — it
    /// exists for downstream code that wants to log or surface the decoder
    /// version.
    public static let version = "0.1.0"

    /// Decode a `.mod` byte stream into a `MODFile`. Equivalent to
    /// `try MODFile(data: data)`, exposed at the namespace level so
    /// callers can write `SwiftMOD.decode(data)` to match the call
    /// shape used by `SwiftS3M.decode` / `SwiftIT.decode`.
    ///
    /// ```swift
    /// let file  = try SwiftMOD.decode(data)
    /// let mixer = SwiftMOD.mixer(for: file, sampleRate: 48_000)
    /// ```
    public static func decode(_ data: Data) throws -> MODFile {
        try MODFile(data: data)
    }

    /// Build a `MODMixer` for a parsed module. Convenience that
    /// matches the namespace decoder above; equivalent to
    /// `MODMixer(file: file, sampleRate: sampleRate)`.
    public static func mixer(
        for file: MODFile,
        sampleRate: Double
    ) -> MODMixer {
        MODMixer(file: file, sampleRate: sampleRate)
    }
}
