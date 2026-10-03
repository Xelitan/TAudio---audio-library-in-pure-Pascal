{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameSimple;

interface

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com

uses
  SysUtils, Classes,
  LameTypes, LameCore, LameVbrTag;

type
  TPCMSamples = array of SmallInt;

  TPCMInfo = record
    NumChannels: Word;       // 1 = mono, 2 = stereo
    BitsPerSample: Word;     // original WAV depth: 8, 16, 24, 32 (int or float) or 64 (float)
    IsFloat: Boolean;        // original WAV samples were IEEE float
    SampleRate: Cardinal;    // Hz
    NumSamples: Cardinal;    // sample frames per channel
    DataSize: Cardinal;      // original PCM payload size in bytes
  end;

const
  PCM_CHUNK = 1152;              // sample frames per MPEG frame
  MP3_BUFSIZE = PCM_CHUNK * 8;   // generous MP3 output buffer


  //functions for use outside this unit
  function WAVToPCM(const WavBytes: TBytes; out Info: TPCMInfo): TPCMSamples;
  function PCMToMP3(const Samples: TPCMSamples; const Info: TPCMInfo; BitrateKbps: Integer): TBytes;

implementation

uses
  Math;

const
  WAVE_FORMAT_PCM        = $0001;
  WAVE_FORMAT_IEEE_FLOAT = $0003;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;
  // KSDATAFORMAT_SUBTYPE_PCM {00000001-0000-0010-8000-00AA00389B71} and
  // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT {00000003-...} in on-disk byte order.
  // The first two bytes hold the plain format tag; the rest is shared.
  KSDATAFORMAT_SUBTYPE_TAIL: array[0..13] of Byte = (
    $00, $00, $00, $00, $10, $00,
    $80, $00, $00, $AA, $00, $38, $9B, $71);

function FourCCEquals(const B: TBytes; Offset: Integer; const S: AnsiString): Boolean;
begin
  Result :=
    (Offset + 3 < Length(B)) and
    (Length(S) = 4) and
    (AnsiChar(B[Offset])     = S[1]) and
    (AnsiChar(B[Offset + 1]) = S[2]) and
    (AnsiChar(B[Offset + 2]) = S[3]) and
    (AnsiChar(B[Offset + 3]) = S[4]);
end;

function ReadLE16(const B: TBytes; Offset: Integer): Word;
begin
  if Offset + 1 >= Length(B) then
    raise Exception.Create('Unexpected end of data while reading WORD.');
  Result := Word(B[Offset]) or (Word(B[Offset + 1]) shl 8);
end;

function ReadLE32(const B: TBytes; Offset: Integer): Cardinal;
begin
  if Offset + 3 >= Length(B) then
    raise Exception.Create('Unexpected end of data while reading DWORD.');
  Result := Cardinal(B[Offset]) or
            (Cardinal(B[Offset + 1]) shl 8) or
            (Cardinal(B[Offset + 2]) shl 16) or
            (Cardinal(B[Offset + 3]) shl 24);
end;

function ReadLESmallInt(const B: TBytes; Offset: Integer): SmallInt;
var
  U: Word;
begin
  U := ReadLE16(B, Offset);
  Result := SmallInt(U);
end;

function ClampToSmallInt(V: Int64): SmallInt;
begin
  if V > High(SmallInt) then
    Result := High(SmallInt)
  else if V < Low(SmallInt) then
    Result := Low(SmallInt)
  else
    Result := SmallInt(V);
end;

// Scales a float sample in [-1.0, 1.0] to 16-bit, rounding and clipping.
function FloatToSmallInt(F: Double): SmallInt;
begin
  if IsNan(F) then
    Result := 0
  else if F >= 1.0 then
    Result := High(SmallInt)
  else if F <= -1.0 then
    Result := Low(SmallInt)
  else
    Result := ClampToSmallInt(Round(F * 32768.0));
end;

// Converts a complete WAV file held in memory into signed 16-bit interleaved PCM.
// The RIFF/WAVE header and all non-audio chunks are stripped.
function WAVToPCM(const WavBytes: TBytes; out Info: TPCMInfo): TPCMSamples;
var
  Pos, ChunkSize, DataOffset: Integer;
  AudioFormat, BlockAlign: Word;
  FmtFound, DataFound: Boolean;
  I, SampleCount, BytesPerSample, Offset: Integer;
  B: Byte;
  V: Int64;
  U32: Cardinal;
  U64: UInt64;
begin
  Result := nil;
  FillChar(Info, SizeOf(Info), 0);

  if Length(WavBytes) < 12 then
    raise Exception.Create('Invalid WAV file: too small.');

  if (not FourCCEquals(WavBytes, 0, 'RIFF')) or
     (not FourCCEquals(WavBytes, 8, 'WAVE')) then
    raise Exception.Create('Invalid WAV file: missing RIFF/WAVE signature.');

  Pos := 12;
  FmtFound := False;
  DataFound := False;
  DataOffset := 0;

  while Pos + 8 <= Length(WavBytes) do
  begin
    ChunkSize := Integer(ReadLE32(WavBytes, Pos + 4));
    Inc(Pos, 8);

    if Pos + ChunkSize > Length(WavBytes) then
      raise Exception.Create('Invalid WAV file: chunk extends past end of file.');

    if FourCCEquals(WavBytes, Pos - 8, 'fmt ') then
    begin
      if ChunkSize < 16 then
        raise Exception.Create('Invalid WAV file: fmt chunk is too small.');

      AudioFormat := ReadLE16(WavBytes, Pos);
      Info.NumChannels := ReadLE16(WavBytes, Pos + 2);
      Info.SampleRate := ReadLE32(WavBytes, Pos + 4);
      BlockAlign := ReadLE16(WavBytes, Pos + 12);
      Info.BitsPerSample := ReadLE16(WavBytes, Pos + 14);

      if AudioFormat = WAVE_FORMAT_EXTENSIBLE then
      begin
        // WAVE_FORMAT_EXTENSIBLE: the real format is the SubFormat GUID at
        // offset 24 of the fmt chunk; only the PCM and IEEE float subtypes are accepted.
        if ChunkSize < 40 then
          raise Exception.Create('Invalid WAV file: extensible fmt chunk is too small.');
        if not CompareMem(@WavBytes[Pos + 26], @KSDATAFORMAT_SUBTYPE_TAIL[0], 14) then
          raise Exception.Create('Only uncompressed PCM or IEEE float WAV files are supported.');
        AudioFormat := ReadLE16(WavBytes, Pos + 24);
      end;

      if not (AudioFormat in [WAVE_FORMAT_PCM, WAVE_FORMAT_IEEE_FLOAT]) then
        raise Exception.Create('Only uncompressed PCM or IEEE float WAV files are supported.');
      Info.IsFloat := AudioFormat = WAVE_FORMAT_IEEE_FLOAT;
      if not (Info.NumChannels in [1, 2]) then
        raise Exception.Create('Only mono and stereo WAV files are supported.');
      if Info.IsFloat then
      begin
        if not (Info.BitsPerSample in [32, 64]) then
          raise Exception.Create('Only 32-bit and 64-bit IEEE float WAV files are supported.');
      end
      else if not (Info.BitsPerSample in [8, 16, 24, 32]) then
        raise Exception.Create('Only 8, 16, 24 and 32-bit PCM WAV files are supported.');
      if BlockAlign <> Info.NumChannels * (Info.BitsPerSample div 8) then
        raise Exception.Create('Invalid WAV file: unexpected block alignment.');

      FmtFound := True;
    end
    else if FourCCEquals(WavBytes, Pos - 8, 'data') then
    begin
      DataOffset := Pos;
      Info.DataSize := Cardinal(ChunkSize);
      DataFound := True;
    end;

    Inc(Pos, ChunkSize);
    if Odd(ChunkSize) then
      Inc(Pos); // RIFF chunks are word-aligned
  end;

  if not FmtFound then
    raise Exception.Create('Invalid WAV file: missing fmt chunk.');
  if not DataFound then
    raise Exception.Create('Invalid WAV file: missing data chunk.');

  BytesPerSample := Info.BitsPerSample div 8;
  BlockAlign := Info.NumChannels * BytesPerSample;
  Info.NumSamples := Info.DataSize div BlockAlign;
  SampleCount := Integer(Info.NumSamples) * Integer(Info.NumChannels);
  SetLength(Result, SampleCount);

  // Everything is reduced to signed 16-bit, which is what LAME encodes.
  for I := 0 to SampleCount - 1 do
  begin
    Offset := DataOffset + I * BytesPerSample;
    if Info.IsFloat then
    begin
      if BytesPerSample = 4 then
      begin
        U32 := ReadLE32(WavBytes, Offset);
        Result[I] := FloatToSmallInt(PSingle(@U32)^);
      end
      else
      begin
        U64 := UInt64(ReadLE32(WavBytes, Offset)) or
               (UInt64(ReadLE32(WavBytes, Offset + 4)) shl 32);
        Result[I] := FloatToSmallInt(PDouble(@U64)^);
      end;
    end
    else
      case BytesPerSample of
        1:
        begin
          // WAV 8-bit PCM is unsigned.
          B := WavBytes[Offset];
          Result[I] := SmallInt(Integer(B) - 128) * 256;
        end;
        2:
          Result[I] := ReadLESmallInt(WavBytes, Offset);
        3:
        begin
          // sign-extend 24-bit, then drop 8 bits with rounding
          V := Int64(WavBytes[Offset]) or (Int64(WavBytes[Offset + 1]) shl 8) or
               (Int64(WavBytes[Offset + 2]) shl 16);
          if V >= $800000 then
            Dec(V, $1000000);
          Result[I] := ClampToSmallInt((V + 128) div 256 - Ord((V + 128) mod 256 < 0));
        end;
      else
        begin
          // 32-bit: drop 16 bits with rounding
          V := Int64(Integer(ReadLE32(WavBytes, Offset)));
          Result[I] := ClampToSmallInt((V + 32768) div 65536 - Ord((V + 32768) mod 65536 < 0));
        end;
      end;
  end;
end;

// Encodes signed 16-bit interleaved PCM samples to MP3 bytes.
// BitrateKbps is a CBR bitrate, for example 128, 192, or 320.
function PCMToMP3(const Samples: TPCMSamples; const Info: TPCMInfo; BitrateKbps: Integer): TBytes;
var
  Gfp: PLameGlobalFlags;
  PcmL, PcmR: array of SmallInt;
  Mp3Buf: array[0..MP3_BUFSIZE - 1] of Byte;
  FrameIndex, FramesLeft, FramesThisPass: Integer;
  I, BaseIndex, Mp3Bytes: Integer;
  OutStream: TMemoryStream;
begin
  Result := nil;

  if not (Info.NumChannels in [1, 2]) then
    raise Exception.Create('PCMToMP3 supports only mono or stereo input.');
  if Length(Samples) < Integer(Info.NumSamples) * Integer(Info.NumChannels) then
    raise Exception.Create('PCM sample array is shorter than the metadata says.');
  if BitrateKbps <= 0 then
    raise Exception.Create('Bitrate must be a positive kbps value.');

  Gfp := lame_init;
  if Gfp = nil then
    raise Exception.Create('lame_init failed.');

  OutStream := TMemoryStream.Create;
  try
    Gfp^.samplerate_in := Info.SampleRate;
    Gfp^.samplerate_out := 0;       // 0 = same as input
    Gfp^.num_channels := Info.NumChannels;
    Gfp^.brate := BitrateKbps;
    Gfp^.VBR := vbr_off;            // CBR; caller controls bitrate
    Gfp^.quality := 5;              // 0/2 = better/slower, 5 = normal, 7 = faster
    Gfp^.write_lame_tag := 1;

    if Info.NumChannels = 1 then
      Gfp^.mode := MONO
    else
      Gfp^.mode := JOINT_STEREO;

    if lame_init_params(Gfp) < 0 then
      raise Exception.Create('lame_init_params failed. Unsupported sample rate or bitrate?');

    if InitVbrTag(Gfp) < 0 then
      Gfp^.write_lame_tag := 0;

    SetLength(PcmL, PCM_CHUNK);
    SetLength(PcmR, PCM_CHUNK);

    FrameIndex := 0;
    while FrameIndex < Integer(Info.NumSamples) do
    begin
      FramesLeft := Integer(Info.NumSamples) - FrameIndex;
      if FramesLeft > PCM_CHUNK then
        FramesThisPass := PCM_CHUNK
      else
        FramesThisPass := FramesLeft;

      if Info.NumChannels = 2 then
      begin
        for I := 0 to FramesThisPass - 1 do
        begin
          BaseIndex := (FrameIndex + I) * 2;
          PcmL[I] := Samples[BaseIndex];
          PcmR[I] := Samples[BaseIndex + 1];
        end;
      end
      else
      begin
        for I := 0 to FramesThisPass - 1 do
        begin
          BaseIndex := FrameIndex + I;
          PcmL[I] := Samples[BaseIndex];
          PcmR[I] := Samples[BaseIndex];
        end;
      end;

      Mp3Bytes := lame_encode_buffer(Gfp,
                                     @PcmL[0], @PcmR[0], FramesThisPass,
                                     @Mp3Buf[0], SizeOf(Mp3Buf));
      if Mp3Bytes < 0 then
        raise Exception.CreateFmt('lame_encode_buffer failed: %d', [Mp3Bytes]);

      if Mp3Bytes > 0 then
        OutStream.WriteBuffer(Mp3Buf[0], Mp3Bytes);

      Inc(FrameIndex, FramesThisPass);
    end;

    Mp3Bytes := lame_encode_flush(Gfp, @Mp3Buf[0], SizeOf(Mp3Buf));
    if Mp3Bytes < 0 then
      raise Exception.CreateFmt('lame_encode_flush failed: %d', [Mp3Bytes]);
    if Mp3Bytes > 0 then
      OutStream.WriteBuffer(Mp3Buf[0], Mp3Bytes);

    if Gfp^.write_lame_tag <> 0 then
      PutVbrTag(Gfp, OutStream);

    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    OutStream.Free;
    lame_close(Gfp);
  end;
end;

end.
