{ KIMTAPE - KIM-1 / SYM-1 tape conversion utility

  Free Pascal port of KIMTAPE 0.5 (17-May-04, DX-Forth, public domain).
  Same command line switches and the same tape encoding as the original.

  Additions compared to the DOS original:
  - New default decoder for KIM-1/HYPERTAPE tapes: a frequency
    discriminator with a bit clock, like the PLL in the KIM-1. It ignores
    waveform distortion, measures tone frequencies, speed and bit period
    from the tape, and repairs invalid hex characters using bit
    confidence (checksum verifies). -K selects the original decoder.
  - Decoding accepts WAV files of any sample rate (11025 .. 192000)
    and any common sample format: 8, 16, 24, 32 bit integer PCM,
    32/64 bit float, WAVE_FORMAT_EXTENSIBLE, mono or stereo.
    Timing is measured in time, not in samples, so all rates work
    with the original decoding algorithm.
  - Automatic DC offset removal and level normalisation (-N disables).
  - Stereo: channels are mixed, or pick one with -P1 (left) / -P2 (right).
  - VOC input with block types 1, 2, 3, 8 and 9; RAW input at any rate (-S).
  - Encoding can write other sample rates and 16 bit samples (-S -W).
    Default output is identical to the original: 22050 Hz 8 bit mono.
  - -O overwrites an existing output file without asking.

  Build:  fpc -O2 kimtape.pas

  Copyright (c) 2026 Hans Otten. MIT License, see LICENSE.
  The original KIMTAPE 0.5 is public domain.
}

program kimtape;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math;

const
  TITLE = 'KIMTAPE version 1.0  (Free Pascal port of KIMTAPE 0.5)';

  SYNC = 22;   { ASCII SYN }
  EOT  = 4;    { ASCII EOT }
  BASERATE = 22050; { the original works at 22050 samples/sec }

  { Waveform tables at 22050 samples/sec, 8 bit unsigned.
    First half: normal polarity, second half: inverted polarity.
    Taken byte for byte from the original KIMTAPE screens 41..46. }
  Bit0SqrKim: array[0..17] of Byte = (   { 1 1/2 cycle 3600 Hz - square equalized }
    $8C, $DC, $FF, $73, $23, $00, $8C, $DC, $FF,
    $73, $23, $00, $8C, $DC, $FF, $73, $23, $00);
  Bit1SqrKim: array[0..17] of Byte = (   { 1 cycle 2400 Hz - square equalized }
    $9D, $DC, $F5, $FF, $97, $55, $2B, $11, $00,
    $62, $23, $0A, $00, $68, $AA, $D4, $EE, $FF);
  Bit0SinKim: array[0..17] of Byte = (   { 1 1/2 cycle 3600 Hz - sine }
    $BE, $FF, $BE, $41, $00, $41, $BE, $FF, $BE,
    $41, $00, $41, $BE, $FF, $BE, $41, $00, $41);
  Bit1SinKim: array[0..17] of Byte = (   { 1 cycle 2400 Hz - sine }
    $D2, $FE, $EF, $AC, $54, $11, $02, $2E, $80,
    $2D, $01, $10, $53, $AB, $EE, $FD, $D1, $7F);
  Bit0SqrSym: array[0..31] of Byte = (   { 1/2 cycle 700 Hz - square equalized }
    $9F, $C7, $DE, $EE, $F8, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,
    $60, $39, $21, $11, $07, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00);
  Bit1SqrSym: array[0..31] of Byte = (   { 1 cycle 1400 Hz - square equalized }
    $9F, $C7, $DE, $EE, $F8, $FF, $60, $39, $21, $11, $07, $00, $00, $00, $00, $00,
    $60, $39, $21, $11, $07, $00, $9F, $C7, $DE, $EE, $F8, $FF, $FF, $FF, $FF, $FF);
  Bit0SinSym: array[0..31] of Byte = (   { 1/2 cycle 700 Hz - sine }
    $97, $AE, $C3, $D5, $E5, $F2, $FA, $FF, $FF, $FA, $F2, $E5, $D5, $C3, $AE, $97,
    $68, $51, $3C, $2A, $1A, $0D, $05, $00, $00, $05, $0D, $1A, $2A, $3C, $51, $68);
  Bit1SinSym: array[0..31] of Byte = (   { 1 cycle 1400 Hz - sine }
    $B7, $E3, $FC, $FC, $E3, $B7, $5B, $3A, $1F, $0B, $01, $01, $0B, $1F, $3A, $5B,
    $48, $1C, $03, $03, $1C, $48, $A4, $C5, $E0, $F4, $FE, $FE, $F4, $E0, $C5, $A4);

type
  EKimAbort = class(Exception);   { error: message already printed, abort }
  EEndOfData = class(Exception);  { end of audio data (THROW 1 in the original) }

  TWaveType = (wtWAV, wtVOC, wtRAW);

{ ---------------------------------------------------------------------- }
{ Options and state (names follow the original Forth variables)          }
{ ---------------------------------------------------------------------- }

var
  SAddr: Word;            { start address }
  EAddr: Word;            { end address + 1 }
  Checksum: Word;         { 16 bit checksum (Forth cell) }
  ConOut: Boolean;        { -C console output }
  Decoding: Boolean;      { false = encode (-M) }
  FileID: Word;           { program ID }
  Polarity: Boolean;      { wave polarity, true = inverted }
  LastCycle: Integer;     { last cycle weight }
  LeadTime: Integer;      { leader in seconds }
  SampleCount: Integer;   { samples in current half cycle }
  Speed: Integer;         { HYPERTAPE speed }
  SymMode: Boolean;       { -U SYM-1 high speed format }
  Sine: Boolean;          { -T sine tone }
  Wave: TWaveType;        { -V -R wave type }
  DecodeCount: Int64;     { bytes decoded }

  Bias: Integer = 0;      { -F DC offset adjust }
  Hysteresis: Integer = 3;{ -H hysteresis level }
  MaxWave: Integer = 7;   { max samples (at 22050) for a high tone, -G adjusts }
  SilenceMax: Integer = 130;
  SilenceMin: Integer = 124;

  { additions }
  Normalize: Boolean = True;   { -N disables }
  ChanSel: Integer = 0;        { -P 0=mix 1=left 2=right }
  SampleRate: Integer = 0;     { -S output rate (encode) / RAW input rate }
  OutBits: Integer = 8;        { -W 8 or 16 }
  Overwrite: Boolean = False;  { -O }

  InFile, OutFile: string;
  InFiles: array of string;      { several recordings: rec1+rec2+... }
  OutStream: TFileStream = nil;

{ ---------------------------------------------------------------------- }
{ Error handling and messages                                            }
{ ---------------------------------------------------------------------- }

procedure Abort2(const Msg: string);
begin
  Write(Msg, ' ... aborting');
  raise EKimAbort.Create(Msg);
end;

procedure BadOption;
begin
  WriteLn;
  Abort2('Invalid option');
end;

function H4(V: LongInt): string;
begin
  Result := IntToHex(V and $FFFF, 4);
end;

function H2(V: LongInt): string;
begin
  Result := IntToHex(V and $FF, 2);
end;

procedure Help;
begin
  WriteLn;
  WriteLn('Use:  KIMTAPE [options] infile[.typ] [outfile[.typ]]');
  WriteLn;
  WriteLn('-C    console output              -M    make wavefile');
  WriteLn('-Bn   HYPERTAPE speed  2x 3x 6x   -I    invert wavefile');
  WriteLn('-U    SYM-1 high speed format     -V    VOC wavefile');
  WriteLn('-Fn   offset  -127 to 127         -R    RAW wavefile');
  WriteLn('-Hn   hysteresis  0 to 127        -Ln   leader (sec)');
  WriteLn('-Gn   timing  -2 to 2             -T    sine tone');
  WriteLn('-An   load address (hex)          -Dn   prog ID (hex)');
  WriteLn;
  WriteLn('Additional options in this version:');
  WriteLn('-K    classic decoder (zero crossings, as KIMTAPE 0.5)');
  WriteLn('-N    no automatic DC/level adjust  (-K and SYM-1 decoding)');
  WriteLn('-Pn   channel  0=mix 1=left 2=right  (decode, stereo files)');
  WriteLn('-Sn   sample rate: output wavefile (encode, default 22050)');
  WriteLn('      or RAW input file (decode, default 22050)');
  WriteLn('-Wn   sample width 8 or 16 bits  (encode, default 8)');
  WriteLn('-O    overwrite output file without asking');
  WriteLn;
  WriteLn('Several recordings of the same tape can be combined:');
  WriteLn('  KIMTAPE rec1.wav+rec2.wav+rec3.wav outfile');
  WriteLn;
  WriteLn('default: decode WAV file, KIM-1 format');
  WriteLn('         load address=0200, file ID=00');
  WriteLn;
  WriteLn('Conversion utility for KIM-1 and SYM-1 format audio tapes.');
  WriteLn('Input WAV files may use any sample rate (44100, 48000, ...),');
  WriteLn('8/16/24/32 bit integer or float samples, mono or stereo.');
  WriteLn('Output is an 8-bit mono WAV, VOC or RAW wavefile recorded at');
  WriteLn('22,050 samples per second unless -S / -W are given.');
  raise EKimAbort.Create('');
end;

{ ---------------------------------------------------------------------- }
{ Audio input                                                            }
{ ---------------------------------------------------------------------- }

type
  TSampleFmt = (sfInt, sfFloat);

  TSegment = record
    Offset: Int64;      { file offset, -1 = silence }
    Frames: Int64;
  end;

  TAudioReader = class
  private
    FS: TFileStream;
    Buf: array[0..65535] of Byte;
    BufPos, BufLen: Integer;
    Segs: array of TSegment;
    SegIdx: Integer;
    SegFramesLeft: Int64;
    SegBytesLeft: Int64;
    function FillBuf: Boolean;
    function NextSeg: Boolean;
    procedure AddSeg(AOffset, AFrames: Int64);
    procedure ParseWAV;
    procedure ParseVOC;
  public
    Fmt: TSampleFmt;
    Bits, Channels, FrameBytes, Rate: Integer;
    Kind: string;
    Position: Int64;      { frames read so far }
    TotalFrames: Int64;
    constructor Create(const FileName: string; ForceRaw: Boolean; RawRate: Integer);
    destructor Destroy; override;
    procedure Rewind;
    function ReadFrame(out X: Double): Boolean;  { X in -1 .. 1 }
  end;

constructor TAudioReader.Create(const FileName: string; ForceRaw: Boolean; RawRate: Integer);
var
  Raw: array[0..19] of Byte;
  Hdr: string;
  N, I: Integer;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  FillChar(Raw, SizeOf(Raw), 0);
  N := FS.Read(Raw, SizeOf(Raw));
  FS.Position := 0;
  SetLength(Hdr, 20);
  for I := 0 to 19 do Hdr[I + 1] := Chr(Raw[I]);
  if (not ForceRaw) and (N >= 12) and (Copy(Hdr, 1, 4) = 'RIFF') and (Copy(Hdr, 9, 4) = 'WAVE') then
    ParseWAV
  else if (not ForceRaw) and (N >= 20) and (Copy(Hdr, 1, 19) = 'Creative Voice File') then
    ParseVOC
  else
  begin
    { RAW: 8 bit unsigned mono }
    Kind := 'RAW';
    Fmt := sfInt; Bits := 8; Channels := 1; FrameBytes := 1;
    if RawRate > 0 then Rate := RawRate else Rate := BASERATE;
    AddSeg(0, FS.Size);
  end;
  Rewind;
