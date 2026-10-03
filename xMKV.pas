unit xMKV;

{$mode objfpc}{$H+}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Matroska / WebM reader for TXelAudio (.mkv, .mka, .webm)      //
//		Takes the first audio track with a supported codec: AAC,      //
//		AC-3, E-AC-3, MP3, FLAC, Vorbis, PCM and A_MS/ACM. Only the   //
//		audio blocks are read, video data is skipped.                 //
// Version:	0.1                                                           //
// Date:	02-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal                                            //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Math, xAudioBase, xM4A, xDemux;

type

  { TAudioMKV }

  TAudioMKV = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

{ the codec of a WAVEFORMATEX tag (also used by xAVI) }
procedure TrackFromWaveFormat(var T: TDemuxTrack; const Fmt: TBytes);

implementation

const
  ID_EBML = $1A45DFA3;
  ID_SEGMENT = $18538067;
  ID_TRACKS = $1654AE6B;
  ID_TRACKENTRY = $AE;
  ID_TRACKNUMBER = $D7;
  ID_TRACKTYPE = $83;
  ID_CODECID = $86;
  ID_CODECPRIVATE = $63A2;
  ID_AUDIO = $E1;
  ID_SAMPLINGFREQ = $B5;
  ID_OUTSAMPLINGFREQ = $78B5;
  ID_CHANNELS = $9F;
  ID_BITDEPTH = $6264;
  ID_CONTENTENCODINGS = $6D80;
  ID_CONTENTENCODING = $6240;
  ID_CONTENTCOMPRESSION = $5034;
  ID_CONTENTCOMPALGO = $4254;
  ID_CONTENTCOMPSETTINGS = $4255;
  ID_CLUSTER = $1F43B675;
  ID_SIMPLEBLOCK = $A3;
  ID_BLOCKGROUP = $A0;
  ID_BLOCK = $A1;
  // level 1 elements: they end a cluster of unknown size
  Level1: array[0..7] of Cardinal = ($1F43B675, $1C53BB6B, $1254C367, $1043A770,
    $1941A469, $114D9B74, $1549A966, $1654AE6B);

type
  TMkvReader = class
    Str: TStream;
    FileSize: Int64;
    Track: TDemuxTrack;
    TrackNumber: Int64;
    CodecId: AnsiString;
    Found: Boolean;
    function ReadByte(var P: Int64): Byte;
    function ReadId(var P: Int64): Cardinal;
    function ReadSize(var P: Int64): Int64;   // -1 = unknown
    function ReadUInt(P, Size: Int64): Int64;
    function ReadFloat(P, Size: Int64): Double;
    function ReadBytes(P, Size: Int64): TBytes;
    procedure ParseTracks(P, Stop: Int64);
    function ParseTrackEntry(P, Stop: Int64): Boolean;
    function ParseCluster(P, Stop: Int64): Int64;
    procedure ParseBlock(P, Size: Int64);
    function Parse: Boolean;
  end;

function TMkvReader.ReadByte(var P: Int64): Byte;
begin
  if P >= FileSize then raise Exception.Create('Matroska data truncated');
  Str.Position := P;
  Str.ReadBuffer(Result, 1);
  Inc(P);
end;

function TMkvReader.ReadId(var P: Int64): Cardinal;
var B: Byte;
    Len, i: Integer;
begin
  B := ReadByte(P);
  Len := 1;
  while (Len <= 4) and (B and ($80 shr (Len - 1)) = 0) do Inc(Len);
  if Len > 4 then raise Exception.Create('Invalid Matroska element id');
  Result := B;
  for i:=2 to Len do Result := (Result shl 8) or ReadByte(P);
end;

function TMkvReader.ReadSize(var P: Int64): Int64;
var B: Byte;
    Len, i: Integer;
    AllOnes: Boolean;
begin
  B := ReadByte(P);
  Len := 1;
  while (Len <= 8) and (B and ($80 shr (Len - 1)) = 0) do Inc(Len);
  if Len > 8 then raise Exception.Create('Invalid Matroska element size');
  Result := B and ($FF shr Len);
  AllOnes := Result = ($FF shr Len);
  for i:=2 to Len do begin
    B := ReadByte(P);
    AllOnes := AllOnes and (B = $FF);
    Result := (Result shl 8) or B;
  end;
  if AllOnes then Result := -1;
end;

function TMkvReader.ReadUInt(P, Size: Int64): Int64;
var i: Integer;
begin
  Result := 0;
  for i:=1 to Min(Size, 8) do Result := (Result shl 8) or ReadByte(P);
end;

function TMkvReader.ReadFloat(P, Size: Int64): Double;
var B: array[0..7] of Byte;
    i: Integer;
    S: Single;
    D: Double;
