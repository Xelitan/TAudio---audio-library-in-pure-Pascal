unit xM4A;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	M4A / MP4 / AAC (ADTS) reader for TXelAudio                   //
//		MP4 audio tracks (also fragmented MP4) and raw ADTS streams,  //
//		decoded by the pure Pascal AAC decoder in xAAC; AC-3 and      //
//		E-AC-3 tracks in MP4 are decoded by xAC3.                     //
// Version:	0.1                                                           //
// Date:	01-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal                                            //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Types, Math, xAudio, xAudioBase, xAAC, xAC3;

type

  { TAudioM4A }

  TAudioM4A = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

  { An AAC access unit (frame) in the file }
  TAacFrameRef = record
    Offset: Int64;
    Size: Int64;
  end;
  TAacFrameRefs = array of TAacFrameRef;

  TFrameCodec = (fcAac, fcAc3);

  { Decodes M4A/MP4/AAC data to interleaved float samples in [-1, 1].
    Returns False for files without AAC audio, raises EAacError for
    unsupported or damaged ones. From MP4 files only the index boxes and the
    audio frames are read, so large video files need little memory. }
function DecodeM4A(Str: TStream; out Samples: TSingleDynArray;
  out Channels, SampleRate: Integer): Boolean; overload;
function DecodeM4A(const Data: TBytes; out Samples: TSingleDynArray;
  out Channels, SampleRate: Integer): Boolean; overload;

{ Decodes a list of AAC frames (raw, configured by an AudioSpecificConfig) or
  AC-3 / E-AC-3 frames read from Str; also used by the MKV and AVI readers.
  SkipTs/TotalTs (units of Timescale) trim the result like an MP4 edit list. }
function DecodeFrameList(Str: TStream; const Frames: TAacFrameRefs; Codec: TFrameCodec;
  const ASC: TBytes; out Samples: TSingleDynArray; out Channels, SampleRate: Integer;
  SkipTs: Int64 = 0; TotalTs: Int64 = -1; Timescale: Cardinal = 0): Boolean;
{ AudioSpecificConfig for the given object type, frequency index and channels }
function MakeASC(ObjectType, SfIndex, ChannelConfig: Integer): TBytes;
{ stores interleaved float samples (1 or 2 channels) in a TXelAudio }
procedure FillAudio(Handle: TXelAudio; const Samples: TSingleDynArray; Channels, Rate: Integer);

implementation

type
  { big-endian reader of a loaded box; positions are file offsets }
  TBoxReader = record
    Data: TBytes;
    Base: Int64;  // file offset of Data[0]
    function U8(P: Int64): Byte;
    function U16(P: Int64): Word;
    function U32(P: Int64): Cardinal;
    function U64(P: Int64): QWord;
    function Typ(P: Int64): AnsiString;
  end;

  TTrackInfo = record
    IsAudio: Boolean;
    TrackId: Cardinal;
    Timescale: Cardinal;
    ASC: TBytes;
    HasAac, HasAc3: Boolean;
    ObjectTypeIndication: Integer;
    ChunkOffsets: array of Int64;
    SampleSizes: array of Cardinal;
    DefaultSampleSize: Cardinal;
    SampleCount: Cardinal;
    StscFirst, StscCount: array of Cardinal;
    EditMediaTime: Int64;     // -1 = none
    EditDuration: Int64;      // in movie timescale, -1 = none
  end;

  TMp4Parser = class
  private
    R: TBoxReader;
    FMovieTimescale: Cardinal;
    FTrack: TTrackInfo;       // track being parsed
    FAudio: TTrackInfo;       // the chosen audio track
    FHaveAudio: Boolean;
    FTrexDefaultSize: Cardinal;
    FFragFrames: TAacFrameRefs;
    procedure ParseBoxes(Start, Stop: Int64; Depth: Integer);
    procedure ParseStsd(P, Stop: Int64);
    procedure ParseEsds(P, Stop: Int64);
    procedure ParseTraf(P, Stop, MoofStart: Int64);
    procedure FinishTrack;
  public
    { SkipSamples, TotalSamples (-1 = all) are in units of Timescale }
    function Parse(Str: TStream; out Frames: TAacFrameRefs; out ASC: TBytes;
      out SkipSamples, TotalSamples: Int64; out Timescale: Cardinal; out IsAc3: Boolean): Boolean;
  end;

