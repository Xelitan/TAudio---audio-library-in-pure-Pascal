unit xMP3;

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

uses Classes, SysUtils, MP3, xAudioBase, xStreams, Dialogs;

type
  TAudioMP3 = class(TAudioBase)
  private
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

implementation

function TAudioMP3.LoadFromStream(Str: TStream): Boolean;
var id: TPdmp3Handle;
    res, InSize, OutSize: Integer;
    InBuf, OutBuf: TByteArray;
    Mem: TMemoryStream;
    SampleRate, NumChannels, NumFrames, Encoding: Integer;
    r: TReader;
    i: Integer;
begin
  Result := False;
  Mem := TMemoryStream.Create;

  pdmp3_open_feed(id);
  res := PDMP3_NEED_MORE;
  while (res = PDMP3_OK) or (res = PDMP3_NEED_MORE) do
  begin
    // transcode
    InSize := Str.Read(InBuf, 2048);
    res := pdmp3_decode(id, InBuf, inSize, OutBuf, SizeOf(OutBuf), OutSize);
    if (res = PDMP3_OK) or (res = PDMP3_NEED_MORE) then
    begin
      Mem.Write(OutBuf, OutSize);
    end;
  end;
  //signed 16 bit little endian, 48 khz, mono
  pdmp3_getformat(id, SampleRate, NumChannels, Encoding);
  FHandle.FSampleSize := 16;
  FHandle.FSampleRate := SampleRate;

  NumFrames := Mem.Size div (FHandle.FSampleSize * NumChannels div 8);
  Mem.Position := 0;

  r := TReader.Create(Mem);

  SetLength(FHandle.FFrames, NumFrames);

  for i:=0 to NumFrames-1 do begin
    FHandle.FFrames[i].Left := 0;
    FHandle.FFrames[i].Right := 0;
  end;

  for i:=0 to NumFrames-1 do begin
    FHandle.FFrames[i].Left := r.getU2;
    if NumChannels>1 then
    FHandle.FFrames[i].Right := r.getU2;
  end;

  Result := True;
  r.Free;
  Mem.Free;
end;

initialization
  RegisterAudioFormat('mp3', TAudioMp3);

end.