begin
  Result := 0;
  if (Size <> 4) and (Size <> 8) then Exit;
  for i:=0 to Size-1 do B[Size - 1 - i] := ReadByte(P);   // big endian
  if Size = 4 then begin
    Move(B[0], S, 4);
    Result := S;
  end
  else begin
    Move(B[0], D, 8);
    Result := D;
  end;
end;

function TMkvReader.ReadBytes(P, Size: Int64): TBytes;
begin
  Result := nil;
  if (Size <= 0) or (P + Size > FileSize) or (Size > 64 shl 20) then Exit;
  SetLength(Result, Size);
  Str.Position := P;
  Str.ReadBuffer(Result[0], Size);
end;

procedure TrackFromWaveFormat(var T: TDemuxTrack; const Fmt: TBytes);
var Tag, CbSize, Extra: Integer;
begin
  T.Codec := dcNone;
  if Length(Fmt) < 16 then Exit;
  Tag := Fmt[0] or (Fmt[1] shl 8);
  T.Channels := Fmt[2] or (Fmt[3] shl 8);
  T.Rate := Fmt[4] or (Fmt[5] shl 8) or (Fmt[6] shl 16) or (Fmt[7] shl 24);
  T.Bits := Fmt[14] or (Fmt[15] shl 8);
  if Length(Fmt) >= 18 then CbSize := Fmt[16] or (Fmt[17] shl 8) else CbSize := 0;
  CbSize := Min(CbSize, Length(Fmt) - 18);
  if (Tag = $FFFE) and (CbSize >= 22) then Tag := Fmt[24] or (Fmt[25] shl 8);  // extensible
  case Tag of
    $0055: T.Codec := dcMp3;
    $0050: T.Codec := dcMp3;
    $2000: T.Codec := dcAc3;
    $00FF, $1600, $1610, $706D: begin
      // AAC; the AudioSpecificConfig is in the extra data (after a
      // HEAACWAVEINFO for $1610), otherwise ADTS frames are expected
      T.Codec := dcAacAdts;
      if Tag = $1610 then Extra := 12 else Extra := 0;
      if CbSize - Extra >= 2 then begin
        T.Priv := Copy(Fmt, 18 + Extra, CbSize - Extra);
        T.Codec := dcAac;
      end;
    end;
    $0001, $0003, $0002, $0006, $0007, $0011, $FFFE: begin
      T.Codec := dcWav;
      T.Priv := Copy(Fmt, 0, Length(Fmt));
    end;
  end;
end;

{ the codec of a Matroska CodecID }
function SetupCodec(var T: TDemuxTrack; const Id: AnsiString; Rate, Channels, Bits: Integer;
  OutRate: Double): Boolean;
var Obj, i, SfIdx: Integer;
const Rates: array[0..12] of Integer = (96000, 88200, 64000, 48000, 44100, 32000, 24000,
  22050, 16000, 12000, 11025, 8000, 7350);
begin
  T.Codec := dcNone;
  T.Rate := Rate;
  T.Channels := Channels;
  T.Bits := Bits;
  if Id = 'A_AC3' then T.Codec := dcAc3
  else if (Copy(Id, 1, 6) = 'A_AC3/') or (Id = 'A_EAC3') then T.Codec := dcAc3
  else if (Id = 'A_MPEG/L3') or (Id = 'A_MPEG/L2') then T.Codec := dcMp3
  else if Id = 'A_FLAC' then begin
    if Length(T.Priv) > 0 then T.Codec := dcFlac;
  end
  else if Id = 'A_VORBIS' then begin
    if Length(T.Priv) > 0 then T.Codec := dcVorbis;
  end
  else if (Id = 'A_PCM/INT/LIT') or (Id = 'A_PCM/INT/BIG') or (Id = 'A_PCM/FLOAT/IEEE') then begin
    T.Codec := dcPcm;
    T.PcmBigEndian := Id = 'A_PCM/INT/BIG';
    T.PcmFloat := Id = 'A_PCM/FLOAT/IEEE';
  end
  else if Id = 'A_MS/ACM' then
    TrackFromWaveFormat(T, T.Priv)
  else if Copy(Id, 1, 5) = 'A_AAC' then begin
    if Length(T.Priv) >= 2 then T.Codec := dcAac
    else begin
      // old style ids: A_AAC/MPEG4/LC, A_AAC/MPEG2/MAIN, .../LC/SBR
      if Pos('/MAIN', Id) > 0 then Obj := 1
      else if Pos('/SSR', Id) > 0 then Obj := 3
      else Obj := 2;
      SfIdx := 4;
      for i:=0 to 12 do
        if Rates[i] = Rate then SfIdx := i;
      T.Priv := MakeASC(Obj, SfIdx, Channels);
      T.Codec := dcAac;
    end;
  end;
  if OutRate > 0 then ;
  Result := T.Codec <> dcNone;
