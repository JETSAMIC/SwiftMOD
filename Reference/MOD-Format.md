# The MOD Module Format

The byte-level and behavioural reference for the Amiga `.mod` music module and its multichannel
descendants. This is the authoritative specification for SwiftMOD, and it is written so that it
can also be read without the package.

Section order: 1 Overview, 2 Conventions, 3 Byte-level layouts, 4 Enumerations and flags,
5 Algorithms, 6 Playback semantics and de-facto behaviour, 7 Robustness guidance, 8 Errata,
9 Implementation status, 10 References and provenance.

---

## Contents

1. [Overview](#1-overview)
   - [1.1 History and creating programs](#11-history-and-creating-programs)
   - [1.2 Variants and how to tell them apart](#12-variants-and-how-to-tell-them-apart)
   - [1.3 File names, extensions and media types](#13-file-names-extensions-and-media-types)
2. [Conventions](#2-conventions)
3. [Byte-level layouts](#3-byte-level-layouts)
   - [3.1 Overall structure](#31-overall-structure)
   - [3.2 31-sample header (1084 bytes)](#32-31-sample-header-1084-bytes)
   - [3.3 Sample header (30 bytes)](#33-sample-header-30-bytes)
   - [3.4 15-sample Soundtracker header (600 bytes)](#34-15-sample-soundtracker-header-600-bytes)
   - [3.5 Pattern data and the cell](#35-pattern-data-and-the-cell)
   - [3.6 StarTrekker FLT8 paired patterns](#36-startrekker-flt8-paired-patterns)
   - [3.7 Sample bodies](#37-sample-bodies)
   - [3.8 Locating structures](#38-locating-structures)
4. [Enumerations and flags](#4-enumerations-and-flags)
   - [4.1 Format signatures](#41-format-signatures)
   - [4.2 Finetune nibble](#42-finetune-nibble)
   - [4.3 Effect commands](#43-effect-commands)
   - [4.4 Extended (E) sub-commands](#44-extended-e-sub-commands)
   - [4.5 Oscillator waveform control](#45-oscillator-waveform-control)
   - [4.6 Soundtracker effect numbering](#46-soundtracker-effect-numbering)
5. [Algorithms](#5-algorithms)
   - [5.1 Signature dispatch and channel count](#51-signature-dispatch-and-channel-count)
   - [5.2 Stored pattern count](#52-stored-pattern-count)
   - [5.3 15-sample detection](#53-15-sample-detection)
   - [5.4 The period table](#54-the-period-table)
   - [5.5 Note lookup](#55-note-lookup)
   - [5.6 Period to frequency](#56-period-to-frequency)
   - [5.7 Timing: speed, tempo, CIA and VBlank](#57-timing-speed-tempo-cia-and-vblank)
   - [5.8 Oscillators](#58-oscillators)
   - [5.9 The ProTracker replay state machine](#59-the-protracker-replay-state-machine)
   - [5.10 Paula and mixing](#510-paula-and-mixing)
6. [Playback semantics and de-facto behaviour](#6-playback-semantics-and-de-facto-behaviour)
   - [6.1 Effect reference (0–F)](#61-effect-reference-0f)
   - [6.2 Extended effect reference (E0–EF)](#62-extended-effect-reference-e0ef)
   - [6.3 Sample numbers, notes and the Paula sample swap](#63-sample-numbers-notes-and-the-paula-sample-swap)
   - [6.4 Loop behaviour](#64-loop-behaviour)
   - [6.5 Song flow and song end](#65-song-flow-and-song-end)
   - [6.6 Tracker differences](#66-tracker-differences)
7. [Robustness guidance for readers](#7-robustness-guidance-for-readers)
8. [Errata](#8-errata)
9. [Implementation status (SwiftMOD)](#9-implementation-status-swiftmod)
10. [References and provenance](#10-references-and-provenance)

---

## 1. Overview

A MOD file is a self-contained piece of music: a small set of 8-bit signed PCM instruments
("samples"), a set of 64-row patterns (a grid of rows × channels, each cell holding a note, a
sample number and one effect), and an order list that says in which sequence the patterns play.
Playback is driven by a fixed-rate "tick" clock; each row lasts *speed* ticks, and effects act on
tick 0 of a row or on every later tick.

The format mirrors the hardware it was designed for: the Commodore Amiga's Paula chip, which
plays four DMA-driven 8-bit channels, two routed left and two right. Pitches are stored as Paula
*periods* (clock divisors), not as note numbers, and sample sizes are stored in 16-bit words
because Paula fetches words.

### 1.1 History and creating programs

| Year | Program | Authors | Contribution |
|------|---------|---------|--------------|
| 1987 | Ultimate Soundtracker | Karsten Obarski | The original layout: 15 samples, 4 channels, no signature, loop start in bytes, a header tempo byte. |
| 1988–89 | Soundtracker 2.x … IX, Master Soundtracker (various crackers/groups) | — | Reworked effect numbering towards the later `0`–`F` set; still 15 samples. |
| 1989 | NoiseTracker | Mahoney & Kaktus | 31 samples, the `M.K.` signature at offset 1080, the restart byte. |
| 1990– | ProTracker 1.x–2.3 (2.3D is the reference release) | Lars Hamre and the Amiga Freelancers, later others | The definitive effect set (all `E` sub-commands), finetune, CIA tempo, `M!K!` for more than 64 patterns. |
| 1990– | StarTrekker | Björn Wesen (Exolon / Fairlight) | `FLT4`, `FLT8` (8 channels as paired patterns), `EXO4`/`EXO8`. |
| 1992– | FastTracker 1 / 2 | Fredrik Huss, Magnus Högdahl (Triton) | `xCHN` / `xxCH` multichannel tags, `8xx` panning, wider period range. |
| 1990s | TakeTracker, Octalyser (Code Design), Digital Tracker | — | `TDZx`/`xxCN`, `CD61`/`CD81`, `FA0x` tags. |

Every later tracker format (`.s3m`, `.xm`, `.it`) inherits MOD's row/channel grid, the `0`–`F`
effect letters and the speed/tempo model.

### 1.2 Variants and how to tell them apart

There is no version field. The variant is inferred, in this order:

1. **Signature** at offset 1080 (`0x438`): a 4-byte ASCII tag (§4.1). A recognised tag means the
   31-sample layout and fixes the channel count.
2. **No recognised tag**: the file may be a 15-sample Soundtracker module (600-byte header). Only
   accept it after structural validation (§5.3) — any binary file has *some* 4 bytes at 1080.
3. **Tracker fingerprinting** (optional, heuristic): the restart byte (`0x78` is typical of
   Soundtracker, `0x7F` of ProTracker and Scream Tracker 3 exports, a real position of NoiseTracker
   and FastTracker), the order-table padding, use of `8xx`/`E8x`, and periods outside 113–856
   suggest which tracker wrote the file and therefore which playback quirks apply. OpenMPT notes
   that it "has to guess" the quirks for every MOD it loads, because the format stores no playback
   settings.

### 1.3 File names, extensions and media types

- Extensions: `.mod` (all variants); `.m15` / `.stk` are used for 15-sample Soundtracker files;
  `.nst` is occasionally seen for NoiseTracker. On the Amiga the convention was a **prefix**,
  `mod.<name>`, which many PC tools fail to recognise.
- Media type: none is registered with IANA. `audio/x-mod` (freedesktop.org shared-mime-info) and
  `audio/mod` are used in practice.
- Apple platforms declare no system UTI for MOD; applications export their own identifier.
- PRONOM: `fmt/716` (identifies `M.K.` at offset 1080).

---

## 2. Conventions

| Topic | Rule |
|-------|------|
| Byte order | **Big-endian** for every multi-byte integer (the sample-header words). All other fields are single bytes or bit fields packed into bytes. |
| Integer types | `u8`, `u16be`. Sample PCM is `s8` (two's complement). There are no fixed-point fields. |
| Word | 2 bytes. Sample length, loop start and loop length are stored in words (except the Soundtracker loop start, §3.4). |
| Strings | Fixed-size fields, padded with NUL (`0x00`); a field may use its full width with no terminator. The Amiga used ISO-8859-1 (Latin-1) with the Topaz font; readers should decode as Latin-1, or pass raw bytes through. Some trackers pad with spaces. Sample names are often used for free text (greetings, credits). |
| Alignment | None. Structures are packed. Pattern data starts directly after the header; sample bodies directly after the last pattern. |
| Indexing | Sample numbers in cells are **1-based** (`1…31`); `0` means "none". Orders, patterns, rows and channels are 0-based. |
| Notes | ProTracker names its three octaves `C-1 … B-3` (period 856 … 113). PC trackers display the same pitches an octave or more higher (OpenMPT shows C-4 … B-6). This document uses the ProTracker names. |
| "Tick", "row", "speed", "tempo" | A tick is one step of the replay clock; a row lasts *speed* ticks; *tempo* (BPM) sets the tick rate. |
| Notation | `XY` is a parameter byte with high nibble `X` and low nibble `Y`; `Exy` is command `E` with sub-command `x`. |

---

## 3. Byte-level layouts

### 3.1 Overall structure

The file is a fixed-layout container: there are no chunks, pointers or length prefixes. Every
position follows from the signature (channel count, header size) and the order table (pattern
count).

```
+-------------------------------+ 0
| header                        |   1084 bytes (31-sample) or 600 bytes (15-sample)
+-------------------------------+ headerSize
| patterns                      |   patternCount × 64 rows × channels × 4 bytes
+-------------------------------+ headerSize + patternBytes
| sample bodies                 |   Σ sample[i].lengthBytes, in slot order
+-------------------------------+ end (possibly followed by junk, or truncated)
```

```
fileSize = headerSize + patternCount × 64 × channels × 4 + Σ lengthBytes[i]
```

### 3.2 31-sample header (1084 bytes)

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|-------:|-----:|------|------|-----------------------|-------|
| `0x000` (0) | 20 | char[20] | `songName` | Title | NUL-padded Latin-1. May be empty. |
| `0x014` (20) | 930 | struct[31] | `samples` | 31 sample headers, 30 bytes each (§3.3) | Slot *n* (1-based) is at `20 + (n−1)×30`. |
| `0x3B6` (950) | 1 | u8 | `songLength` | Number of order positions played, `1…128` | `0` or `>128` is invalid. |
| `0x3B7` (951) | 1 | u8 | `restart` | NoiseTracker: restart order. ProTracker: always written `0x7F`, ignored. Soundtracker heritage: `0x78`. FastTracker: restart order. | See §6.5. |
| `0x3B8` (952) | 128 | u8[128] | `orders` | Pattern number for each order position | Entries at index ≥ `songLength` are not played but do count towards the stored pattern count (§5.2). |
| `0x438` (1080) | 4 | char[4] | `signature` | Format tag (§4.1) | ASCII. |

### 3.3 Sample header (30 bytes)

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|-------:|-----:|------|------|-----------------------|-------|
| `0x00` | 22 | char[22] | `name` | Sample name | NUL-padded Latin-1. Soundtracker disks prefix `st-xx:`. |
| `0x16` | 2 | u16be | `length` | Length in **words**; bytes = `length × 2`, `0…131 070` | `0` = empty slot (no body bytes). |
| `0x18` | 1 | u8 | `finetune` | Low nibble: signed finetune `−8…+7` (§4.2). High nibble: should be 0, ignore it. | Not a finetune in 15-sample files (always 0 there). His Master's NoiseTracker (`FEST`, `M&K!`) uses a different scale (§6.6). |
| `0x19` | 1 | u8 | `volume` | Default volume `0…64` | Values above 64 occur; clamp to 64. |
| `0x1A` | 2 | u16be | `loopStart` | Loop start in **words** (bytes = ×2) | Soundtracker: in **bytes** (§3.4). |
| `0x1C` | 2 | u16be | `loopLength` | Loop length in **words** (bytes = ×2) | `0` or `1` = no loop. ProTracker writes `loopStart = 0, loopLength = 1` for one-shot samples. |

The maximum length is `0xFFFF` words = 131 070 bytes (OpenMPT: "8-bit samples with a maximum size
of 128 KB"). Older trackers had lower limits: Soundtracker versions allowed 9 998 bytes, later
32 KiB (Fraggie's version history).

### 3.4 15-sample Soundtracker header (600 bytes)

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|-------:|-----:|------|------|-----------------------|-------|
| `0x000` (0) | 20 | char[20] | `songName` | Title | |
| `0x014` (20) | 450 | struct[15] | `samples` | 15 sample headers (§3.3) | `finetune` byte is not a finetune; read as 0. **Loop start is in bytes**, loop length in words. |
| `0x1D6` (470) | 1 | u8 | `songLength` | `1…128` | |
| `0x1D7` (471) | 1 | u8 | `tempo` | Initial tempo (Soundtracker "BPM") | Most files store `120` (`0x78`); see §5.7. |
| `0x1D8` (472) | 128 | u8[128] | `orders` | Pattern numbers | Every entry should be `< 64`; validation accepts `< 128`. |
| — | — | — | — | No signature | Pattern data starts at offset 600. Always 4 channels. |

Cell encoding is identical to §3.5, but the sample number never exceeds 15 (the high sample nibble
in byte 0 is zero) and the effect numbering differs by Soundtracker version (§4.6). All Soundtracker
versions play **only the looped part** of a looped sample: the bytes before the loop start are
never heard (Fraggie's SoundTracker version history).

### 3.5 Pattern data and the cell

Patterns are stored one after another in pattern-number order. Each pattern is 64 rows; each row
is `channels` cells; each cell is 4 bytes. Storage is row-major:

```
cellOffset(p, row, ch) = headerSize + ((p × 64 + row) × channels + ch) × 4
```

Cell layout (bits listed most-significant first):

```
byte 0:  s s s s  p p p p     s = sample number bits 7–4,  p = period bits 11–8
byte 1:  p p p p  p p p p     period bits 7–0
byte 2:  s s s s  e e e e     s = sample number bits 3–0,  e = effect command
byte 3:  x x x x  y y y y     effect parameter
```

| Field | Extraction | Range | Meaning |
|-------|------------|-------|---------|
| `period` | `(b0 & 0x0F) << 8 \| b1` | `0…4095` | Amiga period of the note; `0` = no note. Only table periods (§5.4) are written by ProTracker. |
| `sample` | `(b0 & 0xF0) \| (b2 >> 4)` | `0…255` | 1-based sample number; `0` = no sample change. Values above the slot count are invalid; ignore them. |
| `effect` | `b2 & 0x0F` | `0…15` | Command (§4.3). |
| `param` | `b3` | `0…255` | Parameter; for `E`, the high nibble is the sub-command (§4.4). |

The four fields are independent: an effect without a note acts on whatever is playing, a sample
number without a note changes volume/finetune (and queues a sample swap, §6.3), and an all-zero
cell does nothing.

Example: bytes `14 37 10 00` → period `0x437` = 1079, sample `0x11` = 17, effect 0, parameter 0.
ProTracker quantises 1079 to C-1 (§5.5). Bytes `00 00 0C 20` → no note, no sample, `C20` (set volume
to 32).

### 3.6 StarTrekker FLT8 paired patterns

`FLT8` stores each 8-channel pattern as **two consecutive 4-channel patterns**: stored pattern `2n`
holds channels 0–3, stored pattern `2n+1` channels 4–7, each in the 4-channel layout of §3.5 (1 024
bytes). StarTrekker writes **even** order values (the first pattern of the pair), so the
8-channel pattern number is `order / 2`. All other 8-channel tags (`8CHN`, `OCTA`, `OKTA`, `CD81`,
`FA08`, `EXO8`) use the plain 8-channel layout.

### 3.7 Sample bodies

The PCM bodies of all slots follow the last pattern, concatenated in slot order (1, 2, …, 31 or 15)
with no separators. Slot *n* has `length[n] × 2` bytes of signed 8-bit PCM; empty slots occupy no
bytes. ProTracker and NoiseTracker treat the first word of a one-shot sample as the "silent loop"
(§6.4) and write it as zeros.

### 3.8 Locating structures

```
headerSize   = (31-sample) ? 1084 : 600
channels     = channelsFor(signature)                // §5.1
patternBytes = 64 × channels × 4                     // FLT8: 2 × 1024 per 8-channel pattern
patternStart = headerSize
sampleStart  = headerSize + patternCount × patternBytes   // patternCount from §5.2
sampleOffset[n] = sampleStart + Σ_{k<n} length[k] × 2
```

---

## 4. Enumerations and flags

### 4.1 Format signatures

| Tag (offset 1080) | Channels | Written by | Notes |
|-------------------|---------:|------------|-------|
| `M.K.` | 4 | NoiseTracker, ProTracker | The canonical tag. ProTracker writes it while the module has at most 64 patterns. |
| `M!K!` | 4 | ProTracker | Written when more than 64 patterns are stored. Otherwise identical. |
| `M&K!` | 4 | His Master's NoiseTracker | Rare; NoiseTracker-family playback, unusual finetune scale (§6.6). |
| `FEST` | 4 | His Master's NoiseTracker | Believed to be used only by the *His Master's Noise* musicdisk (Modland). Same caveats as `M&K!`. |
| `N.T.` | 4 | NoiseTracker | |
| `FLT4` | 4 | StarTrekker | |
| `FLT8` | 8 | StarTrekker | Paired 4-channel patterns (§3.6). |
| `EXO4` / `EXO8` | 4 / 8 | StarTrekker | `EXO8` uses the plain 8-channel layout. |
| `nCHN`, n = `1`…`9` | n | FastTracker (`2CHN`, `6CHN`, `8CHN`), TakeTracker (`5CHN`, `7CHN`, `9CHN`) | Single ASCII digit. |
| `nnCH`, nn = `01`…`99` | nn | FastTracker 2 and later PC trackers | Two ASCII decimal digits (normally `10` or more). FastTracker writes even counts; odd counts occur from other tools. |
| `nnCN`, nn = `01`…`99` | nn | TakeTracker (reportedly) | Two ASCII decimal digits (normally `10` or more). |
| `TDZ1`…`TDZ3` | 1…3 | TakeTracker | |
| `OCTA`, `OKTA` | 8 | Reportedly Oktalyzer-related / OctaMED exports | Plain 8-channel layout. (Oktalyzer's own format is the unrelated `OKTASONG` file.) |
| `CD61`, `CD81` | 6, 8 | Octalyser (Code Design, Atari STe/Falcon) | |
| `FA04`, `FA06`, `FA08` | 4, 6, 8 | Digital Tracker (Atari Falcon) | Some sources say Digital Tracker files carry extra bytes after the tag; unverified. |
| anything else | — | — | Not a 31-sample MOD. Try the 15-sample layout (§5.3). |

Readers must compare all four bytes exactly. Tags containing non-printable bytes are never valid
31-sample tags (MultimediaWiki: a non-ASCII tag suggests a 15-sample module). Other tags reported
for one-off files (for example `NSMS`, `LARD`) behave like `M.K.`; a reader may add them.

Not detectable from the tag: Mod's Grave `.wow` files carry `M.K.` but hold 8 channels, which can
only be inferred from the file size.

### 4.2 Finetune nibble

Finetune is a 4-bit two's-complement number in eighths of a semitone: `value = nibble < 8 ?
nibble : nibble − 16`.

| Nibble | `0` | `1` | `2` | `3` | `4` | `5` | `6` | `7` | `8` | `9` | `A` | `B` | `C` | `D` | `E` | `F` |
|--------|----:|----:|----:|----:|----:|----:|----:|----:|----:|----:|----:|----:|----:|----:|----:|----:|
| Finetune | 0 | +1 | +2 | +3 | +4 | +5 | +6 | +7 | −8 | −7 | −6 | −5 | −4 | −3 | −2 | −1 |

ProTracker uses the raw nibble as the row index into its period table (§5.4). A positive finetune
raises the pitch (smaller periods). Finetune `−8` is exactly one semitone below finetune 0 (its
row is the finetune-0 row shifted by one note).

### 4.3 Effect commands

| Cmd | Name | Tick 0 | Ticks 1… | Memory |
|----:|------|--------|----------|--------|
| `0` | Arpeggio (`0xy`, `000` = none) | base note | cycles base / +x / +y | none |
| `1` | Portamento up | — | period −= `xx` | none |
| `2` | Portamento down | — | period += `xx` | none |
| `3` | Tone portamento | set target (no retrigger) | slide towards target | speed (`300` reuses) |
| `4` | Vibrato | — (unmodulated) | modulate period | speed and depth per nibble |
| `5` | Tone portamento + volume slide | as `3` without changing speed | as `3` + `A` | uses `3`'s speed |
| `6` | Vibrato + volume slide | — | as `4` + `A` | uses `4`'s parameters |
| `7` | Tremolo | — (unmodulated) | modulate volume | speed and depth per nibble |
| `8` | (unused in ProTracker; PC: panning) | — | — | — |
| `9` | Sample offset | adjust start | — | offset (`900` reuses) |
| `A` | Volume slide | — | volume ± | none |
| `B` | Position jump | set jump | — | — |
| `C` | Set volume | set volume | — | — |
| `D` | Pattern break | set break (decimal row) | — | — |
| `E` | Extended (§4.4) | sub-command | sub-command | per sub-command |
| `F` | Set speed (`01`–`1F`) / tempo (`20`–`FF`), `F00` = stop | set | — | — |

### 4.4 Extended (E) sub-commands

| Sub | Name | Acts on | Notes |
|----:|------|---------|-------|
| `E0x` | Amiga LED filter | tick 0 | `x = 0` filter **on**, `x = 1` off. Hardware only. |
| `E1x` | Fine portamento up | tick 0 | period −= x |
| `E2x` | Fine portamento down | tick 0 | period += x |
| `E3x` | Glissando control | every tick | `x ≠ 0` rounds tone-portamento output to semitones |
| `E4x` | Vibrato waveform | every tick | §4.5 |
| `E5x` | Set finetune | every tick | x is a finetune nibble (§4.2) |
| `E6x` | Pattern loop | tick 0 | `x = 0` set loop row, else loop x times |
| `E7x` | Tremolo waveform | every tick | §4.5 |
| `E8x` | (unused by ProTracker playback) | — | Some PC players: 16-step panning. |
| `E9x` | Retrigger note | ticks where `tick mod x = 0` | `x = 0` = none |
| `EAx` | Fine volume slide up | tick 0 | |
| `EBx` | Fine volume slide down | tick 0 | |
| `ECx` | Note cut | tick x | volume := 0 |
| `EDx` | Note delay | tick x | |
| `EEx` | Pattern delay | tick 0 | repeat the row x more times |
| `EFx` | Invert loop ("funk repeat") | every tick | destructive |

"tick 0" sub-commands check `tick == 0` themselves and therefore also act on tick 0 of every
`EEx` repetition (§6.2).

### 4.5 Oscillator waveform control

`E4x` (vibrato) and `E7x` (tremolo) store `x` per channel:

| Bits | Meaning |
|------|---------|
| `x & 3 = 0` | Sine |
| `x & 3 = 1` | Ramp down (saw) |
| `x & 3 = 2` | Square |
| `x & 3 = 3` | Documented as "random"; **ProTracker plays a square wave** |
| `x & 4` | Do not reset the oscillator position when a note is triggered |
| `x & 8` | Unused |

### 4.6 Soundtracker effect numbering

15-sample modules do not share the ProTracker command set. From Fraggie's SoundTracker version
history:

| Versions | Commands |
|----------|----------|
| Ultimate Soundtracker 1.0–1.21, 1.8–2.0 | `1xy` arpeggio, `2xy` pitch bend (behaves like ProTracker `10y` / `20x`) |
| Soundtracker 2.0 (The Exterminator), D.O.C. Soundtracker II | `0` arpeggio, `1`/`2` portamento, `C` set volume, `D` volume slide (like ProTracker `A`), `E` volume auto-slide (continues until a command with parameter `00`) |
| Defjam III, Alpha Flight IV, D.O.C. IV and VI | as above plus `F0x` set speed |
| D.O.C. Soundtracker IX, Master Soundtracker 1.0 | `0`, `1`, `2`, `C`, `E0x` filter, `F` speed |
| Soundtracker 2.0–2.2 | `0`, `1`, `2`, `B` position jump, `C`, `D00` break (parameter ignored, always next pattern row 0), `E` filter, `F` speed |

`F` in all Soundtracker versions ignores the high nibble (speeds 1–15 only). Telling these
versions apart from the file alone is heuristic (effect usage, sample-name `st-xx:` prefixes, the
tempo byte).

---

## 5. Algorithms

### 5.1 Signature dispatch and channel count

```
func channelsFor(tag[0..4]) -> Int?:
    if any byte of tag is outside 0x20...0x7E: return nil
    switch tag:
      "M.K.", "M!K!", "M&K!", "FEST", "N.T.", "FLT4", "EXO4", "FA04":  return 4
      "CD61", "FA06":                                                   return 6
      "FLT8", "EXO8", "OCTA", "OKTA", "CD81", "FA08":                   return 8
    if tag[1...3] == "CHN" and tag[0] in '1'...'9':  return digit(tag[0])
    if tag[0], tag[1] are digits and tag[2] == 'C' and tag[3] in {'H','N'}:
        n = 10 × digit(tag[0]) + digit(tag[1]); return n ≥ 1 ? n : nil
    if tag[0...2] == "TDZ" and tag[3] in '1'...'3':  return digit(tag[3])
    return nil        // → try 15-sample (§5.3)
```

A reader may impose a lower maximum channel count than 99; SwiftMOD accepts `1…32`.

### 5.2 Stored pattern count

ProTracker writes every pattern up to the highest number found in **all 128** order entries, used
or not:

```
maxAll  = max(orders[0..<128])
maxUsed = max(orders[0..<songLength])
if FLT8: use orders[i] / 2 for both maxima, and patternBytes = 2048
count = maxAll + 1
if maxAll != maxUsed:
    allEnd  = headerSize + (maxAll  + 1) × patternBytes
    usedEnd = headerSize + (maxUsed + 1) × patternBytes
    // Some tools left garbage in unused entries; trust the file size.
    if allEnd > fileSize or (allEnd + Σlength > fileSize and usedEnd + Σlength ≤ fileSize):
        count = maxUsed + 1
```

The pattern data must then fit: `headerSize + count × patternBytes ≤ fileSize`, otherwise the file
is truncated.

### 5.3 15-sample detection

A file without a recognised tag is accepted as a Soundtracker module only if every check passes
(the checks are SwiftMOD's, chosen so that random data fails with overwhelming probability):

```
fileSize ≥ 600 + 1024 (header + one pattern)
1 ≤ songLength ≤ 128
every one of the 128 order entries < 128
for each of the 15 sample headers: length ≤ 32768 words and volume ≤ 64
600 + (maxUsed + 1) × 1024 ≤ fileSize
every cell in patterns 0...maxUsed: (b0 & 0xF0) == 0 and (period == 0 or 100 ≤ period ≤ 1000)
fileSize ≤ 600 + (maxAll + 1) × 1024 + Σ lengthBytes + 4096   // no large unexplained tail
```

Sample loop fields in a 15-sample file: `loopStartBytes = stored value` (bytes), `loopLengthBytes =
stored × 2`.

### 5.4 The period table

ProTracker's period table has 16 rows (one per finetune nibble) of 36 notes (C-1 … B-3). The
values are **published constants**, not a formula: several entries differ from rounding an exact
calculation or halving the octave below, and players must use them verbatim.

Finetune 0, the reference row:

| Note | Octave 1 | Octave 2 | Octave 3 |
|------|---------:|---------:|---------:|
| C  | 856 | 428 | 214 |
| C# | 808 | 404 | 202 |
| D  | 762 | 381 | 190 |
| D# | 720 | 360 | 180 |
| E  | 678 | 339 | 170 |
| F  | 640 | 320 | 160 |
| F# | 604 | 302 | 151 |
| G  | 570 | 285 | 143 |
| G# | 538 | 269 | 135 |
| A  | 508 | 254 | 127 |
| A# | 480 | 240 | 120 |
| B  | 453 | 226 | 113 |

All 16 rows (each line: C, C#, D, D#, E, F, F#, G, G#, A, A#, B):

```
ft  0  o1 856 808 762 720 678 640 604 570 538 508 480 453
       o2 428 404 381 360 339 320 302 285 269 254 240 226
       o3 214 202 190 180 170 160 151 143 135 127 120 113
ft +1  o1 850 802 757 715 674 637 601 567 535 505 477 450
       o2 425 401 379 357 337 318 300 284 268 253 239 225
       o3 213 201 189 179 169 159 150 142 134 126 119 113
ft +2  o1 844 796 752 709 670 632 597 563 532 502 474 447
       o2 422 398 376 355 335 316 298 282 266 251 237 224
       o3 211 199 188 177 167 158 149 141 133 125 118 112
ft +3  o1 838 791 746 704 665 628 592 559 528 498 470 444
       o2 419 395 373 352 332 314 296 280 264 249 235 222
       o3 209 198 187 176 166 157 148 140 132 125 118 111
ft +4  o1 832 785 741 699 660 623 588 555 524 495 467 441
       o2 416 392 370 350 330 312 294 278 262 247 233 220
       o3 208 196 185 175 165 156 147 139 131 124 117 110
ft +5  o1 826 779 736 694 655 619 584 551 520 491 463 437
       o2 413 390 368 347 328 309 292 276 260 245 232 219
       o3 206 195 184 174 164 155 146 138 130 123 116 109
ft +6  o1 820 774 730 689 651 614 580 547 516 487 460 434
       o2 410 387 365 345 325 307 290 274 258 244 230 217
       o3 205 193 183 172 163 154 145 137 129 122 115 109
ft +7  o1 814 768 725 684 646 610 575 543 513 484 457 431
       o2 407 384 363 342 323 305 288 272 256 242 228 216
       o3 204 192 181 171 161 152 144 136 128 121 114 108
ft -8  o1 907 856 808 762 720 678 640 604 570 538 508 480
       o2 453 428 404 381 360 340 320 302 285 269 254 240
       o3 226 214 202 190 180 170 160 151 143 135 127 120
ft -7  o1 900 850 802 757 715 675 636 601 567 535 505 477
       o2 450 425 401 379 357 337 318 300 284 268 253 238
       o3 225 212 200 189 179 169 159 150 142 134 126 119
ft -6  o1 894 844 796 752 709 670 632 597 563 532 502 474
       o2 447 422 398 376 355 335 316 298 282 266 251 237
       o3 223 211 199 188 177 167 158 149 141 133 125 118
ft -5  o1 887 838 791 746 704 665 628 592 559 528 498 470
       o2 444 419 395 373 352 332 314 296 280 264 249 235
       o3 222 209 198 187 176 166 157 148 140 132 125 118
ft -4  o1 881 832 785 741 699 660 623 588 555 524 494 467
       o2 441 416 392 370 350 330 312 294 278 262 247 233
       o3 220 208 196 185 175 165 156 147 139 131 123 117
ft -3  o1 875 826 779 736 694 655 619 584 551 520 491 463
       o2 437 413 390 368 347 328 309 292 276 260 245 232
       o3 219 206 195 184 174 164 155 146 138 130 123 116
ft -2  o1 868 820 774 730 689 651 614 580 547 516 487 460
       o2 434 410 387 365 345 325 307 290 274 258 244 230
       o3 217 205 193 183 172 163 154 145 137 129 122 115
ft -1  o1 862 814 768 725 684 646 610 575 543 513 484 457
       o2 431 407 384 363 342 323 305 288 272 256 242 228
       o3 216 203 192 181 171 161 152 144 136 128 121 114
```

Check values that catch computed or halved tables: ft 0 B-2 = 226 (not 227); ft −8 F-2 = 340;
ft −7 F-1 = 675, F#-1 = 636; ft −4 A#-1 = 494.

**In-memory layout.** ProTracker keeps the rows in nibble order (`0…7` = finetune `0…+7`, then
`8…15` = finetune `−8…−1`) and each row is **37** entries: the 36 notes followed by a `0`. Several
effects scan "the row" over all 37 entries, and arpeggio can index past the end of a row into the
next one (§6.1, `0xy`).

The reachable note periods therefore span 108 (B-3, ft +7) to 907 (C-1, ft −8), while
ProTracker's slide clamps are fixed at 113 and 856 (§6.1). OpenMPT's test case
*AmigaLimitsFinetune* checks that a player keeps finetuned notes in tune rather than clamping every
note to a single range the way Scream Tracker 3 does.

### 5.5 Note lookup

A cell period is never used directly. ProTracker converts it to a note index using the finetune-0
row, then reads the channel's finetune row:

```
func notePeriod(cellPeriod, finetuneNibble) -> Int:
    i = 0
    while i < 36 and table[0][i] > cellPeriod: i += 1   // first entry ≤ cellPeriod
    return table[finetuneNibble][i]                      // i == 36 → the trailing 0
```

So 1079 becomes C-1 (856 at ft 0), and anything below 113 becomes period 0 (silent). Tone
portamento's target and glissando use different searches (§6.1 `3xx`, §6.2 `E3x`).

Multichannel modules from PC trackers often contain notes outside C-1…B-3 (for example 1712 for an
octave below C-1). PC players keep such periods unchanged; SwiftMOD does this for every module that
does not have exactly 4 channels (periods above 907 or below 108 are used as-is).

### 5.6 Period to frequency

Paula plays one sample every *period* cycles of its audio clock:

```
sampleRateHz = clock / period
clock (PAL)  = 7 093 789.2 / 2 = 3 546 894.6 Hz
clock (NTSC) = 7 159 090.5 / 2 = 3 579 545.25 Hz
```

Most modules were made on PAL machines and players use the PAL clock. NTSC playback is about 0.9%
higher in pitch. A software resampler advances its source position by
`step = clock / (period × outputRate)` per output frame. A period of 0 behaves like 65 536 on Paula
(effectively silence).

### 5.7 Timing: speed, tempo, CIA and VBlank

- **Speed**: ticks per row, default 6, set by `F01`–`F1F`.
- **Tempo**: beats per minute, default 125, set by `F20`–`FFF` (CIA mode).
- **Tick rate** (CIA mode): ProTracker programs a CIA timer, clocked at the PAL E-clock of
  709 379 Hz, with `1 773 447 / BPM` (integer division). The tick rate is therefore
  `709 379 / ⌊1 773 447 / BPM⌋` ≈ `BPM × 0.4` Hz: 50 Hz at 125 BPM.

```
ticksPerSecond = BPM × 2 / 5
framesPerTick  = outputRate × 5 / (2 × BPM)        // 882 at 44.1 kHz, 125 BPM
framesPerRow   = framesPerTick × speed
```

- A tempo change takes effect **after the tick on which it was set** (OpenMPT test case
  *TempoChange*: at speed 1 it applies to the following row).
- **VBlank mode.** Soundtracker, NoiseTracker and ProTracker in VBlank mode tick at the 50 Hz
  (PAL) vertical blank and treat every `Fxx` as a speed. Modules written for VBlank timing that
  use `F20` or higher play far too fast in a CIA player; players offer a VBlank option or detect
  it heuristically.
- **Soundtracker tempo byte** (offset 471). Ultimate Soundtracker 1.0–1.21 and most Soundtracker
  versions write a constant 120 and run at the default rate. Ultimate Soundtracker 1.8–2.0 and
  D.O.C. Soundtracker IX honour other values, which Fraggie's version history converts as
  `BPM = (709 378.92 / 50 × 125) / ((240 − tempo) × 122)`; the result can exceed 255.

### 5.8 Oscillators

Vibrato and tremolo share one oscillator design. Each channel keeps an 8-bit position per
oscillator; the table index is `(position >> 2) & 0x1F` and the second half of the cycle is
signalled by `position & 0x80`.

```
sine[32] = 0 24 49 74 97 120 141 161 180 197 212 224 235 244 250 253
           255 253 250 244 235 224 212 197 180 161 141 120 97 74 49 24

func wave(type, position, signPosition) -> 0...255:
    i = (position >> 2) & 31
    switch type & 3:
      0: return sine[i]
      1: r = (i << 3) & 255; return (signPosition & 0x80) ? 255 − r : r
      2, 3: return 255

vibrato (ticks ≥ 1):
    delta  = (wave(vibType, vibPos, vibPos) × depth) >> 7
    output = (vibPos & 0x80) ? period − delta : period + delta
    vibPos = (vibPos + speed × 4) & 0xFF

tremolo (ticks ≥ 1):
    delta  = (wave(treType, trePos, vibPos) × depth) >> 6     // note: sign from vibPos
    output = clamp((trePos & 0x80) ? volume − delta : volume + delta, 0, 64)
    trePos = (trePos + speed × 4) & 0xFF
```

The modulated period/volume is written to the output only; the channel's stored period and volume
are unchanged. Oscillator positions are reset to 0 when a note is triggered, unless bit 2 of the
waveform control is set. ProTracker neither applies nor advances the oscillator on tick 0 (OpenMPT
test case *VibratoReset*). The ramp-down tremolo testing the **vibrato** position is a ProTracker
quirk that accurate players reproduce.

### 5.9 The ProTracker replay state machine

ProTracker 2.x (2.3D in particular) is the reference for 4-channel MODs. Reproducing its replay
routine as a state machine, rather than implementing a table of effect descriptions, is what gets
the edge cases right.

Song state: `speed`, `counter` (tick within the row), `songPos`, `patternPos` (row), `breakPos`,
`posJumpFlag`, `loopJumpFlag` (set only by `E6x`), `pattDelay`, `pattDelayRemaining`.

Channel state: the current cell, the sample's `start`/`length`/`loopStart`/`loopLength`, the funk
`waveStart`, `period`, `finetune`, `volume`, tone-portamento `target`/`speed`/`direction`, vibrato
and tremolo command bytes and positions, `waveControl`, glissando and funk nibbles, the `9xx`
memory, the `E6x` loop row and counter.

```
every tick:
    counter += 1
    if counter ≥ speed:
        counter = 0
        if pattDelayRemaining == 0:
            for each channel: newRow(ch)          // reads the cells, tick-0 effects
            for each channel: write loop registers (loopStart, loopLength) to Paula
        else:
            for each channel: perTick(ch)         // a pattern-delay repeat: no new notes
        endOfRow()
    else:
        for each channel: perTick(ch)
        while posJumpFlag: nextPosition()

newRow(ch):
    if the channel's previous cell was all zero: output period := period
    store the new cell
    if sample number s ≠ 0 (and valid):
        start = 0; length = len(s)
        if s loops: loopStart, loopLength = s.loop; if loopStart > 0: length = loopStart + loopLength
        else: loopStart = 0; loopLength = 1 word
        finetune = s.finetune; volume = s.volume; output volume = volume
    if cell period == 0: tickZeroEffects(ch); return
    if cmd == E5x:         finetune = x; setPeriod(ch)
    elif cmd == 3 or 5:    setTonePortaTarget(ch); tickZeroEffects(ch)
    elif cmd == 9:         tickZeroEffects(ch); setPeriod(ch)       // offset applied twice in total
    else:                  setPeriod(ch)

setPeriod(ch):
    period = notePeriod(cell period, finetune)                     // §5.5
    if cmd == EDx: tickZeroEffects(ch); return                     // delayed: no trigger
    if !(waveControl & 0x04): vibPos = 0
    if !(waveControl & 0x40): trePos = 0
    trigger Paula: DMA from start for length; output period = period
    tickZeroEffects(ch)

tickZeroEffects(ch):
    updateFunk(ch)
    switch cmd: 9 → sampleOffset; B → positionJump; D → patternBreak;
                E → extended(ch); C → setVolume; F → setSpeed;
                otherwise → output period := period

perTick(ch):
    updateFunk(ch)
    if cmd == 0 and param == 0: output period := period; return
    switch cmd: 0 arpeggio, 1 portaUp, 2 portaDown, 3 tonePorta, 4 vibrato,
                5 tonePorta(no speed change) + volumeSlide, 6 vibrato(no change) + volumeSlide,
                E extended(ch),
                otherwise: output period := period; 7 → tremolo; A → volumeSlide

endOfRow():
    patternPos += 1
    if pattDelay ≠ 0: pattDelayRemaining = pattDelay; pattDelay = 0
    if pattDelayRemaining ≠ 0:
        pattDelayRemaining -= 1
        if pattDelayRemaining ≠ 0: patternPos -= 1
    if loopJumpFlag: loopJumpFlag = false; patternPos = breakPos; breakPos = 0
    if patternPos ≥ 64: nextPosition()
    while posJumpFlag: nextPosition()

nextPosition():
    patternPos = breakPos; breakPos = 0; posJumpFlag = false
    songPos = (songPos + 1) & 127
    if songPos ≥ songLength: songPos = 0
```

All `E` handlers run on every tick; those meant to act once test `counter == 0`, which is why they
act again on tick 0 of each pattern-delay repetition. Because `nextPosition` runs immediately after
the delay bookkeeping, `EEx` together with `Dxx` resumes one row **after** the break target
(OpenMPT test case *DelayBreak*).

### 5.10 Paula and mixing

Hardware facts relevant to a software player:

- **Four DMA channels.** Paula reads sample data from chip RAM one 16-bit word (two samples) at a
  time. Each channel has a location register (`AUDxLC`), a length register in words (`AUDxLEN`,
  so 65 535 words is the largest block), a period register (`AUDxPER`) and a volume register
  (`AUDxVOL`).
- **Automatic looping.** When DMA starts, Paula latches location and length and raises an
  interrupt; when the block finishes it reloads from the registers again. ProTracker starts a note
  with the sample's start and length, then immediately rewrites the registers with the loop start
  and loop length, so the hardware continues into the loop on its own. A one-shot sample is given
  a 1-word loop on its first (zeroed) word, so the channel keeps running but outputs silence.
- **Volume** is `0…64` (64 = full scale; the register holds 7 bits and values above 64 act as 64).
  The output is effectively `sample × volume`, 8 bit × 6 bit.
- **Period** counts audio-clock cycles per sample. The Hardware Reference Manual gives 124 as the
  smallest period that DMA can sustain; ProTracker's table goes below that (to 108). Players
  normally play such periods at their nominal rate.
- **Stereo.** Channels 0 and 3 go to the left output, 1 and 2 to the right ("LRRL"), hard-panned.
  Multichannel players repeat the pattern every four channels. Many players offer reduced stereo
  separation because full separation is fatiguing on headphones; this is a presentation choice.
- **Zero-order hold.** Paula holds each sample value until the next one: there is no
  interpolation, so the output contains images of the sample spectrum. Software players use linear
  or higher-order interpolation (smoother, not authentic) or band-limited step synthesis (BLEP,
  authentic without aliasing).
- **Analogue filters.** After the DACs the Amiga has a fixed one-pole low-pass (on the A500 its
  cut-off is commonly given as roughly 4.4–4.9 kHz; on the A1200 it is far above the audible
  range) and the switchable "LED" filter, a two-pole Butterworth low-pass at roughly 3.1–3.3 kHz,
  controlled by `E0x` and the power-LED bit. These figures are widely published by Amiga audio
  emulation authors; they are not stored in the file and are optional for a player.

Mixing recipe (SwiftMOD): for each output frame, for each active voice, read
`pcm[pos] + (pcm[pos+1] − pcm[pos]) × frac` (the next sample comes from the loop start at a
segment end), multiply by `volume / 64 / 128`, add to the voice's side, then scale each side by
`1 / ceil(channels / 2)` and clamp to `−1…1`.

---

## 6. Playback semantics and de-facto behaviour

Unless stated otherwise, the behaviour below is ProTracker 2.3D's, as documented by the OpenMPT
test cases named in each entry and by the ProTracker manual.

### 6.1 Effect reference (0–F)

**`0xy` Arpeggio.** On ticks with `counter mod 3 = 0` the base period plays, `= 1` the note `x`
semitones up, `= 2` the note `y` semitones up. The shifted note is found by scanning the channel's
finetune row (37 entries) for the first entry `≤` the current period and adding the semitone count
to that index. Past B-3 the lookup reads the row's trailing `0` (period 0, effectively 65 536, i.e.
silence) and then the next row's lowest notes (OpenMPT test case *ArpWraparound*). `000` is "no
effect" and resets the output period. Note: the cycle is driven by the tick counter, which restarts
on each row and on each `EEx` repetition. FastTracker 2 and Impulse Tracker order the three notes
differently.

**`1xx` / `2xx` Portamento up / down.** On every tick after 0, subtract / add `xx` to the period;
clamp to **113** (up) / **856** (down) regardless of finetune. No memory: `100`/`200` do nothing.
(SwiftMOD widens the clamps to 28…6848 for modules with other than 4 channels.)

**`3xx` Tone portamento.** With a note on the row, the note becomes the target and the sample is
**not** retriggered. The target is found in the channel's *own* finetune row: first entry `≤` the
cell period (index 35 if none); if the finetune is negative (nibble bit 3 set) and the index is not
0, ProTracker steps one entry back. If the target equals the current period the target is cleared.
On every tick after 0 the period moves towards the target by the speed, stopping exactly on it, and
then the target is cleared — so a later `300` does not slide back (OpenMPT *PortaTarget*). A new
note without `3xx` does **not** clear the target: a later `3xx` / `5xy` without a note still slides
towards it. `xx = 0` keeps the previous speed. With glissando on, the *output* period is rounded
(§6.2 `E3x`).

**`4xy` Vibrato.** Sets the speed (`x`) and depth (`y`); a zero nibble keeps the stored value.
Applied on ticks after 0 only (§5.8).

**`5xy` Tone portamento + volume slide.** Continues `3xx` with its stored speed (the parameter is
the volume slide, as `Axy`).

**`6xy` Vibrato + volume slide.** Continues `4xy` with its stored speed and depth; the parameter is
the volume slide.

**`7xy` Tremolo.** As vibrato but modulates the output volume (§5.8).

**`8xx`.** Not a ProTracker effect: ignored. PC players (FastTracker, DMP and descendants) use it as
panning, `00` = left … `FF` = right (some use `00`–`80` and `A4` = surround). Demos sometimes use it
as a synchronisation marker.

**`9xx` Sample offset.** `xx ≠ 0` stores the offset; the effective offset is `stored × 256` bytes.
It runs on tick 0 whether or not there is a note: if the offset is less than the channel's current
length, `length -= offset` and `start += offset`; otherwise `length` becomes 1 word, so the note
plays one word and then continues with the loop (silence for a one-shot sample). On a row with a
note, ProTracker applies the offset once before triggering and once more after (OpenMPT *ptoffset*):
the note starts at `1×` offset, but the channel's start pointer is left at `2×` offset. The
adjusted start persists until a sample number reloads it, so a later note or `E9x` retrigger without
a sample number restarts from there (OpenMPT *PTOffsetRetrigger*).

**`Axy` Volume slide.** On every tick after 0: if `x > 0` add `x`, otherwise subtract `y`; clamp to
`0…64`. No memory: `A00` does nothing. When both nibbles are set, `x` wins.

**`Bxx` Position jump.** On tick 0: `songPos = xx − 1` (8-bit wrap), `breakPos = 0`, set the jump
flag. The following `nextPosition` makes the order `(xx) & 127`, wrapping to 0 if that is at or past
the song length. Channels are processed left to right, and `Bxx` clears `breakPos`, so a `Dxx` to
the **left** of a `Bxx` on the same row is cancelled while one to the **right** chooses the row in
the target order (OpenMPT *PatternJump*).

**`Cxx` Set volume.** On tick 0, volume = `min(xx, 64)`. A volume set together with a sample number
but no note is kept when a later note without a sample number triggers (OpenMPT *PTInstrVolume*).

**`Dxy` Pattern break.** On tick 0: `breakPos = x × 10 + y` (**decimal**: `D14` is row 14; digits
above 9 are not rejected, so `D1A` is row 20), `breakPos = 0` if that exceeds 63; set the jump flag.
The break does not reset `E6x` loop counters (OpenMPT *PatLoop-Break*).

**`Fxx` Speed / tempo.** On tick 0: `F00` stops the song (ProTracker; FastTracker and others ignore
it); `F01`–`F1F` set the speed (and restart the tick counter); `F20`–`FFF` set the tempo, effective
from the next tick (§5.7). If several channels set the speed on one row, the rightmost wins.

### 6.2 Extended effect reference (E0–EF)

**`E0x` Filter.** `E00` switches the Amiga LED low-pass filter on, `E01` off. Hardware only; most
software players ignore it.

**`E1x` / `E2x` Fine portamento.** On tick 0 subtract / add `x`, with the `1xx`/`2xx` clamps. No
memory. Repeats on each `EEx` repetition.

**`E3x` Glissando.** `x ≠ 0` turns glissando on for the channel. During tone portamento the output
period becomes the first entry in the channel's finetune row that is `≤` the sliding period (the
nearest semitone at or above the current pitch); the stored period keeps sliding smoothly.

**`E4x` Vibrato waveform**, **`E7x` Tremolo waveform.** §4.5.

**`E5x` Set finetune.** Sets the channel's finetune nibble. It takes effect even without a note
(OpenMPT *finetune*), changes the lookup of later notes and of the tone-portamento target, and lasts
until a sample number reloads the sample's own finetune. On a row with a note it is applied before
the note is looked up.

**`E6x` Pattern loop.** Per channel, on tick 0. `E60` stores the current row as the channel's loop
row (initially 0; not reset by a new pattern or a break). `E6x` with `x > 0`: if the channel's
counter is 0, set it to `x` and jump; otherwise decrement it and jump unless it reached 0. The jump
sets `breakPos` to the loop row and the loop-jump flag, so the next row read is the loop row in the
**same** pattern. Interlocking loops on different channels can repeat forever.

**`E8x`.** Ignored by ProTracker 2.3D playback. Some ProTracker manuals describe a destructive
"Karplus-Strong" sample filter here; some PC players use `E8x` as 16-step panning
(`0` = left … `F` = right).

**`E9x` Retrigger.** For `x ≠ 0`, restart the sample from the channel's current start pointer on
every tick where `counter mod x = 0`, except tick 0 of a row that has a note (that note has already
triggered). Without a note, tick 0 does retrigger. The counter restarts on each `EEx` repetition
(OpenMPT *PTRetrigger*). A sample number next to `E9x` without a note swaps to the new sample
immediately at the retrigger; the period is not re-looked-up, so the new finetune is not heard
(OpenMPT *InstrSwapRetrigger*).

**`EAx` / `EBx` Fine volume slide.** On tick 0 add / subtract `x`, clamp `0…64`. No memory.

**`ECx` Note cut.** On the tick where `counter = x`, volume := 0 (the sample keeps running muted).
`EC0` cuts on tick 0; `x ≥ speed` never cuts.

**`EDx` Note delay.** With a note: on tick 0 the sample number (volume, finetune, start pointer,
loop registers) is loaded and the note's period is computed into the channel, but the voice is not
triggered and the oscillators are not reset. On the tick where `counter = x` the voice is
triggered, provided the cell's note word (period plus the sample number's high nibble) is non-zero.
If `x ≥ speed` the note never triggers; the next row's tick 0 then moves the still-playing voice to
the new period without restarting it, like an instant portamento (OpenMPT *NoteDelay-NextRow*). A
new sample number on the delayed row takes effect through the loop registers when the current
sample's block ends (OpenMPT *InstrDelay*). Note delays repeat on `EEx` repetitions (OpenMPT
*PatternDelaysRetrig*).

**`EEx` Pattern delay.** On tick 0, if no delay is running, request `x + 1` plays of the row; across
channels the rightmost request wins. The row is replayed `x` more times; on the repetitions no notes
are read, but every per-tick handler runs on every tick, including tick 0 — so `E1x`, `E2x`, `EAx`,
`EBx`, `E6x`, `E9x` and `EDx` act again (OpenMPT *PatternDelaysRetrig*). The tick counter restarts
at 0 for each repetition.

**`EFx` Invert loop ("funk repeat").** `x` selects a speed from
`0, 5, 6, 7, 8, 10, 11, 13, 16, 19, 22, 26, 32, 43, 64, 128`. On every tick (from the tick-0 and
per-tick paths) the speed is added to an 8-bit accumulator; when bit 7 becomes set, the accumulator
is cleared, a pointer advances one byte through the sample's loop (wrapping from the loop end to
the loop start) and the byte there is replaced by its ones' complement. This permanently changes
the sample data for the rest of the playback. It only acts on samples with a real loop.

### 6.3 Sample numbers, notes and the Paula sample swap

- **Sample number with a note**: the sample's start/length/loop, finetune and volume are loaded,
  then the note is looked up at that finetune and triggered.
- **Note without a sample number**: the channel's current start pointer, length, finetune and
  volume are reused (including any `9xx`-adjusted start and any volume set by `Cxx`).
- **Sample number without a note** (the "sample swap"): volume and finetune are loaded and the
  volume is output immediately, but the playing voice is not restarted. The new sample's loop
  registers are written at the end of the row, so the new sample is heard only when the current
  block ends: the voice continues into the new sample's loop, or into silence if it does not loop
  (OpenMPT *PTInstrSwap*, *PortaSmpChange*). The new finetune is not audible until the next note
  (*PortaSwapPT*), except that with tone portamento the target uses it immediately.
- A voice that has already run out of a one-shot sample picks up a looped sample immediately
  (*PTStoppedSwap*); swapping to an empty slot or to a non-looping sample leads to silence at the
  block end (*PTSwapEmpty*, *PTSwapNoLoop*).

### 6.4 Loop behaviour

- `loopLength ≤ 1` word means no loop. ProTracker writes `loopStart = 0, loopLength = 1`; the 1-word
  loop runs over the zeroed first word, which is silent.
- **Loop start > 0**: the note plays `[0, loopStart + loopLength)` and then repeats the loop;
  anything after the loop end is never heard.
- **Loop start = 0**: the note plays the whole sample `[0, length)` once, then repeats
  `[0, loopLength)`.
- **Soundtracker** (15-sample files): the note plays only the loop, `[loopStart, loopStart +
  loopLength)`, repeatedly.
- **Interpolation at the loop seam**: the sample after the loop end is the loop start. Clicks at a
  seam come from the sample data, not from the format.
- A loop that extends past the sample end is common in old files (especially Soundtracker files read
  with word loop starts); clamp it (§7).

### 6.5 Song flow and song end

- Orders `0 … songLength − 1` play in sequence. Rows advance after the last tick of the row; `Bxx`,
  `Dxx`, `E6x` and `EEx` modify the next row as in §5.9.
- **Restart.** ProTracker always continues at order 0 after the last order. NoiseTracker and
  FastTracker use the restart byte as the order to continue at; a reader should use it only when it
  is `< songLength`. Soundtracker's byte at the same position is a tempo (§5.7), and ProTracker's
  `0x7F` is a placeholder.
- **Song end.** A MOD never ends on its own: the order list wraps and `Bxx` can jump backwards.
  Players decide when to stop. SwiftMOD stops when the next row to read is an order/row pair already
  played (covering the end of the order list and every `Bxx`/`Dxx` loop), except that rows replayed
  by `E6x` are allowed; `F00` stops immediately; and a maximum rendering duration bounds everything
  else, including interlocking `E6x` loops.

### 6.6 Tracker differences

| Topic | ProTracker 2.3D | Others |
|-------|-----------------|--------|
| Note range | Notes quantised to C-1…B-3 (finetuned 108…907); slides clamped 113…856 | FastTracker / OpenMPT "PC" mode: wider ranges, raw periods |
| `8xx`, `E8x` | Ignored | Panning in FastTracker, DMP, Cubic Player, OpenMPT PC mode |
| `F00` | Stops | FastTracker: ignored |
| `Fxx` ≥ `20` | Tempo (CIA) | VBlank players: speed |
| `9xx` double offset | Yes | MultimediaWiki attributes the doubling to ProTracker versions before 3.15 (uncertain); PC trackers apply it once |
| Sample swap without note | Deferred to block end | FastTracker / Impulse Tracker: new sample from the next note only |
| `Dxx` | Decimal row | NoiseTracker: reportedly always row 0; FastTracker 2 XM: decimal too, IT: hex |
| Arpeggio order | base, +x, +y by `counter mod 3` | Other trackers derive the phase differently |
| His Master's NoiseTracker (`FEST`, `M&K!`) | — | Uses a different finetune scale (OpenMPT issue 749 adjusts these finetunes on load) and a "mega arpeggio" `7xx` command |
| Soundtracker (15 samples) | — | Different command numbering (§4.6), tempo byte (§5.7), loop start in bytes, loop-only playback |

---

## 7. Robustness guidance for readers

Every field is untrusted. Recommended handling:

| Field / situation | Handling |
|-------------------|----------|
| File shorter than the header | Reject (truncated header). |
| Unknown tag | Do not assume 31 samples / 4 channels; try the 15-sample validator (§5.3), otherwise reject as unrecognised. |
| Tag with non-printable bytes | Never a 31-sample tag. |
| Channel count | Bound it (SwiftMOD: 1…32); reject other `nnCH` values. |
| `songLength` 0 or > 128 | Reject. |
| Order entries | Any byte value; validate against the stored pattern count before indexing. Entries past `songLength` may be garbage. |
| Pattern count | Compute both maxima (§5.2) and choose by file size; check `headerSize + count × patternBytes ≤ fileSize` with overflow-safe arithmetic. |
| Pattern data cut short | Reject (truncated patterns). |
| Sample bodies cut short | Common in archives: keep the bytes present, shorten the sample, flag the file as truncated. |
| Extra bytes after the samples | Ignore. |
| Sample length | `u16` words; byte length fits comfortably in 32 bits. |
| Volume > 64 | Clamp to 64. |
| Finetune high nibble | Ignore it. |
| Loop start ≥ sample length | Disable the loop. |
| Loop end > sample length | Clamp the loop length to the sample end. |
| Loop length 0 or 1 word | No loop. |
| Sample number > slot count | Treat as "no sample". |
| Period 0 | No note; on output, a period of 0 must not divide by zero (treat as 65 536 or silence). |
| Arpeggio / table reads past the table | Return 0 (silence), never index out of bounds. |
| Infinite playback (`Bxx`/`Dxx` loops, interlocking `E6x`) | Detect revisited order/row pairs, and cap total duration. |
| `EFx` | Rewrites sample data: operate on a private copy. |
| Huge output rates / tempos | Bound frames-per-tick arithmetic (SwiftMOD requires an output rate of 1 Hz…1 MHz). |

---

## 8. Errata

### 8.1 Corrections to earlier editions of this document

| # | Earlier statement | Correction | Evidence |
|--:|-------------------|------------|----------|
| 1 | Octaves 2 and 3 of each finetune row "follow by halving" octave 1 | The table is a set of constants with irregular entries (e.g. ft 0 B-2 = 226, not 227) | ProTracker period table (§5.4) |
| 2 | Finetune −7 F-1/F#-1 = 674/637; finetune −4 A#-1 = 495 | 675/636 and 494 | ProTracker period table |
| 3 | NTSC clock 1 789 772.5 Hz | 3 579 545.25 Hz (half the 7.159 MHz NTSC system clock) | Amiga Hardware Reference Manual |
| 4 | Vibrato position advances on every tick, including tick 0 | Neither applied nor advanced on tick 0 | OpenMPT *VibratoReset* |
| 5 | `8xx` is a ProTracker panning extension | ProTracker ignores `8xx` | ProTracker manual; OpenMPT PC/Amiga mode distinction |
| 6 | `E8x` is coarse panning | Not a ProTracker playback effect | ProTracker 2.3D behaviour |
| 7 | `Axy`: "`A00` continues the previous slide in some implementations" | ProTracker has no volume-slide memory | ProTracker 2.3D behaviour |
| 8 | B/D on one row: processing order "implementation-defined" | Left to right; `Bxx` cancels a `Dxx` to its left | OpenMPT *PatternJump* |
| 9 | FLT8: the order list stores the pair index; pattern count = (max used + 1) × 2 | Orders store the even first-of-pair number; halve them | StarTrekker behaviour; §3.6 |
| 10 | Stored pattern count = highest *used* order + 1 | ProTracker counts all 128 entries; fall back only when the file size disagrees | §5.2 |
| 11 | `E4x` waveform 3 is random | ProTracker plays a square wave | ProTracker 2.3D behaviour |
| 12 | Paula volume register is 6 bits | It holds 0…64 (7 bits) | Amiga Hardware Reference Manual |
| 13 | `E0x` toggles a "~4 kHz" filter | The LED filter is a 2-pole Butterworth at roughly 3.1–3.3 kHz; the fixed A500 filter (~4.4–4.9 kHz) is separate and not switchable | §5.10 |
| 14 | Periods above 1023 are illegal; "FastTracker raised it to 1712" | MOD has a 12-bit period field (0…4095); FastTracker-era MODs use periods such as 1712 (octave 0) | §3.5, §5.5 |
| 15 | A 5-byte `M.K.!` signature "overruns into the song-length byte" | Impossible: the song length is at 950, before the tag at 1080; no such variant is documented | §3.2 |
| 16 | ProTracker writes `0x7F` and uses it as the restart position | ProTracker writes `0x7F` and ignores it; NoiseTracker and FastTracker use it as a restart position; Soundtracker stores a tempo there | MultimediaWiki *Protracker Module*; Fraggie's version history |
| 17 | `M!K!` allows pattern indices up to 255, others up to 127 | `M!K!` only signals more than 64 stored patterns; orders are bytes in every variant and must be checked against the stored pattern count | MultimediaWiki *Protracker Module* |
| 18 | 15-sample files use "a 12-bit (not 16-bit) period encoding" | The cell encoding is identical to the 31-sample layout | §3.4 |
| 19 | Soundtracker loop start is in bytes only when the word reading overruns the sample | All Soundtracker versions store the loop start in bytes, and play only the loop | Fraggie's SoundTracker version history |
| 20 | ProTracker `8xx`/`E8x` can override the LRRL panning | Neither does anything in ProTracker | §6.1 |
| 21 | Period range 113–856 is the full note range | Finetuned notes span 108–907; only the slides clamp to 113–856 | §5.4 |
| 22 | 15-sample cells "use the same effects" | Soundtracker versions number effects differently | §4.6 |
| 23 | NTSC playback is "~0.4% faster" | 3 579 545.25 / 3 546 894.6 ≈ 1.0092: about 0.9% higher | §5.6 |
| 24 | Reference list attributed `MOD-FORM.TXT` to "Brad Watkins / Steinberg" and `MODFIL10.TXT` to FireLight | Those attributions could not be confirmed; the reference list now names only sources that were consulted | §10 |

### 8.2 Errors in other circulating documents

| Document | Statement | Correction |
|----------|-----------|------------|
| MultimediaWiki, *Protracker Module* (2010 revision) | `9CHN` is 8 channels | 9 channels, like every `nCHN` tag |
| MultimediaWiki, *Protracker Module* | The Amiga filter is "a 1-pole low-pass at about 11 500 Hz" (flagged there as a rough estimate) | The switchable LED filter is a 2-pole low-pass near 3.1–3.3 kHz |
| MultimediaWiki, *Protracker Module* | `xxCH` channel counts are even | FastTracker writes even counts, but odd counts occur and play fine |
| Various early text files | `Dxy` is a hexadecimal row | ProTracker uses `x × 10 + y` |
| Various early text files | Period tables generated by halving the octave above | Use the ProTracker constants (§5.4) |
| Various early text files | Loop length 0 is the "no loop" value | ProTracker writes 1; both 0 and 1 mean no loop |
| Various player descriptions | `E9x` retriggers on tick 0 | Not on tick 0 of a row with a note (OpenMPT *PTRetrigger*) |

---

## 9. Implementation status (SwiftMOD)

| Feature | Section | Status |
|---------|---------|--------|
| 31-sample header, sample headers, order table | §3.2–3.3 | Supported |
| 15-sample Soundtracker layout, validated detection | §3.4, §5.3 | Supported |
| Soundtracker loop start in bytes; loop-only playback | §3.4, §6.4 | Supported |
| Soundtracker effect numbering (§4.6) and tempo byte (§5.7) | §4.6, §5.7 | Unsupported — 15-sample modules play with ProTracker effects at 125 BPM |
| Tags `M.K.` `M!K!` `M&K!` `FEST` `N.T.` `FLT4` `EXO4` | §4.1 | Supported (4 channels) |
| His Master's NoiseTracker finetune scale and `7xx` mega arpeggio | §6.6 | Unsupported — finetune read as a standard nibble, `7xx` played as tremolo |
| `FLT8` paired patterns | §3.6 | Supported |
| `1CHN`–`9CHN`, `01CH`–`32CH`, `01CN`–`32CN`, `TDZ1`–`TDZ3`, `OCTA` `OKTA` `CD61` `CD81` `EXO8` | §4.1 | Supported |
| Channel counts 33–99 (`33CH`…`99CH`) | §4.1 | Unsupported — rejected as unrecognised |
| `FA04` / `FA06` / `FA08` | §4.1 | Partial — standard layout assumed |
| Other one-off tags (`NSMS`, `LARD`, …), `.wow` 8-channel `M.K.` | §4.1 | Unsupported |
| Pattern count from all 128 orders with size fallback | §5.2 | Supported |
| Lenient truncated sample bodies; loop clamping | §7 | Supported (`MODFile.isTruncated`) |
| ProTracker period table, note quantisation, finetune rows | §5.4–5.5 | Supported |
| Multichannel raw periods and wide slide range | §5.5 | Supported (non-4-channel modules) |
| Speed / CIA tempo, `F00` stop, tempo after current tick | §5.7 | Supported — tick length is `2.5 / BPM` s exactly, not the integer CIA divisor (< 0.01% difference) |
| VBlank timing mode | §5.7 | Unsupported |
| Every `0`–`F` effect and quirk in §6.1 | §6.1 | Supported; `8xx` ignored (as ProTracker) |
| Every `E0`–`EF` sub-command and quirk in §6.2 | §6.2 | Supported; `E0x` and `E8x` ignored |
| Sample swap, swap after stop, delayed-note loading | §6.3 | Supported |
| Loop rules (loop start 0 vs > 0) | §6.4 | Supported |
| Restart byte | §6.5 | Used only with `MODMixer.Options.loopSong`, when `< songLength` |
| Song-end detection and duration cap | §6.5 | Supported |
| Paula output: LRRL hard panning, PAL clock, linear interpolation | §5.10 | Supported |
| NTSC clock, BLEP synthesis, A500/A1200 and LED filters, stereo separation control | §5.10 | Unsupported |

---

## 10. References and provenance

1. **ProTracker 2.x user manual** — Lars Hamre and the Amiga Freelancers (later revisions by others).
   Effect catalogue, period table, sample header fields.
2. **OpenMPT wiki, *Development: Test Cases/MOD*** — the OpenMPT developers (Johannes Schultz et
   al.). https://wiki.openmpt.org/Development:_Test_Cases/MOD — prose descriptions of ProTracker
   behaviour (test cases cited by name throughout). CC BY-SA.
3. **OpenMPT wiki, *Manual: Module formats*** — https://wiki.openmpt.org/Manual:_Module_formats —
   sample size limit, Amiga/PC MOD modes, quirk guessing.
4. **"SoundTracker version history"** — Fraggie, posted on the un4seen forums, mirrored at
   https://resources.openmpt.org/documents/soundtracker_versions.html — Soundtracker effect sets,
   tempo byte and conversion formula, loop start in bytes, loop-only playback, sample size limits.
5. **MultimediaWiki, *Protracker Module*** — https://wiki.multimedia.cx/index.php/Protracker_Module —
   signature list, restart-byte usage by tracker, `M!K!` meaning.
6. **OpenMPT issue 749** — https://bugs.openmpt.org/view.php?id=749 — discussion of `FEST` / `M&K!`
   (His Master's NoiseTracker) finetune and `7xx` (prose only).
7. **Modland format notes** — https://modland.com/ — His Master's Noise / `FEST` provenance,
   variant tags.
8. **Amiga Hardware Reference Manual**, 3rd edition — Commodore-Amiga, Inc. (Addison-Wesley, 1991,
   ISBN 0-201-56776-8). Paula registers, clock constants, minimum DMA period.
9. **"Noisetracker/Soundtracker/Protracker Module Format"** — Andrew Scott,
   https://www.aes.id.au/modformat.html — byte layout.
10. **MOD-FORM.TXT** — "Thunder", early 1990s, widely mirrored — byte layout and effect summary.
11. **PRONOM `fmt/716`** — The National Archives (UK) — signature registration.
12. **Wikipedia, *MOD (file format)*** — historical context only.

**Provenance.** This document was written from the public documents listed above and from
black-box observation of playback behaviour as described in the OpenMPT test-case pages. No
third-party source code (ProTracker replay routines, libxmp, OpenMPT, MikMod, Schism Tracker,
pt2-clone) was copied or consulted while writing it. Tables of numbers (period table, oscillator
and funk tables) are facts reproduced for interoperability. All prose is original; short quotations
are attributed.
