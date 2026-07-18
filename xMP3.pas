unit xMP3;

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

uses Classes, SysUtils, MP3, LameSimple, xAudioBase, xStreams, Dialogs;

type
  TAudioMP3 = class(TAudioBase)
  private
  public
    function LoadFromStream(Str: TStream): Boolean; override;
    function SaveToStream(Str: TStream): Boolean; override;
  end;

implementation

//MP3 supports only fixed MPEG sample rates; for rates within 3% of a valid
//one (old Mac/AU rates like 11127 Hz) the audio is encoded at the nearest
//valid rate, which slightly changes the speed but avoids resampling
function NearestMp3Rate(Rate: Integer): Integer;
const Rates: array[0..8] of Integer = (8000,11025,12000,16000,22050,24000,32000,44100,48000);
var i, Best: Integer;
begin
  Best := Rates[0];

  for i:=0 to High(Rates) do
    if abs(Rates[i]-Rate) < abs(Best-Rate) then Best := Rates[i];

  if abs(Best-Rate)/Rate > 0.03 then
    raise Exception.Create('Sample rate ' + IntToStr(Rate) +
      ' Hz is not supported by MP3, call SetSampleRate first');

  Result := Best;
end;

function TAudioMP3.SaveToStream(Str: TStream): Boolean;
var Info: TPCMInfo;
    Samples: TPCMSamples;
    Mp3Bytes: TBytes;
    NumFrames: Integer;
    Bitrate: Integer;
    i: Integer;
begin
  Result := False;

  NumFrames := Length(FHandle.FFrames);
  if NumFrames < 1 then Exit;

  Bitrate := FHandle.FBitrate;
  if Bitrate < 1 then Bitrate := 128;

  Info.NumChannels   := 2;
  Info.BitsPerSample := 16;
  Info.SampleRate    := NearestMp3Rate(FHandle.FSampleRate);
  Info.NumSamples    := NumFrames;
  Info.DataSize      := NumFrames * 4;

  //LAME encodes signed 16 bit PCM, convert from current sample size
  SetLength(Samples, NumFrames * 2);

  for i:=0 to NumFrames-1 do begin
    Samples[2*i]   := SampleToS16(FHandle.FFrames[i].Left,  FHandle.FSampleSize);
    Samples[2*i+1] := SampleToS16(FHandle.FFrames[i].Right, FHandle.FSampleSize);
  end;

  Mp3Bytes := PCMToMP3(Samples, Info, Bitrate);

  if Length(Mp3Bytes) > 0 then
    Str.WriteBuffer(Mp3Bytes[0], Length(Mp3Bytes));

  Result := True;
end;

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
  RegisterAudioFormat('mp3', TAudioMp3, True);

end.