end;

function TMkvReader.ParseTrackEntry(P, Stop: Int64): Boolean;
var Id: Cardinal;
    Size, Q, Stop2, Stop3, Stop4: Int64;
    Num, TrackType, Rate, Channels, Bits, Algo: Int64;
    Codec: AnsiString;
    Priv, Settings: TBytes;
    OutRate: Double;
begin
  Result := False;
  Num := 0; TrackType := 0; Rate := 8000; Channels := 1; Bits := 0; Algo := -1;
  OutRate := 0;
  Codec := '';
  Priv := nil;
  Settings := nil;
  while P < Stop do begin
    Id := ReadId(P);
    Size := ReadSize(P);
    if Size < 0 then Break;
    case Id of
      ID_TRACKNUMBER: Num := ReadUInt(P, Size);
      ID_TRACKTYPE: TrackType := ReadUInt(P, Size);
      ID_CODECID: begin
        SetLength(Codec, Size);
        if Size > 0 then begin
          Str.Position := P;
          Str.ReadBuffer(Codec[1], Size);
        end;
        Codec := TrimRight(PAnsiChar(Codec));
      end;
      ID_CODECPRIVATE: Priv := ReadBytes(P, Size);
      ID_AUDIO: begin
        Q := P;
        Stop2 := P + Size;
        while Q < Stop2 do begin
          Id := ReadId(Q);
          Size := ReadSize(Q);
          if Size < 0 then Break;
          case Id of
            ID_SAMPLINGFREQ: Rate := Round(ReadFloat(Q, Size));
            ID_OUTSAMPLINGFREQ: OutRate := ReadFloat(Q, Size);
            ID_CHANNELS: Channels := ReadUInt(Q, Size);
            ID_BITDEPTH: Bits := ReadUInt(Q, Size);
          end;
          Inc(Q, Size);
        end;
        Size := Stop2 - P;
      end;
      ID_CONTENTENCODINGS: begin
        // header stripping (ContentCompAlgo 3) is supported, other encodings are not
        Q := P;
        Stop2 := P + Size;
        while Q < Stop2 do begin
          Id := ReadId(Q);
          Size := ReadSize(Q);
          if Size < 0 then Break;
          if Id = ID_CONTENTENCODING then begin
            Stop3 := Q + Size;
            while Q < Stop3 do begin
              Id := ReadId(Q);
              Size := ReadSize(Q);
              if Size < 0 then Break;
              if Id = ID_CONTENTCOMPRESSION then begin
                Stop4 := Q + Size;
                Algo := 0;
                while Q < Stop4 do begin
                  Id := ReadId(Q);
                  Size := ReadSize(Q);
                  if Size < 0 then Break;
                  if Id = ID_CONTENTCOMPALGO then Algo := ReadUInt(Q, Size)
                  else if Id = ID_CONTENTCOMPSETTINGS then Settings := ReadBytes(Q, Size);
                  Inc(Q, Size);
                end;
                Size := 0;
              end;
              Inc(Q, Size);
            end;
            Size := 0;
          end;
          Inc(Q, Size);
        end;
        Size := Stop2 - P;
      end;
    end;
    Inc(P, Size);
  end;
  if (TrackType <> 2) or Found then Exit;
  if (Algo >= 0) and (Algo <> 3) then Exit;      // compressed track (zlib, ...)
  Track := Default(TDemuxTrack);
  Track.Priv := Priv;
  if Algo = 3 then Track.Prefix := Settings;
  if not SetupCodec(Track, Codec, Rate, Channels, Bits, OutRate) then Exit;
  TrackNumber := Num;
  CodecId := Codec;
  Found := True;
  Result := True;
end;

procedure TMkvReader.ParseTracks(P, Stop: Int64);
var Id: Cardinal;
    Size: Int64;
begin
  while P < Stop do begin
    Id := ReadId(P);
    Size := ReadSize(P);
    if Size < 0 then Break;
    if Id = ID_TRACKENTRY then ParseTrackEntry(P, P + Size);
    Inc(P, Size);
  end;
end;

procedure TMkvReader.ParseBlock(P, Size: Int64);
var Stop, Num: Int64;
    Flags, Lacing, Count, i, B: Integer;
    Sizes: array of Int64;
    Total, V, Q: Int64;
    Len: Integer;
