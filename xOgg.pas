unit xOgg;

interface

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	TAudio - convert and modify sound files                       //
// Version:	0.1                                                           //
// Date:	26-APR-2025                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2025 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

uses Classes, SysUtils, xAudioBase, xStreams, vorbis;

type

  { TAudioOGG }

  TAudioOGG = class(TAudioBase)
  private
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

implementation

function TAudioOGG.LoadFromStream(Str: TStream): Boolean;
var S: TFileStream;
    Buf: array of Byte;
    Len,Len2: Integer;
    NumChannels: Integer;
    Buf2: array of SmallInt;
    b2: pint16;
    NumFrames: Integer;
    Info: Pvorb;
    Mem: TMemoryStream;
    r: TReader;
    i: Integer;
begin
  Result := False;
  Len := Str.Size;
  SetLength(Buf, Len);

  Str.Read(Buf[0], Len);

  try
    NumFrames := stb_vorbis_decode_memory(buf, len, NumChannels, b2, Info);
  except
    Exit;
  end;

  FHandle.FSampleSize := 16;
  FHandle.FSampleRate := Info^.sample_rate;

  SetLength(FHandle.FFrames, NumFrames);

  Mem := TMemoryStream.Create;
  Mem.Write(B2^, NumFrames*2);
  Mem.Position := 0;

  r := TReader.Create(Mem);

  for i:=0 to NumFrames-1 do begin
    FHandle.FFrames[i].Left := 0;
    FHandle.FFrames[i].Right := 0;
  end;

  for i:=0 to NumFrames-1 do begin
    FHandle.FFrames[i].Left  := r.getU2;
    if NumChannels > 1 then
      FHandle.FFrames[i].Right := r.getU2;
  end;

  Result := True;
  Mem.Free;
  r.Free;
end;

initialization
  RegisterAudioFormat('ogg', TAudioOgg);

end.
