unit xDemux;

{$mode objfpc}{$H+}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	Shared part of the container readers (xMKV, xAVI): an audio  //
//		track found in a container is passed to the matching          //
//		TXelAudio decoder.                                            //
// Version:	0.1                                                           //
// Date:	02-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal                                            //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Types, Math, xAudio, xM4A, xAC3;

type
  TDemuxCodec = (dcNone,
    dcAac,       // raw AAC frames, Priv = AudioSpecificConfig
    dcAacAdts,   // AAC frames with ADTS headers
    dcAc3,       // AC-3 / E-AC-3 sync frames
    dcMp3,       // MPEG audio frames
    dcFlac,      // FLAC frames, Priv = "fLaC" + metadata blocks
    dcVorbis,    // Vorbis packets, Priv = Xiph laced header packets
    dcPcm,       // PCM: Bits, PcmFloat, PcmBigEndian
    dcWav);      // data for a WAVEFORMATEX in Priv (ADPCM, A-law, ...)

  { an audio track found in a container }
  TDemuxTrack = record
    Codec: TDemuxCodec;
    Priv: TBytes;
    Prefix: TBytes;          // bytes removed from every frame (Matroska header stripping)
    Rate, Channels, Bits: Integer;
    PcmFloat, PcmBigEndian: Boolean;
    Frames: TAacFrameRefs;   // positions of the frames in the file
    FrameCount: Integer;     // used part of Frames
  end;

procedure AddFrame(var T: TDemuxTrack; Offset, Size: Int64);
{ decodes the track into Handle; False if the codec is not supported }
function DecodeDemuxed(Handle: TXelAudio; Str: TStream; var T: TDemuxTrack): Boolean;

implementation

procedure AddFrame(var T: TDemuxTrack; Offset, Size: Int64);
begin
  if Size <= 0 then Exit;
  if T.FrameCount >= Length(T.Frames) then SetLength(T.Frames, Max(1024, Length(T.Frames) * 2));
  T.Frames[T.FrameCount].Offset := Offset;
  T.Frames[T.FrameCount].Size := Size;
  Inc(T.FrameCount);
end;

{ copies all frames (with the stripped header bytes) to Dest }
procedure CopyFrames(Str: TStream; const T: TDemuxTrack; Dest: TStream);
var i: Integer;
    Buf: TBytes;
begin
  for i:=0 to T.FrameCount-1 do begin
    if T.Frames[i].Offset + T.Frames[i].Size > Str.Size then Break;
    if Length(T.Prefix) > 0 then Dest.WriteBuffer(T.Prefix[0], Length(T.Prefix));
    if Length(Buf) < T.Frames[i].Size then SetLength(Buf, T.Frames[i].Size);
    Str.Position := T.Frames[i].Offset;
    Str.ReadBuffer(Buf[0], T.Frames[i].Size);
    Dest.WriteBuffer(Buf[0], T.Frames[i].Size);
  end;
  Dest.Position := 0;
end;

procedure WriteU16(S: TStream; V: Word);
begin
  S.WriteBuffer(V, 2);
end;

procedure WriteU32(S: TStream; V: Cardinal);
begin
  S.WriteBuffer(V, 4);
end;

{ RIFF WAVE file around the data; Fmt = WAVEFORMATEX (or nil for plain PCM) }
function BuildWav(Str: TStream; const T: TDemuxTrack; const Fmt: TBytes): TMemoryStream;
var Data: TMemoryStream;
    i, BytesPer: Integer;
    P: PByte;
    B: Byte;
begin
  Data := TMemoryStream.Create;
  try
    CopyFrames(Str, T, Data);
    if T.PcmBigEndian and (T.Bits > 8) then begin
      // swap to little endian
      BytesPer := T.Bits div 8;
      P := Data.Memory;
      i := 0;
      while i + BytesPer <= Data.Size do begin
        case BytesPer of
          2: begin B := P[i]; P[i] := P[i+1]; P[i+1] := B; end;
          3: begin B := P[i]; P[i] := P[i+2]; P[i+2] := B; end;
          4: begin B := P[i]; P[i] := P[i+3]; P[i+3] := B; B := P[i+1]; P[i+1] := P[i+2]; P[i+2] := B; end;
          8: begin
            B := P[i]; P[i] := P[i+7]; P[i+7] := B; B := P[i+1]; P[i+1] := P[i+6]; P[i+6] := B;
            B := P[i+2]; P[i+2] := P[i+5]; P[i+5] := B; B := P[i+3]; P[i+3] := P[i+4]; P[i+4] := B;
          end;
        end;
        Inc(i, BytesPer);
      end;
    end;
    Result := TMemoryStream.Create;
    Result.WriteBuffer(AnsiString('RIFF')[1], 4);
    if Length(Fmt) > 0 then WriteU32(Result, 4 + 8 + ((Length(Fmt) + 1) and not 1) + 8 + Data.Size)
    else WriteU32(Result, 4 + 8 + 16 + 8 + Data.Size);
    Result.WriteBuffer(AnsiString('WAVEfmt ')[1], 8);
    if Length(Fmt) > 0 then begin
      WriteU32(Result, Length(Fmt));
      Result.WriteBuffer(Fmt[0], Length(Fmt));
      if Odd(Length(Fmt)) then begin B := 0; Result.WriteBuffer(B, 1); end;
    end
    else begin
      WriteU32(Result, 16);
      if T.PcmFloat then WriteU16(Result, 3) else WriteU16(Result, 1);
      WriteU16(Result, T.Channels);
      WriteU32(Result, T.Rate);
      WriteU32(Result, T.Rate * T.Channels * (T.Bits div 8));
      WriteU16(Result, T.Channels * (T.Bits div 8));
      WriteU16(Result, T.Bits);
    end;
    Result.WriteBuffer(AnsiString('data')[1], 4);
    WriteU32(Result, Data.Size);
    Result.CopyFrom(Data, 0);
    Result.Position := 0;
  finally
    Data.Free;
  end;
