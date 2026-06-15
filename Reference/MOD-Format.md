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

A parser computes `numPatterns` as `max(orderTable[0..<songLength]) + 1`. Anything past that in the order table is unused padding.

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
- **Sample 0 is conventionally empty.** Sample indices in pattern cells are 1-based (1..31); a cell with sample index 0 means "no new sample, continue using the previous one." A length of 0 produces no bytes in the sample bodies section.
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

- **Song length** (`0x3B6`) is the number of used order positions, `1..128`. Older Amiga modules sometimes had stray non-zero values past `songLength` in the order table; these are ignored.
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

**Detection:** if the bytes at offset 1080 do not match any known signature, attempt a 15-sample parse. Validate by checking that the computed file size (`600 + numPatterns × 4 × 64 × 4 + Σ sample.lengthBytes`) matches (or is within a small tolerance of) the actual file size. Older versions of the format had quirks around finetune (the byte at sample-header offset `0x18` was a "sample repeat byte" in pre-NoiseTracker layouts and not a finetune nibble) — readers can keep the field as zero finetune for safety.

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
| `2CHN`    | 2   | 127 | FastTracker stereo |
| `6CHN`    | 6   | 127 | TakeTracker / FastTracker |
| `8CHN`    | 8   | 127 | TakeTracker / FastTracker |
| `xxCH`    | `xx` decimal, 10..32 | 127 | Generalized TakeTracker (e.g. `10CH`, `16CH`, `32CH`) |
| `xxCN`    | `xx` decimal, 10..32 | 127 | Generalized variant (less common) |
| `OCTA`    | 8   | 127 | Oktalyzer 8-channel |
| `OKTA`    | 8   | 127 | Oktalyzer alternative tag |
| `CD61`    | 6   | 127 | Falcon CD61 player |
| `CD81`    | 8   | 127 | Falcon CD81 player |
| `FA04`    | 4   | 127 | DigitalSound Falcon 4-channel |
| `FA06`    | 6   | 127 | DigitalSound Falcon 6-channel |
| `FA08`    | 8   | 127 | DigitalSound Falcon 8-channel |
| `TDZ1`..`TDZ3` | 1..3 | 127 | TakeTracker low-channel |
| (anything else / absent) | 4 | 63 | 15-sample variant, attempt fallback parse |

The general pattern for `xxCH` / `xxCN`: take the first two bytes as ASCII digits, parse as a decimal integer, that's the channel count. So `16CH` → 16 channels, `32CH` → 32 channels. Defensive: clamp to a sane upper bound (32) and reject zero or anything not in the form `[0-9][0-9]CH`.

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

# Plays sample 17 at period 1079 (≈ C-1 with finetune 0), no effect.
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

The StarTrekker `FLT8` 8-channel variant is the one place where pattern storage deviates from the formula above. `FLT8` files store **two 4-channel patterns** that together represent one 8-channel pattern: pattern `2n` holds channels 0..3 and pattern `2n+1` holds channels 4..7. The order list references the *pair* index, so order byte `k` means "play the 8-channel pattern composed of stored-pattern `2k` and stored-pattern `2k+1`."

Pattern count is computed as `(max(orderTable[0..<songLength]) + 1) × 2` for FLT8.

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

Looping samples: if `loopLength > 1` (i.e. > 2 bytes), the player should jump from `loopStart + loopLength` back to `loopStart` when playback reaches the loop end. ProTracker convention: the loop region is `[loopStart, loopStart + loopLength)` in byte offsets (after multiplying both fields by 2 to convert from words to bytes).

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

Each octave is exactly one half of the previous (with rounding). The legal period range is **113 (B-3) to 856 (C-1)**. ProTracker enforced these bounds; later variants relaxed them upward (lower notes than C-1) and downward (higher notes than B-3) but pure ProTracker periods stay in this window.

### Finetune adjustment

The Amiga produced its 50-Hz vertical-blank tick from a divisor that wasn't a perfect match to equal temperament, so each sample carries a **finetune** value in `-8..+7` steps. Each finetune step shifts the period table; the full set of 16 finetuned period tables is:

