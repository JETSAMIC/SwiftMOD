# The MOD File Format

A byte-level reference for the Amiga `.mod` module format and its multichannel descendants, written to be useful both as the SwiftMOD implementation spec and as a standalone document for anyone reading or writing MOD files.

This is a **clean-room** reference. It cites only public-domain or freely-available specifications (the ProTracker user manual, the FireLight `MODFIL10.TXT` technote, the Commodore Amiga Hardware Reference Manual, the OpenMPT wiki's prose pages). No LGPL/GPL source code — libxmp, OpenMPT's `Load_mod.cpp`, MikMod, Schism Tracker — was consulted in writing it. Where the public specs disagree or are silent, the document calls that out explicitly under [Known quirks](#known-quirks-and-ambiguities).

---

## Contents

- [Heritage and lineage](#heritage-and-lineage)
- [File layout overview](#file-layout-overview)
- [The 1084-byte header (31-sample variants)](#the-1084-byte-header-31-sample-variants)
  - [Song name](#song-name)
  - [Sample headers](#sample-headers)
  - [Song length and restart byte](#song-length-and-restart-byte)
  - [Pattern order table](#pattern-order-table)
  - [Format signature](#format-signature)
- [The 600-byte header (15-sample Ultimate Soundtracker variant)](#the-600-byte-header-15-sample-ultimate-soundtracker-variant)
- [Format signature dispatch](#format-signature-dispatch)
- [Pattern data](#pattern-data)
  - [Cell encoding](#cell-encoding)
  - [Decoding examples](#decoding-examples)
  - [StarTrekker FLT8 paired patterns](#startrekker-flt8-paired-patterns)
- [Sample bodies](#sample-bodies)
- [The Amiga period table](#the-amiga-period-table)
  - [Finetune adjustment](#finetune-adjustment)
  - [Period to frequency](#period-to-frequency)
- [Effect command reference](#effect-command-reference)
  - [Primary commands 0..F](#primary-commands-0f)
  - [Extended commands E0..EF](#extended-commands-e0ef)
- [Paula chip behavior](#paula-chip-behavior)
- [Timing model](#timing-model)
- [ProTracker playback semantics](#protracker-playback-semantics)
- [Known quirks and ambiguities](#known-quirks-and-ambiguities)
- [References](#references)

---

## Heritage and lineage

The `.mod` format is the original multichannel tracker module. It dates to Karsten Obarski's *Ultimate Soundtracker* (Commodore Amiga, 1987), which introduced the foundational layout: a fixed sample table, a row-and-channel pattern grid, an order list addressing those patterns, and 8-bit signed PCM samples played through the Amiga's Paula custom audio chip. The early format used a 15-entry sample table and **no signature bytes** — the file format was implied by the `.mod` extension and the tracker that wrote it.

NoiseTracker (Mahoney & Kaktus / TJC, 1989) extended the sample table to 31 entries and added the `M.K.` signature at file offset 1080 to distinguish the new layout from the original. ProTracker (Lars Hamre and the Amiga Freelancers, starting 1990) inherited the NoiseTracker layout, finalized the effect command set still in use today, and added the `M!K!` signature for files with more than 64 patterns. A wave of late-Amiga and early-PC trackers (StarTrekker, TakeTracker, FastTracker, Oktalyzer, the DigitalSound family) added multichannel variants — 6, 8, up to 32 channels — distinguished only by which 4-byte signature appears at offset 1080.

Every other module format in this family tree (`.s3m`, `.xm`, `.it`) is conceptually downstream. The Amiga period table, the `0..F` effect numbering, the row × channel cell grid, and the speed/tempo timing model all originate in `.mod`.

## File layout overview

A 31-sample MOD file is a fixed-layout binary container, not a chunked one. There are no parapointers, no offsets, no length prefixes. Every byte position is computed from the file's signature (which determines channel count) and the order list (which determines how many patterns are present).

```
+-------------------------------+
| 1084-byte header              |
|   20 bytes  song name         |
|  930 bytes  31 sample headers |
|    1 byte   song length       |
|    1 byte   restart byte      |
|  128 bytes  order table       |
|    4 bytes  format signature  |
+-------------------------------+
| Pattern data                  |
|   numPatterns × channels × 64 |
|   × 4 bytes                   |
+-------------------------------+
| Sample bodies                 |
|   samples[1].lengthBytes      |
|   samples[2].lengthBytes      |
|   ...                         |
|   samples[31].lengthBytes     |
+-------------------------------+
```

The 15-sample (signature-less) variant has the same shape but with a 600-byte header (only 15 sample slots) and pattern data that uses 4 channels and a 12-bit (not 16-bit) period encoding identical to the modern layout.

The total file size is fully determined:

```
fileSize = headerBytes
         + numPatterns × channels × 64 × 4
         + Σ samples[i].lengthBytes
```

ProTracker writes `numPatterns = max(orderTable[0..<128]) + 1` — the maximum over **all 128** order entries, including unused ones past `songLength`. Some other tools wrote garbage (e.g. `0xFF`) into the unused entries, so a robust parser uses the all-entries count when the file is large enough to hold that many patterns plus the sample bodies, and falls back to `max(orderTable[0..<songLength]) + 1` otherwise. (SwiftMOD does exactly this.)

## The 1084-byte header (31-sample variants)

### Song name

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x000` | 20 | Song name |

ASCII, NUL-padded. Track names can be empty (all zero bytes). High-ASCII bytes appear in older Amiga modules (Latin-1 or Amiga character set) — readers should pass the bytes through unchanged and let the consumer decide on charset.

### Sample headers

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x014` | 930 | 31 sample headers × 30 bytes each |

Each 30-byte sample header has this layout:

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| `0x00` | 22 | Sample name | ASCII, NUL-padded |
| `0x16` | 2  | Sample length in **words** | Big-endian. Multiply by 2 for the byte length. |
| `0x18` | 1  | Finetune | Low 4 bits, signed `-8..+7` (see [Finetune adjustment](#finetune-adjustment)) |
| `0x19` | 1  | Default volume | `0..64` |
| `0x1A` | 2  | Loop start in words | Big-endian. Multiply by 2 for byte offset. |
| `0x1C` | 2  | Loop length in words | Big-endian. **A length of 1 (= 2 bytes) or 0 means "no loop."** |

Important details:

- **All multi-byte sample-header fields are big-endian.** This is the only big-endian region of the file (pattern cell bytes are positional, not multi-byte integers, and the period and parameter fields don't cross byte boundaries in a way that depends on endianness). The Amiga is big-endian; pattern data was authored to be word-aligned for hardware reasons but is read byte-by-byte by the player.
- **Sample length is in words, not bytes.** Multiply by 2. The maximum representable length is `0xFFFF × 2 = 131_070` bytes, which is the Amiga `.mod` per-sample limit. Files that need longer samples per slot use other formats (`.xm`, `.it`).
- **Sample numbers are 1-based.** There is no sample 0 slot: pattern cells reference sample headers 1..31, and a cell with sample number 0 means "no new sample, keep the channel's current one." A header with length 0 is an empty slot and contributes no bytes to the sample bodies section.
- **Loop length ≤ 1 disables looping.** ProTracker conventionally writes loop-start=0, loop-length=1 (= 2 bytes) for non-looping samples, because the Amiga Paula hardware always loops — the player just sets the loop to point at two zero bytes after the sample data. Some authoring tools write loop-length=0 instead. Both must be treated as "no loop" by a software player.
- **Loop bounds are in words.** Multiply by 2 to get byte offsets into the sample body.
- **Finetune is a 4-bit signed nibble** with the encoding:

| Stored byte (low 4 bits) | Signed value |
|-------------------------:|:------------:|
| `0x0` | `0`  |
| `0x1` | `+1` |
| `0x2` | `+2` |
| `0x3` | `+3` |
| `0x4` | `+4` |
| `0x5` | `+5` |
| `0x6` | `+6` |
| `0x7` | `+7` |
| `0x8` | `-8` |
| `0x9` | `-7` |
| `0xA` | `-6` |
| `0xB` | `-5` |
| `0xC` | `-4` |
| `0xD` | `-3` |
| `0xE` | `-2` |
| `0xF` | `-1` |

This is two's-complement nibble arithmetic: `if value >= 8 then value -= 16`.

### Song length and restart byte

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x3B6` | 1 | Song length |
| `0x3B7` | 1 | Restart byte / CIAA timer |

- **Song length** (`0x3B6`) is the number of used order positions, `1..128`. A value of 0 or above 128 is invalid (SwiftMOD throws `invalidSongLength`). Order entries past `songLength` are never played, but see [File layout overview](#file-layout-overview) for their effect on the stored pattern count.
- **Restart byte** (`0x3B7`) was the CIAA (Complex Interface Adapter A) timer value on the Amiga, used by NoiseTracker for tempo. ProTracker hard-coded it to `0x7F` (127) and used it as the restart position when the song looped. Modern players ignore it for playback timing (effect `Fxx` is authoritative) but may use it as the loop-back order position when the order list is exhausted. A robust reader treats `restart >= songLength` as "restart at 0."

### Pattern order table

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x3B8` | 128 | Pattern order table |

128 bytes, one byte per slot. Each byte is the index of a pattern to play. The number of patterns actually stored in the file is `max(orderTable[0..<songLength]) + 1`, **not** `songLength` — the same pattern can be referenced many times across the order list, and patterns are stored once.

For the `M!K!` signature, valid pattern indices go up to 255. For all other 31-sample variants the upper bound is 127 (effectively — older trackers tolerated up to 99). The `M!K!` extension exists specifically because the order byte is unsigned 8-bit and someone wanted more than 64 patterns without breaking the byte width.

### Format signature

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x438` | 4 | Format signature |

A 4-byte ASCII signature identifying the variant. See [Format signature dispatch](#format-signature-dispatch) for the full table.

## The 600-byte header (15-sample Ultimate Soundtracker variant)

The pre-`M.K.` Ultimate Soundtracker / Soundtracker layout has only 15 sample slots:

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x000` | 20  | Song name |
| `0x014` | 450 | 15 sample headers × 30 bytes |
| `0x1D6` | 1   | Song length |
| `0x1D7` | 1   | Restart byte |
| `0x1D8` | 128 | Order table |
| total   | 600 | (no signature) |

Pattern data starts immediately at offset 600. Channel count is always 4. Per-cell encoding is the same as the modern format.

**Detection:** if the bytes at offset 1080 do not match any known signature, attempt a 15-sample parse, but only accept it after validation — otherwise any random file would "parse". SwiftMOD requires: song length `1..128`; all 128 order entries `< 128`; every sample length `≤ 32768` words and volume `≤ 64`; the pattern data to fit in the file; every pattern cell to reference sample `0..15` (high sample nibble zero) with period `0` or `100..1000`; and the file not to be more than 4 KiB longer than header + patterns + sample bodies.

Older versions of the format had quirks around finetune (the byte at sample-header offset `0x18` was not a finetune nibble in pre-NoiseTracker layouts) — readers treat finetune as zero. Ultimate Soundtracker also stored the **loop start in bytes** rather than words: when `loopStart×2 + loopLength×2` overruns the sample but `loopStart + loopLength×2` does not, the stored value is a byte offset.

## Format signature dispatch

The 4-byte signature at offset 1080 determines channel count and (for `M!K!`) the maximum pattern index:

| Signature | Channels | Max pattern index | Notes |
|-----------|---------:|------------------:|-------|
| `M.K.`    | 4   | 127 | NoiseTracker / ProTracker canonical |
| `M!K!`    | 4   | 255 | ProTracker, extended pattern table |
| `M&K!`    | 4   | 127 | NoiseTracker variant (very rare) |
| `N.T.`    | 4   | 127 | NoiseTracker original |
| `FLT4`    | 4   | 127 | StarTrekker 4-channel |
| `FLT8`    | 8   | 127 | StarTrekker 8-channel ([paired patterns](#startrekker-flt8-paired-patterns)) |
| `EXO4`    | 4   | 127 | StarTrekker EXO variant |
| `EXO8`    | 8   | 127 | StarTrekker EXO variant |
| `xCHN`    | `x` decimal, 1..9 | 127 | FastTracker / TakeTracker (`2CHN`, `6CHN`, `8CHN` are the common ones) |
| `xxCH`    | `xx` decimal, 01..32 | 127 | Generalized TakeTracker / FastTracker (e.g. `10CH`, `16CH`, `32CH`) |
| `xxCN`    | `xx` decimal, 01..32 | 127 | Generalized variant (less common) |
| `OCTA`    | 8   | 127 | Oktalyzer 8-channel |
| `OKTA`    | 8   | 127 | Oktalyzer alternative tag |
| `CD61`    | 6   | 127 | Falcon CD61 player |
| `CD81`    | 8   | 127 | Falcon CD81 player |
| `FA04`    | 4   | 127 | Digital Tracker (Atari Falcon) 4-channel |
| `FA06`    | 6   | 127 | Digital Tracker 6-channel |
| `FA08`    | 8   | 127 | Digital Tracker 8-channel |
| `TDZ1`..`TDZ3` | 1..3 | 127 | TakeTracker low-channel |
| (anything else / absent) | 4 | 63 | 15-sample variant, attempt fallback parse |

The general pattern for `xxCH` / `xxCN`: take the first two bytes as ASCII digits, parse as a decimal integer, that's the channel count. So `16CH` → 16 channels, `32CH` → 32 channels. Defensive: accept only `01..32` and the exact forms `[0-9][0-9]CH` / `[0-9][0-9]CN`; likewise `[1-9]CHN`.

Note: some sources state that Digital Tracker `FA0x` files carry extra bytes after the signature. This document and SwiftMOD assume the standard layout; that detail is unverified.

## Pattern data

After the header, pattern data is laid down sequentially: pattern 0, pattern 1, ..., pattern N. Each pattern is exactly `channels × 64 × 4` bytes (64 rows × `channels` channels × 4 bytes per cell). Patterns are stored in **row-major** order: row 0's cells for channels 0, 1, 2, …, then row 1's cells, and so on.

### Cell encoding

Each 4-byte cell packs four fields:

```
byte 0: ssss pppp
byte 1: pppp pppp
byte 2: ssss eeee
byte 3: pppp pppp

period    = ((byte0 & 0x0F) << 8) | byte1           // 12 bits
sample    = (byte0 & 0xF0)        | (byte2 >> 4)    //  8 bits
effect    = byte2 & 0x0F                            //  4 bits
parameter = byte3                                   //  8 bits
```

Where:

- **`period`** is a 12-bit Amiga period value. `0` means "no note this cell." See [The Amiga period table](#the-amiga-period-table) for the legal values and their note-to-period mapping.
- **`sample`** is a 1-based sample index (1..31). `0` means "no new sample — continue with the previous sample on this channel." Indices > 31 are treated as 0.
- **`effect`** is the primary effect command nibble. See [Primary commands 0..F](#primary-commands-0f).
- **`parameter`** is the effect parameter byte. For most commands, the upper and lower nibbles encode two separate values (e.g. for `0xy` arpeggio, `x` and `y` are independent semitone offsets).

A common encoding gotcha: a cell can have a non-zero effect and parameter but a period of zero and a sample of zero. That's how MOD encodes effects that don't retrigger the sample — volume slides, position jumps, set-volume on the currently-playing note, etc. Conversely, a cell with a period and no effect is a "plain note trigger." The four fields are independent.

### Decoding examples

```
Cell bytes:    0x14  0x37  0x10  0x00
byte0 = 0001 0100 → sampleHi = 0001, periodHi = 0100  (= 0x04)
byte1 = 0011 0111 → periodLo = 0x37
byte2 = 0001 0000 → sampleLo = 0001, effect = 0x0
byte3 = 0000 0000 → parameter = 0x00

period    = (0x04 << 8) | 0x37 = 0x0437 = 1079
sample    = (0x10)      | 0x01 = 0x11   = 17
effect    = 0x0
parameter = 0x00

# Plays sample 17 at period 1079 — lower than C-1 (856); ProTracker quantises it to C-1, while PC trackers treat it as roughly A#-0.
```

```
Cell bytes:    0x00  0x00  0x0C  0x20
byte0 = 0x00      → sampleHi = 0,    periodHi = 0
byte1 = 0x00      → periodLo = 0
byte2 = 0x00 0xC  → sampleLo = 0,    effect = 0xC
byte3 = 0x20      → parameter = 0x20

period    = 0
sample    = 0
effect    = 0xC  (set volume)
parameter = 0x20 (= 32)

# Sets the channel's volume to 32 without retriggering the sample.
```

### StarTrekker FLT8 paired patterns

The StarTrekker `FLT8` 8-channel variant is the one place where pattern storage deviates from the formula above. `FLT8` files store **two 4-channel patterns** that together represent one 8-channel pattern: stored pattern `2n` holds channels 0..3 and stored pattern `2n+1` holds channels 4..7. StarTrekker writes **even** values into the order list (the index of the first stored pattern of the pair), so a reader divides each order entry by 2 to get the 8-channel pattern number `n`.

The number of stored 4-channel patterns is `(max(orderTable / 2) + 1) × 2` (each pair is 2048 bytes).

All other 8-channel variants (`8CHN`, `OCTA`, `CD81`, `FA08`) store all 8 channels in a single pattern with the natural `channels × 64 × 4` layout.

## Sample bodies

After the last pattern, the raw 8-bit signed PCM sample bodies are concatenated in sample-index order:

```
sample[1].bytes (sample[1].lengthBytes bytes)
sample[2].bytes (sample[2].lengthBytes bytes)
...
sample[31].bytes (sample[31].lengthBytes bytes)
```

There is no separator and no length prefix in this section — the sample lengths come from the sample headers. A sample with `length == 0` contributes zero bytes.

Each byte is **signed 8-bit PCM** in the range `-128..127`. The Amiga Paula chip plays the bytes back at a sample rate derived from the current period (see [Paula chip behavior](#paula-chip-behavior)).

Looping samples: if `loopLength > 1` word (i.e. > 2 bytes), the loop region is `[loopStart, loopStart + loopLength)` in byte offsets (after multiplying both fields by 2). How ProTracker starts a looped sample depends on the loop start:

- **Loop start > 0:** the note plays `[0, loopStart + loopLength)` — anything after the loop end is never heard — then repeats the loop.
- **Loop start = 0:** the note plays the **whole sample** `[0, length)` once, then repeats `[0, loopLength)`.

Loop bounds come from an untrusted file: a reader must clamp `loopStart + loopLength` to the sample length and disable the loop if `loopStart` is at or past the end.

## The Amiga period table

The Amiga `.mod` format predates equal-temperament frequency tables; it uses **periods**, which are the divisor values written to the Paula chip's per-channel period register. A higher period = lower frequency.

The canonical ProTracker period table covers three octaves × 12 semitones = 36 notes:

### Standard (finetune 0)

| Note | Octave 1 | Octave 2 | Octave 3 |
|------|---------:|---------:|---------:|
| C    | 856 | 428 | 214 |
| C#   | 808 | 404 | 202 |
| D    | 762 | 381 | 190 |
| D#   | 720 | 360 | 180 |
| E    | 678 | 339 | 170 |
| F    | 640 | 320 | 160 |
| F#   | 604 | 302 | 151 |
| G    | 570 | 285 | 143 |
| G#   | 538 | 269 | 135 |
| A    | 508 | 254 | 127 |
| A#   | 480 | 240 | 120 |
| B    | 453 | 226 | 113 |

Octaves are **not** exact halvings: B-2 is 226 although 453 / 2 rounds to 227, and several finetuned rows differ the same way. Players must use the published table, not compute it. The ProTracker range for finetune 0 is **113 (B-3) to 856 (C-1)**; the slide clamps (`1xx`/`2xx`/`E1x`/`E2x`) use exactly these two values regardless of finetune.

### Finetune adjustment

Each sample carries a **finetune** value in `-8..+7` eighths of a semitone, which selects one of 16 period rows (each note is C, C#, D, D#, E, F, F#, G, G#, A, A#, B). The full ProTracker table:

```
finetune  0:  oct 1  856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453
               oct 2  428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226
               oct 3  214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113
finetune +1:  oct 1  850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477, 450
               oct 2  425, 401, 379, 357, 337, 318, 300, 284, 268, 253, 239, 225
               oct 3  213, 201, 189, 179, 169, 159, 150, 142, 134, 126, 119, 113
finetune +2:  oct 1  844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, 447
               oct 2  422, 398, 376, 355, 335, 316, 298, 282, 266, 251, 237, 224
               oct 3  211, 199, 188, 177, 167, 158, 149, 141, 133, 125, 118, 112
finetune +3:  oct 1  838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470, 444
               oct 2  419, 395, 373, 352, 332, 314, 296, 280, 264, 249, 235, 222
               oct 3  209, 198, 187, 176, 166, 157, 148, 140, 132, 125, 118, 111
finetune +4:  oct 1  832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467, 441
               oct 2  416, 392, 370, 350, 330, 312, 294, 278, 262, 247, 233, 220
               oct 3  208, 196, 185, 175, 165, 156, 147, 139, 131, 124, 117, 110
finetune +5:  oct 1  826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, 437
               oct 2  413, 390, 368, 347, 328, 309, 292, 276, 260, 245, 232, 219
               oct 3  206, 195, 184, 174, 164, 155, 146, 138, 130, 123, 116, 109
finetune +6:  oct 1  820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460, 434
               oct 2  410, 387, 365, 345, 325, 307, 290, 274, 258, 244, 230, 217
               oct 3  205, 193, 183, 172, 163, 154, 145, 137, 129, 122, 115, 109
finetune +7:  oct 1  814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, 431
               oct 2  407, 384, 363, 342, 323, 305, 288, 272, 256, 242, 228, 216
               oct 3  204, 192, 181, 171, 161, 152, 144, 136, 128, 121, 114, 108
finetune -8:  oct 1  907, 856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480
               oct 2  453, 428, 404, 381, 360, 340, 320, 302, 285, 269, 254, 240
               oct 3  226, 214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120
finetune -7:  oct 1  900, 850, 802, 757, 715, 675, 636, 601, 567, 535, 505, 477
               oct 2  450, 425, 401, 379, 357, 337, 318, 300, 284, 268, 253, 238
               oct 3  225, 212, 200, 189, 179, 169, 159, 150, 142, 134, 126, 119
finetune -6:  oct 1  894, 844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474
               oct 2  447, 422, 398, 376, 355, 335, 316, 298, 282, 266, 251, 237
               oct 3  223, 211, 199, 188, 177, 167, 158, 149, 141, 133, 125, 118
finetune -5:  oct 1  887, 838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470
               oct 2  444, 419, 395, 373, 352, 332, 314, 296, 280, 264, 249, 235
               oct 3  222, 209, 198, 187, 176, 166, 157, 148, 140, 132, 125, 118
finetune -4:  oct 1  881, 832, 785, 741, 699, 660, 623, 588, 555, 524, 494, 467
               oct 2  441, 416, 392, 370, 350, 330, 312, 294, 278, 262, 247, 233
               oct 3  220, 208, 196, 185, 175, 165, 156, 147, 139, 131, 123, 117
finetune -3:  oct 1  875, 826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463
               oct 2  437, 413, 390, 368, 347, 328, 309, 292, 276, 260, 245, 232
               oct 3  219, 206, 195, 184, 174, 164, 155, 146, 138, 130, 123, 116
finetune -2:  oct 1  868, 820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460
               oct 2  434, 410, 387, 365, 345, 325, 307, 290, 274, 258, 244, 230
               oct 3  217, 205, 193, 183, 172, 163, 154, 145, 137, 129, 122, 115
finetune -1:  oct 1  862, 814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457
               oct 2  431, 407, 384, 363, 342, 323, 305, 288, 272, 256, 242, 228
               oct 3  216, 203, 192, 181, 171, 161, 152, 144, 136, 128, 121, 114
```

Irregular entries worth testing against: finetune 0 B-2 = 226; finetune -8 F-2 = 340; finetune -7 F-1 = 675, F#-1 = 636; finetune -4 A#-1 = 494.

In memory ProTracker stores the rows in finetune-nibble order (`0..+7`, then `-8..-1`), each **37** entries long: the 36 notes followed by a `0`. Arpeggio and glissando search within a row; arpeggio past B-3 reads that trailing `0` (an effectively silent period) and then the following row.

**Note lookup.** A cell's period is not used directly. ProTracker scans the finetune-0 row for the first entry `≤` the cell period (so 1079 becomes C-1, and periods below the table resolve to the trailing `0`), then reads the same note index from the channel's finetune row.

### Period to frequency

The playback sample rate for a given period is:

```
sampleRate = paulaClockHz / period
```

Where `paulaClockHz` is:

- **PAL**: `3_546_894.6` Hz (canonical: 7_093_789.2 / 2)
- **NTSC**: `3_579_545.25` Hz (canonical: 7_159_090.5 / 2; rarely relevant — most modules are PAL-authored)

Most software MOD players use the PAL clock unconditionally. The NTSC clock produces slightly higher playback frequencies (~0.4% faster) and is only relevant for NTSC-Amiga-authored modules, which are rare.

Conversion from playback sample rate to the host audio device's sample rate is a per-sample-step: `step = paulaClockHz / (period * hostSampleRate)`. The mixer accumulates this step into a fractional sample-position pointer and reads from the sample body with linear (or higher-order) interpolation.

## Effect command reference

Effects are encoded in the pattern cell as a 4-bit command (`effect`) plus an 8-bit parameter (`parameter`). The parameter is conventionally written `XY` for "upper nibble X, lower nibble Y" — many effects use the two nibbles independently. Effects evaluate **once per tick**, with most behaviors split into "fire on tick 0" (initial trigger / set) and "fire on every tick after 0" (continuous).

### Primary commands 0..F

| Cmd | Mnemonic | Parameter | Behavior |
|----:|----------|-----------|----------|
| `0` | Arpeggio | `XY` | On ticks with `tick % 3 == 0` play the base note, `== 1` base + X semitones, `== 2` base + Y semitones (looked up in the channel's finetune row). If `XY == 0` this is a no-op. |
| `1` | Portamento up | `XX` | On every tick after 0, decrement the period by `XX`; clamp at 113. **No memory**: `100` does nothing. |
| `2` | Portamento down | `XX` | On every tick after 0, increment the period by `XX`; clamp at 856 (some later trackers allow more). **No memory.** |
| `3` | Tone portamento | `XX` | The note in the cell becomes the *target* (looked up at the channel's finetune) and does **not** retrigger the sample. On every tick after 0 the period moves toward the target by `XX`; on reaching it the target is cleared, so a later `300` does not slide back. `XX = 0` reuses the previous speed (memory). |
| `4` | Vibrato | `XY` | Period offset from the vibrato waveform: `X` = speed, `Y` = depth; a zero nibble keeps the previous value (per-nibble memory). Applied and advanced only on ticks after 0 — tick 0 plays the unmodulated period. Offset = `(wave × depth) >> 7`, added during the first half of the cycle and subtracted in the second; position advances by `4 × speed` (of 256). |
| `5` | Tone portamento + volume slide | `XY` | Identical effect parameters as command `A`. Continues the previous `3` tone-portamento (period parameter is implicit). Volume slides up by `X` per tick if `X > 0`, else slides down by `Y` per tick. |
| `6` | Vibrato + volume slide | `XY` | Continues the previous `4` vibrato (speed/depth implicit). Volume slides as command `A`. |
| `7` | Tremolo | `XY` | Volume offset `(wave × depth) >> 6` from the tremolo waveform, clamped to `0..64`; the channel's stored volume is unchanged. Same per-nibble memory and tick rules as vibrato. ProTracker quirk: the ramp-down tremolo waveform tests the sign of the *vibrato* position. |
| `8` | (Panning) | `XX` | **Not implemented by ProTracker** (ignored). Some PC players treat it as pan `0..255`; demos sometimes use it as a sync marker. |
| `9` | Sample offset | `XX` | With a note: start the sample `XX × 256` bytes in. `XX = 0` reuses the previous offset (memory). ProTracker implements this by advancing the channel's start pointer and shortening its length, and it does so **twice** on a row with a note (once before and once after triggering), so a later note without a sample number starts at twice the offset. An offset at or past the end plays one word and then continues with the loop (silence for one-shot samples). |
| `A` | Volume slide | `XY` | On every tick after 0: if `X > 0` slide up by `X`, else down by `Y`; clamp to `0..64`. **No memory**: `A00` does nothing. |
| `B` | Position jump | `XX` | At the end of the row, continue at order `XX` (row 0). An order at or past the song length wraps to order 0. Within a row, channels are processed left to right: `B` resets the break row, so a `Dxx` to the *left* of a `Bxx` is cancelled, while one to the *right* sets the row in the jumped-to order. |
| `C` | Set volume | `XX` | On tick 0, set channel volume to `XX`. Clamp to `0..64` (parameters > 64 are clamped to 64). |
| `D` | Pattern break | `XY` | At end of current row, advance to the next order with the new pattern position being `X * 10 + Y` (note: **decimal**, not hex). So `D14` jumps to row 14 in decimal = 0x0E in hex. A computed row above 63 becomes 0. |
| `E` | Extended | see below | The lower nibble of the parameter selects a sub-command (`E0..EF`). See [Extended commands](#extended-commands-e0ef). |
| `F` | Set speed / set tempo | `XX` | `F01..F1F` set the **speed** (ticks per row) immediately. `F20..FFF` set the **tempo** (BPM); `F20` is BPM 32, not speed 32. The new tempo applies from the tick *after* the one that set it (the CIA timer reloads on underflow). `F00` stops the song in ProTracker. |

### Extended commands E0..EF

The parameter byte for command `E` is `X * 16 + Y` where `X` selects the sub-command and `Y` is the sub-parameter:

| Sub  | Mnemonic | Param | Behavior |
|-----:|----------|-------|----------|
| `E0` | Set filter | `Y` | `Y = 0` enables the Amiga LED low-pass filter; `Y = 1` disables it. A hardware post-DAC filter (~3.3 kHz); often ignored by software players (SwiftMOD ignores it). |
| `E1` | Fine portamento up | `Y` | Decrement period by `Y` once on tick 0, clamp at 113. No memory. |
| `E2` | Fine portamento down | `Y` | Increment period by `Y` once on tick 0, clamp at 856. No memory. |
| `E3` | Glissando control | `Y` | `Y = 0` smooth tone portamento, `Y ≠ 0` the *output* period is rounded to the first table note at or above the current pitch (the internal period still slides smoothly). |
| `E4` | Vibrato waveform | `Y` | `Y & 3`: 0 = sine, 1 = ramp down, 2 = square, 3 = documented as "random" but ProTracker plays a **square** wave. `Y & 4`: don't reset the waveform position on a new note. |
| `E5` | Set finetune | `Y` | Set the channel's finetune (signed nibble). On a row with a note it is applied before the note's period lookup; it stays in effect until a sample number reloads the sample's own finetune. |
| `E6` | Pattern loop | `Y` | Per channel. `Y = 0` stores the current row as that channel's loop row (initially 0, not reset between patterns). `Y > 0`: if the channel's counter is 0, set it to `Y` and jump; else decrement it and jump unless it reached 0. The jump is to the stored row within the current pattern. |
| `E7` | Tremolo waveform | `Y` | Same encoding as `E4` but for tremolo. |
| `E8` | (Unused) | `Y` | Not a playback effect in ProTracker 2 (later versions used it for a destructive "Karplus-Strong" filter). Some PC players treat it as coarse panning. |
| `E9` | Retrigger note | `Y` | Restart the sample (from the channel's current start pointer, so `9xx` offsets apply) on every tick where `tick % Y == 0`, except tick 0 of a row that has a note. `Y = 0` is a no-op. |
| `EA` | Fine volume slide up | `Y` | Add `Y` to channel volume once on tick 0. No memory. |
| `EB` | Fine volume slide down | `Y` | Subtract `Y` from channel volume once on tick 0. No memory. |
| `EC` | Note cut | `Y` | On tick `Y`, set channel volume to 0. The sample keeps playing but is muted. `Y = 0` cuts immediately; `Y ≥ speed` never cuts. |
| `ED` | Note delay | `Y` | The note's period (and any sample number's volume) are latched on tick 0, but the sample is triggered on tick `Y`. `Y = 0` is no delay. If `Y ≥ speed` the note never triggers, and the next row's tick 0 moves the still-playing voice to the new period. |
| `EE` | Pattern delay | `Y` | Repeat the current row `Y` extra times (`Y + 1` plays in total). Notes are not retriggered on the repeats, but the per-tick effects run on every tick, including tick 0 of each repeat — so fine slides (`E1`/`E2`/`EA`/`EB`) and `E6x` apply once per repetition. The tick counter restarts at 0 for every repeat. If another `EEx` is already running it is ignored; between channels on one row the rightmost wins. |
| `EF` | Invert loop | `Y` | "Funk repeat": `Y` selects a speed from `0,5,6,7,8,10,11,13,16,19,22,26,32,43,64,128`, added every tick to an accumulator; whenever it reaches 128, one byte of the looped sample is replaced by its one's complement, walking through the loop. Destructive: it permanently changes the sample data during playback. |

## Paula chip behavior

The Amiga's Paula chip is a 4-channel DMA-driven 8-bit PCM playback engine. Each channel reads from a DMA pointer at a programmable rate, with hardware-supplied looping. The behavioral characteristics that matter for a software MOD player:

- **Four hardware channels.** A pure 4-channel MOD plays exactly four samples in parallel. Multi-channel variants (`6CHN`, `8CHN`, etc) emulate additional channels in software.
- **Hard LR panning.** On the Amiga, channels 0 and 3 route to the left output; channels 1 and 2 route to the right. This is the "LRRL" panning convention. Software MOD players typically default to this layout but ProTracker effect `8` and extended `E8` can override it.
- **8-bit signed PCM, no DPCM, no compression.** Sample bytes are direct DAC values in the range `-128..127`. Each Paula channel's DAC produces output at the rate `paulaClockHz / period`.
- **Volume 0..64.** Paula's per-channel volume register takes `0..64`, where 64 is full scale (the register is 7 bits wide; 64 is the maximum meaningful value).
- **Period range 113..856.** ProTracker's authoring tool clamped periods to this range. Software players that strictly emulate ProTracker enforce the clamp; players that target later trackers (and the multichannel MOD variants) often allow a wider range.
- **Hardware loop registers.** Paula has a location register (`AUDxLC`) and a length register (`AUDxLEN`). They are latched when DMA starts and **re-read every time the current block finishes**. ProTracker starts a note with the sample start/length, then immediately rewrites the registers with the loop start/length, so the hardware continues with the loop. A "non-looping" sample has a 1-word loop at the start of the sample, which ProTracker zeroes — the voice keeps running but outputs silence. This is why MOD sample loop fields are `loopStart` + `loopLength`, and why a loop length of 1 word means "no loop".
- **Sample swap.** Because the loop registers are rewritten every row, a sample number *without* a note changes the volume and finetune immediately, but the new sample is only heard when the current block ends: the voice continues into the new sample's loop (or into silence if the new sample does not loop or is empty). A voice that has already run out of a one-shot sample picks up a looped sample immediately.
- **No envelope, no filter modulation per-sample.** Paula's only post-DAC processing is the global ~4 kHz low-pass filter, toggleable via `E0`. There are no per-note envelopes (that's an FT2 / IT-era extension); volume changes are explicit via the volume column or via effects `A` / `C` / `EA` / `EB` / `EC` / `7` (tremolo).
- **DMA fetch quirks.** Paula fetches sample bytes in 16-bit (word) units, which is why MOD sample lengths are stored in words and why the format requires word-aligned samples. A software player rendering at arbitrary sample rates can read byte-by-byte.

## Timing model

MOD timing is governed by two parameters, both set via effect `Fxx`:

- **Speed** (ticks per row). Default 6. Set via `Fxx` where `xx ≤ 0x1F`.
- **Tempo** (tick rate in BPM-derived units). Default 125. Set via `Fxx` where `xx ≥ 0x20`.

The tick rate in Hz is derived from tempo via the standard tracker formula:

```
tickRateHz = tempo * 2 / 5
```

Why this formula? It comes from the Amiga PAL VBL rate of 50 Hz being the canonical tick base, and 125 being the conventional BPM that maps to 50 Hz (`125 * 2/5 = 50`). Higher BPM values give proportionally faster ticks.

Derived quantities for a host sample rate of `R`:

```
samplesPerTick = R / tickRateHz       = R * 5 / (tempo * 2)
samplesPerRow  = samplesPerTick * speed
samplesPerBeat = samplesPerRow * 4    (a tracker "beat" is conventionally 4 rows)
```

At defaults (`speed = 6`, `tempo = 125`, `R = 44_100`): tick rate = 50 Hz, samples per tick = 882, samples per row = 5292, samples per beat = 21168.

ProTracker sets the tick rate with a CIA timer: `timer = 1_773_447 / BPM` (PAL), which works out to `BPM × 0.4` Hz. A new BPM takes effect after the current tick.

Each tick the player (see [ProTracker playback semantics](#protracker-playback-semantics) for the exact order):

1. On tick 0 of a new row, read each channel's cell: load the sample header if a sample number is present, trigger the note (unless tone portamento or note delay), and run the tick-0 commands `9`, `B`, `C`, `D`, `E`, `F`.
2. On every other tick (and on every tick of a pattern-delay repeat), run the per-tick commands `0`–`7`, `A` and `E`.
3. After tick 0's processing, advance the row pointer, applying pattern delay, pattern-loop jumps, pattern breaks and position jumps.

## ProTracker playback semantics

ProTracker 2.x is the de-facto reference for 4-channel MODs. Its replay routine is a small state machine; reproducing it — rather than a table of effect descriptions — is what gets the edge cases right. Song state: `speed`, `counter` (tick within row), `songPos`, `patternPos` (row), `breakPos`, `posJumpFlag`, `breakFlag` (set only by `E6x`), `pattDelay`, `pattDelayRemaining`. Per channel: the current cell, sample start/length/loop start/loop length pointers, period, finetune, volume, tone-portamento target/speed/direction, vibrato and tremolo command/position, wave control, glissando/funk nibbles, sample-offset memory, loop row and loop counter.

Each tick:

1. `counter += 1`. If `counter ≥ speed`: `counter = 0`; if no pattern delay is running, process the new row (below) and write every channel's loop registers; otherwise run the per-tick effects for every channel. Then do the end-of-row step.
2. Otherwise run the per-tick effects for every channel, and if `posJumpFlag` is set, go to the next position.

**New row, per channel.** If the *previous* cell was entirely empty, reset the output period to the channel period. Store the new cell. If it has a sample number: set start = 0, length = sample length (or loop start + loop length if the loop starts after 0), loop pointers, finetune and volume (volume is output immediately). Then, if the cell has a note: `E5x` sets the finetune and triggers; `3xx`/`5xy` only set the tone-portamento target; `9xx` applies the offset, then triggers; anything else triggers. Triggering looks the note up (see [Finetune adjustment](#finetune-adjustment)), and — unless the command is `EDx` — resets the vibrato/tremolo positions (unless their retain bits are set) and restarts the voice from start/length. Finally (and also when there is no note) the tick-0 commands run: `9` offset, `B` jump, `D` break, `E` extended, `C` volume, `F` speed/tempo; any other command resets the output period to the channel period.

**Per-tick effects.** An empty command (`000`) resets the output period. `0`–`6` and `E` run their handlers (which write the output period themselves); every other command first resets the output period, then `7` runs tremolo and `A` the volume slide. All `Exy` handlers run on every tick; those that should act once (`E1`, `E2`, `E6`, `EA`, `EB`, `EE`, `EF`) check `counter == 0`, which is why they repeat on pattern-delay repeats.

**End of row.** `patternPos += 1`. If a pattern delay was just requested, start it; while one is running, decrement it and, unless it just ran out, `patternPos -= 1`. If `breakFlag` (pattern loop) is set, `patternPos = breakPos` within the current pattern. If `patternPos ≥ 64`, go to the next position. While `posJumpFlag` is set, go to the next position: `patternPos = breakPos`, `breakPos = 0`, `songPos = (songPos + 1) & 127`, wrapping to order 0 at the song length. (Because the next-position step runs immediately, `EEx` combined with `Dxx` resumes one row *after* the break target.)

**Song end.** ProTracker never ends a song (except on `F00`); it wraps to order 0. A renderer has to decide when to stop. SwiftMOD stops when the next row to be read is an order/row pair it has already played — which covers the natural end of the order list and every `Bxx`/`Dxx` loop — while rows replayed by an `E6x` loop are exempt. Because interlocking `E6x` loops can still run forever, a maximum render duration is the final guarantee.

## Known quirks and ambiguities

The MOD format has accumulated a small pile of known weirdness over its multi-decade lifetime. Implementers should know about these.

### Pattern loop state is per-channel

The `E6` pattern-loop effect's loop counter and loop-start row are tracked **per channel**, not globally, and neither is reset by a pattern break or a new pattern. Two channels with `E6x` on different rows can interlock so that the counters never expire together, which loops forever in ProTracker; players must bound playback some other way (SwiftMOD: a maximum render duration).

### `F00` is implementation-defined

ProTracker treats `F00` as "halt the song." Some clones (FastTracker, OpenMPT in compatibility-MOD mode) treat it as "ignore." A robust reader should treat `F00` as "halt" by default and offer an option.

### Pattern break parameter is decimal

`Dxy` jumps to row `X * 10 + Y`, **decimal**, not `(X << 4) | Y` hex. So `D14` jumps to row 14, not row 20. This is a long-standing footgun for authors who don't know the format; FT2 and IT changed it to hex to avoid the confusion.

### Pattern break + position jump on the same row

If both `Bxx` and `Dyy` appear on the same row (different channels), `Bxx` sets the order index and `Dyy` sets the row within the *new* pattern — but only if the `D` is to the **right** of the `B`. ProTracker processes channels left to right and `Bxx` clears the break row, so `Dyy` in an earlier channel is cancelled.

### Arpeggio tick distribution

Effect `0xy` cycles through the three notes (base, base+x, base+y) at `tickIndex % 3`. The exact mapping of `tickIndex` to the three positions varies between trackers — ProTracker, FastTracker, and Impulse Tracker all do it slightly differently. ProTracker's canonical mapping is `tick % 3 == 0 → base`, `== 1 → base + x`, `== 2 → base + y`. Other implementations swap the order. In ProTracker a shifted note above B-3 reads past the end of the finetune row: first the trailing `0` (period 0 ≈ silence), then the next row's low notes.

### Vibrato wave reset

Effect `4xy` (vibrato) shares its waveform position with the channel's tremolo (`7xy`) waveform position in some implementations and not in others. ProTracker keeps them separate. The `E4Y` "vibrato waveform" sub-command's `Y & 4` bit controls whether the waveform position resets when a new note is triggered.

### Sample loop at exact end

A sample with `loopStart = 0` and `loopLength = sampleLength / 2` ostensibly loops the whole sample. ProTracker's hardware did this fine. A software player using linear interpolation at the loop point can produce a one-sample-period click if the loop start and end values aren't bit-identical (most aren't). Various players add a small linear blend across the loop boundary; this is a quality-of-implementation choice, not part of the spec.

### Sample length 1 (= 2 bytes)

A sample with `lengthBytes == 2` and `loopLength == 1` is the canonical "empty placeholder" sample. ProTracker writes two zero bytes for the body. Readers should treat it as silent.

### Period 0 vs period clipped

A cell with `period == 0` means "no note" (continue current playback). Slides clamp to 113..856 in ProTracker. Note periods outside the table are quantised (above 856 → C-1; below the table → period 0). Multichannel modules written by PC trackers commonly use notes outside C-1..B-3 (e.g. 1712 = C-0); SwiftMOD keeps those raw for modules with other than 4 channels and widens the slide clamp to 28..6848.

### Ghost-note empty cells

A cell with all four bytes zero is a "no-op" — no note, no effect, continue. This is the most common cell in a sparse pattern.

### M.K.! variant

Some files write `M.K.!` (5 bytes) as a variant signature, by overrunning the 4-byte slot into the song-length byte. This is not a valid format extension; readers should ignore the extra `!`.

## References

This document was written against the following public-domain or freely-available references. No source code from libxmp, OpenMPT's `Load_mod.cpp`, MikMod, or Schism Tracker was consulted.

1. **ProTracker 2.x User Manual** (Lars Hamre / the Amiga Freelancers, 1990). The canonical effect command catalog 0..F + Exx subcommands, the period table, sample header layout. Freeware Amiga doc, widely mirrored. https://www.amiga-stuff.com/, https://modarchive.org/forums/index.php?topic=2362.0
2. **MODFIL10.TXT** (Andrew Scott / FireLight, ~1995). The exhaustive byte-by-byte layout: 1084-byte header, 31-sample table, 4-byte format tag at offset 1080, packed pattern cell encoding. Released as a public-domain reference doc. https://www.aes.id.au/modformat.html
3. **MOD-FORM.TXT / mod-form.txt / MOD.TXT** (Brad Watkins / Steinberg, early 90s). Paula chip semantics: 4 hardware channels, 8-bit signed PCM, hardware loop registers, sample rate from period.
4. **Commodore-Amiga Hardware Reference Manual**, 3rd edition (Commodore-Amiga / Addison-Wesley, 1991, ISBN 0-201-56776-8). Paula clock constants: PAL audio clock `3_546_894.6` Hz, NTSC audio clock `3_579_545.25` Hz. The chip-specification constants are facts widely reproduced across public documentation.
5. **Wikipedia: MOD (file format)** — https://en.wikipedia.org/wiki/MOD_(file_format). Useful for high-level history and the format-lineage timeline. Cited only for historical context, never for byte-level claims.
6. **OpenMPT Wiki: Module formats** — https://wiki.openmpt.org/Manual:_Module_formats and the format-quirks pages. Used for the documented edge cases (pattern-loop per-channel state, FLT8 paired patterns, finetune table quirks). The OpenMPT wiki prose is CC-BY-SA 3.0; this doc cites tables and prose, never source code.
7. **Modland format documentation** — https://modland.com/. The format-variant signature table (which tags imply which channel counts).
8. **Ultimate Soundtracker / Karsten Obarski source comments** (1987 Amiga freeware release). The 15-sample no-signature variant layout was reconstructed from author-supplied documentation.

Explicitly **not** cited (license-incompatible for clean-room): libxmp (LGPL), OpenMPT source code (BSD, but reading it taints clean-room status), MikMod source (LGPL), 4mat's PT2.3D assembly (no license), Schism Tracker source (GPL).
