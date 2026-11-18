# KIMTAPE, read and write KIM-1 audio datafiles

A Free Pascal port of KIMTAPE 0.5 (17-May-04), the DX-Forth DOS utility by Ed Smeda
that converts KIM-1 and SYM-1 cassette tape audio (KIM-1, HYPERTAPE 2x/3x/6x,
SYM-1 high speed) to program files and back. 
Crossplatform thanks to Freepascal source.

The command line is the same as the original's with additions. 
```
KIMTAPE version 1.0  (Free Pascal port of KIMTAPE 0.5)

Use:  KIMTAPE [options] infile[.typ] [outfile[.typ]]

-C    console output              -M    make wavefile
-Bn   HYPERTAPE speed  2x 3x 6x   -I    invert wavefile
-U    SYM-1 high speed format     -V    VOC wavefile
-Fn   offset  -127 to 127         -R    RAW wavefile
-Hn   hysteresis  0 to 127        -Ln   leader (sec)
-Gn   timing  -2 to 2             -T    sine tone
-An   load address (hex)          -Dn   prog ID (hex)

Additional options in this version:
-K    classic decoder (zero crossings, as KIMTAPE 0.5)
-En   high tone boost 0..4 (default: automatic)
-N    no automatic DC/level adjust  (-K and SYM-1 decoding)
-Pn   channel  0=mix 1=left 2=right  (decode, stereo files)
-Sn   sample rate: output wavefile (encode, default 22050)
      or RAW input file (decode, default 22050)
-Wn   sample width 8 or 16 bits  (encode, default 8)
-O    overwrite output file without asking

Several recordings of the same tape can be combined:
  KIMTAPE rec1.wav+rec2.wav+rec3.wav outfile

default: decode WAV file, KIM-1 format
         load address=0200, file ID=00
```
Conversion utility for KIM-1 and SYM-1 format audio tapes.
Input WAV files may use any sample rate (44100, 48000, ...),
8/16/24/32 bit integer or float samples, mono or stereo.
Output is an 8-bit mono WAV, VOC or RAW wavefile recorded at
22,050 samples per second unless -S / -W are given.

Examples:

```
kimtape KB9V01A.WAV KB9V01A.BIN                  decode
kimtape -M -A2000 -D01 KB9V01A.BIN TAPE.WAV      encode, $2000, ID 01
kimtape -M -B3 -S44100 -W16 PROG.BIN TAPE.WAV    HYPERTAPE 3x, 44.1 kHz 16 bit
kimtape -P1 STEREO.WAV PROG.BIN                  decode left channel only
```

Several recordings of the same tape can be combined (see below):

```
kimtape REC1.WAV+REC2.WAV+REC3.WAV PROG.BIN
```

Switches start with `-`. On Windows `/` also works, as in the DOS original.

## What is new compared to the DOS version

- **New decoder for KIM-1 and HYPERTAPE tapes.** The original counts
  zero crossings, which fails on recordings with distorted waveforms,
  strong harmonics or phase shift: typical for old cassettes and for
  modern 44.1 kHz recordings. The new decoder works like the phase
  locked loop in the KIM-1 itself:
  - a band-pass filter (1700-4200 Hz) and a quadrature (FM)
    discriminator measure the tone frequency, whatever the waveform
    shape or polarity;
  - the two tone frequencies and the bit period are measured from the
    recording, so a recorder running too slow or fast and all speeds
    (1x, HYPERTAPE 2x/3x/6x) are handled without switches;
  - a bit clock locks onto the start of each bit and follows speed
    drift; each bit is decided in its middle third
    (0 = high-high-low, 1 = high-low-low);
  - every bit gets a confidence value. An invalid hex character is
    repaired by flipping its least certain bits, and every repair is
    reported with its time in the recording. The checksum then shows
    whether the result is correct. Decoding continues instead of
    aborting with "Bad pattern error".

  - cassette players with a misaligned head (azimuth) lose the 3600 Hz
    tone. The decoder tries 0 to 3 steps of high tone boost (+3.5 dB
    each) and keeps the one that gives the cleanest data; a clean
    first pass needs no extra time. `-En` sets the boost by hand.

  The first line of output shows what was measured, e.g.
  `tape: tones 2455/3238 Hz, bit 1.38 ms, HYPERTAPE 6x`.
  `-K` selects the original decoder; SYM-1 high speed tapes (`-U`)
  always use it.
