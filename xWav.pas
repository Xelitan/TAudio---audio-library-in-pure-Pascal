unit xWav;

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

uses Classes, SysUtils, xStreams, xAudioBase, Dialogs;

type

  { TAudioWav }

  TAudioWav = class(TAudioBase)
  public
    function SaveToStream(Str: TStream): Boolean; override;
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

implementation

function TAudioWav.SaveToStream(Str: TStream): Boolean;
var w: TWriter;
    Size, NumChannels, ByteRate, BlockAlign, AudioDataSize: Integer;
    i: Integer;
begin
  NumChannels := 2;

  ByteRate := FHandle.FSampleRate * NumChannels * (FHandle.FSampleSize div 8);
  BlockAlign := NumChannels * (FHandle.FSampleSize div 8);
  AudioDataSize := Length(FHandle.FFrames) * 4;
  Size := AudioDataSize + 36;

  w := TWriter.Create(Str);

  w.putS('RIFF');
  w.putU4(Size);
  w.putS('WAVE');
  w.putS('fmt ');

  w.putU4(16);
  w.putU2(1); //PCM

  w.putU2(NumChannels);
  w.putU4(FHandle.FSampleRate);
  w.putU4(ByteRate);
  w.putU2(BlockAlign);
  w.putU2(FHandle.FSampleSize);

  w.putS('data');
  w.putU4(AudioDataSize);

  if FHandle.FSampleSize = 8 then begin
    for i:=0 to Length(FHandle.FFrames)-1 do begin
      w.putU(FHandle.FFrames[i].Left);
      w.putU(FHandle.FFrames[i].Right);
    end;
  end
  else if FHandle.FSampleSize = 16 then begin
    for i:=0 to Length(FHandle.FFrames)-1 do begin
      w.putU2(FHandle.FFrames[i].Left);
      w.putU2(FHandle.FFrames[i].Right);
    end;
  end
  else if FHandle.FSampleSize = 24 then begin
    for i:=0 to Length(FHandle.FFrames)-1 do begin
      w.putU3(FHandle.FFrames[i].Left);
      w.putU3(FHandle.FFrames[i].Right);
    end;
  end
  else begin
    for i:=0 to Length(FHandle.FFrames)-1 do begin
      w.putU4(FHandle.FFrames[i].Left);
      w.putU4(FHandle.FFrames[i].Right);
    end;
  end;

  w.Free;
end;

function TAudioWav.LoadFromStream(Str: TStream): Boolean;
var r: TReader;
    Size, NumChannels, ByteRate, BlockAlign, AudioDataSize: Integer;
    i: Integer;
    Magic, Magic2, ChunkName, Data: String;
    FormatSize, Compression, NumFrames, ExtraLen: Integer;
begin
  Result := False;
  if Str.Size < 100 then Exit;

  r := TReader.Create(Str);

  Magic := r.getS(4);
  Size := r.getU4;
  Magic2 := r.getS(4);
  ChunkName := r.getS(4); //'fmt '

  if (Magic <> 'RIFF') or (Magic2 <> 'WAVE') then begin
    r.Free;
    Exit;
  end;

  FormatSize := r.getU4; //16

  Compression := r.getU2;
  NumChannels := r.getU2;
  FHandle.FSampleRate := r.getU4;
  ByteRate    := r.getU4;
  BlockAlign  := r.getU2;
  FHandle.FSampleSize := r.getU2;

  if FormatSize > 16 then begin
    ExtraLen     := r.GetU2;
    if ExtraLen > 0 then r.Skip(ExtraLen);
  end;

  if not Compression in [1,6,7] then begin //not PCM
    r.Free;
    Exit;
  end;


  while true do begin
    ChunkName := r.getS(4); //'data'
    AudioDataSize := r.getU4;
    if ChunkName = 'data' then break;
    r.skip(AudioDataSize);
  end;

  NumFrames := AudioDataSize div (FHandle.FSampleSize * NumChannels div 8);

  SetLength(FHandle.FFrames, NumFrames);

  for i:=0 to NumFrames-1 do begin
    FHandle.FFrames[i].Left := 0;
    FHandle.FFrames[i].Right := 0;
  end;

  if Compression = 6 then begin
    //alaw
    FHandle.FSampleSize := 16;
    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := ALaw_Decode2(r.getU );
      if NumChannels>1 then
        FHandle.FFrames[i].Right := ALaw_Decode2(r.getU );
    end;
  end
  else if Compression = 7 then begin
    //mulaw
    FHandle.FSampleSize := 16;
    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := MuLaw_Decode2(r.getU - 128);
      if NumChannels>1 then
        FHandle.FFrames[i].Right := MuLaw_Decode2(r.getU - 128);
    end;
  end
  else if FHandle.FSampleSize = 8 then begin
    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := r.getU;
      if NumChannels>1 then
        FHandle.FFrames[i].Right := r.getU;
    end;
  end
  else if FHandle.FSampleSize = 16 then begin
    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := r.getU2;
      if NumChannels>1 then
        FHandle.FFrames[i].Right := r.getU2;
    end;
  end
  else if FHandle.FSampleSize = 24 then begin
    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := r.getU3;
      if NumChannels>1 then
        FHandle.FFrames[i].Right := r.getU3;
    end;
  end
  else begin
    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := r.getU4;
      if NumChannels>1 then
        FHandle.FFrames[i].Right := r.getU4;
    end;
  end;

  r.Free;
  Result := True;
end;

initialization
  RegisterAudioFormat('wav', TAudioWav, True);

end.
