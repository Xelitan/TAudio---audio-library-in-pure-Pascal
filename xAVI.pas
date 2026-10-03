unit xAVI;

{$mode objfpc}{$H+}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	AVI reader for TXelAudio                                      //
//		Takes the first audio stream with a supported format: PCM and  //
//		the other WAV formats, MP3, AC-3, AAC. OpenDML (AVIX)         //
//		files over 1 GB are supported; video data is skipped.         //
// Version:	0.1                                                           //
// Date:	02-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal                                            //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses Classes, SysUtils, Math, xAudioBase, xDemux, xMKV;

type

  { TAudioAVI }

  TAudioAVI = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

implementation

type
  TAviReader = class
    Str: TStream;
    FileSize: Int64;
    Track: TDemuxTrack;
    StreamIndex: Integer;   // the chosen audio stream, -1 = none
    StreamCount: Integer;
    ChunkId: array[0..1] of AnsiChar;
    function U32(P: Int64): Cardinal;
    function Fcc(P: Int64): AnsiString;
    procedure ParseHdrl(P, Stop: Int64);
    procedure ParseStrl(P, Stop: Int64);
    procedure ParseMovi(P, Stop: Int64; Depth: Integer);
    function Parse: Boolean;
  end;

function TAviReader.U32(P: Int64): Cardinal;
begin
  if P + 4 > FileSize then raise Exception.Create('AVI data truncated');
  Str.Position := P;
  Str.ReadBuffer(Result, 4);
end;

function TAviReader.Fcc(P: Int64): AnsiString;
begin
  SetLength(Result, 4);
  if P + 4 > FileSize then raise Exception.Create('AVI data truncated');
  Str.Position := P;
  Str.ReadBuffer(Result[1], 4);
end;

procedure TAviReader.ParseStrl(P, Stop: Int64);
var Id: AnsiString;
    Size: Int64;
    IsAudio: Boolean;
    Fmt: TBytes;
    T: TDemuxTrack;
begin
  IsAudio := False;
  Fmt := nil;
  while P + 8 <= Stop do begin
    Id := Fcc(P);
    Size := U32(P + 4);
    if Id = 'strh' then IsAudio := Fcc(P + 8) = 'auds'
    else if (Id = 'strf') and (Size >= 16) and (Size < 1 shl 20) then begin
      SetLength(Fmt, Size);
      Str.Position := P + 8;
      Str.ReadBuffer(Fmt[0], Size);
    end;
    P := P + 8 + ((Size + 1) and not 1);
  end;
  if IsAudio and (StreamIndex < 0) and (Length(Fmt) > 0) then begin
    T := Default(TDemuxTrack);
    TrackFromWaveFormat(T, Fmt);
    if T.Codec <> dcNone then begin
      Track := T;
      StreamIndex := StreamCount;
    end;
  end;
  Inc(StreamCount);
end;

procedure TAviReader.ParseHdrl(P, Stop: Int64);
var Id: AnsiString;
    Size: Int64;
begin
  while P + 8 <= Stop do begin
    Id := Fcc(P);
    Size := U32(P + 4);
    if (Id = 'LIST') and (Size >= 4) and (Fcc(P + 8) = 'strl') then ParseStrl(P + 12, Min(Stop, P + 8 + Size));
    P := P + 8 + ((Size + 1) and not 1);
  end;
end;

procedure TAviReader.ParseMovi(P, Stop: Int64; Depth: Integer);
var Id: AnsiString;
    Size: Int64;
begin
  while P + 8 <= Stop do begin
    Id := Fcc(P);
    Size := U32(P + 4);
    if Id = 'LIST' then begin
      if (Depth < 4) and (Size >= 4) then ParseMovi(P + 12, Min(Stop, P + 8 + Size), Depth + 1);
    end
    else if (Id[1] = ChunkId[0]) and (Id[2] = ChunkId[1]) and (Id[3] = 'w') and (Id[4] = 'b') then
      AddFrame(Track, P + 8, Min(Size, Stop - P - 8));
    P := P + 8 + ((Size + 1) and not 1);
  end;
end;

function TAviReader.Parse: Boolean;
var P, Size, RiffEnd, Q: Int64;
    Id, Kind: AnsiString;
    First: Boolean;
begin
  Result := False;
  FileSize := Str.Size;
  StreamIndex := -1;
  P := 0;
  First := True;
  while P + 12 <= FileSize do begin
    if Fcc(P) <> 'RIFF' then Break;
    Size := U32(P + 4);
    Kind := Fcc(P + 8);
    if First and (Kind <> 'AVI ') then Exit;
    if not First and (Kind <> 'AVIX') then Break;
    RiffEnd := Min(FileSize, P + 8 + Size);
    Q := P + 12;
    while Q + 8 <= RiffEnd do begin
      Id := Fcc(Q);
      Size := U32(Q + 4);
      if (Id = 'LIST') and (Size >= 4) then begin
        Kind := Fcc(Q + 8);
        if Kind = 'hdrl' then begin
          ParseHdrl(Q + 12, Min(RiffEnd, Q + 8 + Size));
          if StreamIndex < 0 then Exit;
          ChunkId[0] := AnsiChar(Ord('0') + StreamIndex div 10);
          ChunkId[1] := AnsiChar(Ord('0') + StreamIndex mod 10);
        end
        else if (Kind = 'movi') and (StreamIndex >= 0) then
          ParseMovi(Q + 12, Min(RiffEnd, Q + 8 + Size), 0);
      end;
      Q := Q + 8 + ((Size + 1) and not 1);
    end;
    P := RiffEnd + (RiffEnd and 1);
    First := False;
  end;
  Result := (StreamIndex >= 0) and (Track.FrameCount > 0);
end;

{ TAudioAVI }

function TAudioAVI.LoadFromStream(Str: TStream): Boolean;
var R: TAviReader;
begin
  Result := False;
  R := TAviReader.Create;
  try
    R.Str := Str;
    try
      if not R.Parse then Exit;
    except
      // a damaged or truncated file: decode what was found
      if R.Track.FrameCount = 0 then raise;
    end;
    Result := DecodeDemuxed(FHandle, Str, R.Track);
  finally
    R.Free;
  end;
end;

initialization
  RegisterAudioFormat('avi', TAudioAVI);

end.
