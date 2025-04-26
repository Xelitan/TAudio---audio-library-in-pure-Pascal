unit xAU;

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

uses
  Windows, SysUtils, Classes, Math, xAudioBase, xStreams, Dialogs;

type
  TAudioAU = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

implementation

function TAudioAU.LoadFromStream(Str: TStream): Boolean;
var Magic, DataOffset, Encoding, SampleRate, Channels, NumFrames: Integer;
    i: Integer;
    DataSize: LongWord;
    r: TReader;
begin
  Result := False;

  if Str.Size < 100 then Exit;

  r := TReader.Create(Str);

  Magic      := r.getMU4;
  DataOffset := r.getMU4;
  DataSize   := r.getMU4;
  Encoding   := r.getMU4; //ULAW = 1?
  SampleRate := r.getMU4;
  Channels   := r.getMU4;

  if Magic <> $2E736E64 then begin
    r.Free;
    Exit;
  end;

  case Encoding of
   1,3: FHandle.FSampleSize := 16;
   2:   FHandle.FSampleSize := 8;
   4:   FHandle.FSampleSize := 24;
   5:   FHandle.FSampleSize := 32;
  end;

  if DataSize = 0 then  DataSize := Str.Size - DataOffset;
  NumFrames := DataSize div (FHandle.FSampleSize * Channels div 8);

  r.offset := DataOffset;

  FHandle.FSampleRate := SampleRate;
  SetLength(FHandle.FFrames, NumFrames);

  for i:=0 to NumFrames-1 do begin
    FHandle.FFrames[i].Left  := 0;
    FHandle.FFrames[i].Right := 0;
  end; 

  if Encoding = 1 then begin
    //MuLaw
    for i:=0 to NumFrames-1 do begin
       FHandle.FFrames[i].Left  := MuLaw_Decode2(r.getI);
       if Channels > 1 then
       FHandle.FFrames[i].Right := MuLaw_Decode2(r.getI);
    end;
  end
  else if Encoding = 2 then begin
    //PCM 8
   for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left  := r.getU + 128;
      if Channels > 1 then
      FHandle.FFrames[i].Right := r.getU + 128;
    end;
   end
  else if Encoding = 3 then begin
    //PCM 16
   for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left  := r.getMI2;
      if Channels > 1 then
      FHandle.FFrames[i].Right := r.getMI2;
    end;
   end
   else if Encoding = 4 then begin      //TODO: problem?
     //PCM 24
    for i:=0 to NumFrames-1 do begin
       FHandle.FFrames[i].Left  := r.getMI3;
       if Channels > 1 then
       FHandle.FFrames[i].Right := r.getMI3;
     end;
   end
   else if Encoding = 5 then begin
     //PCM 32
    for i:=0 to NumFrames-1 do begin
       FHandle.FFrames[i].Left  := r.getMI4;
       if Channels > 1 then
       FHandle.FFrames[i].Right := r.getMI4;
     end;
  end;

  r.Free;
  Result := True;
end;

initialization
  RegisterAudioFormat('au', TAudioAu);

end.
    