{ TBoxReader }

function TBoxReader.U8(P: Int64): Byte;
begin
  Dec(P, Base);
  if (P < 0) or (P >= Length(Data)) then raise EAacError.Create('MP4 box out of range');
  Result := Data[P];
end;

function TBoxReader.U16(P: Int64): Word;
begin
  Result := (Word(U8(P)) shl 8) or U8(P+1);
end;

function TBoxReader.U32(P: Int64): Cardinal;
begin
  Result := (Cardinal(U16(P)) shl 16) or U16(P+2);
end;

function TBoxReader.U64(P: Int64): QWord;
begin
  Result := (QWord(U32(P)) shl 32) or U32(P+4);
end;

function TBoxReader.Typ(P: Int64): AnsiString;
begin
  SetLength(Result, 4);
  Result[1] := AnsiChar(U8(P));
  Result[2] := AnsiChar(U8(P+1));
  Result[3] := AnsiChar(U8(P+2));
  Result[4] := AnsiChar(U8(P+3));
end;

{ descriptor length: up to 4 bytes of 7 bits }
function ReadDescLen(var R: TBoxReader; var P: Int64): Integer;
var i: Integer;
    B: Byte;
begin
  Result := 0;
  for i:=1 to 4 do begin
    B := R.U8(P);
    Inc(P);
    Result := (Result shl 7) or (B and $7F);
    if B and $80 = 0 then Break;
  end;
end;

{ TMp4Parser }

procedure TMp4Parser.ParseEsds(P, Stop: Int64);
var Tag, Len, Flags: Integer;
    DescEnd, Q: Int64;
begin
  Inc(P, 4); // version, flags
  while P + 2 <= Stop do begin
    Tag := R.U8(P);
    Inc(P);
    Len := ReadDescLen(R, P);
    DescEnd := P + Len;
    case Tag of
      3: begin // ES_Descriptor: descend into it
        Inc(P, 2); // ES_ID
        Flags := R.U8(P);
        Inc(P);
        if Flags and $80 <> 0 then Inc(P, 2);
        if Flags and $40 <> 0 then Inc(P, 1 + R.U8(P));
        if Flags and $20 <> 0 then Inc(P, 2);
        Continue;
      end;
      4: begin // DecoderConfigDescriptor
        FTrack.ObjectTypeIndication := R.U8(P);
        P := P + 13;
        Continue; // DecoderSpecificInfo follows inside
      end;
      5: begin // DecoderSpecificInfo = AudioSpecificConfig
        SetLength(FTrack.ASC, Len);
        for Q:=0 to Len-1 do FTrack.ASC[Q] := R.U8(P + Q);
      end;
    end;
    P := DescEnd;
  end;
end;

procedure TMp4Parser.ParseStsd(P, Stop: Int64);
var Count, i: Integer;
    Size, EntryEnd, Q, BoxSize: Int64;
    Version: Integer;
    Typ: AnsiString;