end;

destructor TAudioReader.Destroy;
begin
  FS.Free;
  inherited;
end;

procedure TAudioReader.AddSeg(AOffset, AFrames: Int64);
begin
  if AFrames <= 0 then Exit;
  SetLength(Segs, Length(Segs) + 1);
  Segs[High(Segs)].Offset := AOffset;
  Segs[High(Segs)].Frames := AFrames;
  Inc(TotalFrames, AFrames);
end;

procedure TAudioReader.ParseWAV;
var
  ID: array[0..3] of Char;
  Size, Pos, DataOfs, DataSize: Int64;
  CSize: LongWord;
  Tag, Ch, BlockAlign, BPS: Word;
  SRate: LongWord;
  HaveFmt: Boolean;
  Ext: array[0..23] of Byte;
begin
  Kind := 'WAV';
  HaveFmt := False;
  DataOfs := -1; DataSize := 0;
  Tag := 0; Ch := 0; BlockAlign := 0; BPS := 0; SRate := 0;
  Size := FS.Size;
  Pos := 12;
  while Pos + 8 <= Size do
  begin
    FS.Position := Pos;
    FS.ReadBuffer(ID, 4);
    CSize := LEtoN(FS.ReadDWord);
    if ID = 'fmt ' then
    begin
      Tag := LEtoN(FS.ReadWord);
      Ch := LEtoN(FS.ReadWord);
      SRate := LEtoN(FS.ReadDWord);
      FS.ReadDWord;                         { byte rate }
      BlockAlign := LEtoN(FS.ReadWord);
      BPS := LEtoN(FS.ReadWord);
      if (Tag = $FFFE) and (CSize >= 40) then
      begin
        FS.ReadBuffer(Ext, 24);             { cbSize, valid bits, mask, GUID }
        Tag := Ext[8] or (Ext[9] shl 8);    { first two bytes of sub format GUID }
      end;
      HaveFmt := True;
    end
    else if ID = 'data' then
    begin
      DataOfs := Pos + 8;
      DataSize := CSize;
      { size 0 or past end of file: streaming writer, use rest of file }
      if (DataSize = 0) or (DataSize = $FFFFFFFF) or (DataOfs + DataSize > Size) then
        DataSize := Size - DataOfs;
      if HaveFmt then Break;
    end;
    Pos := Pos + 8 + CSize + (CSize and 1);
  end;
  if not HaveFmt then Abort2('WAV file has no format chunk');
  if DataOfs < 0 then Abort2('WAV file has no data chunk');
  case Tag of
    1: Fmt := sfInt;
    3: Fmt := sfFloat;
  else
    Abort2('WAV format ' + IntToStr(Tag) + ' not supported (PCM or float only)');
  end;
  if (Fmt = sfInt) and not (BPS in [8, 16, 24, 32]) then
    Abort2('WAV with ' + IntToStr(BPS) + ' bits per sample not supported');
  if (Fmt = sfFloat) and not (BPS in [32, 64]) then
    Abort2('Float WAV with ' + IntToStr(BPS) + ' bits per sample not supported');
  if (Ch < 1) or (SRate < 1000) then Abort2('Invalid WAV format chunk');
  Bits := BPS; Channels := Ch; Rate := SRate;
  FrameBytes := (Bits div 8) * Channels;
  if BlockAlign > FrameBytes then FrameBytes := BlockAlign;
  AddSeg(DataOfs, DataSize div FrameBytes);
end;

procedure TAudioReader.ParseVOC;
var
  HdrSize: Word;
  Pos, Size, BLen, Rest: Int64;
  BType, TC, Pack, Mode: Byte;
  B3: array[0..2] of Byte;
  ThisRate, ThisBits, ThisCh: Integer;
  ExtRate, ExtCh: Integer;
  Codec: Word;
  TC16: Word;

  procedure SetFormat(R, B, C: Integer);
  begin
    if Rate = 0 then
    begin
      Rate := R; Bits := B; Channels := C;
      FrameBytes := (B div 8) * C;
    end
    else if (B <> Bits) or (C <> Channels) then
      Abort2('VOC file mixes different sample formats');
  end;

begin
  Kind := 'VOC';
  Fmt := sfInt;
  Rate := 0; Bits := 8; Channels := 1; FrameBytes := 1;
  ExtRate := 0; ExtCh := 0;
  Size := FS.Size;
  FS.Position := 20;
  HdrSize := LEtoN(FS.ReadWord);
  Pos := HdrSize;
  while Pos < Size do
  begin
    FS.Position := Pos;
    BType := FS.ReadByte;
    if BType = 0 then Break;
    FS.ReadBuffer(B3, 3);
    BLen := B3[0] or (B3[1] shl 8) or (B3[2] shl 16);
    if Pos + 4 + BLen > Size then BLen := Size - Pos - 4;
    if BType in [1, 2, 9] then
    begin
      { KIMTAPE 0.5 wrote VOC blocks > 16 MB with a wrapped 3 byte size }
      Rest := Size - (Pos + 4 + BLen);
      if (Rest >= $1000000) and ((Rest mod $1000000) <= 1) then
        BLen := BLen + Rest - (Rest mod $1000000);
    end;
    case BType of
      1: begin  { sound data }
           TC := FS.ReadByte; Pack := FS.ReadByte;
           if Pack <> 0 then Abort2('Compressed VOC data not supported');
           if ExtRate > 0 then
           begin
             ThisRate := ExtRate; ThisCh := ExtCh;
             ExtRate := 0;
           end
           else
           begin
             { KIMTAPE wrote time constant $D3 (22222 Hz) for 22050 Hz data }
             if TC = $D3 then ThisRate := BASERATE
             else ThisRate := Round(1000000 / (256 - TC));
             ThisCh := 1;
           end;
           SetFormat(ThisRate, 8, ThisCh);
           AddSeg(Pos + 6, (BLen - 2) div FrameBytes);
         end;
      2: if Rate > 0 then AddSeg(Pos + 4, BLen div FrameBytes);   { continuation }
      3: begin  { silence }
           TC16 := LEtoN(FS.ReadWord);
           if Rate = 0 then
           begin
             TC := FS.ReadByte;
             SetFormat(Round(1000000 / (256 - TC)), 8, 1);
           end;
           AddSeg(-1, Int64(TC16) + 1);
         end;
      8: begin  { extended info for next type 1 block }
           TC16 := LEtoN(FS.ReadWord); Pack := FS.ReadByte; Mode := FS.ReadByte;
           if Pack <> 0 then Abort2('Compressed VOC data not supported');
           ExtCh := Mode + 1;
           ExtRate := Round(256000000 / (65536 - TC16) / ExtCh);
         end;
      9: begin  { new format sound data }
           ThisRate := LEtoN(FS.ReadDWord);
           ThisBits := FS.ReadByte;
           ThisCh := FS.ReadByte;
           Codec := LEtoN(FS.ReadWord);
           if not (((Codec = 0) and (ThisBits = 8)) or ((Codec = 4) and (ThisBits = 16))) then
             Abort2('VOC codec ' + IntToStr(Codec) + ' not supported');
           SetFormat(ThisRate, ThisBits, ThisCh);
           AddSeg(Pos + 16, (BLen - 12) div FrameBytes);
         end;
    end;
    Pos := Pos + 4 + BLen;
  end;
  if Rate = 0 then Abort2('VOC file contains no sound data');
end;

procedure TAudioReader.Rewind;
begin
  SegIdx := -1;
  SegFramesLeft := 0;
  SegBytesLeft := 0;
  BufPos := 0; BufLen := 0;
  Position := 0;
end;

function TAudioReader.NextSeg: Boolean;
begin
  Inc(SegIdx);
  Result := SegIdx <= High(Segs);
  if not Result then Exit;
  SegFramesLeft := Segs[SegIdx].Frames;
  BufPos := 0; BufLen := 0;
  if Segs[SegIdx].Offset >= 0 then
  begin
    FS.Position := Segs[SegIdx].Offset;
    SegBytesLeft := SegFramesLeft * FrameBytes;
  end
  else
    SegBytesLeft := 0;
end;

function TAudioReader.FillBuf: Boolean;
var
  Keep, Want, Got: Integer;
begin
  Keep := BufLen - BufPos;
  if Keep > 0 then Move(Buf[BufPos], Buf[0], Keep);
  BufPos := 0; BufLen := Keep;
  Want := SizeOf(Buf) - Keep;
  if Want > SegBytesLeft then Want := SegBytesLeft;
  Got := 0;
  if Want > 0 then Got := FS.Read(Buf[Keep], Want);
  Inc(BufLen, Got);
  Dec(SegBytesLeft, Got);
  Result := BufLen - BufPos >= FrameBytes;
end;

function TAudioReader.ReadFrame(out X: Double): Boolean;

  function GetCh(P: Integer): Double;
  var
    I: LongInt;
    S: Single;
    D: Double;
  begin
    if Fmt = sfFloat then
    begin
      if Bits = 32 then
      begin
        Move(Buf[P], S, 4);
        Result := S;
      end
      else
      begin
        Move(Buf[P], D, 8);
        Result := D;
      end;
      Exit;
    end;
    case Bits of
      8:  Result := (Buf[P] - 128) / 128;
      16: Result := SmallInt(Buf[P] or (Buf[P + 1] shl 8)) / 32768;
      24: begin
            I := Buf[P] or (Buf[P + 1] shl 8) or (Buf[P + 2] shl 16);
            if I >= $800000 then I := I - $1000000;
            Result := I / 8388608;
          end;
    else
      Result := LongInt(LongWord(Buf[P]) or (LongWord(Buf[P + 1]) shl 8) or
        (LongWord(Buf[P + 2]) shl 16) or (LongWord(Buf[P + 3]) shl 24)) / 2147483648.0;
    end;
  end;

var
  C, BW: Integer;
begin
  while SegFramesLeft <= 0 do
    if not NextSeg then
    begin
      Result := False;
      Exit;
    end;
  if Segs[SegIdx].Offset < 0 then
    X := 0   { silence block }
  else
  begin
    if (BufLen - BufPos < FrameBytes) and not FillBuf then
    begin
      SegFramesLeft := 0;   { truncated file }
      Result := ReadFrame(X);
      Exit;
    end;
    BW := Bits div 8;
    if Channels = 1 then
      X := GetCh(BufPos)
    else if ChanSel = 1 then
      X := GetCh(BufPos)
    else if ChanSel = 2 then
      X := GetCh(BufPos + BW)
    else
    begin
      X := 0;
      for C := 0 to Channels - 1 do X := X + GetCh(BufPos + C * BW);
      X := X / Channels;
    end;
    Inc(BufPos, FrameBytes);
  end;
  Dec(SegFramesLeft);
  Inc(Position);
  Result := True;
end;

{ ---------------------------------------------------------------------- }
{ Decoder (screens 59-74 of the original)                                }
{ ---------------------------------------------------------------------- }

var
  Reader: TAudioReader;
  LevelDC, LevelGain: Double;     { automatic level adjust }
  ThreshKim, ThreshSym: Double;   { tone thresholds in samples at the input rate }
  OutBuf: array of Byte;
  OutLen: Integer;

procedure FlushOut;
begin
  if (OutStream <> nil) and (OutLen > 0) then
    OutStream.WriteBuffer(OutBuf[0], OutLen);
  OutLen := 0;
end;

