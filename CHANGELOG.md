# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased (proposed initial release)

### Added

- `MODFile` parser for 31-sample (`M.K.`, `M!K!`, `M&K!`, `N.T.`, `FLT4`,
  `FLT8`, `EXO4`/`EXO8`, `nCHN`, `nnCH`, `nnCN`, `TDZn`, `OCTA`/`OKTA`,
  `CD61`/`CD81`, `FA04`/`FA06`/`FA08`) and validated 15-sample
  Soundtracker modules, with `FLT8` pattern-pair reassembly and lenient
  loading of truncated sample data (`isTruncated`).
- Typed, `Equatable` `MODError` (`truncated`, `unrecognizedFormat`,
  `invalidSongLength`).
- `MODSignature` value type with static members for every known tag.
- Exact ProTracker period table (`MODPeriod`) with PAL/NTSC Paula clocks.
- `MODMixer`: ProTracker 2.x replayer and Paula voice emulation covering
  every `0`–`F` / `E1`–`EF` effect (except the `E0x` LED filter and
  `8xx`/`E8x` panning, which ProTracker also ignores), sample swapping,
  song-end detection, `Options` (`loopSong`, `maximumDuration`), a
  non-allocating `render(into:)`, and position/speed/tempo accessors.
- DocC catalog, Swift Package Index configuration and CI workflow.