begin
  Count := R.U32(P + 4);
  P := P + 8;
  for i:=1 to Count do begin
    if P + 8 > Stop then Break;
    Size := R.U32(P);
    Typ := R.Typ(P + 4);
    EntryEnd := P + Size;
    if Typ = 'mp4a' then begin
      FTrack.HasAac := True;
      Version := R.U16(P + 16);
      Q := P + 36;              // after AudioSampleEntry
      if Version = 1 then Inc(Q, 16)
      else if Version = 2 then Inc(Q, 36);
      // child boxes: esds, or wave > esds (QuickTime)
      while Q + 8 <= EntryEnd do begin
        BoxSize := R.U32(Q);
        if BoxSize < 8 then Break;
        if R.Typ(Q + 4) = 'esds' then ParseEsds(Q + 8, Q + BoxSize)
        else if R.Typ(Q + 4) = 'wave' then begin
          // search the esds box inside 'wave'
          Q := Q + 8;
          Continue;
        end;
        Q := Q + BoxSize;
      end;
    end
    else if (Typ = 'ac-3') or (Typ = 'ec-3') then
      FTrack.HasAc3 := True;
    P := EntryEnd;
  end;
end;

procedure TMp4Parser.FinishTrack;
begin
  if FTrack.IsAudio and (FTrack.HasAac or FTrack.HasAc3) and not FHaveAudio then begin
    FAudio := FTrack;
    FHaveAudio := True;
  end;
end;

procedure TMp4Parser.ParseTraf(P, Stop, MoofStart: Int64);
var Q, BoxSize, Base, DataPos: Int64;
    Typ: AnsiString;
    Flags, Count, i: Cardinal;
    TrackId, DefSize: Cardinal;
    Size: Cardinal;
    Mine: Boolean;
begin
  Base := MoofStart;
  DefSize := FTrexDefaultSize;
  Mine := False;
  DataPos := -1;
  Q := P;
  while Q + 8 <= Stop do begin
    BoxSize := R.U32(Q);
    if BoxSize < 8 then Break;
    Typ := R.Typ(Q + 4);
    if Typ = 'tfhd' then begin
      Flags := R.U32(Q + 8) and $FFFFFF;
      TrackId := R.U32(Q + 12);
      Mine := TrackId = FAudio.TrackId;
      P := Q + 16;
      if Flags and $1 <> 0 then begin Base := R.U64(P); Inc(P, 8); end;
      if Flags and $2 <> 0 then Inc(P, 4);
      if Flags and $8 <> 0 then Inc(P, 4);
      if Flags and $10 <> 0 then begin DefSize := R.U32(P); Inc(P, 4); end;
    end
    else if (Typ = 'trun') and Mine then begin
      Flags := R.U32(Q + 8) and $FFFFFF;
      Count := R.U32(Q + 12);
      P := Q + 16;
      if Flags and $1 <> 0 then begin DataPos := Base + LongInt(R.U32(P)); Inc(P, 4); end
      else if DataPos < 0 then DataPos := Base;
      if Flags and $4 <> 0 then Inc(P, 4);
      for i:=1 to Count do begin
        if Flags and $100 <> 0 then Inc(P, 4);
        if Flags and $200 <> 0 then begin Size := R.U32(P); Inc(P, 4); end
        else Size := DefSize;
        if Flags and $400 <> 0 then Inc(P, 4);
        if Flags and $800 <> 0 then Inc(P, 4);
        SetLength(FFragFrames, Length(FFragFrames) + 1);
        FFragFrames[High(FFragFrames)].Offset := DataPos;
        FFragFrames[High(FFragFrames)].Size := Size;
        Inc(DataPos, Size);
      end;
    end;
    Q := Q + BoxSize;
  end;
end;

procedure TMp4Parser.ParseBoxes(Start, Stop: Int64; Depth: Integer);
var P, Size, Hdr, Body, BodyEnd: Int64;
    Typ: AnsiString;
    Version, Count, i: Integer;