procedure WriteChar(B: Byte);
begin
  if OutLen >= Length(OutBuf) then FlushOut;
  OutBuf[OutLen] := B;
  Inc(OutLen);
end;

procedure EmitChar(B: Byte);   { ?EMIT }
begin
  if ConOut then
    if (B >= 32) and (B < 127) then Write(Chr(B)) else Write('.');
end;

{ Get sample as an 8 bit equivalent level 0..255 (128 = centre) }
function Sample: Double;
var
  X: Double;
begin
  if not Reader.ReadFrame(X) then raise EEndOfData.Create('');
  Inc(SampleCount);
  Result := 128 + (X - LevelDC) * LevelGain * 128;
end;

procedure SetLevels;
begin
  SilenceMin := EnsureRange((1275 - Hysteresis * 10) div 10 + Bias, 0, 255);
  SilenceMax := EnsureRange((1275 + Hysteresis * 10) div 10 + Bias, 0, 255);
end;

function SeekHalf: Integer;
begin
  SampleCount := 0;
  if Polarity then
    repeat until Sample > SilenceMax     { +ve going edge }
  else
    repeat until Sample < SilenceMin;    { -ve going edge }
  Result := SampleCount;
  Polarity := not Polarity;
end;

function SeekWhole: Integer;
begin
  Result := SeekHalf;
  Result := Result + SeekHalf;
end;

{ true = high tone }
function GetTone: Boolean;
begin
  if SymMode then
    Result := SeekHalf <= ThreshSym     { half cycle }
  else
    Result := SeekWhole <= ThreshKim;   { whole cycle }
end;

function GetBitKim: Integer;
var
  Sum, Last, W: Integer;
begin
  Sum := 0;
  repeat
    Last := LastCycle;
    Sum := Sum + Last;            { sum weights }
    W := 3;
    if GetTone then
    begin
      W := -3;                    { high tone }
      SeekHalf;                   { discard next half cycle }
    end;
    LastCycle := W;
  until W < Last;                 { start of new bit }
  Result := Ord(Sum > 0);
end;

function GetBitSym: Integer;
begin
  Result := 0;
  if GetTone then
  begin
    Result := 1;
    SeekHalf;                     { discard next half cycle }
  end;
end;

{ ---------------------------------------------------------------------- }
{ Frequency discriminator decoder (default for KIM-1 format)             }
{                                                                        }
{ Works like the phase locked loop in the KIM-1 itself instead of        }
{ counting zero crossings:                                               }
{ 1. band-pass 1700-4200 Hz (removes hum, hiss and tone harmonics),      }
{ 2. quadrature (FM) discriminator gives the tone frequency per sample,  }
{ 3. the two tone frequencies and the bit period are measured from the   }
{    tape, so wrong tape speed and all HYPERTAPE speeds are handled,     }
{ 4. a bit clock locks on the start of each bit (low->high tone change)  }
{    and decides each bit in the middle third of the bit:                }
{    0 = high high low, 1 = high low low.                                }
{ Each bit also gets a confidence value; invalid hex characters are      }
{ repaired by flipping the least certain bits, the checksum verifies.    }
{ ---------------------------------------------------------------------- }

var
  Classic: Boolean = False;      { -K: original zero crossing decoder }
  DecFs: Double;                 { rate of the stored discriminator output }
  DecDelay: Integer;             { filter delay in stored samples }
  ToneF: array of SmallInt;      { measured frequency (Hz) }
  ToneA: array of SmallInt;      { amplitude * 16384 }
  ToneHi: array of Byte;         { 1 = high tone }
  ToneCum: array of LongInt;     { prefix sum of ToneHi }
  ToneN: Integer;
  BitVal: array of Byte;         { decoded bit stream }
  BitConf: array of Single;      { 0 (unsure) .. 0.5 (certain) }
  BitPos: array of LongInt;      { bit start, stored sample index }
  BitCount, BitIdx: Integer;
  ByteConf: array[0..7] of Single;
  ByteTime: Double;
  Repaired, Unreadable: Integer;
  TotalRepaired, TotalUnreadable: Integer;

procedure Discriminate;
const
  BPLO = 1700; BPHI = 4200;
var
  Rate: Double;
  NB, NH, W, DecN, I, K, Cnt, Flush: Integer;
  HB, HH: array of Double;
  RX, RY: array of Double;     { rings stored twice: contiguous reads }
  RPr, RPi: array of Double;
  X, Y, Q, Zr, Zi, PZr, PZi, Pr, Pi_, Sr, Si, T: Double;
  PosX, PosY, PosP: Integer;
  PX, PH: PDouble;

  function Sinc(V: Double): Double;
  begin
    if V = 0 then Result := 1 else Result := Sin(Pi * V) / (Pi * V);
  end;

  function Blackman(I, N: Integer): Double;
  begin
    Result := 0.42 - 0.5 * Cos(2 * Pi * I / (N - 1)) + 0.08 * Cos(4 * Pi * I / (N - 1));
  end;

  procedure Store(F, A: Double);
  begin
    if ToneN >= Length(ToneF) then
    begin
      SetLength(ToneF, Length(ToneF) * 2 + 65536);
      SetLength(ToneA, Length(ToneF));
    end;
    ToneF[ToneN] := EnsureRange(Round(F), -32768, 32767);
    ToneA[ToneN] := EnsureRange(Round(A * 16384), 0, 32767);
    Inc(ToneN);
  end;

begin
  Rate := Reader.Rate;
  DecN := Max(1, Round(Rate / BASERATE));
  DecFs := Rate / DecN;
  { band-pass at the input rate, evaluated only for the kept samples;
    everything after it runs at the reduced rate DecFs (about 22 kHz) }
  NB := Round(8E-3 * Rate) or 1;      { 8 ms }
  NH := Round(2E-3 * DecFs) or 1;     { Hilbert transformer, 2 ms }
  W := Max(3, Trunc(150E-6 * DecFs)); { smoothing, 150 us }
  SetLength(HB, NB); SetLength(HH, NH);
  { taps stored reversed so that HB[k] pairs with the k-th oldest sample }
  for I := 0 to NB - 1 do
  begin
    T := I - (NB - 1) / 2;
    HB[NB - 1 - I] := (2 * BPHI / Rate * Sinc(2 * BPHI / Rate * T) -
              2 * BPLO / Rate * Sinc(2 * BPLO / Rate * T)) * Blackman(I, NB);
  end;
  for I := 0 to NH - 1 do
  begin
    K := I - (NH - 1) div 2;
    if Odd(K) then HH[NH - 1 - I] := 2 / (Pi * K) * Blackman(I, NH) else HH[NH - 1 - I] := 0;
  end;
  SetLength(RX, 2 * NB); SetLength(RY, 2 * NH); SetLength(RPr, W); SetLength(RPi, W);
  FillChar(RX[0], 2 * NB * SizeOf(Double), 0);
  FillChar(RY[0], 2 * NH * SizeOf(Double), 0);
  FillChar(RPr[0], W * SizeOf(Double), 0);
  FillChar(RPi[0], W * SizeOf(Double), 0);
  PosX := 0; PosY := 0; PosP := 0;
  PZr := 0; PZi := 0; Sr := 0; Si := 0;
  ToneN := 0;
  SetLength(ToneF, 0); SetLength(ToneA, 0);
  DecDelay := Round((NB - 1) / 2 / DecN + (NH - 1) / 2 + W / 2);
  Cnt := 0;
  Flush := NB + (NH + W) * DecN;
  Reader.Rewind;
  while True do
  begin
    if not Reader.ReadFrame(X) then
    begin
      if Flush = 0 then Break;
      X := 0;
      Dec(Flush);
    end;
    RX[PosX] := X;
    RX[PosX + NB] := X;
    PosX := PosX + 1;
    if PosX = NB then PosX := 0;
    Inc(Cnt);
    if Cnt mod DecN <> 0 then Continue;
    { band-pass: oldest sample is RX[PosX] }
    Y := 0;
    PX := @RX[PosX]; PH := @HB[0];
    for K := 0 to NB - 1 do
    begin
      Y := Y + PH^ * PX^;
      Inc(PX); Inc(PH);
    end;
    { Hilbert: quadrature component; in-phase is the centre sample }
    RY[PosY] := Y;
    RY[PosY + NH] := Y;
    PosY := PosY + 1;
    if PosY = NH then PosY := 0;
    Q := 0;
    K := 0;
    while K < NH do
    begin
      if HH[K] <> 0 then Q := Q + HH[K] * RY[PosY + K];
      Inc(K);
    end;
    Zr := RY[PosY + (NH - 1) div 2];
    Zi := Q;
    { phase step z[n] * conj(z[n-1]), averaged }
    Pr := Zr * PZr + Zi * PZi;
    Pi_ := Zi * PZr - Zr * PZi;
    PZr := Zr; PZi := Zi;
    Sr := Sr + Pr - RPr[PosP];
    Si := Si + Pi_ - RPi[PosP];
    RPr[PosP] := Pr; RPi[PosP] := Pi_;
    PosP := PosP + 1;
    if PosP = W then PosP := 0;
    Store(ArcTan2(Si, Sr) * DecFs / (2 * Pi), Sqrt(Zr * Zr + Zi * Zi));
  end;
end;

{ Measure tone frequencies, set the high/low decision }
procedure Calibrate(out FLo, FHi, KSpeed: Double);
const
  NA = 4096;
var
  AHist: array[0..NA - 1] of Int64;
  FHist: array[0..61] of Int64;   { 1500..4600 Hz, 50 Hz bins }
  I, J, Total: Integer;
  Acc, Target: Int64;
  Act, Thr: Integer;
  Sp, Fl, Fh, Ca, Cb, Na_, Nb_, Sc, Best, C: Double;
begin
  FillChar(AHist, SizeOf(AHist), 0);
  for I := 0 to ToneN - 1 do Inc(AHist[ToneA[I] * (NA - 1) div 32767]);
  Target := Max(1, ToneN div 100);       { 99th percentile }
  Acc := 0; I := NA - 1;
  while (I > 0) and (Acc + AHist[I] < Target) do
  begin
    Acc := Acc + AHist[I];
    Dec(I);
  end;
  Act := Round(0.25 * I * 32767 / (NA - 1));
  FillChar(FHist, SizeOf(FHist), 0);
  Total := 0;
  for I := 0 to ToneN - 1 do
    if (ToneA[I] > Act) and (ToneF[I] >= 1500) and (ToneF[I] < 4600) then
    begin
      Inc(FHist[(ToneF[I] - 1500) div 50]);
      Inc(Total);
    end;
  FLo := 2400; FHi := 3600;
  Best := -1;
  if Total > 0 then
  begin
    Sp := 2500;
    while Sp < 3400 do
    begin
      Ca := 0; Na_ := 0; Cb := 0; Nb_ := 0;
      for J := 0 to 61 do
      begin
        C := 1500 + J * 50 + 25;
        if (C > 1700) and (C < Sp) then begin Ca := Ca + C * FHist[J]; Na_ := Na_ + FHist[J]; end;
        if (C >= Sp) and (C < 4300) then begin Cb := Cb + C * FHist[J]; Nb_ := Nb_ + FHist[J]; end;
      end;
      if (Na_ > 0) and (Nb_ > 0) then
      begin
        Fl := Ca / Na_; Fh := Cb / Nb_;
        Sc := 0;
        for J := 0 to 61 do
        begin
          C := 1500 + J * 50 + 25;
          if (C > 1700) and (C < Sp) then Sc := Sc + Sqr(C - Fl) * FHist[J];
          if (C >= Sp) and (C < 4300) then Sc := Sc + Sqr(C - Fh) * FHist[J];
        end;
        Sc := Sc / (Na_ + Nb_);
        if (Best < 0) or (Sc < Best) then
        begin
          Best := Sc; FLo := Fl; FHi := Fh;
        end;
      end;
      Sp := Sp + 50;
    end;
  end;
  KSpeed := (FHi / 3600 + FLo / 2400) / 2;
  Thr := Round(Sqrt(FLo * FHi));
  SetLength(ToneHi, ToneN);
  SetLength(ToneCum, ToneN + 1);
  ToneCum[0] := 0;
  for I := 0 to ToneN - 1 do
  begin
    ToneHi[I] := Ord(ToneF[I] > Thr);
    ToneCum[I + 1] := ToneCum[I] + ToneHi[I];
  end;
  SetLength(ToneF, 0);
  SetLength(ToneA, 0);
