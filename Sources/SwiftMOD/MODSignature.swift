/// MODSignature.swift
///
/// The 4-byte format tag at file offset 1080 (`0x438`) and the channel
/// count it implies. See `Reference/MOD-Format.md`, "Format signature
/// dispatch".

import Foundation

/// The format tag stored at offset 1080 of a 31-sample module, or the
/// absence of one for 15-sample Soundtracker modules.
///
/// `MODSignature` is a value (tag + channel count) rather than a closed
/// enum so that new tags can be recognised in later releases without
/// breaking `switch` statements in client code. Compare against the
/// static members (`.mk`, `.flt8`, `.xxCH(16)`, …) with `==`.
public struct MODSignature: Sendable, Hashable, CustomStringConvertible {

    /// The 4-character ASCII tag exactly as stored in the file
    /// (`"M.K."`, `"8CHN"`, `"16CH"`, …). Empty for
    /// ``noSignature15Sample``.
    public let tag: String

    /// Number of pattern channels the tag implies (`1...32`).
    public let channelCount: Int

    init(tag: String, channelCount: Int) {
        self.tag = tag
        self.channelCount = channelCount
    }

    /// Number of sample-header slots: 31 for every tagged variant, 15
    /// for the signature-less Soundtracker layout.
    public var sampleSlotCount: Int { tag.isEmpty ? 15 : 31 }

    /// `true` for StarTrekker `FLT8`, whose 8-channel patterns are
    /// stored as pairs of 4-channel patterns.
    public var isStarTrekkerPaired: Bool { tag == "FLT8" }

    /// The tag, or `"(none)"` for a 15-sample module.
    public var description: String { tag.isEmpty ? "(none)" : tag }

    // MARK: Known tags

    /// `M.K.` — ProTracker / NoiseTracker, 4 channels (the canonical tag).
    public static let mk = MODSignature(tag: "M.K.", channelCount: 4)
    /// `M!K!` — ProTracker, 4 channels, more than 64 patterns.
    public static let mkExtended = MODSignature(tag: "M!K!", channelCount: 4)
    /// `M&K!` — NoiseTracker variant, 4 channels.
    public static let mAndK = MODSignature(tag: "M&K!", channelCount: 4)
    /// `N.T.` — NoiseTracker, 4 channels.
    public static let nT = MODSignature(tag: "N.T.", channelCount: 4)
    /// `FLT4` — StarTrekker, 4 channels.
    public static let flt4 = MODSignature(tag: "FLT4", channelCount: 4)
    /// `FLT8` — StarTrekker, 8 channels stored as paired 4-channel patterns.
    public static let flt8 = MODSignature(tag: "FLT8", channelCount: 8)
    /// `EXO4` — StarTrekker variant, 4 channels.
    public static let exo4 = MODSignature(tag: "EXO4", channelCount: 4)
    /// `EXO8` — StarTrekker variant, 8 channels.
    public static let exo8 = MODSignature(tag: "EXO8", channelCount: 8)
    /// `2CHN` — FastTracker, 2 channels.
    public static let twoCHN = xCHN(2)
    /// `6CHN` — FastTracker / TakeTracker, 6 channels.
    public static let sixCHN = xCHN(6)
    /// `8CHN` — FastTracker / TakeTracker, 8 channels.
    public static let eightCHN = xCHN(8)
    /// `OCTA` — 8 channels.
    public static let octa = MODSignature(tag: "OCTA", channelCount: 8)
    /// `OKTA` — 8 channels.
    public static let okta = MODSignature(tag: "OKTA", channelCount: 8)
    /// `CD61` — Octalyser, 6 channels.
    public static let cd61 = MODSignature(tag: "CD61", channelCount: 6)
    /// `CD81` — Octalyser, 8 channels.
    public static let cd81 = MODSignature(tag: "CD81", channelCount: 8)
    /// `FA04` — Digital Tracker, 4 channels.
    public static let fa04 = MODSignature(tag: "FA04", channelCount: 4)
    /// `FA06` — Digital Tracker, 6 channels.
    public static let fa06 = MODSignature(tag: "FA06", channelCount: 6)
    /// `FA08` — Digital Tracker, 8 channels.
    public static let fa08 = MODSignature(tag: "FA08", channelCount: 8)