begin
  if Depth > 16 then Exit;
  P := Start;
  while P + 8 <= Stop do begin
    Size := R.U32(P);
    Typ := R.Typ(P + 4);
    Hdr := 8;
    if Size = 1 then begin
      Size := R.U64(P + 8);
      Hdr := 16;
    end
    else if Size = 0 then Size := Stop - P;
    if (Size < Hdr) or (P + Size > Stop) then Size := Stop - P;
    Body := P + Hdr;
    BodyEnd := P + Size;

    if (Typ = 'moov') or (Typ = 'mdia') or (Typ = 'minf') or (Typ = 'stbl') or
       (Typ = 'edts') or (Typ = 'mvex') then
      ParseBoxes(Body, BodyEnd, Depth + 1)
    else if Typ = 'trak' then begin
      FillChar(FTrack, SizeOf(FTrack), 0);
      FTrack.EditMediaTime := -1;
      FTrack.EditDuration := -1;
      ParseBoxes(Body, BodyEnd, Depth + 1);
      FinishTrack;
      Finalize(FTrack);
    end
    else if Typ = 'mvhd' then begin
      if R.U8(Body) = 1 then FMovieTimescale := R.U32(Body + 20)
      else FMovieTimescale := R.U32(Body + 12);
    end
    else if Typ = 'tkhd' then begin
      if R.U8(Body) = 1 then FTrack.TrackId := R.U32(Body + 20)
      else FTrack.TrackId := R.U32(Body + 12);
    end
    else if Typ = 'mdhd' then begin
      if R.U8(Body) = 1 then FTrack.Timescale := R.U32(Body + 20)
      else FTrack.Timescale := R.U32(Body + 12);
    end
    else if Typ = 'hdlr' then
      FTrack.IsAudio := R.Typ(Body + 8) = 'soun'
    else if Typ = 'elst' then begin
      Version := R.U8(Body);
      Count := R.U32(Body + 4);
      P := Body + 8;
      for i:=1 to Count do begin
        if Version = 1 then begin
          if (Int64(R.U64(P + 8)) >= 0) and (FTrack.EditMediaTime < 0) then begin
            FTrack.EditDuration := R.U64(P);
            FTrack.EditMediaTime := R.U64(P + 8);
          end;
          Inc(P, 20);
        end
        else begin
          if (LongInt(R.U32(P + 4)) >= 0) and (FTrack.EditMediaTime < 0) then begin
            FTrack.EditDuration := R.U32(P);
            FTrack.EditMediaTime := LongInt(R.U32(P + 4));
          end;
          Inc(P, 12);
        end;
      end;
    end
    else if Typ = 'stsd' then
      ParseStsd(Body, BodyEnd)
    else if Typ = 'stsz' then begin
      FTrack.DefaultSampleSize := R.U32(Body + 4);
      FTrack.SampleCount := R.U32(Body + 8);
      if FTrack.DefaultSampleSize = 0 then begin
        SetLength(FTrack.SampleSizes, FTrack.SampleCount);
        for i:=0 to Integer(FTrack.SampleCount)-1 do FTrack.SampleSizes[i] := R.U32(Body + 12 + 4*Int64(i));
      end;
    end
    else if Typ = 'stsc' then begin
      Count := R.U32(Body + 4);
      SetLength(FTrack.StscFirst, Count);
      SetLength(FTrack.StscCount, Count);
      for i:=0 to Count-1 do begin
        FTrack.StscFirst[i] := R.U32(Body + 8 + 12*Int64(i));
        FTrack.StscCount[i] := R.U32(Body + 12 + 12*Int64(i));
      end;
    end
    else if Typ = 'stco' then begin
      Count := R.U32(Body + 4);
      SetLength(FTrack.ChunkOffsets, Count);
      for i:=0 to Count-1 do FTrack.ChunkOffsets[i] := R.U32(Body + 8 + 4*Int64(i));
    end
    else if Typ = 'co64' then begin
      Count := R.U32(Body + 4);
      SetLength(FTrack.ChunkOffsets, Count);
      for i:=0 to Count-1 do FTrack.ChunkOffsets[i] := R.U64(Body + 8 + 8*Int64(i));
    end
    else if Typ = 'trex' then begin
      if FHaveAudio and (R.U32(Body + 4) = FAudio.TrackId) then FTrexDefaultSize := R.U32(Body + 16);
    end
    else if Typ = 'moof' then begin
      if FHaveAudio then begin
        P := Body;
        while P + 8 <= BodyEnd do begin
          Size := R.U32(P);
          if Size < 8 then Break;
          if R.Typ(P + 4) = 'traf' then ParseTraf(P + 8, P + Size, Body - Hdr);
          P := P + Size;
        end;
      end;
    end;

    P := BodyEnd;
  end;