end;

{ Most common bit period: high tone run + following low tone run }
function MeasureBitPeriod: Double;
var
  RunV: array of Byte;
  RunL: array of LongInt;
  NR, I, L, MinL, MaxL, Bin, BestBin: Integer;
  Hist: array of LongInt;
  BinW: Double;
begin
  RunV := nil; RunL := nil;
  SetLength(RunV, 1024); SetLength(RunL, 1024);
  NR := 0;
  MinL := Round(0.15E-3 * DecFs);
  I := 0;
  while I < ToneN do
  begin
    L := I;
    while (L < ToneN) and (ToneHi[L] = ToneHi[I]) do Inc(L);
    if L - I >= MinL then
    begin
      if NR >= Length(RunV) then
      begin
        SetLength(RunV, NR * 2); SetLength(RunL, NR * 2);
      end;
      RunV[NR] := ToneHi[I];
      RunL[NR] := L - I;
      Inc(NR);
    end;
    I := L;
  end;
  BinW := Max(1, Trunc(0.05E-3 * DecFs));
  SetLength(Hist, Trunc(25E-3 * DecFs / BinW) + 2);
  MaxL := Round(8E-3 * DecFs);
  for I := 0 to NR - 2 do
    if (RunV[I] = 1) and (RunV[I + 1] = 0) and (RunL[I] < MaxL) and (RunL[I + 1] < MaxL) then
    begin
      Bin := Trunc((RunL[I] + RunL[I + 1]) / BinW);
      if Bin <= High(Hist) then Inc(Hist[Bin]);
    end;
  BestBin := 0;
  for I := 1 to High(Hist) do
    if Hist[I] > Hist[BestBin] then BestBin := I;
  if Hist[BestBin] = 0 then Result := 0
  else Result := (BestBin + 0.5) * BinW;
end;

function HighFrac(A, B: Double): Double;
var
  IA, IB: Integer;
begin
  IA := EnsureRange(Trunc(A), 0, ToneN);
  IB := EnsureRange(Trunc(B), 0, ToneN);
  if IB <= IA then Exit(0);
  Result := (ToneCum[IB] - ToneCum[IA]) / (IB - IA);
end;

procedure AddBit(V: Integer; Conf: Double; Pos: Integer);
begin
  if BitCount >= Length(BitVal) then
  begin
    SetLength(BitVal, BitCount * 2 + 4096);
    SetLength(BitConf, Length(BitVal));
    SetLength(BitPos, Length(BitVal));
  end;
  BitVal[BitCount] := V;
  BitConf[BitCount] := Conf;
  BitPos[BitCount] := Pos;
  Inc(BitCount);
end;

{ Bit clock: lock on low->high tone changes, track the tape speed }
procedure ClockBits(PM: Double);
var
  Tr: array of LongInt;
  NT, I, J, Best, Miss, K: Integer;
  U0, P, Pred, Win, Tb, Prev, U, M: Double;
  HavePrev: Boolean;
begin
  Tr := nil;
  SetLength(Tr, 4096);
  NT := 0;
  for I := 1 to ToneN - 1 do
    if (ToneHi[I] = 1) and (ToneHi[I - 1] = 0) then
    begin
      if NT >= Length(Tr) then SetLength(Tr, NT * 2);
      Tr[NT] := I;
      Inc(NT);
    end;
  BitCount := 0;
  U0 := PM / 3; P := PM;
  HavePrev := False; K := 0; Miss := 0; Prev := 0;
  while True do
  begin
    if not HavePrev then
    begin
      if K >= NT then Break;
      Tb := Tr[K]; P := PM; Miss := 0;
    end
    else
    begin
      if Miss = 0 then Win := 0.15 * P else Win := 0.3 * P;
      Pred := Prev + P;
      { first transition at or after Pred - Win }
      I := 0; J := NT;
      while I < J do
        if Tr[(I + J) div 2] < Pred - Win then I := (I + J) div 2 + 1 else J := (I + J) div 2;
      Best := -1;
      while (I < NT) and (Tr[I] <= Pred + Win) do
      begin
        if (Best < 0) or (Abs(Tr[I] - Pred) < Abs(Tr[Best] - Pred)) then Best := I;
        Inc(I);
      end;
      if Best >= 0 then
      begin
        Tb := Tr[Best];
        Miss := 0;
        P := 0.95 * P + 0.05 * (Tb - Prev);   { follow tape speed }
        P := EnsureRange(P, 2.4 * U0, 3.6 * U0);
      end
      else
      begin
        Tb := Pred;
        Inc(Miss);
      end;
      if Tb + P > ToneN then Break;
    end;
    U := P / 3;
    M := HighFrac(Tb + U + 0.15 * U, Tb + 2 * U - 0.15 * U);   { middle third }
    if M > 0.5 then AddBit(0, M - 0.5, Round(Tb)) else AddBit(1, 0.5 - M, Round(Tb));
    Prev := Tb;
    HavePrev := True;
    if Miss > 8 then
    begin
      { lost lock: restart at the next tone change }
      I := 0; J := NT;
      while I < J do
        if Tr[(I + J) div 2] < Tb + P then I := (I + J) div 2 + 1 else J := (I + J) div 2;
      K := I;
      HavePrev := False;
    end;
  end;
end;

function SpeedName(PM: Double; KSpeed: Double): string;
var
  Chunks: Double;
begin
  { one unit is (6 div speed) chunks of 9 samples at 22050 Hz }
  Chunks := PM / DecFs * KSpeed / 3 / (9 / BASERATE);
  if Abs(Chunks - 6) < 0.6 then Result := 'KIM-1 1x'
  else if Abs(Chunks - 3) < 0.35 then Result := 'HYPERTAPE 2x'
  else if Abs(Chunks - 2) < 0.25 then Result := 'HYPERTAPE 3x'
  else if Abs(Chunks - 1) < 0.15 then Result := 'HYPERTAPE 6x'
  else Result := 'non-standard speed';
end;

procedure PrepareBits;
var
  FLo, FHi, KSpeed, PM: Double;
begin
  Discriminate;
  Calibrate(FLo, FHi, KSpeed);
  PM := MeasureBitPeriod;
  if PM <= 0 then
  begin
    WriteLn('tape:    no KIM-1 tones found');
    BitCount := 0;
  end
  else
  begin
    WriteLn(Format('tape:    tones %.0f/%.0f Hz, bit %.2f ms, %s',
      [FLo, FHi, PM / DecFs * 1000, SpeedName(PM, KSpeed)]));
    ClockBits(PM);
  end;
  SetLength(ToneHi, 0);
  SetLength(ToneCum, 0);
  BitIdx := 0;
end;

function GetBitPLL(out Conf: Single): Integer;
begin
  if BitIdx >= BitCount then raise EEndOfData.Create('');
  Result := BitVal[BitIdx];
  Conf := BitConf[BitIdx];
  Inc(BitIdx);
end;

function BitTime(I: Integer): Double;
begin
  if BitCount = 0 then Exit(0);
  I := EnsureRange(I, 0, BitCount - 1);
  Result := Max(0, BitPos[I] - DecDelay) / DecFs;
end;

function IsHexChar(C: Integer): Boolean;
begin
  Result := (C in [Ord('0')..Ord('9')]) or (C in [Ord('A')..Ord('F')]);
end;

{ Repair an invalid character by flipping its least certain bits }
function RepairChar(C: Integer; AllowSlash: Boolean; out Fixed: Integer): Boolean;
var
  Order: array[0..7] of Integer;
  I, J, T, A, B: Integer;

  function Ok(D: Integer): Boolean;
  begin
    Result := IsHexChar(D) or (AllowSlash and (D = Ord('/')));
  end;

begin
  for I := 0 to 7 do Order[I] := I;
  for I := 0 to 6 do
    for J := I + 1 to 7 do
      if ByteConf[Order[J]] < ByteConf[Order[I]] then
      begin
        T := Order[I]; Order[I] := Order[J]; Order[J] := T;
      end;
  Result := True;
  for A := 0 to 3 do
  begin
    Fixed := C xor (1 shl Order[A]);
    if Ok(Fixed) then Exit;
  end;
  for A := 0 to 2 do
    for B := A + 1 to 3 do
    begin
      Fixed := C xor (1 shl Order[A]) xor (1 shl Order[B]);
      if Ok(Fixed) then Exit;
    end;
  Result := False;
  Fixed := Ord('0');
end;

procedure ReportChar(C, Fixed: Integer; Ok: Boolean);
begin
  if Repaired + Unreadable <= 20 then
  begin
    WriteLn;
    if Ok then
      Write(Format('repaired character at %.2f s: $%s -> "%s"', [ByteTime, H2(C), Chr(Fixed)]))
    else
      Write(Format('unreadable character at %.2f s: $%s', [ByteTime, H2(C)]));
  end;
end;

{ Make an invalid hex character valid (PLL mode) }
function FixChar(C: Integer; AllowSlash: Boolean): Integer;
var
  Ok: Boolean;
begin
  Result := C;
  if IsHexChar(C) or (AllowSlash and (C = Ord('/'))) then Exit;
  Ok := RepairChar(C, AllowSlash, Result);
  if Ok then Inc(Repaired) else Inc(Unreadable);
  ReportChar(C, Result, Ok);
end;

function UsePLL: Boolean;
begin
  Result := not (Classic or SymMode);
end;

function GetBit: Integer;
var
  C: Single;
begin
  if UsePLL then
    Result := GetBitPLL(C)
  else if SymMode then Result := GetBitSym else Result := GetBitKim;
end;

function PosText: string;
begin
  if UsePLL then
    Result := Format(' at %.3f s', [BitTime(BitIdx)])
  else
    Result := Format(' at sample %d (%.3f s)', [Reader.Position, Reader.Position / Reader.Rate]);
end;

function DecodedText: string;
begin
  Result := 'Program ' + H2(FileID) + '  address ' + H4(SAddr);
  if SymMode then Result := Result + ' ' + H4(EAddr - 1);
  Result := Result + '  checksum ';
  if Checksum <> 0 then Result := Result + 'ERROR' else Result := Result + 'OK';
  Result := Result + '  ' + IntToStr(DecodeCount) + ' bytes';
  if Repaired > 0 then Result := Result + ', ' + IntToStr(Repaired) + ' chars repaired';
  if Unreadable > 0 then Result := Result + ', ' + IntToStr(Unreadable) + ' chars unreadable';
end;

procedure ShowDecoded;
begin
  WriteLn;
  Write(DecodedText);
end;

