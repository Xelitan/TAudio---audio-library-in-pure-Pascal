unit xOgg;

interface

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	XelTAudio - convert and modify sound files                    //
// Version:	0.2                                                           //
// Date:	16-JUL-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
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

  b2 := nil;
  Info := nil;
  NumChannels := 0;
  try
    NumFrames := stb_vorbis_decode_memory(buf, len, NumChannels, b2, Info);
  except
    Exit;
  end;

  try
    if (NumFrames <= 0) or (Info = nil) or (b2 = nil) or (NumChannels < 1) then Exit;

    FHandle.FSampleSize := 16;
    FHandle.FSampleRate := Info^.sample_rate;

    SetLength(FHandle.FFrames, NumFrames);

    //b2 holds NumFrames * NumChannels interleaved samples; extra channels
    //(more than 2) are skipped
    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := Word(b2[i*NumChannels]);
      if NumChannels > 1 then
        FHandle.FFrames[i].Right := Word(b2[i*NumChannels + 1])
      else
        FHandle.FFrames[i].Right := 0;
    end;

    Result := True;
  finally
    if b2 <> nil then FreeMem(b2);
    if Info <> nil then stb_vorbis_close(Info);
  end;
end;

initialization
  RegisterAudioFormat('ogg', TAudioOgg);

end.