end;

function TMp4Parser.Parse(Str: TStream; out Frames: TAacFrameRefs; out ASC: TBytes;
  out SkipSamples, TotalSamples: Int64; out Timescale: Cardinal; out IsAc3: Boolean): Boolean;
const MaxIndexBox = 512 * 1024 * 1024;
var Chunk, Entry, InChunk, S, N: Integer;
    Pos, FileSize, BoxSize: Int64;
    Hdr: array[0..15] of Byte;
    Typ: AnsiString;
begin
  Result := False;
  Frames := nil;
  ASC := nil;
  SkipSamples := 0;
  TotalSamples := -1;
  Timescale := 0;
  FHaveAudio := False;
  FMovieTimescale := 0;
  FTrexDefaultSize := 0;

  // top level: load and parse only the index boxes (moov, moof)
  FileSize := Str.Size;
  Pos := 0;
  SetLength(Typ, 4);
  FillChar(Hdr, SizeOf(Hdr), 0);
  while Pos + 8 <= FileSize do begin
    Str.Position := Pos;
    Str.ReadBuffer(Hdr, Min(16, FileSize - Pos));
    BoxSize := (Int64(Hdr[0]) shl 24) or (Hdr[1] shl 16) or (Hdr[2] shl 8) or Hdr[3];
    Move(Hdr[4], Typ[1], 4);
    if BoxSize = 1 then begin
      if Pos + 16 > FileSize then Break;
      BoxSize := (Int64(Hdr[8]) shl 56) or (Int64(Hdr[9]) shl 48) or (Int64(Hdr[10]) shl 40) or
        (Int64(Hdr[11]) shl 32) or (Int64(Hdr[12]) shl 24) or (Hdr[13] shl 16) or (Hdr[14] shl 8) or Hdr[15];
    end
    else if BoxSize = 0 then BoxSize := FileSize - Pos;
    if BoxSize < 8 then Break;
    if Pos + BoxSize > FileSize then BoxSize := FileSize - Pos;
    if ((Typ = 'moov') or (Typ = 'moof')) and (BoxSize <= MaxIndexBox) then begin
      SetLength(R.Data, BoxSize);
      R.Base := Pos;
      Str.Position := Pos;
      Str.ReadBuffer(R.Data[0], BoxSize);
      ParseBoxes(Pos, Pos + BoxSize, 0);
    end;
    Inc(Pos, BoxSize);
  end;
  R.Data := nil;
  if not FHaveAudio then Exit;
  IsAc3 := FAudio.HasAc3 and not FAudio.HasAac;
  if not IsAc3 and (FAudio.ObjectTypeIndication <> $40) and (FAudio.ObjectTypeIndication <> $66) and
     (FAudio.ObjectTypeIndication <> $67) then
    raise EAacError.CreateFmt('MP4 audio codec 0x%x is not AAC', [FAudio.ObjectTypeIndication]);
  ASC := FAudio.ASC;

  // sample table: chunk offsets + samples per chunk + sample sizes
  N := 0;
  if Length(FAudio.ChunkOffsets) > 0 then begin
    SetLength(Frames, FAudio.SampleCount);
    S := 0;
    Entry := 0;
    for Chunk:=0 to High(FAudio.ChunkOffsets) do begin
      while (Entry + 1 < Length(FAudio.StscFirst)) and (Cardinal(Chunk + 1) >= FAudio.StscFirst[Entry + 1]) do
        Inc(Entry);
      if Length(FAudio.StscCount) = 0 then Break;
      Pos := FAudio.ChunkOffsets[Chunk];
      for InChunk:=1 to Min(Int64(FAudio.StscCount[Entry]), Int64(FAudio.SampleCount)) do begin
        if S >= Integer(FAudio.SampleCount) then Break;
        Frames[S].Offset := Pos;
        if FAudio.DefaultSampleSize <> 0 then Frames[S].Size := FAudio.DefaultSampleSize
        else Frames[S].Size := FAudio.SampleSizes[S];
        Inc(Pos, Frames[S].Size);
        Inc(S);
      end;
    end;
    SetLength(Frames, S);
    N := S;
  end;
  if Length(FFragFrames) > 0 then begin
    SetLength(Frames, N + Length(FFragFrames));
    for S:=0 to High(FFragFrames) do Frames[N + S] := FFragFrames[S];
  end;

  // edit list: priming samples to skip and the length to keep (media timescale)
  if FAudio.EditMediaTime > 0 then SkipSamples := FAudio.EditMediaTime;
  if (FAudio.EditDuration > 0) and (FMovieTimescale > 0) and (FAudio.Timescale > 0) then
    TotalSamples := Round(FAudio.EditDuration * Int64(FAudio.Timescale) / FMovieTimescale);
  Timescale := FAudio.Timescale;
  Result := Length(Frames) > 0;