procedure ErrPosition(const What: string);
begin
  WriteLn;
  Write(What, PosText);
  ShowDecoded;
  Abort2('');
end;

procedure BadPattern;
begin
  ErrPosition('Bad pattern error');
end;

procedure Missing(const What: string);
begin
  ErrPosition('Missing ' + What);
end;

function DecodeByte: Integer;
var
  I: Integer;
  C: Single;
begin
  Result := 0;
  if UsePLL then
  begin
    ByteTime := BitTime(BitIdx);
    for I := 0 to 7 do
    begin
      Result := (Result shr 1) or (GetBitPLL(C) shl 7);
      ByteConf[I] := C;
    end;
  end
  else
  begin
    if SymMode then SeekHalf;      { discard start bit }
    for I := 1 to 8 do
      Result := (Result shr 1) or (GetBit shl 7);
  end;
  EmitChar(Result);
end;

{ Decode next byte ignoring end of data }
function DecodeByteNoEOF: Integer;
begin
  try
    Result := DecodeByte;
  except
    on EEndOfData do Result := 256;
  end;
end;

procedure Synchronize;
var
  B: Integer;
begin
  B := 0;
  repeat
    B := (B shr 1) or (GetBit shl 7);
  until B = SYNC;
  EmitChar(B);
end;

procedure FindSync;   { find 10 consecutive SYNC characters }
var
  N: Integer;
begin
  Synchronize;
  N := 9;
  repeat
    if DecodeByte = SYNC then
      Dec(N)
    else
    begin
      Polarity := not Polarity;   { try changing polarity }
      Synchronize;
      N := 9;
    end;
  until N = 0;
end;

procedure FindPreamble;
var
  B: Integer;
begin
  repeat
    FindSync;
    repeat
      B := DecodeByte;
    until (B <> SYNC) and (B <> 0);   { skip sync chars }
  until B = Ord('*');
end;

function AddChecksum(B: Integer): Integer;
begin
  Result := B and 255;
  Checksum := Word(Checksum + Result);
end;

function GetByteBin: Integer;     { @BYTE }
begin
  Result := AddChecksum(DecodeByte);
end;

function GetWordBin: Integer;     { @WORD }
begin
  Result := GetByteBin;
  Result := Result + GetByteBin * 256;
end;

function HexChar(U, C: Integer): Integer;
begin
  if UsePLL then C := FixChar(C, False);
  if C < Ord('0') then BadPattern;
  if C > Ord('9') then
  begin
    if C < Ord('A') then BadPattern;
    if C > Ord('F') then BadPattern;
    C := C - 7;
  end;
  Result := U * 16 + (C and 15);
end;

function GetAscByte: Integer;     { @ASCBYTE }
var
  U: Integer;
begin
  U := HexChar(0, DecodeByte);
  U := HexChar(U, DecodeByte);
  Result := AddChecksum(U);
end;

function GetAscWord: Integer;     { @ASCWORD }
begin
  Result := GetAscByte;
  Result := Result + GetAscByte * 256;
end;

procedure GetID;
begin
  if SymMode then FileID := GetByteBin else FileID := GetAscByte;
end;

procedure GetAddress;
begin
  if SymMode then
  begin
    SAddr := GetWordBin;
    EAddr := GetWordBin;
  end
  else
    SAddr := GetAscWord;
end;

function GetDataByte(out B: Integer): Boolean;
var
  C2: Integer;
begin
  Result := False;
  if SymMode then
  begin
    if Word(DecodeCount + SAddr) = EAddr then
    begin
      B := DecodeByte;
      if B <> Ord('/') then Missing('/');
      Exit;
    end;
    B := DecodeByte;
  end
  else
  begin
    B := DecodeByte;
    if UsePLL then B := FixChar(B, True);
    if B = Ord('/') then Exit;
    B := HexChar(0, B);
    C2 := DecodeByte;
    B := HexChar(B, C2);
  end;
  Result := True;
end;

procedure GetData;
var
  B: Integer;
begin
  DecodeCount := 0;
  while GetDataByte(B) do
  begin
    AddChecksum(B);
    if not ConOut then WriteChar(B);
    Inc(DecodeCount);
  end;
end;

procedure GetChecksum;
var
  Old, Got: Word;
begin
  Old := Checksum;
  if SymMode then Got := GetWordBin else Got := GetAscWord;
  Checksum := Word(Old - Got);
end;

procedure GetEnd;   { EOT chars are ignored for KIM/SYM compatibility }
begin
  DecodeByteNoEOF;
  DecodeByteNoEOF;
end;

{ Measure DC offset and level, set gain so peaks reach ~90% }
procedure MeasureLevels;
const
  NBins = 4096;
var
  Hist: array[0..NBins - 1] of Int64;
  X, Sum, Lo, Hi, Peak: Double;
  N, Acc, Target: Int64;
  I: Integer;
begin
  LevelDC := 0;
  LevelGain := 1;
  if not Normalize then Exit;
  FillChar(Hist, SizeOf(Hist), 0);
  Sum := 0; N := 0;
  Reader.Rewind;
  while Reader.ReadFrame(X) do
  begin
    Sum := Sum + X;
    Inc(N);
    I := EnsureRange(Trunc((X + 1) * (NBins / 2)), 0, NBins - 1);
    Inc(Hist[I]);
  end;
  Reader.Rewind;
  if N = 0 then Exit;
  LevelDC := Sum / N;
  { 0.1 and 99.9 percentiles: ignore clicks and dropouts }
  Target := Max(1, N div 1000);
  Acc := 0; I := 0;
  while (I < NBins - 1) and (Acc + Hist[I] < Target) do
  begin
    Acc := Acc + Hist[I];
    Inc(I);
  end;
  Lo := I / (NBins / 2) - 1;
  Acc := 0; I := NBins - 1;
  while (I > 0) and (Acc + Hist[I] < Target) do
  begin
    Acc := Acc + Hist[I];
    Dec(I);
  end;
  Hi := (I + 1) / (NBins / 2) - 1;
  Peak := Max(Hi - LevelDC, LevelDC - Lo);
  if Peak < 1E-4 then Peak := 1E-4;
  LevelGain := Min(0.9 / Peak, 200);
  WriteLn(Format('level:   DC offset %.1f%%  gain %.2f', [LevelDC * 100, LevelGain]));
end;

procedure DecodeCombined; forward;

procedure Decode;
var
  Fmt, ChanText: string;
begin
  if Length(InFiles) > 1 then
  begin
    DecodeCombined;
    Exit;
  end;
  Reader := TAudioReader.Create(InFile, Wave = wtRAW, SampleRate);
  try
    if Reader.Fmt = sfFloat then Fmt := 'float' else Fmt := 'bit';
    if Reader.Channels = 1 then ChanText := 'mono'
    else ChanText := IntToStr(Reader.Channels) + ' channels';
    WriteLn(Format('format:  %s %d Hz %d %s %s', [Reader.Kind, Reader.Rate, Reader.Bits, Fmt,
      ChanText]));
    if (Reader.Rate < 16000) and not UsePLL then
      WriteLn('warning: sample rate below 16000 Hz, decoding may fail');
    if UsePLL then
      PrepareBits
    else
      MeasureLevels;
    { The original counts samples at 22050/sec: a whole cycle of at most
      MAXWAVE samples is a high tone (KIM), a half cycle of at most
      MAXWAVE+3 samples is a high tone (SYM). Scale to the actual rate. }
    ThreshKim := (MaxWave + 0.5) * Reader.Rate / BASERATE;
    ThreshSym := (MaxWave + 3 + 0.5) * Reader.Rate / BASERATE;
    LastCycle := 0;
    while True do
    begin
      try
        FindPreamble;
      except
        on EEndOfData do Break;
      end;
      DecodeCount := 0;
      Repaired := 0; Unreadable := 0;
      try GetID; except on EEndOfData do Missing('ID'); end;
      Checksum := 0;
      try GetAddress; except on EEndOfData do Missing('address'); end;
      try GetData; except on EEndOfData do Missing('data'); end;
      try GetChecksum; except on EEndOfData do Missing('checksum'); end;
      GetEnd;
      ShowDecoded;
      if Repaired + Unreadable > 20 then
        Write(Format('  (%d more not listed)', [Repaired + Unreadable - 20]));
    end;
  finally
    FreeAndNil(Reader);
  end;
end;