begin
  Stop := P + Size;
  Num := ReadSize(P);               // track number (vint)
  if Num <> TrackNumber then Exit;
  Inc(P, 2);                        // timecode
  Flags := ReadByte(P);
  Lacing := (Flags shr 1) and 3;
  if Lacing = 0 then begin
    AddFrame(Track, P, Stop - P);
    Exit;
  end;
  Count := ReadByte(P) + 1;
  SetLength(Sizes, Count);
  Total := 0;
  case Lacing of
    1: // Xiph
      for i:=0 to Count-2 do begin
        Sizes[i] := 0;
        repeat
          B := ReadByte(P);
          Inc(Sizes[i], B);
        until B < 255;
        Inc(Total, Sizes[i]);
      end;
    3: // EBML: first size, then signed differences
      for i:=0 to Count-2 do begin
        Q := P;
        V := ReadSize(P);
        if i = 0 then Sizes[0] := V
        else begin
          Len := P - Q;
          Sizes[i] := Sizes[i-1] + V - ((Int64(1) shl (7 * Len - 1)) - 1);
        end;
        Inc(Total, Sizes[i]);
      end;
    2: begin // fixed
      for i:=0 to Count-2 do Sizes[i] := (Stop - P) div Count;
      Total := Sizes[0] * (Count - 1);
    end;
  end;
  Sizes[Count-1] := Stop - P - Total;
  for i:=0 to Count-1 do begin
    if (Sizes[i] <= 0) or (P + Sizes[i] > Stop) then Break;
    AddFrame(Track, P, Sizes[i]);
    Inc(P, Sizes[i]);
  end;
end;

{ returns the position after the cluster }
function TMkvReader.ParseCluster(P, Stop: Int64): Int64;
var Id: Cardinal;
    Size, Q, Stop2, Start: Int64;
    Unknown: Boolean;
    i: Integer;
begin
  Unknown := Stop < 0;
  if Unknown then Stop := FileSize;
  while P < Stop do begin
    Start := P;
    Id := ReadId(P);
    if Unknown then
      for i:=0 to High(Level1) do
        if Id = Level1[i] then Exit(Start);
    Size := ReadSize(P);
    if Size < 0 then Exit(Stop);
    if Id = ID_SIMPLEBLOCK then ParseBlock(P, Size)
    else if Id = ID_BLOCKGROUP then begin
      Q := P;
      Stop2 := P + Size;
      while Q < Stop2 do begin
        Id := ReadId(Q);
        Size := ReadSize(Q);
        if Size < 0 then Break;
        if Id = ID_BLOCK then ParseBlock(Q, Size);
        Inc(Q, Size);
      end;
      Size := Stop2 - P;
    end;
    Inc(P, Size);
  end;
  Result := Stop;
end;

function TMkvReader.Parse: Boolean;
var P, Size, SegEnd, Stop: Int64;
    Id: Cardinal;
begin
  Result := False;
  FileSize := Str.Size;
  P := 0;
  if (ReadId(P) <> ID_EBML) then Exit;
  Size := ReadSize(P);
  if Size < 0 then Exit;
  Inc(P, Size);
  while P < FileSize do begin
    Id := ReadId(P);
    Size := ReadSize(P);
    if Id <> ID_SEGMENT then begin
      if Size < 0 then Exit;
      Inc(P, Size);
      Continue;
    end;
    if Size < 0 then SegEnd := FileSize else SegEnd := Min(FileSize, P + Size);
    while P < SegEnd do begin
      Id := ReadId(P);
      Size := ReadSize(P);
      if Id = ID_TRACKS then begin
        if Size < 0 then Exit;
        ParseTracks(P, P + Size);
        Inc(P, Size);
      end
      else if Id = ID_CLUSTER then begin
        if not Found then Exit;   // tracks must come first
        if Size < 0 then Stop := -1 else Stop := Min(SegEnd, P + Size);
        P := ParseCluster(P, Stop);
      end
      else begin
        if Size < 0 then Break;
        Inc(P, Size);
      end;
    end;
    Break;   // first segment only
  end;
  Result := Found and (Track.FrameCount > 0);
end;

{ TAudioMKV }

function TAudioMKV.LoadFromStream(Str: TStream): Boolean;
var R: TMkvReader;
begin
  Result := False;
  R := TMkvReader.Create;
  try
    R.Str := Str;
    try
      if not R.Parse then Exit;
    except
      // a damaged file: decode what was found
      if R.Track.FrameCount = 0 then raise;
    end;
    Result := DecodeDemuxed(FHandle, Str, R.Track);
  finally
    R.Free;
  end;
end;

initialization
  RegisterAudioFormat('mkv', TAudioMKV);
  RegisterAudioFormat('mka', TAudioMKV);
  RegisterAudioFormat('webm', TAudioMKV);

end.