end;

{ ADTS }

function ParseAdts(const Data: TBytes; Start: Integer; out Frames: TAacFrameRefs;
  out Profile, SfIndex, ChanCfg: Integer): Boolean;
var P, Len, Hdr, N: Integer;
begin
  Result := False;
  Frames := nil;
  N := 0;
  P := Start;
  Profile := -1;
  while P + 7 <= Length(Data) do begin
    if (Data[P] <> $FF) or (Data[P+1] and $F6 <> $F0) then begin
      // resynchronize
      Inc(P);
      Continue;
    end;
    Len := ((Data[P+3] and 3) shl 11) or (Data[P+4] shl 3) or (Data[P+5] shr 5);
    if Data[P+1] and 1 <> 0 then Hdr := 7 else Hdr := 9; // protection_absent
    if (Len < Hdr) or (P + Len > Length(Data)) then Break;
    if Profile < 0 then begin
      Profile := Data[P+2] shr 6;
      SfIndex := (Data[P+2] shr 2) and 15;
      ChanCfg := ((Data[P+2] and 1) shl 2) or (Data[P+3] shr 6);
    end;
    if Data[P+6] and 3 <> 0 then
      raise EAacError.Create('ADTS frames with several raw data blocks are not supported');
    if N >= Length(Frames) then SetLength(Frames, N * 2 + 256);
    Frames[N].Offset := P + Hdr;
    Frames[N].Size := Len - Hdr;
    Inc(N);
    Inc(P, Len);
  end;
  SetLength(Frames, N);
  Result := N > 0;
end;

function SkipId3(const Data: TBytes): Integer;
begin
  Result := 0;
  while (Result + 10 <= Length(Data)) and (Data[Result] = Ord('I')) and (Data[Result+1] = Ord('D')) and
        (Data[Result+2] = Ord('3')) do
    Inc(Result, 10 + ((Data[Result+6] and $7F) shl 21) + ((Data[Result+7] and $7F) shl 14) +
      ((Data[Result+8] and $7F) shl 7) + (Data[Result+9] and $7F));
end;

function IsMp4(Str: TStream): Boolean;
var T: AnsiString;
begin
  Result := False;
  if Str.Size < 12 then Exit;
  SetLength(T, 4);
  Str.Position := 4;
  Str.ReadBuffer(T[1], 4);
  Result := (T = 'ftyp') or (T = 'moov') or (T = 'mdat') or (T = 'free') or (T = 'skip') or (T = 'wide');
end;

function DecodeM4A(const Data: TBytes; out Samples: TSingleDynArray;
  out Channels, SampleRate: Integer): Boolean;