    /// No tag: the original 15-sample Ultimate Soundtracker layout
    /// (600-byte header, 4 channels).
    public static let noSignature15Sample = MODSignature(tag: "", channelCount: 4)

    /// `nCHN` — FastTracker / TakeTracker single-digit channel tag.
    /// - Parameter n: Channel count `1...9`.
    public static func xCHN(_ n: Int) -> MODSignature {
        MODSignature(tag: "\(n)CHN", channelCount: n)
    }

    /// `nnCH` — FastTracker / TakeTracker two-digit channel tag.
    /// - Parameter n: Channel count `1...32`, written as two digits.
    public static func xxCH(_ n: Int) -> MODSignature {
        MODSignature(tag: twoDigits(n) + "CH", channelCount: n)
    }

    /// `nnCN` — two-digit channel tag variant.
    /// - Parameter n: Channel count `1...32`, written as two digits.
    public static func xxCN(_ n: Int) -> MODSignature {
        MODSignature(tag: twoDigits(n) + "CN", channelCount: n)
    }

    /// `TDZn` — TakeTracker low-channel tag.
    /// - Parameter n: Channel count `1...3`.
    public static func tdz(_ n: Int) -> MODSignature {
        MODSignature(tag: "TDZ\(n)", channelCount: n)
    }

    private static func twoDigits(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }

    // MARK: Detection

    /// Detect the tag at offset 1080 of a module.
    ///
    /// - Parameter data: The whole module (at least 1084 bytes).
    /// - Returns: The recognised signature, or `nil` if `data` is too
    ///   short or the 4 bytes are not a known tag (which is the case
    ///   for 15-sample Soundtracker modules).
    public static func detect(in data: Data) -> MODSignature? {
        guard data.count >= 1084 else { return nil }
        let start = data.startIndex + 1080
        return detect(bytes: Array(data[start..<(start + 4)]))
    }

    /// Detect a signature from its raw 4-byte tag.
    ///
    /// - Parameter tag: Exactly 4 bytes.
    /// - Returns: The recognised signature, or `nil` for anything else.
    public static func detect(tag: Data) -> MODSignature? {
        detect(bytes: Array(tag))
    }

    static func detect(bytes: [UInt8]) -> MODSignature? {
        guard bytes.count == 4,
              bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let ascii = String(bytes: bytes, encoding: .ascii) else { return nil }

        let fixed: [MODSignature] = [
            .mk, .mkExtended, .mAndK, .nT, .flt4, .flt8, .exo4, .exo8,
            .octa, .okta, .cd61, .cd81, .fa04, .fa06, .fa08
        ]
        if let match = fixed.first(where: { $0.tag == ascii }) { return match }

        let digit: (UInt8) -> Int? = { (0x30...0x39).contains($0) ? Int($0 - 0x30) : nil }

        // "nCHN", n = 1...9
        if bytes[1...3] == [0x43, 0x48, 0x4E][...], let n = digit(bytes[0]), n >= 1 {
            return MODSignature(tag: ascii, channelCount: n)
        }
        // "nnCH" / "nnCN", nn = 01...32
        if let hi = digit(bytes[0]), let lo = digit(bytes[1]), bytes[2] == 0x43 {
            let n = hi * 10 + lo
            if (1...32).contains(n), bytes[3] == 0x48 || bytes[3] == 0x4E {
                return MODSignature(tag: ascii, channelCount: n)
            }
        }
        // "TDZn", n = 1...3
        if ascii.hasPrefix("TDZ"), let n = digit(bytes[3]), (1...3).contains(n) {
            return MODSignature(tag: ascii, channelCount: n)
        }
        return nil
    }
}