{ ---------------------------------------------------------------------- }
{ Combining several recordings of the same tape                          }
{ (infile1+infile2+...): soft majority vote per bit, weighted by the     }
{ decoder's confidence, restricted to valid characters; remaining        }
{ checksum errors are resolved by trying alternatives for the least      }
{ certain characters.                                                    }
{ ---------------------------------------------------------------------- }

type
  TTapeChar = record
    B: Byte;
    C: array[0..7] of Single;
    T: Single;               { time in the recording }
  end;
  TTapeProg = array of TTapeChar;
  TTapeRec = array of TTapeProg;

{ Read all programs of the current recording as raw characters after '*' }
function CollectPrograms: TTapeRec;
var
  P: TTapeProg;
  N, Tail, Junk, I: Integer;
  B: Integer;
  Slash: Boolean;
begin
  Result := nil;
  while True do
  begin
    try
      FindPreamble;
    except
      on EEndOfData do Break;
    end;
    P := nil; N := 0; Tail := -1; Junk := 0;
    Slash := False;
    while True do
    begin
      try
        B := DecodeByte;
      except
        on EEndOfData do Break;
      end;
      if B in [SYNC, EOT, 0] then Inc(Junk) else Junk := 0;
      if Junk >= 3 then
      begin
        N := N - 2;   { drop the junk already stored }
        Break;
      end;
      if N >= Length(P) then SetLength(P, N * 2 + 256);
      P[N].B := B;
      for I := 0 to 7 do P[N].C[I] := ByteConf[I];
      P[N].T := ByteTime;
      Inc(N);
      if Slash then
      begin
        Dec(Tail);
        if Tail = 0 then Break;
      end
      else if (B = Ord('/')) and (N - 1 >= 6) and not Odd(N - 1) then
      begin
        Slash := True;
        Tail := 4;    { four checksum characters follow }
      end;
      if N > 2 * 65536 + 16 then Break;
    end;
    SetLength(P, Max(0, N));
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := P;
  end;
end;

function HexVal(C: Integer): Integer;
begin
  if C <= Ord('9') then Result := C - Ord('0') else Result := C - Ord('A') + 10;
end;

const
  CandChars: string = '0123456789ABCDEF/';

procedure CombineProgram(const Progs: array of TTapeProg; const RecNames: array of string;
  ProgNo: Integer);
const
  MAXU = 12;
var
  NR, L, I, J, R, Q, K, Bit, SlashPos, NData, Best, Second, NU, Combo, NCombo: Integer;
  V: array[0..7] of Double;
  Score: array of array of Double;   { [pos][candidate 0..16] }
  Choice, Choice2: array of Integer;
  Margin: array of Double;
  Valid: array of array of Boolean;  { [rec][pos] recording used here }
  Agree, Cnt: Integer;
  S, BestScore, Total: Double;
  UPos: array[0..MAXU - 1] of Integer = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  CkCalc, CkTape, Matches: Integer;
  BestCombo: Integer;
  Differ: Integer;
  ID, Addr: Integer;
  BestFlips, Flips, VaryMask, FirstMatch, LastByte: Integer;
  AltText: string;
  Unknown: array of Boolean;
  NUnk, UnkPos, UnkVal, BestUnk, FirstUnk: Integer;
  HasValid, Conflict, Found, UnkVaries: Boolean;

  function CharScore(Pos, Cand: Integer): Double;
  var
    Q2, D: Integer;
  begin
    D := Ord(CandChars[Cand + 1]);
    Result := 0;
    for Q2 := 0 to 7 do
      if Odd(D shr Q2) then Result := Result + V[Q2] else Result := Result - V[Q2];
  end;

  procedure Vote(Pos: Integer);
  var
    R2, Q2, N2: Integer;
    C, Wt: Double;
  begin
    for Q2 := 0 to 7 do V[Q2] := 0;
    for R2 := 0 to NR - 1 do
      if (Pos <= High(Progs[R2])) and Valid[R2][Pos] then
      begin
        { a recording that produced an invalid character here is unreliable }
        Wt := 1;
        if not (IsHexChar(Progs[R2][Pos].B) or (Progs[R2][Pos].B = Ord('/'))) then Wt := 0.25;
        { errors come in bursts: invalid neighbours lower the trust }
        for N2 := Pos - 3 to Pos + 3 do
          if (N2 <> Pos) and (N2 >= 0) and (N2 <= High(Progs[R2])) and
             not (IsHexChar(Progs[R2][N2].B) or (Progs[R2][N2].B in [Ord('/'), Ord('*')])) then
            Wt := Wt * 0.6;
        for Q2 := 0 to 7 do
        begin
          C := (Progs[R2][Pos].C[Q2] + 0.01) * Wt;   { small weight even when unsure }
          if Odd(Progs[R2][Pos].B shr Q2) then V[Q2] := V[Q2] + C else V[Q2] := V[Q2] - C;
        end;
      end;
  end;

  procedure ScoreAll;
  var
    P2, K2: Integer;
  begin
    for P2 := 0 to L - 1 do
    begin
      Vote(P2);
      for K2 := 0 to 16 do Score[P2][K2] := CharScore(P2, K2);
    end;
  end;

  { best candidate for a position; slash only where allowed }
  procedure Pick(P2: Integer; AllowSlash: Boolean; out B1, B2: Integer);
  var
    K2, Last: Integer;
  begin
    if AllowSlash then Last := 16 else Last := 15;
    B1 := 0; B2 := 1;
    if Score[P2][1] > Score[P2][0] then begin B1 := 1; B2 := 0; end;
    for K2 := 2 to Last do
      if Score[P2][K2] > Score[P2][B1] then begin B2 := B1; B1 := K2; end
      else if Score[P2][K2] > Score[P2][B2] then B2 := K2;
  end;

  function CharOf(P2: Integer): Integer;
  begin
    Result := Ord(CandChars[Choice[P2] + 1]);
  end;

  function ByteAt(P2: Integer): Integer;   { hex pair starting at P2 }
  begin
    Result := HexVal(CharOf(P2)) * 16 + HexVal(CharOf(P2 + 1));
  end;

  function CalcChecksums(out Calc, Tape: Integer): Boolean;
  var
    P2: Integer;
  begin
    Calc := 0;
    P2 := 2;
    while P2 < SlashPos do
    begin
      Calc := (Calc + ByteAt(P2)) and $FFFF;
      Inc(P2, 2);
    end;
    if SlashPos + 4 < L then
      Tape := ByteAt(SlashPos + 1) + ByteAt(SlashPos + 3) * 256
    else
      Tape := -1;
    Result := Calc = Tape;
  end;

begin
  NR := Length(Progs);
  L := 0;
  for R := 0 to NR - 1 do L := Max(L, Length(Progs[R]));
  if L < 6 then Exit;
  SetLength(Score, L, 17);
  SetLength(Choice, L);
  SetLength(Choice2, L);
  SetLength(Margin, L);
  SetLength(Valid, NR, L);
  for R := 0 to NR - 1 do
    for I := 0 to L - 1 do Valid[R][I] := I <= High(Progs[R]);

  { first pass, then drop recordings that lose sync (bit slip) }
  ScoreAll;
  for I := 0 to L - 1 do Pick(I, True, Choice[I], Choice2[I]);
  for R := 0 to NR - 1 do
  begin
    I := 0;
    while I + 16 <= Length(Progs[R]) do
    begin
      Agree := 0; Cnt := 0;
      for J := I to I + 15 do
      begin
        Inc(Cnt);
        if Progs[R][J].B = CharOf(J) then Inc(Agree);
      end;
      if (NR > 1) and (Agree * 4 < Cnt) then
      begin
        { from here this recording no longer agrees: ignore the rest }
        for J := I to L - 1 do Valid[R][J] := False;
        WriteLn(Format('  recording %d out of step from %.2f s, ignored from there',
          [R + 1, Progs[R][I].T]));
        Break;
      end;
      Inc(I, 16);
    end;
  end;
  ScoreAll;

  { find '/' : first even position >= 6 where '/' wins }
  SlashPos := -1;
  I := 6;
  while I < L do
  begin
    Pick(I, True, Best, Second);
    if Best = 16 then
    begin
      SlashPos := I;
      Break;
    end;
    Inc(I, 2);
  end;
  if SlashPos < 0 then SlashPos := L - (L mod 2);

  { choose characters: hex only, '/' only at its position }
  Differ := 0;
  for I := 0 to L - 1 do
  begin
    Pick(I, I = SlashPos, Best, Second);
    if I = SlashPos then begin Best := 16; Second := 16; end;
    Choice[I] := Best;
    Choice2[I] := Second;
    Margin[I] := Score[I][Best] - Score[I][Second];
    if I <> SlashPos then
      for R := 0 to NR - 1 do
        if Valid[R][I] and (Progs[R][I].B <> CharOf(I)) then
        begin
          Inc(Differ);
          Break;
        end;
  end;

  { warn when a recording ends at a different place: different program? }
  for R := 0 to NR - 1 do
  begin
    I := 6;
    while (I <= High(Progs[R])) and (Progs[R][I].B <> Ord('/')) do Inc(I, 2);
    if (NR > 1) and (I <= High(Progs[R])) and (I <> SlashPos) then
      WriteLn(Format('  warning: recording %d has %d bytes, the result %d - a different program?',
        [R + 1, (I - 6) div 2, (SlashPos - 6) div 2]));
  end;

  { warn when a recording mostly disagrees: different program? }
  for R := 0 to NR - 1 do
  begin
    Agree := 0; Cnt := 0;
    for I := 0 to Min(High(Progs[R]), SlashPos - 1) do
      if Valid[R][I] and IsHexChar(Progs[R][I].B) then
      begin
        Inc(Cnt);
        if Progs[R][I].B = CharOf(I) then Inc(Agree);
      end;
    if (NR > 1) and (Cnt > 16) and (Agree < Cnt * 8 div 10) then
      WriteLn(Format('  warning: recording %d agrees only %d%% with the result - a different program?',
        [R + 1, Agree * 100 div Cnt]));
  end;

  NData := (SlashPos - 6) div 2;
  ID := HexVal(CharOf(0)) * 16 + HexVal(CharOf(1));
  Addr := ByteAt(2) + ByteAt(4) * 256;

  { Classify characters: certain (valid in a recording, no valid
    contradiction), conflict (valid characters disagree) or unknown
    (no recording has a valid character here). }
  SetLength(Unknown, L);
  NUnk := 0;
  for I := 0 to L - 1 do
  begin
    Unknown[I] := False;
    if (I = SlashPos) or (I > SlashPos + 4) then Continue;
    HasValid := False; Conflict := False;
    for R := 0 to NR - 1 do
      if Valid[R][I] and IsHexChar(Progs[R][I].B) then
      begin
        HasValid := True;
        if Progs[R][I].B <> CharOf(I) then Conflict := True;
      end;
    if not HasValid then
    begin
      Unknown[I] := True;
      Inc(NUnk);
      Margin[I] := 1E9;               { solved separately }
    end
    else if not Conflict then
      Margin[I] := 1E9;               { certain }
  end;

  Matches := 0;
  if (SlashPos + 4 < L) and (not CalcChecksums(CkCalc, CkTape) or (NUnk > 0)) then
  begin
    { conflicts with the smallest margins are the alternatives to try }
    NU := 0;
    for I := 2 to Min(L - 1, SlashPos + 4) do
      if (I <> SlashPos) and (Margin[I] < 1E9) then
      begin
        J := NU;
        if NU < MAXU then Inc(NU) else if Margin[I] >= Margin[UPos[MAXU - 1]] then Continue
        else J := MAXU - 1;
        while (J > 0) and (Margin[UPos[J - 1]] > Margin[I]) do
        begin
          UPos[J] := UPos[J - 1];
          Dec(J);
        end;
        UPos[J] := I;
      end;
    UnkPos := -1;
    if NUnk = 1 then
      for I := 0 to L - 1 do if Unknown[I] then UnkPos := I;
    BestCombo := -1; BestFlips := 99; BestScore := 0; BestUnk := 0;
    VaryMask := 0; FirstMatch := -1; UnkVaries := False;
    if NUnk <= 1 then
      for Combo := 0 to (1 shl NU) - 1 do
      begin
        Total := 0; Flips := 0;
        for K := 0 to NU - 1 do
          if Odd(Combo shr K) then
          begin
            Q := Choice[UPos[K]]; Choice[UPos[K]] := Choice2[UPos[K]]; Choice2[UPos[K]] := Q;
            Total := Total - Margin[UPos[K]];
            Inc(Flips);
          end;
        Found := False; UnkVal := 0;
        if UnkPos < 0 then
          Found := CalcChecksums(CkCalc, CkTape)
        else
          { the checksum gives the value of the unknown character }
          for UnkVal := 0 to 15 do
          begin
            Choice[UnkPos] := UnkVal;
            if CalcChecksums(CkCalc, CkTape) then
            begin
              Found := True;
              Break;
            end;
          end;
        if Found then
        begin
          Inc(Matches);
          if FirstMatch < 0 then
          begin
            FirstMatch := Combo; FirstUnk := UnkVal;
          end
          else
          begin
            VaryMask := VaryMask or (Combo xor FirstMatch);
            if UnkVal <> FirstUnk then UnkVaries := True;
          end;
          if (Flips < BestFlips) or ((Flips = BestFlips) and (Total > BestScore)) then
          begin
            BestCombo := Combo; BestScore := Total; BestFlips := Flips; BestUnk := UnkVal;
          end;
        end;
        for K := 0 to NU - 1 do
          if Odd(Combo shr K) then
          begin
            Q := Choice[UPos[K]]; Choice[UPos[K]] := Choice2[UPos[K]]; Choice2[UPos[K]] := Q;
          end;
      end;
    if BestCombo >= 0 then
    begin
      for K := 0 to NU - 1 do
        if Odd(BestCombo shr K) then
        begin
          I := UPos[K];
          Q := Choice[I]; Choice[I] := Choice2[I]; Choice2[I] := Q;
        end;
      if UnkPos >= 0 then Choice[UnkPos] := BestUnk;
      LastByte := -1;
      for K := -1 to NU - 1 do
      begin
        if K < 0 then
        begin
          if UnkPos < 0 then Continue;
          I := UnkPos;
        end
        else
        begin
          if not Odd((BestCombo or VaryMask) shr K) then Continue;
          I := UPos[K];
        end;
        if I >= SlashPos then Continue;
        J := I - Ord(Odd(I));
        if J = LastByte then Continue;
        LastByte := J;
        if (K >= 0) and Odd(VaryMask shr K) then
        begin
          Q := Choice[I]; Choice[I] := Choice2[I];
          AltText := H2(ByteAt(J));
          Choice[I] := Q;
          WriteLn(Format('  byte $%s uncertain: %s (or %s)', [H4(Addr + (J - 6) div 2), H2(ByteAt(J)), AltText]));
        end
        else if (K < 0) and UnkVaries then
          WriteLn(Format('  byte $%s uncertain: %s (unreadable in all recordings)', [H4(Addr + (J - 6) div 2), H2(ByteAt(J))]))
        else if K < 0 then
          WriteLn(Format('  byte $%s unreadable, value %s from checksum', [H4(Addr + (J - 6) div 2), H2(ByteAt(J))]))
        else
          WriteLn(Format('  byte $%s conflict, set by checksum: %s', [H4(Addr + (J - 6) div 2), H2(ByteAt(J))]));
      end;
    end
    else
    begin
      for I := 0 to L - 1 do
        if Unknown[I] and (I < SlashPos) and (I >= 6) then
          WriteLn(Format('  byte $%s unreadable in all recordings', [H4(Addr + (I - 6) div 2)]));
    end;
  end;

  CalcChecksums(CkCalc, CkTape);
  for I := 0 to NData - 1 do
  begin
    if ConOut then Write(Chr(CharOf(6 + 2 * I)), Chr(CharOf(7 + 2 * I)))
    else WriteChar(ByteAt(6 + 2 * I));
  end;
  WriteLn;
  Write('Program ', H2(ID), '  address ', H4(Addr), '  checksum ');
  if CkCalc = CkTape then Write('OK') else Write('ERROR');
  Write('  ', NData, ' bytes');
  Write(Format(', %d recordings, %d characters differed', [NR, Differ]));
  if Matches > 1 then
    Write(Format(', %d combinations fit the checksum: fewest changes used', [Matches]));
  WriteLn;
end;

procedure DecodeCombined;
var
  Recs: array of TTapeRec;
  R, K, NP, N: Integer;
  Progs: array of TTapeProg;
  Names: array of string;
begin
  if SymMode or Classic then
    Abort2('Combining recordings needs the default decoder (no -U or -K)');
  SetLength(Recs, Length(InFiles));
  for R := 0 to High(InFiles) do
  begin
    Reader := TAudioReader.Create(InFiles[R], Wave = wtRAW, SampleRate);
    try
      Write(Format('%d: %s %d Hz  ', [R + 1, ExtractFileName(InFiles[R]), Reader.Rate]));
      PrepareBits;
      Recs[R] := CollectPrograms;
    finally
      FreeAndNil(Reader);
    end;
  end;
  NP := 0;
  for R := 0 to High(Recs) do NP := Max(NP, Length(Recs[R]));
  if NP = 0 then Exit;
  for K := 0 to NP - 1 do
  begin
    Progs := nil; Names := nil;
    N := 0;
    for R := 0 to High(Recs) do
      if K <= High(Recs[R]) then
      begin
        SetLength(Progs, N + 1); SetLength(Names, N + 1);
        Progs[N] := Recs[R][K];
        Names[N] := InFiles[R];
        Inc(N);
      end;
    CombineProgram(Progs, Names, K);
  end;
end;

{ ---------------------------------------------------------------------- }
{ Wave output with optional resampling                                   }
{ ---------------------------------------------------------------------- }

const
  RS_HALF = 16;        { kernel half width in source samples }
  RS_PHASES = 256;     { kernel table resolution }

var
  OutRate: Integer;
  WaveSize: Int64;     { data bytes written }
  Resample: Boolean;
  RsRatio: Double;     { source samples per output sample }
  RsCut: Double;       { cutoff relative to source Nyquist }
  RsKernel: array of Double;
  RsHist: array of Double;    { source history }
  RsHistStart: Int64;         { source index of RsHist[0] }
  RsHistLen: Integer;
  RsSrcCount: Int64;          { source samples pushed }
  RsOutCount: Int64;          { output samples produced }

const
  VOC_BLOCK_MAX = $FFFFF0;   { VOC block size field is only 3 bytes }

var
  VocBlockPos: array of Int64;    { file position of each block's size field }
  VocBlockSize: array of Int64;   { data bytes in each block }

function OutPosition: Int64;
begin
  Result := OutStream.Position + OutLen;
end;

{ Write one byte of wave data }
procedure DataByte(B: Byte);
var
  N: Integer;
begin
  if Wave = wtVOC then
  begin
    N := High(VocBlockSize);
    if VocBlockSize[N] >= VOC_BLOCK_MAX then
    begin
      { start a continuation block }
      WriteChar(2);
      SetLength(VocBlockPos, N + 2);
      SetLength(VocBlockSize, N + 2);
      Inc(N);
      VocBlockPos[N] := OutPosition;
      VocBlockSize[N] := 0;
      WriteChar(0); WriteChar(0); WriteChar(0);
    end;
    Inc(VocBlockSize[N]);
  end;
  WriteChar(B);
  Inc(WaveSize);
end;

procedure PutOutSample(V: Double);   { V in -1 .. 1 }
var
  I: Integer;
begin
  if OutBits = 16 then
  begin
    I := EnsureRange(Round(V * 32768), -32768, 32767);
    DataByte(I and $FF);
    DataByte((I shr 8) and $FF);
  end
  else
    DataByte(EnsureRange(Round(V * 128 + 128), 0, 255));
end;

procedure InitResampler;
var
  I: Integer;
  T, W, S: Double;
begin
  RsRatio := BASERATE / OutRate;
  RsCut := Min(1.0, OutRate / BASERATE);
  SetLength(RsKernel, RS_HALF * RS_PHASES * 2 + 2);
  for I := 0 to High(RsKernel) do
  begin
    T := I / RS_PHASES - RS_HALF;     { distance in source samples }
    if Abs(T) >= RS_HALF then W := 0
    else W := 0.42 + 0.5 * Cos(Pi * T / RS_HALF) + 0.08 * Cos(2 * Pi * T / RS_HALF);
    if T = 0 then S := 1 else S := Sin(Pi * RsCut * T) / (Pi * RsCut * T);
    RsKernel[I] := RsCut * S * W;
  end;
  SetLength(RsHist, 65536);
  RsHistStart := 0; RsHistLen := 0;
  RsSrcCount := 0; RsOutCount := 0;
end;

function Kernel(T: Double): Double;
var
  P: Double;
  I: Integer;
begin
  P := (T + RS_HALF) * RS_PHASES;
  I := Trunc(P);
  if (I < 0) or (I >= High(RsKernel)) then Exit(0);
  Result := RsKernel[I] + (RsKernel[I + 1] - RsKernel[I]) * (P - I);
end;

{ produce all output samples that have enough source lookahead }
procedure RsProduce(Final: Boolean; SrcLen: Int64);
var
  P, Acc: Double;
  C, K, K0, K1: Int64;
  Drop: Integer;
begin
  while True do
  begin
    P := RsOutCount * RsRatio;
    if Final then
    begin
      if P >= SrcLen then Break;
    end
    else if Floor(P) + RS_HALF >= RsSrcCount then Break;
    C := Floor(P);
    K0 := Max(C - RS_HALF + 1, RsHistStart);
    K1 := Min(C + RS_HALF, RsHistStart + RsHistLen - 1);
    Acc := 0;
    for K := K0 to K1 do
      Acc := Acc + RsHist[K - RsHistStart] * Kernel(K - P);
    PutOutSample(Acc);
    Inc(RsOutCount);
  end;
  { discard history no longer needed }
  Drop := Floor(RsOutCount * RsRatio) - RS_HALF - RsHistStart;
  if Drop > 4096 then
  begin
    Move(RsHist[Drop], RsHist[0], (RsHistLen - Drop) * SizeOf(Double));
    Dec(RsHistLen, Drop);
    Inc(RsHistStart, Drop);
  end;
end;

procedure RsPush(V: Double);
begin
  if RsHistLen >= Length(RsHist) then SetLength(RsHist, Length(RsHist) * 2);
  RsHist[RsHistLen] := V;
  Inc(RsHistLen);
  Inc(RsSrcCount);
  RsProduce(False, 0);
end;

procedure RsFinish;
var
  SrcLen: Int64;
  I: Integer;
begin
  SrcLen := RsSrcCount;
  for I := 1 to RS_HALF + 1 do
  begin
    if RsHistLen >= Length(RsHist) then SetLength(RsHist, Length(RsHist) * 2);
    RsHist[RsHistLen] := 0;
    Inc(RsHistLen);
    Inc(RsSrcCount);
  end;
  RsProduce(True, SrcLen);
end;

{ Write one 22050 Hz 8 bit sample }
procedure PutSample(B: Byte);
begin
  if Resample then
    RsPush((B - 128) / 128)
  else if OutBits = 16 then
    PutOutSample((B - 128) / 128)
  else
    DataByte(B);
end;

procedure WriteBytes(const Bytes: array of Byte);
var
  I: Integer;
begin
  for I := 0 to High(Bytes) do WriteChar(Bytes[I]);
end;

procedure WriteLE(V: LongWord; N: Integer);
var
  I: Integer;
begin
  for I := 1 to N do
  begin
    WriteChar(V and $FF);
    V := V shr 8;
  end;
end;

function VocOriginal: Boolean;   { original VOC header: 22050 Hz 8 bit }
begin
  Result := (OutRate = BASERATE) and (OutBits = 8);
end;

procedure WriteHeader;
const
  VocID = 'Creative Voice File';
var
  I: Integer;
begin
  case Wave of
    wtWAV:
      begin
        WriteBytes([Ord('R'), Ord('I'), Ord('F'), Ord('F')]);
        WriteLE(0, 4);
        WriteBytes([Ord('W'), Ord('A'), Ord('V'), Ord('E'), Ord('f'), Ord('m'), Ord('t'), Ord(' ')]);
        WriteLE(16, 4);
        WriteLE(1, 2);                          { PCM }
        WriteLE(1, 2);                          { mono }
        WriteLE(OutRate, 4);
        WriteLE(OutRate * (OutBits div 8), 4);  { byte rate }
        WriteLE(OutBits div 8, 2);              { block align }
        WriteLE(OutBits, 2);
        WriteBytes([Ord('d'), Ord('a'), Ord('t'), Ord('a')]);
        WriteLE(0, 4);
      end;
    wtVOC:
      begin
        for I := 1 to Length(VocID) do WriteChar(Ord(VocID[I]));
        WriteChar($1A);
        WriteLE(26, 2);
        SetLength(VocBlockPos, 1);
        SetLength(VocBlockSize, 1);
        VocBlockPos[0] := 27;
        VocBlockSize[0] := 0;
        if VocOriginal then
        begin
          WriteLE($010A, 2); WriteLE($1129, 2);  { version 1.10 }
          WriteChar(1); WriteLE(0, 3);          { sound data block }
          WriteChar($D3); WriteChar(0);         { time constant, 8 bit }
        end
        else
        begin
          WriteLE($0114, 2); WriteLE($111F, 2);  { version 1.20 }
          WriteChar(9); WriteLE(0, 3);          { new format sound data }
          WriteLE(OutRate, 4);
          WriteChar(OutBits); WriteChar(1);
          if OutBits = 16 then WriteLE(4, 2) else WriteLE(0, 2);
          WriteLE(0, 4);
        end;
      end;
    wtRAW: ;
  end;
end;

procedure PatchLE(Pos: Int64; V: LongWord; N: Integer);
var
  B: array[0..3] of Byte;
  I: Integer;
begin
  for I := 0 to N - 1 do
  begin
    B[I] := V and $FF;
    V := V shr 8;
  end;
  OutStream.Position := Pos;
  OutStream.WriteBuffer(B, N);
end;

procedure FinishWave;
var
  I: Integer;
begin
  case Wave of
    wtWAV:
      begin
        if Odd(WaveSize) then WriteChar(0);   { pad byte }
        FlushOut;
        PatchLE(4, 36 + WaveSize + (WaveSize and 1), 4);
        PatchLE(40, WaveSize, 4);
      end;
    wtVOC:
      begin
        WriteChar(0);                         { terminator }
        FlushOut;
        if VocOriginal then PatchLE(27, VocBlockSize[0] + 2, 3)
        else PatchLE(27, VocBlockSize[0] + 12, 3);
        for I := 1 to High(VocBlockPos) do
          PatchLE(VocBlockPos[I], VocBlockSize[I], 3);
      end;
    wtRAW: FlushOut;
  end;
end;

{ ---------------------------------------------------------------------- }
{ Encoder (screens 45-58 of the original)                                }
{ ---------------------------------------------------------------------- }

var
  ProgData: array of Byte;

procedure SendBit(const Tab: array of Byte);
var
  N, I, Ofs: Integer;
begin
  N := Length(Tab) div 2;
  if Polarity then Ofs := N else Ofs := 0;   { index to inverted bit data }
  for I := 0 to N - 1 do PutSample(Tab[Ofs + I]);
end;

procedure Leader;   { silence: LEADTIME * 408 * 6 * 9 samples }
var
  I: Int64;
begin
  for I := 1 to Int64(LeadTime) * 408 * 6 * 9 do PutSample($80);
end;

procedure HighTone;
var
  I: Integer;
begin
  for I := 1 to 6 div Speed do
  begin
    if Sine then SendBit(Bit0SinKim) else SendBit(Bit0SqrKim);
    Polarity := not Polarity;
  end;
end;

procedure LowTone;
var
  I: Integer;
begin
  for I := 1 to 6 div Speed do
    if Sine then SendBit(Bit1SinKim) else SendBit(Bit1SqrKim);
end;

procedure Bit0;
begin
  if SymMode then
  begin
    if Sine then SendBit(Bit0SinSym) else SendBit(Bit0SqrSym);
    Polarity := not Polarity;
  end
  else
  begin
    HighTone; HighTone; LowTone;
  end;
end;

procedure Bit1;
begin
  if SymMode then
  begin
    if Sine then SendBit(Bit1SinSym) else SendBit(Bit1SqrSym);
  end
  else
  begin
    HighTone; LowTone; LowTone;
  end;
end;

procedure SendByte(C: Integer);
var
  I: Integer;
begin
  if SymMode then Bit0;   { start bit }
  for I := 1 to 8 do
  begin
    if Odd(C) then Bit1 else Bit0;
    C := C shr 1;
  end;
end;

procedure PutByte(U: Integer);       { !BYTE }
begin
  SendByte(AddChecksum(U));
end;

procedure PutWord(U: Integer);       { !WORD }
begin
  PutByte(U and 255);
  PutByte((U shr 8) and 255);
end;

procedure PutAscByte(U: Integer);    { !ASCBYTE }
const
  HexDig: string = '0123456789ABCDEF';
begin
  U := AddChecksum(U);
  SendByte(Ord(HexDig[(U shr 4) + 1]));
  SendByte(Ord(HexDig[(U and 15) + 1]));
end;

procedure PutAscWord(U: Integer);    { !ASCWORD }
begin
  PutAscByte(U and 255);
  PutAscByte((U shr 8) and 255);
end;

procedure PutDataByte(U: Integer);
begin
  if SymMode then PutByte(U) else PutAscByte(U);
end;

procedure Encode;
var
  FS: TFileStream;
  Size, I: Int64;
begin
  FS := TFileStream.Create(InFile, fmOpenRead or fmShareDenyWrite);
  try
    Size := FS.Size;
    if Size + SAddr >= $10001 then
    begin
      WriteLn;
      Abort2('End address exceeds $FFFF');
    end;
    SetLength(ProgData, Size);
    if Size > 0 then FS.ReadBuffer(ProgData[0], Size);
  finally
    FS.Free;
  end;
  EAddr := Word(SAddr + Size);

  if SampleRate > 0 then OutRate := SampleRate else OutRate := BASERATE;
  Resample := OutRate <> BASERATE;
  if Resample then InitResampler;
  if (OutRate <> BASERATE) or (OutBits <> 8) then
    WriteLn(Format('format:  %d Hz %d bit mono', [OutRate, OutBits]));

  WaveSize := 0;
  WriteHeader;
  Leader;
  for I := 1 to IfThen(SymMode, 1000, 100) do SendByte(SYNC);   { preamble }
  SendByte(Ord('*'));
  PutDataByte(FileID);                   { ID }
  Checksum := 0;
  if SymMode then                        { address }
  begin
    PutWord(SAddr);
    PutWord(EAddr);
  end
  else
    PutAscWord(SAddr);
  for I := 0 to Size - 1 do PutDataByte(ProgData[I]);
  SendByte(Ord('/'));                    { checksum }
  if SymMode then PutWord(Checksum) else PutAscWord(Checksum);
  SendByte(EOT); SendByte(EOT);          { postamble }
  Leader;
  if Resample then RsFinish;
  FinishWave;
  WriteLn;
end;

{ ---------------------------------------------------------------------- }
{ Command line                                                           }
{ ---------------------------------------------------------------------- }

function ParseNum(const S: string; Hex: Boolean; Lo, Hi: Integer): Integer;
var
  Code: Integer;
  T: string;
begin
  T := S;
  if Hex then
  begin
    if (T <> '') and (T[1] = '$') then Delete(T, 1, 1);
    T := '$' + T;
  end;
  Val(T, Result, Code);
  if (Code <> 0) or (S = '') or (Result < Lo) or (Result > Hi) then BadOption;
end;

{ Process a switch string like "B3" or "CM" (characters after - or /) }
procedure SetOptions(S: string);
var
  C: Char;
  Rest: string;
begin
  while S <> '' do
  begin
    C := UpCase(S[1]);
    Rest := Copy(S, 2, MaxInt);
    S := '';    { options with a number consume the rest }
    case C of
      'A': SAddr := ParseNum(Rest, True, 0, $FFFF);
      'B': Speed := ParseNum(Rest, False, 2, 6);
      'D': FileID := ParseNum(Rest, True, 0, $FF);
      'F': begin Bias := ParseNum(Rest, False, -127, 127); SetLevels; end;
      'G': MaxWave := MaxWave + ParseNum(Rest, False, -2, 2);
      'H': begin Hysteresis := ParseNum(Rest, False, 0, 127); SetLevels; end;
      'L': LeadTime := ParseNum(Rest, False, 0, 3600);
      'P': ChanSel := ParseNum(Rest, False, 0, 2);
      'S': SampleRate := ParseNum(Rest, False, 4000, 384000);
      'W': begin
             OutBits := ParseNum(Rest, False, 8, 16);
             if not (OutBits in [8, 16]) then BadOption;
           end;
    else
      S := Rest;  { single letter flags may be combined }
      case C of
        'C': ConOut := True;
        'I': Polarity := True;
        'K': Classic := True;
        'M': Decoding := False;
        'N': Normalize := False;
        'O': Overwrite := True;
        'R': Wave := wtRAW;
        'T': Sine := True;
        'U': SymMode := True;
        'V': Wave := wtVOC;
        '?': Help;
      else
        BadOption;
      end;
    end;
  end;
end;

function WaveExt: string;
begin
  case Wave of
    wtVOC: Result := '.VOC';
    wtRAW: Result := '.RAW';
  else
    Result := '.WAV';
  end;
end;

{ add extension if the name has none }
function AddExt(const Name, Ext: string): string;
begin
  if ExtractFileExt(Name) = '' then Result := Name + Ext else Result := Name;
end;

procedure ParseCmd;
var
  I: Integer;
  A: string;
  Names: array of string;
  IsSwitch: Boolean;
begin
  Names := nil;
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    IsSwitch := (Length(A) > 1) and (A[1] = '-');
    {$IFDEF WINDOWS}
    if (Length(A) > 1) and (A[1] = '/') then IsSwitch := True;
    {$ENDIF}
    if IsSwitch then
      SetOptions(Copy(A, 2, MaxInt))
    else
    begin
      SetLength(Names, Length(Names) + 1);
      Names[High(Names)] := A;
    end;
  end;
  if Length(Names) = 0 then Help;
  { several recordings of one tape: rec1.wav+rec2.wav+... }
  InFiles := nil;
  A := Names[0];
  while A <> '' do
  begin
    I := Pos('+', A);
    if I = 0 then I := Length(A) + 1;
    if I > 1 then
    begin
      SetLength(InFiles, Length(InFiles) + 1);
      if Decoding then InFiles[High(InFiles)] := AddExt(Copy(A, 1, I - 1), WaveExt)
      else InFiles[High(InFiles)] := AddExt(Copy(A, 1, I - 1), '.PRG');
    end;
    Delete(A, 1, I);
  end;
  if Length(InFiles) = 0 then Help;
  if (Length(InFiles) > 1) and not Decoding then BadOption;
  InFile := InFiles[0];
  if Length(Names) > 1 then
    OutFile := Names[1]
  else
    OutFile := ChangeFileExt(ExtractFileName(InFile), '');
  if Decoding then OutFile := AddExt(OutFile, '.PRG')
  else OutFile := AddExt(OutFile, WaveExt);
end;

procedure OpenInFile;
var
  I: Integer;
begin
  WriteLn;
  for I := 0 to High(InFiles) do
  begin
    Write('infile:  ', InFiles[I]);
    if not FileExists(InFiles[I]) then
      Abort2(' file not found');
    WriteLn;
  end;
end;

procedure OpenOutFile;
var
  Answer: string;
begin
  Write('outfile: ', OutFile);
  if FileExists(OutFile) and not Overwrite then
  begin
    Write(' exists - overwrite? (y/n) ');
    ReadLn(Answer);
    if (Answer = '') or (UpCase(Answer[1]) <> 'Y') then Abort2('');
  end
  else
    WriteLn;
  try
    OutStream := TFileStream.Create(OutFile, fmCreate);
  except
    Abort2(' create error');
  end;
end;

procedure Defaults;
begin
  SymMode := False; Decoding := True; ConOut := False; Speed := 1; LeadTime := 5;
  Wave := wtWAV; Sine := False; Polarity := False; FileID := 0; SAddr := $200;
  SetLevels;
end;

procedure Run;
begin
  OpenInFile;
  SetLength(OutBuf, 65536);
  OutLen := 0;
  if Decoding then
  begin
    if not ConOut then OpenOutFile;
    Decode;
    FlushOut;
  end
  else
  begin
    OpenOutFile;
    Encode;
  end;
end;

begin
  ExitCode := 0;
  WriteLn;
  WriteLn(TITLE);
  try
    try
      Defaults;
      ParseCmd;
      Run;
      WriteLn;
      WriteLn('done');
    finally
      try
        FlushOut;
      except
      end;
      FreeAndNil(OutStream);
    end;
  except
    on E: EKimAbort do
    begin
      WriteLn;
      ExitCode := 1;
    end;
    on E: Exception do
    begin
      WriteLn;
      WriteLn('Error: ', E.Message, ' ... aborting');
      ExitCode := 1;
    end;
  end;
end.