end;

{ --- Ogg encapsulation of Vorbis packets --- }

var
  OggCrcTable: array[0..255] of Cardinal;
  OggCrcReady: Boolean = False;

function OggCrc(P: PByte; Len: Integer): Cardinal;
var i, j: Integer;
    R: Cardinal;
begin
  if not OggCrcReady then begin
    for i:=0 to 255 do begin
      R := Cardinal(i) shl 24;
      for j:=0 to 7 do
        if R and $80000000 <> 0 then R := (R shl 1) xor $04C11DB7 else R := R shl 1;
      OggCrcTable[i] := R;
    end;
    OggCrcReady := True;
  end;
  Result := 0;
  for i:=0 to Len-1 do
    Result := (Result shl 8) xor OggCrcTable[((Result shr 24) xor P[i]) and $FF];
end;

type
  TOggWriter = class
    Dest: TMemoryStream;
    Seq: Cardinal;
    Segs: array[0..254] of Byte;
    NSegs: Integer;
    Body: TMemoryStream;
    Continued: Boolean;   // the next page continues a packet
    constructor Create(ADest: TMemoryStream);
    destructor Destroy; override;
    procedure Flush(Flags: Byte; Granule: Int64);
    procedure AddPacket(P: PByte; Len: Integer; Granule: Int64);
  end;

constructor TOggWriter.Create(ADest: TMemoryStream);
begin
  Dest := ADest;
  Body := TMemoryStream.Create;
end;

destructor TOggWriter.Destroy;
begin
  Body.Free;
  inherited Destroy;
end;

procedure TOggWriter.Flush(Flags: Byte; Granule: Int64);
var Hdr: array[0..27 + 255 - 1] of Byte;
    HLen: Integer;
    Crc: Cardinal;
    Page: TBytes;
begin
  if (NSegs = 0) and (Body.Size = 0) then Exit;
  FillChar(Hdr, SizeOf(Hdr), 0);
  Hdr[0] := Ord('O'); Hdr[1] := Ord('g'); Hdr[2] := Ord('g'); Hdr[3] := Ord('S');
  Hdr[5] := Flags or Ord(Continued);
  Continued := False;
  Move(Granule, Hdr[6], 8);
  PCardinal(@Hdr[14])^ := 1;    // serial number
  PCardinal(@Hdr[18])^ := Seq;
  Hdr[26] := NSegs;
  Move(Segs[0], Hdr[27], NSegs);
  HLen := 27 + NSegs;
  SetLength(Page, HLen + Body.Size);
  Move(Hdr[0], Page[0], HLen);
  if Body.Size > 0 then Move(Body.Memory^, Page[HLen], Body.Size);
  Crc := OggCrc(@Page[0], Length(Page));
  Move(Crc, Page[22], 4);
  Dest.WriteBuffer(Page[0], Length(Page));
  Inc(Seq);
  NSegs := 0;
  Body.Clear;
end;

procedure TOggWriter.AddPacket(P: PByte; Len: Integer; Granule: Int64);
var Rest, N: Integer;
begin
  Rest := Len;
  repeat
    if NSegs = 255 then begin
      Flush(0, -1);                     // no packet ends on this page
      Continued := True;
    end;
    N := Min(Rest, 255);
    Segs[NSegs] := N;
    Inc(NSegs);
    Body.WriteBuffer(P^, N);
    Inc(P, N);
    Dec(Rest, N);
  until (N < 255);
  if NSegs >= 200 then Flush(0, Granule);
end;

function BuildOgg(Str: TStream; const T: TDemuxTrack): TMemoryStream;
var Cnt, i, Pos, Total: Integer;
    Sizes: array[0..2] of Integer;
    W: TOggWriter;
    Buf: TBytes;
    Granule: Int64;
