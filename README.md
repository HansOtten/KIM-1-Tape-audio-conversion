# KIMTAPE for Free Pascal

A Free Pascal port of KIMTAPE 0.5 (17-May-04), the DX-Forth DOS utility
that converts KIM-1 and SYM-1 cassette tape audio (KIM-1, HYPERTAPE 2x/3x/6x,
SYM-1 high speed) to program files and back. It runs natively on Windows,
Linux and macOS, so no DOS emulator is needed.

The command line is the same as the original's. See `original/KIMTAPE.TXT` for the full
user notes.

```
KIMTAPE [options] infile[.typ] [outfile[.typ]]

-C    console output              -M    make wavefile
-Bn   HYPERTAPE speed  2x 3x 6x   -I    invert wavefile
-U    SYM-1 high speed format     -V    VOC wavefile
-Fn   offset  -127 to 127         -R    RAW wavefile
-Hn   hysteresis  0 to 127        -Ln   leader (sec)
-Gn   timing  -2 to 2             -T    sine tone
-An   load address (hex)          -Dn   prog ID (hex)

Additional options:
-N    no automatic DC/level adjust  (decode)
-Pn   channel  0=mix 1=left 2=right  (decode, stereo files)
-Sn   sample rate: output wavefile (encode) or RAW input (decode)
-Wn   sample width 8 or 16 bits  (encode)
-O    overwrite output file without asking
```

Examples:

```
kimtape KB9V01A.WAV KB9V01A.BIN                  decode
kimtape -M -A2000 -D01 KB9V01A.BIN TAPE.WAV      encode, $2000, ID 01
kimtape -M -B3 -S44100 -W16 PROG.BIN TAPE.WAV    HYPERTAPE 3x, 44.1 kHz 16 bit
kimtape -P1 STEREO.WAV PROG.BIN                  decode left channel only
```

Switches start with `-`. On Windows `/` also works, as in the DOS original.

## What is new compared to the DOS version

- **Decoding accepts any WAV format:** any sample rate (16 kHz and up,
  e.g. 44100, 48000, 96000), 8/16/24/32 bit integer or 32/64 bit float
  samples, WAVE_FORMAT_EXTENSIBLE, mono or stereo. Extra chunks (LIST,
  fact, ...) are skipped. The decoder is the original algorithm, but it
  measures cycle lengths in time instead of samples at 22050 Hz.
- **Automatic level adjustment:** DC offset is removed and the level is
  normalised, so quiet 16-bit recordings decode. `-N` gives the original
  fixed levels; `-F` and `-H` still work on top of either.
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

## Building

```
fpc -O2 kimtape.pas
```

Free Pascal 3.2 or later; no other units needed. To build the Windows
executable from Linux, install the win64 units and run
`fpc -Twin64 -O2 kimtape.pas`.

## Verification

- Decoding `KB9V01A.WAV` gives a file identical to the original's output.
- The original (run in DOSBox) encoded eight test cases: KIM-1, HYPERTAPE
  3x, 6x sine, inverted, SYM-1 square and sine, VOC and RAW. All eight
  match the port's output byte for byte (apart from the stray WAV byte).
- The same recording, resampled to 44.1/48/96 kHz as 16/24/32 bit and
  float, stereo and quiet with DC offset, decodes to the identical program.

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
