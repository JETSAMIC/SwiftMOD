// MODSignatureTests.swift
//
// Format-tag detection. Synthesizes 4-byte fixtures (and minimal
// 1084-byte stand-ins where the parser dispatch path is exercised)
// to confirm each documented signature maps to the right enum case
// and channel count.

import Foundation
import Testing
@testable import SwiftMOD

@Suite("MOD signature detection")
struct MODSignatureTests {

    private func tag(_ s: String) -> Data {
        Data(s.utf8)
    }

    @Test("M.K. is the canonical 4-channel tag")
    func detectMK() {
        let sig = MODSignature.detect(tag: tag("M.K."))
        #expect(sig == .mk)
        #expect(sig?.channelCount == 4)
        #expect(sig?.sampleSlotCount == 31)
    }

    @Test("M!K! extended pattern table, 4 channels")
    func detectMKExtended() {
        #expect(MODSignature.detect(tag: tag("M!K!")) == .mkExtended)
    }

    @Test("FLT4 / FLT8 StarTrekker variants")
    func detectFLT() {
        #expect(MODSignature.detect(tag: tag("FLT4")) == .flt4)
        #expect(MODSignature.detect(tag: tag("FLT8")) == .flt8)
        #expect(MODSignature.detect(tag: tag("FLT8"))?.channelCount == 8)
    }

    @Test("2/6/8 CHN FastTracker / TakeTracker tags")
    func detectCHN() {
        #expect(MODSignature.detect(tag: tag("2CHN")) == .twoCHN)
        #expect(MODSignature.detect(tag: tag("6CHN")) == .sixCHN)
        #expect(MODSignature.detect(tag: tag("8CHN")) == .eightCHN)
        #expect(MODSignature.detect(tag: tag("6CHN"))?.channelCount == 6)
    }

    @Test("xxCH generalized — 10CH .. 32CH")
    func detectXxCH() {
        let s10 = MODSignature.detect(tag: tag("10CH"))
        let s16 = MODSignature.detect(tag: tag("16CH"))
        let s32 = MODSignature.detect(tag: tag("32CH"))
        #expect(s10 == .xxCH(10))
        #expect(s16 == .xxCH(16))
        #expect(s32 == .xxCH(32))
        #expect(s32?.channelCount == 32)
    }

    @Test("OCTA, CD81, FA08 8-channel tags")
    func detectExotic8() {
        #expect(MODSignature.detect(tag: tag("OCTA")) == .octa)
        #expect(MODSignature.detect(tag: tag("CD81")) == .cd81)
        #expect(MODSignature.detect(tag: tag("FA08")) == .fa08)
        #expect(MODSignature.detect(tag: tag("OCTA"))?.channelCount == 8)
    }

    @Test("Unknown tags return nil")
    func detectUnknown() {
        #expect(MODSignature.detect(tag: tag("WXYZ")) == nil)
        #expect(MODSignature.detect(tag: tag("....")) == nil)
        // Empty / zero-byte tag is the standard "no signature" marker.
        #expect(MODSignature.detect(tag: Data([0, 0, 0, 0])) == nil)
    }

    @Test("detect(in:) reads bytes at offset 1080")
    func detectInData() {
        var data = Data(repeating: 0, count: 1084)
        data.replaceSubrange(1080..<1084, with: tag("M.K."))
        #expect(MODSignature.detect(in: data) == .mk)

        data.replaceSubrange(1080..<1084, with: tag("8CHN"))
        #expect(MODSignature.detect(in: data) == .eightCHN)
    }

    @Test("noSignature15Sample reports 4 channels, 15 slots")
    func detectFifteenSampleLegacy() {
        let sig: MODSignature = .noSignature15Sample
        #expect(sig.channelCount == 4)
        #expect(sig.sampleSlotCount == 15)
    }
}