```
finetune  0: 856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453, ...
finetune +1: 850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477, 450, ...
finetune +2: 844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, 447, ...
finetune +3: 838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470, 444, ...
finetune +4: 832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467, 441, ...
finetune +5: 826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, 437, ...
finetune +6: 820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460, 434, ...
finetune +7: 814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, 431, ...
finetune -8: 907, 856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, ...
finetune -7: 900, 850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477, ...
finetune -6: 894, 844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, ...
finetune -5: 887, 838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470, ...
finetune -4: 881, 832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467, ...
finetune -3: 875, 826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, ...
finetune -2: 868, 820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460, ...
finetune -1: 862, 814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, ...
```

(Octaves 2 and 3 follow by halving — multiply each octave-1 entry by 1/2 and 1/4 with rounding.)

For tracker-grade implementations a player typically stores all 16 tables × 36 notes (576 entries) as a lookup table indexed by `(finetune + 8) * 36 + noteIndex`.

### Period to frequency

The playback sample rate for a given period is:

```
sampleRate = paulaClockHz / period
```

Where `paulaClockHz` is:

- **PAL**: `3_546_894.6` Hz (canonical: 7_093_789.2 / 2)
- **NTSC**: `3_579_545.0 / 2 = 1_789_772.5` Hz (rarely used in MOD authoring — most modules are PAL-authored)

Most software MOD players use the PAL clock unconditionally. The NTSC clock produces slightly higher playback frequencies (~0.4% faster) and is only relevant for NTSC-Amiga-authored modules, which are rare.

Conversion from playback sample rate to the host audio device's sample rate is a per-sample-step: `step = paulaClockHz / (period * hostSampleRate)`. The mixer accumulates this step into a fractional sample-position pointer and reads from the sample body with linear (or higher-order) interpolation.

## Effect command reference

Effects are encoded in the pattern cell as a 4-bit command (`effect`) plus an 8-bit parameter (`parameter`). The parameter is conventionally written `XY` for "upper nibble X, lower nibble Y" — many effects use the two nibbles independently. Effects evaluate **once per tick**, with most behaviors split into "fire on tick 0" (initial trigger / set) and "fire on every tick after 0" (continuous).

### Primary commands 0..F