var Str: TBytesStream;
begin
  Str := TBytesStream.Create(Data);
  try
    Result := DecodeM4A(Str, Samples, Channels, SampleRate);
  finally
    Str.Free;
  end;
end;

function DecodeFrameList(Str: TStream; const Frames: TAacFrameRefs; Codec: TFrameCodec;
  const ASC: TBytes; out Samples: TSingleDynArray; out Channels, SampleRate: Integer;
  SkipTs: Int64; TotalTs: Int64; Timescale: Cardinal): Boolean;
var Buf: TBytes;
    FileSize, Skip, Total, Count: Int64;
    i, N, Errors, Decoded: Integer;
    Aac: TAacDecoder;
    Ac3: TAc3Decoder;
    Src: PSingle;
begin
  Result := False;
  Samples := nil;
  Channels := 0;
  SampleRate := 0;
  FileSize := Str.Size;
  Aac := nil;
  Ac3 := nil;
  try
    if Codec = fcAac then begin
      if Length(ASC) = 0 then raise EAacError.Create('AAC track without AudioSpecificConfig');
      Aac := TAacDecoder.Create;
      Aac.ConfigureASC(ASC);
    end
    else Ac3 := TAc3Decoder.Create;

    Count := 0;
    Errors := 0;
    Decoded := 0;
    for i:=0 to High(Frames) do begin
      if (Frames[i].Offset < 0) or (Frames[i].Size <= 0) or (Frames[i].Size > 1 shl 20) or
         (Frames[i].Offset + Frames[i].Size > FileSize) then Break;
      if Length(Buf) < Frames[i].Size then SetLength(Buf, Frames[i].Size);
      Str.Position := Frames[i].Offset;
      Str.ReadBuffer(Buf[0], Frames[i].Size);

      if Codec = fcAc3 then begin
        // AC-3 / E-AC-3: a block may hold several sync frames
        N := 0;
        while N + 6 <= Frames[i].Size do begin
          Decoded := TAc3Decoder.FrameLength(@Buf[N], Frames[i].Size - N);
          if Decoded = 0 then Break;
          try
            if Ac3.DecodeFrame(@Buf[N], Min(Decoded, Frames[i].Size - N)) > 0 then begin
              Channels := Ac3.Downmix(Samples, Count);
              SampleRate := Ac3.SampleRate;
            end;
          except
            on E: EAc3Error do begin
              Inc(Errors);
              if (Channels = 0) or ((Errors > 10) and (Errors * 2 > i)) then raise;
              Ac3.OutputSilence;
              Ac3.Downmix(Samples, Count);
            end;
          end;
          Inc(N, Decoded);
        end;
        Continue;
      end;

      try
        N := Aac.DecodeFrame(@Buf[0], Frames[i].Size);
      except
        on E: EAacError do begin
          // a damaged frame: keep its length as silence, give up after many
          Inc(Errors);
          if (Errors > 10) and (Errors * 2 > i) then raise;
          N := 1024;
          Aac.OutputSilence;
        end;
      end;
      Channels := Aac.OutChannels;
      if Count + N * Channels > Length(Samples) then
        SetLength(Samples, Max(Length(Samples) * 2, Count + N * Channels + 65536));
      Src := Aac.Output;
      Move(Src^, Samples[Count], N * Channels * SizeOf(Single));
      Inc(Count, N * Channels);
    end;
    if Channels = 0 then Exit;
    // the output rate is known after the first frame (SBR doubles it)
    if Codec = fcAac then SampleRate := Aac.SampleRate;

    // edit list (track timescale): drop the encoder delay and the padding
    Skip := 0;
    Total := -1;
    if Timescale > 0 then begin
      Skip := Round(SkipTs * SampleRate / Timescale);
      if TotalTs >= 0 then Total := Round(TotalTs * SampleRate / Timescale);
    end;
    Count := Count div Channels;
    if Skip > Count then Skip := Count;
    if (Total < 0) or (Skip + Total > Count) then Total := Count - Skip;
    if Skip > 0 then Move(Samples[Skip * Channels], Samples[0], Total * Channels * SizeOf(Single));
    SetLength(Samples, Total * Channels);
    Result := Total > 0;
  finally
    Aac.Free;
    Ac3.Free;
  end;
