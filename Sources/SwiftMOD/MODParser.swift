/// MODParser.swift
///
/// Stub. Real parser implementation lands in the next commit.
///
/// This file exists only so `MODFile(data:)` resolves during the
/// scaffolding commit. Replaced wholesale in
/// `parser(add): MOD file decoder for header, patterns, and PCM samples`.

import Foundation

enum MODParser {
    static func parse(_ data: Data) throws -> MODFile {
        throw MODError.truncated(stage: "parser-not-implemented")
    }
}