begin
  Result := nil;
  // Xiph lacing: packet count - 1, sizes of all but the last packet
  if Length(T.Priv) < 3 then Exit;
  Cnt := T.Priv[0] + 1;
  if Cnt <> 3 then Exit;
  Pos := 1;
  Total := 0;
  for i:=0 to 1 do begin
    Sizes[i] := 0;
    repeat
      if Pos >= Length(T.Priv) then Exit;
      Inc(Sizes[i], T.Priv[Pos]);
      Inc(Pos);
    until T.Priv[Pos - 1] < 255;
    Inc(Total, Sizes[i]);
  end;
  Sizes[2] := Length(T.Priv) - Pos - Total;
  if Sizes[2] <= 0 then Exit;

  Result := TMemoryStream.Create;
  W := TOggWriter.Create(Result);
  try
    W.AddPacket(@T.Priv[Pos], Sizes[0], 0);
    W.Flush(2, 0);                                  // first page: identification header
    W.AddPacket(@T.Priv[Pos + Sizes[0]], Sizes[1], 0);
    W.AddPacket(@T.Priv[Pos + Sizes[0] + Sizes[1]], Sizes[2], 0);
    W.Flush(0, 0);
    Granule := 0;
    for i:=0 to T.FrameCount-1 do begin
      if T.Frames[i].Offset + T.Frames[i].Size > Str.Size then Break;
      if Length(Buf) < T.Frames[i].Size then SetLength(Buf, T.Frames[i].Size);
      Str.Position := T.Frames[i].Offset;
      Str.ReadBuffer(Buf[0], T.Frames[i].Size);
      Inc(Granule, 1024);   // only needs to increase; the last page is not trimmed
      W.AddPacket(@Buf[0], T.Frames[i].Size, Granule);
    end;
    W.Flush(0, Granule);
  finally
    W.Free;
  end;
  Result.Position := 0;
end;

function DecodeDemuxed(Handle: TXelAudio; Str: TStream; var T: TDemuxTrack): Boolean;
var Mem: TMemoryStream;
    Samples: TSingleDynArray;
    Channels, Rate, i: Integer;
    Refs: TAacFrameRefs;
    Pos: Int64;
begin
  Result := False;
  if T.FrameCount = 0 then Exit;
  SetLength(T.Frames, T.FrameCount);
  Mem := nil;
  try
    case T.Codec of
      dcAac: begin
        if Length(T.Prefix) = 0 then
          Result := DecodeFrameList(Str, T.Frames, fcAac, T.Priv, Samples, Channels, Rate)
        else begin
          Mem := TMemoryStream.Create;
          CopyFrames(Str, T, Mem);
          SetLength(Refs, T.FrameCount);
          Pos := 0;
          for i:=0 to T.FrameCount-1 do begin
            Refs[i].Offset := Pos;
            Refs[i].Size := T.Frames[i].Size + Length(T.Prefix);
            Inc(Pos, Refs[i].Size);
          end;
          Result := DecodeFrameList(Mem, Refs, fcAac, T.Priv, Samples, Channels, Rate);
        end;
        if Result then FillAudio(Handle, Samples, Channels, Rate);
      end;
      dcAacAdts, dcAc3: begin
        Mem := TMemoryStream.Create;
        CopyFrames(Str, T, Mem);
        if T.Codec = dcAc3 then Result := DecodeAC3(Mem, Samples, Channels, Rate)
        else Result := DecodeM4A(Mem, Samples, Channels, Rate);
        if Result then FillAudio(Handle, Samples, Channels, Rate);
      end;
      dcMp3: begin
        Mem := TMemoryStream.Create;
        CopyFrames(Str, T, Mem);
        Result := Handle.LoadFromStream(Mem, 'mp3');
      end;
      dcFlac: begin
        Mem := TMemoryStream.Create;
        if Length(T.Priv) > 0 then Mem.WriteBuffer(T.Priv[0], Length(T.Priv));
        CopyFrames(Str, T, Mem);
        Mem.Position := 0;
        Result := Handle.LoadFromStream(Mem, 'flac');
      end;
      dcVorbis: begin
        Mem := BuildOgg(Str, T);
        if Mem <> nil then Result := Handle.LoadFromStream(Mem, 'ogg');
      end;
      dcPcm: begin
        if not (T.Bits in [8, 16, 24, 32, 64]) or (T.Channels < 1) or (T.Rate < 1) then Exit;
        Mem := BuildWav(Str, T, nil);
        Result := Handle.LoadFromStream(Mem, 'wav');
      end;
      dcWav: begin
        Mem := BuildWav(Str, T, T.Priv);
        Result := Handle.LoadFromStream(Mem, 'wav');
      end;
    end;
  finally
    Mem.Free;
  end;
  Result := Result and (Length(Handle.FFrames) > 0);
end;

end.