- **Decoding accepts any WAV format:** any sample rate (11025 Hz and up,
  e.g. 44100, 48000, 96000), 8/16/24/32 bit integer or 32/64 bit float
  samples, WAVE_FORMAT_EXTENSIBLE, mono or stereo. Extra chunks (LIST,
  fact, ...) are skipped. The decoder is the original algorithm, but it
  measures cycle lengths in time instead of samples at 22050 Hz.
- **Combining recordings:** `rec1.wav+rec2.wav+...` decodes each
  recording and combines them character by character:
  - each bit is a vote weighted by the decoder's confidence; recordings
    with invalid characters nearby (error bursts) count less, and a
    recording that slips out of step is ignored from that point;
  - only valid hex characters can win;
  - a character that no recording could read is calculated from the
    checksum when it is the only one;
  - if the checksum still does not match, alternatives for the
    conflicting characters are tried and the combination with the
    fewest changes is used;
  - every byte that was decided this way is listed. When several
    combinations fit the checksum, the bytes are listed as
    "uncertain" with their alternative, so they can be checked by hand
    (for example against the 6502 code);
  - a warning is shown when a recording seems to hold a different
    program (different length, or little agreement).

  Programs are matched by their order in each recording.
- **Automatic level adjustment** for the classic decoder (`-K`, SYM-1):
  DC offset is removed and the level is normalised, so quiet 16-bit
  recordings decode. `-N` gives the original fixed levels; `-F`, `-H`
  and `-G` still work on top of either.
- **Stereo input:** channels are mixed by default; `-P1` or `-P2` picks
  the left or right channel.
- **VOC input:** block types 1, 2, 3, 8 and 9 are supported. RAW input at
  any rate with `-S`.
- **Encoding:** the default output is byte-identical to the original
  (22050 Hz, 8 bit mono). `-S` and `-W` write other rates or 16-bit
  samples, using band-limited resampling of the original waveform.
- **Fixes:**
  - WAV files no longer have a stray byte after the data chunk.
  - VOC files over 16 MB are split into continuation blocks (the original
    wrapped the 3-byte block size). Old files with the wrapped size are
    still read.
- Error positions are given as sample number and time, not as a file offset.

## Recording tips

- Turn off automatic gain control (AGC) and any "enhancements" on the
  sound card input. AGC makes the start of a recording overdriven and
  then fades the level, which damages the first part of the data.
- Record at a moderate level with no clipping; 16 bit, 44.1 or 48 kHz,
  mono or stereo.
- Also turn off noise suppression, noise gates and limiters. They cut
  quiet parts to silence and squash the loud parts.
- Record the whole program plus a few seconds of silence after it.
- A quiet recording is fine; clipping or a limiter is not.
- If KIMTAPE reports a high tone boost, the player's head is probably
  not aligned with the recorder that made the tape. Adjusting the
  azimuth screw for the brightest sound helps.
- If one stereo channel is cleaner, select it with `-P1` or `-P2`.
- Several recordings of a difficult tape can be combined (`+`).

## Building

```
fpc -O2 kimtape.pas

## Verification

- Decoding `KB9V01A.WAV` gives a file identical to the original's output.
- The original (run in DOSBox) encoded eight test cases: KIM-1, HYPERTAPE
  3x, 6x sine, inverted, SYM-1 square and sine, VOC and RAW. All eight
  match the port's output byte for byte (apart from the stray WAV byte).
- The same recording, resampled to 11/44.1/48/96 kHz as 16/24/32 bit and
  float, stereo and quiet with DC offset, decodes to the identical program.
- New recordings of old cassettes that the classic decoder cannot read at
  all (overdriven, strong harmonics, about 5% slow) decode with the new
  decoder apart from a few characters in the overdriven part.

## Repository contents

- `kimtape.pas`: the program source
- `kimtape.exe`: Windows 64-bit build
- `original/`: the DOS original, KIMTAPE 0.5: DX-Forth source
  (`KIMTAPE.SCR` with listing `KIMTAPE.LST`), `KIMTAPE.COM`, docs and
  disclaimer

## Credits

The original KIMTAPE was written in DX-Forth and released as public
domain. This port follows its structure word by word; Forth word names
appear in the comments.

## License

The Free Pascal port is released under the MIT License (see `LICENSE`).
The original KIMTAPE 0.5 files in `original/` remain public domain, as
stated in `original/DISCLAIM.TXT`.