| Cmd | Mnemonic | Parameter | Behavior |
|----:|----------|-----------|----------|
| `0` | Arpeggio | `XY` | On tick 0 play base note. On ticks where `(tickIndex % 3 == 1)` play base + X semitones. On ticks where `(tickIndex % 3 == 2)` play base + Y semitones. If `XY == 0` this is a no-op. |
| `1` | Portamento up | `XX` | On every tick after 0, decrement the channel's period by `XX`. Clamp at the upper-frequency period bound (113 for ProTracker). |
| `2` | Portamento down | `XX` | On every tick after 0, increment the channel's period by `XX`. Clamp at the lower-frequency period bound (856 for ProTracker; some implementations allow up to 1023 or higher). |
| `3` | Tone portamento | `XX` | Slide toward a target period set by the last-noted period on this channel. On every tick after 0, move the period toward the target by `XX`. The note in the cell with this effect is the *target* and does **not** retrigger the sample — it just updates the target. `XX = 0` continues using the previous tone-portamento rate (memory effect). |
| `4` | Vibrato | `XY` | Apply a sinusoidal period offset. `X` = speed (vibrato rate, 0..15), `Y` = depth (vibrato amplitude, 0..15). Either nibble of `0` means "use the previous value" (memory). Vibrato position advances on every tick, including tick 0. |
| `5` | Tone portamento + volume slide | `XY` | Identical effect parameters as command `A`. Continues the previous `3` tone-portamento (period parameter is implicit). Volume slides up by `X` per tick if `X > 0`, else slides down by `Y` per tick. |
| `6` | Vibrato + volume slide | `XY` | Continues the previous `4` vibrato (speed/depth implicit). Volume slides as command `A`. |
| `7` | Tremolo | `XY` | Sinusoidal volume offset. `X` = speed, `Y` = depth. Same memory semantics as vibrato. |
| `8` | Set panning | `XX` | ProTracker extension (not in the original NoiseTracker). Pan position `0..255`, where `0x00` is hard left, `0x80` is center, `0xFF` is hard right. Many MOD readers map `XX = 0xA4` to "surround." Behavior is undefined in pure 4-channel MOD (use hard LRRL panning instead). |
| `9` | Sample offset | `XX` | On tick 0, set the sample playback position to `XX × 256` bytes into the sample body. If `XX > sampleLength / 256` the behavior is "play silence" (ProTracker) or "cut" (some clones). `XX = 0` uses the *previous* offset value (memory). |
| `A` | Volume slide | `XY` | On every tick after 0, slide channel volume. If `X > 0` slide up by `X` per tick. Else slide down by `Y` per tick. Clamp at 0 and 64. `XY = 0` continues the previous slide (memory in some implementations, but ProTracker treats it as "stop sliding"). |
| `B` | Position jump | `XX` | At end of current row, jump to order index `XX`. Combined with `D` in the same row, `D` wins for the in-pattern row index and `B` for the order. |
| `C` | Set volume | `XX` | On tick 0, set channel volume to `XX`. Clamp to `0..64` (parameters > 64 are clamped to 64). |
| `D` | Pattern break | `XY` | At end of current row, advance to the next order with the new pattern position being `X * 10 + Y` (note: **decimal**, not hex). So `D14` jumps to row 14 in decimal = 0x0E in hex. Parameters > 63 wrap to 0. |
| `E` | Extended | see below | The lower nibble of the parameter selects a sub-command (`E0..EF`). See [Extended commands](#extended-commands-e0ef). |
| `F` | Set speed / set tempo | `XX` | If `XX < 0x20` (i.e. `0..31`), set the **speed** (ticks per row) to `XX`. If `XX >= 0x20` (i.e. `32..255`), set the **tempo** (BPM) to `XX`. `XX = 0` is a special case: some clones halt the song, others ignore it. |

### Extended commands E0..EF

The parameter byte for command `E` is `X * 16 + Y` where `X` selects the sub-command and `Y` is the sub-parameter:

| Sub  | Mnemonic | Param | Behavior |
|-----:|----------|-------|----------|
| `E0` | Set filter | `Y` | `Y = 0` enables the Amiga low-pass filter; `Y = 1` disables it. Often ignored by modern software players (the hardware filter is a Paula post-DAC analog filter ~ 4 kHz cutoff). |
| `E1` | Fine portamento up | `Y` | Decrement period by `Y` once on tick 0 (no continuous slide). |
| `E2` | Fine portamento down | `Y` | Increment period by `Y` once on tick 0. |
| `E3` | Glissando control | `Y` | `Y = 0` smooth tone portamento, `Y = 1` snap to semitone boundaries. |
| `E4` | Vibrato waveform | `Y` | `Y & 3`: 0 = sine, 1 = ramp down, 2 = square, 3 = random. `Y & 4`: don't retrigger waveform on new note. |
| `E5` | Set finetune | `Y` | Override the sample's finetune for this row. `Y` is a 4-bit signed nibble (see [Finetune adjustment](#finetune-adjustment)). |
| `E6` | Pattern loop | `Y` | `Y = 0` set loop start at current row. `Y > 0` loop back to start `Y` times. (See [Known quirks](#known-quirks-and-ambiguities) for the per-channel state bug.) |
| `E7` | Tremolo waveform | `Y` | Same encoding as `E4` but for tremolo. |
| `E8` | Set panning (coarse) | `Y` | Set channel pan to `Y * 17` (mapping 0..15 → 0..255). Less common than the primary `8` command. |
| `E9` | Retrigger note | `Y` | Retrigger the current sample every `Y` ticks within the row. `Y = 0` is no-op. |
| `EA` | Fine volume slide up | `Y` | Add `Y` to channel volume once on tick 0. |
| `EB` | Fine volume slide down | `Y` | Subtract `Y` from channel volume once on tick 0. |
| `EC` | Note cut | `Y` | On tick `Y`, set channel volume to 0. The sample keeps playing but is muted. `Y = 0` cuts immediately. |
| `ED` | Note delay | `Y` | On tick 0, *don't* retrigger the sample. On tick `Y`, retrigger. `Y = 0` is identical to no delay. |
| `EE` | Pattern delay | `Y` | Repeat the current row `Y` extra times (so a total of `Y + 1` plays of the row). Other effects still evaluate on the extra ticks. |
| `EF` | Invert loop | `Y` | Funktrepänen "invert loop" effect — XOR sample bytes within the loop region at the rate `Y`. Almost never used; many players ignore it. |

## Paula chip behavior

The Amiga's Paula chip is a 4-channel DMA-driven 8-bit PCM playback engine. Each channel reads from a DMA pointer at a programmable rate, with hardware-supplied looping. The behavioral characteristics that matter for a software MOD player:

- **Four hardware channels.** A pure 4-channel MOD plays exactly four samples in parallel. Multi-channel variants (`6CHN`, `8CHN`, etc) emulate additional channels in software.
- **Hard LR panning.** On the Amiga, channels 0 and 3 route to the left output; channels 1 and 2 route to the right. This is the "LRRL" panning convention. Software MOD players typically default to this layout but ProTracker effect `8` and extended `E8` can override it.
- **8-bit signed PCM, no DPCM, no compression.** Sample bytes are direct DAC values in the range `-128..127`. Each Paula channel's DAC produces output at the rate `paulaClockHz / period`.
- **Volume 0..64.** Paula has a 6-bit per-channel volume register. Software players represent volume as `0..64` (so 65 values, despite the 6-bit register, because ProTracker overshoots). Values > 64 are clamped on the hardware.
- **Period range 113..856.** ProTracker's authoring tool clamped periods to this range. Software players that strictly emulate ProTracker enforce the clamp; players that target later trackers (and the multichannel MOD variants) often allow a wider range.
- **Hardware loop registers.** Paula has separate `LCH`/`LCL` (loop pointer) and `LEN` (sample length) registers. When the channel reaches end-of-sample the hardware automatically resumes playback from the loop pointer. ProTracker writes the loop pointer to the loop start and writes the loop length to `LEN`; a "non-looping" sample is implemented by pointing the loop registers at two zero bytes after the actual sample. This is why MOD sample loop fields are `loopStart` + `loopLength` rather than `loopStart` + `loopEnd`.
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

Each tick the mixer:

1. Advances the song position. On the first tick of a new row, latch the cell's note (if any) and apply tick-0 effects (set volume, set sample offset, position jump, pattern break, fine portamento, fine volume slide, set finetune, note cut at tick 0).
2. Apply continuous effects on every tick (portamento up/down, tone portamento, vibrato, tremolo, volume slide, arpeggio, retrigger if `tick % param == 0`).
3. On the last tick of a row, advance row pointer (or honor a pending position jump / pattern break).

## Known quirks and ambiguities

The MOD format has accumulated a small pile of known weirdness over its multi-decade lifetime. Implementers should know about these.

### Pattern loop state is per-channel

The `E6` pattern-loop effect's loop counter and loop-start row are tracked **per channel**, not globally. ProTracker authors discovered (and intermittently exploited) that two channels writing `E6X` on the same row could create overlapping or interlocking loops, which is undefined behavior in some clones. Modern players uniformly implement per-channel loop state and stop when *any* channel's loop counter reaches zero.

### `F00` is implementation-defined

ProTracker treats `F00` as "halt the song." Some clones (FastTracker, OpenMPT in compatibility-MOD mode) treat it as "ignore." A robust reader should treat `F00` as "halt" by default and offer an option.

### Pattern break parameter is decimal

`Dxy` jumps to row `X * 10 + Y`, **decimal**, not `(X << 4) | Y` hex. So `D14` jumps to row 14, not row 20. This is a long-standing footgun for authors who don't know the format; FT2 and IT changed it to hex to avoid the confusion.

### Pattern break + position jump on the same row

If both `Bxx` and `Dyy` appear on the same row (different channels), `Bxx` sets the order index and `Dyy` sets the row within the *new* pattern. The order in which the two effects are processed within the row is implementation-defined but most implementations process `B` first.

### Arpeggio tick distribution

Effect `0xy` cycles through the three notes (base, base+x, base+y) at `tickIndex % 3`. The exact mapping of `tickIndex` to the three positions varies between trackers — ProTracker, FastTracker, and Impulse Tracker all do it slightly differently. ProTracker's canonical mapping is `tick % 3 == 0 → base`, `== 1 → base + x`, `== 2 → base + y`. Other implementations swap the order.

### Vibrato wave reset

Effect `4xy` (vibrato) shares its waveform position with the channel's tremolo (`7xy`) waveform position in some implementations and not in others. ProTracker keeps them separate. The `E4Y` "vibrato waveform" sub-command's `Y & 4` bit controls whether the waveform position resets when a new note is triggered.

### Sample loop at exact end

A sample with `loopStart = 0` and `loopLength = sampleLength / 2` ostensibly loops the whole sample. ProTracker's hardware did this fine. A software player using linear interpolation at the loop point can produce a one-sample-period click if the loop start and end values aren't bit-identical (most aren't). Various players add a small linear blend across the loop boundary; this is a quality-of-implementation choice, not part of the spec.

### Sample length 1 (= 2 bytes)

A sample with `lengthBytes == 2` and `loopLength == 1` is the canonical "empty placeholder" sample. ProTracker writes two zero bytes for the body. Readers should treat it as silent.

### Period 0 vs period clipped

A cell with `period == 0` means "no note" (continue current playback). A cell with a *negative* (after slide) period is illegal; players clamp to 113 (or sometimes to a wider range). A period above 1023 is also illegal but more permissively handled (FastTracker raised it to 1712 to support B-3 minus octaves).

### Ghost-note empty cells

A cell with all four bytes zero is a "no-op" — no note, no effect, continue. This is the most common cell in a sparse pattern.

### M.K.! variant

Some files write `M.K.!` (5 bytes) as a variant signature, by overrunning the 4-byte slot into the song-length byte. This is not a valid format extension; readers should ignore the extra `!`.

## References

This document was written against the following public-domain or freely-available references. No source code from libxmp, OpenMPT's `Load_mod.cpp`, MikMod, or Schism Tracker was consulted.

1. **ProTracker 2.x User Manual** (Lars Hamre / the Amiga Freelancers, 1990). The canonical effect command catalog 0..F + Exx subcommands, the period table, sample header layout. Freeware Amiga doc, widely mirrored. https://www.amiga-stuff.com/, https://modarchive.org/forums/index.php?topic=2362.0
2. **MODFIL10.TXT** (Andrew Scott / FireLight, ~1995). The exhaustive byte-by-byte layout: 1084-byte header, 31-sample table, 4-byte format tag at offset 1080, packed pattern cell encoding. Released as a public-domain reference doc. https://www.aes.id.au/modformat.html
3. **MOD-FORM.TXT / mod-form.txt / MOD.TXT** (Brad Watkins / Steinberg, early 90s). Paula chip semantics: 4 hardware channels, 8-bit signed PCM, hardware loop registers, sample rate from period.
4. **Commodore-Amiga Hardware Reference Manual**, 3rd edition (Commodore-Amiga / Addison-Wesley, 1991, ISBN 0-201-56776-8). Paula clock constants: PAL audio clock `3_546_894.6` Hz, NTSC audio clock `1_789_772.5` Hz. The chip-specification constants are facts widely reproduced across public documentation.
5. **Wikipedia: MOD (file format)** — https://en.wikipedia.org/wiki/MOD_(file_format). Useful for high-level history and the format-lineage timeline. Cited only for historical context, never for byte-level claims.
6. **OpenMPT Wiki: Module formats** — https://wiki.openmpt.org/Manual:_Module_formats and the format-quirks pages. Used for the documented edge cases (pattern-loop per-channel state, FLT8 paired patterns, finetune table quirks). The OpenMPT wiki prose is CC-BY-SA 3.0; this doc cites tables and prose, never source code.
7. **Modland format documentation** — https://modland.com/. The format-variant signature table (which tags imply which channel counts).
8. **Ultimate Soundtracker / Karsten Obarski source comments** (1987 Amiga freeware release). The 15-sample no-signature variant layout was reconstructed from author-supplied documentation.

Explicitly **not** cited (license-incompatible for clean-room): libxmp (LGPL), OpenMPT source code (BSD, but reading it taints clean-room status), MikMod source (LGPL), 4mat's PT2.3D assembly (no license), Schism Tracker source (GPL).