end;

function DecodeM4A(Str: TStream; out Samples: TSingleDynArray;
  out Channels, SampleRate: Integer): Boolean;
var Frames: TAacFrameRefs;
    ASC, Data: TBytes;
    Parser: TMp4Parser;
    SkipTs, TotalTs: Int64;
    Timescale: Cardinal;
    Profile, SfIndex, ChanCfg: Integer;
    IsAc3: Boolean;
    Mem: TBytesStream;
begin
  Result := False;
  Samples := nil;
  Channels := 0;
  SampleRate := 0;
  if IsMp4(Str) then begin
    Parser := TMp4Parser.Create;
    try
      if not Parser.Parse(Str, Frames, ASC, SkipTs, TotalTs, Timescale, IsAc3) then Exit;
    finally
      Parser.Free;
    end;
    if IsAc3 then
      Result := DecodeFrameList(Str, Frames, fcAc3, nil, Samples, Channels, SampleRate, SkipTs, TotalTs, Timescale)
    else
      Result := DecodeFrameList(Str, Frames, fcAac, ASC, Samples, Channels, SampleRate, SkipTs, TotalTs, Timescale);
  end
  else begin
    // ADTS: the frames are read from memory
    SetLength(Data, Str.Size);
    Str.Position := 0;
    if Length(Data) > 0 then Str.ReadBuffer(Data[0], Length(Data));
    if not ParseAdts(Data, SkipId3(Data), Frames, Profile, SfIndex, ChanCfg) then Exit;
    ASC := MakeASC(Profile + 1, SfIndex, ChanCfg);
    Mem := TBytesStream.Create(Data);
    try
      Result := DecodeFrameList(Mem, Frames, fcAac, ASC, Samples, Channels, SampleRate);
    finally
      Mem.Free;
    end;
  end;
end;

function MakeASC(ObjectType, SfIndex, ChannelConfig: Integer): TBytes;
var V: Integer;
begin
  V := ((ObjectType and 31) shl 11) or ((SfIndex and 15) shl 7) or ((ChannelConfig and 15) shl 3);
  SetLength(Result, 2);
  Result[0] := V shr 8;
  Result[1] := V and $FF;
end;

procedure FillAudio(Handle: TXelAudio; const Samples: TSingleDynArray; Channels, Rate: Integer);
var i, N, V: Integer;
begin
  Handle.FSampleSize := 16;
  Handle.FSampleRate := Rate;
  N := Length(Samples) div Channels;
  SetLength(Handle.FFrames, N);
  for i:=0 to N-1 do begin
    V := EnsureRange(Round(Samples[i*Channels] * 32768), -32768, 32767);
    Handle.FFrames[i].Left := SignedToSample(V, 16);
    if Channels > 1 then begin
      V := EnsureRange(Round(Samples[i*Channels + 1] * 32768), -32768, 32767);
      Handle.FFrames[i].Right := SignedToSample(V, 16);
    end
    else
      Handle.FFrames[i].Right := 0;
  end;
end;

{ TAudioM4A }

function TAudioM4A.LoadFromStream(Str: TStream): Boolean;
var Samples: TSingleDynArray;
    Channels, Rate: Integer;
begin
  Result := False;
  if Str.Size = 0 then Exit;
  if not DecodeM4A(Str, Samples, Channels, Rate) then Exit;
  FillAudio(FHandle, Samples, Channels, Rate);
  Result := True;
end;

initialization
  RegisterAudioFormat('m4a', TAudioM4A);
  RegisterAudioFormat('m4b', TAudioM4A);
  RegisterAudioFormat('mp4', TAudioM4A);
  RegisterAudioFormat('aac', TAudioM4A);

end.
