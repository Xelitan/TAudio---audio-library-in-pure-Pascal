unit xAU;

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

uses
  SysUtils, Classes, Math, xAudioBase, xStreams, Dialogs;

type
  TAudioAU = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
    function SaveToStream(Str: TStream): Boolean; override;
  end;

implementation

function TAudioAU.SaveToStream(Str: TStream): Boolean;
var w: TWriter;
    NumChannels, Encoding, BytesPerSample: Integer;
    NumFrames, i: Integer;
begin
  NumChannels := 2;
  NumFrames := Length(FHandle.FFrames);

  case FHandle.FSampleSize of
    8:  begin Encoding := 2; BytesPerSample := 1; end;
    16: begin Encoding := 3; BytesPerSample := 2; end;
    24: begin Encoding := 4; BytesPerSample := 3; end;
    else begin Encoding := 5; BytesPerSample := 4; end;
  end;

  w := TWriter.Create(Str);

  w.putMU4($2E736E64); //.snd
  w.putMU4(24);        //data offset
  w.putMU4(NumFrames * NumChannels * BytesPerSample);
  w.putMU4(Encoding);
  w.putMU4(FHandle.FSampleRate);
  w.putMU4(NumChannels);

  case FHandle.FSampleSize of
    8:  for i:=0 to NumFrames-1 do begin
          //internal 8 bit is unsigned, AU stores signed
          w.putU(FHandle.FFrames[i].Left xor $80);
          w.putU(FHandle.FFrames[i].Right xor $80);
        end;
    16: for i:=0 to NumFrames-1 do begin
          w.putMU2(FHandle.FFrames[i].Left);
          w.putMU2(FHandle.FFrames[i].Right);
        end;
    24: for i:=0 to NumFrames-1 do begin
          w.putMU3(FHandle.FFrames[i].Left);
          w.putMU3(FHandle.FFrames[i].Right);
        end;
    else for i:=0 to NumFrames-1 do begin
          w.putMU4(FHandle.FFrames[i].Left);
          w.putMU4(FHandle.FFrames[i].Right);
        end;
  end;

  w.Free;
  Result := True;
end;

function TAudioAU.LoadFromStream(Str: TStream): Boolean;
var Magic, DataOffset, Encoding, SampleRate, Channels, NumFrames: Integer;
    i: Integer;
    DataSize: LongWord;
    BytesPerSample: Integer;
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

  if (Magic <> $2E736E64) or (Channels < 1) then begin
    r.Free;
    Exit;
  end;

  case Encoding of
   1,27: begin FHandle.FSampleSize := 16; BytesPerSample := 1; end; //mulaw, alaw
   2:    begin FHandle.FSampleSize := 8;  BytesPerSample := 1; end;
   3:    begin FHandle.FSampleSize := 16; BytesPerSample := 2; end;
   4:    begin FHandle.FSampleSize := 24; BytesPerSample := 3; end;
   5:    begin FHandle.FSampleSize := 32; BytesPerSample := 4; end;
   6:    begin FHandle.FSampleSize := 16; BytesPerSample := 4; end; //float 32
   7:    begin FHandle.FSampleSize := 16; BytesPerSample := 8; end; //float 64
   else begin //unsupported encoding
     r.Free;
     Exit;
   end;
  end;

  if (DataSize = 0) or (DataSize > Str.Size - DataOffset) then DataSize := Str.Size - DataOffset;

  NumFrames := DataSize div (BytesPerSample * Channels);

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
  else if Encoding = 27 then begin
    //ALaw
    for i:=0 to NumFrames-1 do begin
       FHandle.FFrames[i].Left  := ALaw_Decode2(r.getI);
       if Channels > 1 then
       FHandle.FFrames[i].Right := ALaw_Decode2(r.getI);
    end;
  end
  else if Encoding = 2 then begin
    //PCM 8, signed to unsigned
   for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left  := r.getU xor $80;
      if Channels > 1 then
      FHandle.FFrames[i].Right := r.getU xor $80;
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
  end
   else if Encoding = 6 then begin
     //float 32 big endian
    for i:=0 to NumFrames-1 do begin
       FHandle.FFrames[i].Left  := SignedToSample(Round(r.getMF * 32768), 16);
       if Channels > 1 then
       FHandle.FFrames[i].Right := SignedToSample(Round(r.getMF * 32768), 16);
     end;
  end
   else if Encoding = 7 then begin
     //float 64 big endian
    for i:=0 to NumFrames-1 do begin
       FHandle.FFrames[i].Left  := SignedToSample(Round(r.getMD * 32768), 16);
       if Channels > 1 then
       FHandle.FFrames[i].Right := SignedToSample(Round(r.getMD * 32768), 16);
     end;
  end;

  if Channels = 1 then
    for i:=0 to NumFrames-1 do
      FHandle.FFrames[i].Right := FHandle.FFrames[i].Left;

  r.Free;
  Result := True;
end;

initialization
  RegisterAudioFormat('au', TAudioAu, True);

end.
    
