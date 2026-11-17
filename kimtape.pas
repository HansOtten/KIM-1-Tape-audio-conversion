{ KIMTAPE - KIM-1 / SYM-1 tape conversion utility

  Free Pascal port of KIMTAPE 0.5 (17-May-04, DX-Forth, public domain).
  Same command line switches and the same tape encoding as the original.

  Additions compared to the DOS original:
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
  WriteLn('-N    no automatic DC/level adjust  (decode)');
  WriteLn('-Pn   channel  0=mix 1=left 2=right  (decode, stereo files)');
  WriteLn('-Sn   sample rate: output wavefile (encode, default 22050)');
  WriteLn('      or RAW input file (decode, default 22050)');
  WriteLn('-Wn   sample width 8 or 16 bits  (encode, default 8)');
  WriteLn('-O    overwrite output file without asking');
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

function GetBit: Integer;
begin
  if SymMode then Result := GetBitSym else Result := GetBitKim;
end;

function PosText: string;
begin
  Result := Format(' at sample %d (%.3f s)', [Reader.Position, Reader.Position / Reader.Rate]);
end;

function DecodedText: string;
begin
  Result := 'Program ' + H2(FileID) + '  address ' + H4(SAddr);
  if SymMode then Result := Result + ' ' + H4(EAddr - 1);
  Result := Result + '  checksum ';
  if Checksum <> 0 then Result := Result + 'ERROR' else Result := Result + 'OK';
  Result := Result + '  ' + IntToStr(DecodeCount) + ' bytes';
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
begin
  if SymMode then SeekHalf;      { discard start bit }
  Result := 0;
  for I := 1 to 8 do
    Result := (Result shr 1) or (GetBit shl 7);
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
    if B = Ord('/') then Exit;
    B := HexChar(HexChar(0, B), DecodeByte);
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

procedure Decode;
var
  Fmt, ChanText: string;
begin
  Reader := TAudioReader.Create(InFile, Wave = wtRAW, SampleRate);
  try
    if Reader.Fmt = sfFloat then Fmt := 'float' else Fmt := 'bit';
    if Reader.Channels = 1 then ChanText := 'mono'
    else ChanText := IntToStr(Reader.Channels) + ' channels';
    WriteLn(Format('format:  %s %d Hz %d %s %s', [Reader.Kind, Reader.Rate, Reader.Bits, Fmt,
      ChanText]));
    if Reader.Rate < 16000 then
      WriteLn('warning: sample rate below 16000 Hz, decoding may fail');
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
      try GetID; except on EEndOfData do Missing('ID'); end;
      Checksum := 0;
      try GetAddress; except on EEndOfData do Missing('address'); end;
      try GetData; except on EEndOfData do Missing('data'); end;
      try GetChecksum; except on EEndOfData do Missing('checksum'); end;
      GetEnd;
      ShowDecoded;
    end;
  finally
    FreeAndNil(Reader);
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
  if Decoding then InFile := AddExt(Names[0], WaveExt)
  else InFile := AddExt(Names[0], '.PRG');
  if Length(Names) > 1 then
    OutFile := Names[1]
  else
    OutFile := ChangeFileExt(ExtractFileName(InFile), '');
  if Decoding then OutFile := AddExt(OutFile, '.PRG')
  else OutFile := AddExt(OutFile, WaveExt);
end;

procedure OpenInFile;
begin
  WriteLn;
  Write('infile:  ', InFile);
  if not FileExists(InFile) then
    Abort2(' file not found');
  WriteLn;
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
