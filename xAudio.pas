unit xAudio;

interface

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	TXelAudio - convert and modify sound files                    //
// Version:	0.2                                                           //
// Date:	16-JUL-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

uses Graphics, Classes, SysUtils, Math, BufStream, xStreams, Dialogs, xPlayback;

type
  TXelAudioFrame = record
    Left: Longint;
    Right: Longint;
  end;

  { TXelAudio }

 TXelAudio = class
  private
    function GetTotalSamples: Integer;
  public
    FSampleSize: Byte;
    FSampleRate: Integer;
    FBitrate: Integer; //kbps, used when saving to lossy formats like mp3
    FFrames: array of TXelAudioFrame;
  public
    function SaveToStream(Str: TStream; Ext: String = ''; Bitrate: Integer = 128): Boolean;
    function LoadFromStream(Str: TStream; Ext: String = ''): Boolean;
    function SaveToFile(Filename: String; Bitrate: Integer = 128): Boolean;
    function LoadFromFile(Filename: String): Boolean;

    function FindPeak: Integer;
    function GetRMS: Extended;
    function GetDuration: Extended;
    procedure Cut(FromTime, ToTime: Extended);
    procedure Delete(FromTime, ToTime: Extended);
    procedure FadeOut(Durationn: Extended);
    procedure FadeIn(Durationn: Extended);
    procedure Amplify(Db: Extended);
    procedure Append(Other: TXelAudio);
    procedure Mix(Other: TXelAudio; AtTime: Extended);
    procedure InsertSilence(AtTime, Durationn: Extended);
    procedure Reverse;
    procedure Loop(Count: Integer);
    procedure SwapChannels;
    procedure MonoToStereo;
    procedure StereoToMono;
    procedure Balance(Value: Extended);
    procedure TrimSilence(ThresholdPercent: Extended = 0.5);
    procedure RemoveDCOffset;
    procedure Waveform(Bmp: TBitmap);
    procedure Play;
    procedure Stop;
    procedure Normalize;
    procedure SetSampleRate(Rate: Cardinal);

    property TotalSamples: Integer read GetTotalSamples;
    property Duration: Extended read GetDuration;
  end;

implementation

uses xAudioBase;

//rescale a signed sample between bit depths
function ConvertDepth(V: LongInt; FromBits, ToBits: Byte): LongInt;
begin
  if FromBits = ToBits then Result := V
  else if FromBits < ToBits then Result := V shl (ToBits - FromBits)
  else Result := SarLongint(V, FromBits - ToBits);
end;

function FullScale(SampleSize: Byte): LongInt;
begin
  case SampleSize of
    8:  Result := 127;
    16: Result := 32767;
    24: Result := 8388607;
    else Result := High(LongInt);
  end;
end;

function TXelAudio.FindPeak: Integer;
var Val: Integer;
    i: Integer;
begin
  Result := 0;

  for i:=0 to Length(FFrames)-1 do begin
    Val := abs(SampleToSigned(FFrames[i].Left, FSampleSize));
    if Val > Result then Result := Val;

    Val := abs(SampleToSigned(FFrames[i].Right, FSampleSize));
    if Val > Result then Result := Val;
  end;
end;

procedure TXelAudio.SetSampleRate(Rate: Cardinal);
var Divv: Integer;
    i,j: Integer;
    SumL, SumR: Extended;
    Samples2: array of TXelAudioFrame;
    TotalSamples2: Integer;
begin
  if Rate < 1 then Exit;

  Divv := Floor(FSampleRate / Rate);
  if Divv < 1 then Exit; //upsampling not supported

  TotalSamples2 := Floor(TotalSamples/Divv);

  SetLength(Samples2, TotalSamples2);

  for j:=0 to TotalSamples2-1 do begin

    SumL := 0;
    SumR := 0;

    for i:=0 to Divv-1 do begin
      SumL := SumL + SampleToSigned(FFrames[j*Divv+i].Left,  FSampleSize);
      SumR := SumR + SampleToSigned(FFrames[j*Divv+i].Right, FSampleSize);
    end;

    SumL := SumL / Divv;
    SumR := SumR / Divv;

    Samples2[j].Left  := SignedToSample(Round(SumL), FSampleSize);
    Samples2[j].Right := SignedToSample(Round(SumR), FSampleSize);
  end;

  FFrames := Samples2;
  FSampleRate := FSampleRate div Divv;
end;

procedure TXelAudio.Play;
var Buf: array of SmallInt;
    i, N: Integer;
begin
  //miedzyplatformowo przez xPlayback (waveOut / ALSA / AudioQueue);
  //wczesniejsze sndPlaySound istnialo tylko na Windowsie. Semantyka jak
  //dawniej: blokujaco, do konca utworu.
  N := Length(FFrames);
  if N < 1 then Exit;

  SetLength(Buf, N * 2);
  for i:=0 to N-1 do begin
    Buf[i*2]   := SmallInt(ConvertDepth(SampleToSigned(FFrames[i].Left,  FSampleSize), FSampleSize, 16));
    Buf[i*2+1] := SmallInt(ConvertDepth(SampleToSigned(FFrames[i].Right, FSampleSize), FSampleSize, 16));
  end;

  PlayPCM16(Buf, N, FSampleRate, True);
end;

procedure TXelAudio.Stop;
begin
  StopPlayback;
end;

procedure TXelAudio.Normalize;
var Peak: Integer;
    TargetMax: Integer;
    Factor: Extended;
    i: Integer;
begin
  Peak := FindPeak;
  if Peak = 0 then Exit;

  case FSampleSize of
    8:  TargetMax := 127;
    16: TargetMax := 32767;
    24: TargetMax := 8388607;
    else TargetMax := High(LongInt);
  end;

  Factor := TargetMax / Peak;

  for i:=0 to TotalSamples-1 do begin
    FFrames[i].Left  := SignedToSample(Round(Factor * SampleToSigned(FFrames[i].Left,  FSampleSize)), FSampleSize);
    FFrames[i].Right := SignedToSample(Round(Factor * SampleToSigned(FFrames[i].Right, FSampleSize)), FSampleSize);
  end;
end;

procedure TXelAudio.Cut(FromTime, ToTime: Extended);
var Fromm, Too: Integer;
    Samples2: array of TXelAudioFrame;
    Len: Integer;
    i: Integer;
begin
  Fromm := Round(FromTime * FSampleRate);
  Too   := Round(ToTime * FSampleRate);

  if Fromm < 0 then Fromm := 0;
  if Too > TotalSamples then Too := TotalSamples;

  Len := Too - Fromm;
  if Len < 0 then Len := 0;

  SetLength(Samples2, Len);

  for i:=0 to Len-1 do begin
    Samples2[i].Left  := FFrames[i+Fromm].Left;
    Samples2[i].Right := FFrames[i+Fromm].Right;
  end;

  FFrames := Samples2;
end;

procedure TXelAudio.FadeOut(Durationn: Extended);
var i: Integer;
    Fromm: Integer;
    Len: Integer;
    Val: Extended;
begin
  Fromm := TotalSamples - Round(Durationn*FSampleRate);
  if Fromm < 0 then Fromm := 0;

  Len := TotalSamples - Fromm;
  if Len < 1 then Exit;

  for i:=0 to Len-1 do begin
    Val := 1 - (i/Len);

    FFrames[i+Fromm].Left  := SignedToSample(Round(Val * SampleToSigned(FFrames[i+Fromm].Left,  FSampleSize)), FSampleSize);
    FFrames[i+Fromm].Right := SignedToSample(Round(Val * SampleToSigned(FFrames[i+Fromm].Right, FSampleSize)), FSampleSize);
  end;
end;

procedure TXelAudio.FadeIn(Durationn: Extended);
var i: Integer;
    Len: Integer;
    Val: Extended;
begin
  Len := Round(Durationn*FSampleRate);
  if Len > TotalSamples then Len := TotalSamples;
  if Len < 1 then Exit;

  for i:=0 to Len-1 do begin
    Val := i/Len;

    FFrames[i].Left  := SignedToSample(Round(Val * SampleToSigned(FFrames[i].Left,  FSampleSize)), FSampleSize);
    FFrames[i].Right := SignedToSample(Round(Val * SampleToSigned(FFrames[i].Right, FSampleSize)), FSampleSize);
  end;
end;

procedure TXelAudio.Delete(FromTime, ToTime: Extended);
var Fromm, Too: Integer;
    i: Integer;
begin
  Fromm := Round(FromTime * FSampleRate);
  Too   := Round(ToTime * FSampleRate);

  if Fromm < 0 then Fromm := 0;
  if Too > TotalSamples then Too := TotalSamples;
  if Too <= Fromm then Exit;

  for i:=Too to TotalSamples-1 do
    FFrames[Fromm + (i-Too)] := FFrames[i];

  SetLength(FFrames, TotalSamples - (Too - Fromm));
end;

procedure TXelAudio.Amplify(Db: Extended);
var Factor: Extended;
    i: Integer;
begin
  Factor := Power(10, Db/20);

  for i:=0 to TotalSamples-1 do begin
    FFrames[i].Left  := SignedToSample(Round(Factor * SampleToSigned(FFrames[i].Left,  FSampleSize)), FSampleSize);
    FFrames[i].Right := SignedToSample(Round(Factor * SampleToSigned(FFrames[i].Right, FSampleSize)), FSampleSize);
  end;
end;

procedure TXelAudio.Append(Other: TXelAudio);
var Base, i: Integer;
    L, R: LongInt;
begin
  if Other.FSampleRate <> FSampleRate then
    raise Exception.Create('Append: sample rates differ, call SetSampleRate first');

  Base := TotalSamples;
  SetLength(FFrames, Base + Other.TotalSamples);

  for i:=0 to Other.TotalSamples-1 do begin
    L := ConvertDepth(SampleToSigned(Other.FFrames[i].Left,  Other.FSampleSize), Other.FSampleSize, FSampleSize);
    R := ConvertDepth(SampleToSigned(Other.FFrames[i].Right, Other.FSampleSize), Other.FSampleSize, FSampleSize);

    FFrames[Base+i].Left  := SignedToSample(L, FSampleSize);
    FFrames[Base+i].Right := SignedToSample(R, FSampleSize);
  end;
end;

procedure TXelAudio.Mix(Other: TXelAudio; AtTime: Extended);
var Start, Needed, i: Integer;
    L, R: Int64;
begin
  if Other.FSampleRate <> FSampleRate then
    raise Exception.Create('Mix: sample rates differ, call SetSampleRate first');

  Start := Round(AtTime * FSampleRate);
  if Start < 0 then Start := 0;

  Needed := Start + Other.TotalSamples;
  if Needed > TotalSamples then begin
    i := TotalSamples;
    SetLength(FFrames, Needed);
    while i < Needed do begin
      FFrames[i].Left  := SignedToSample(0, FSampleSize);
      FFrames[i].Right := SignedToSample(0, FSampleSize);
      Inc(i);
    end;
  end;

  for i:=0 to Other.TotalSamples-1 do begin
    L := SampleToSigned(FFrames[Start+i].Left, FSampleSize) +
         ConvertDepth(SampleToSigned(Other.FFrames[i].Left, Other.FSampleSize), Other.FSampleSize, FSampleSize);
    R := SampleToSigned(FFrames[Start+i].Right, FSampleSize) +
         ConvertDepth(SampleToSigned(Other.FFrames[i].Right, Other.FSampleSize), Other.FSampleSize, FSampleSize);

    FFrames[Start+i].Left  := SignedToSample(L, FSampleSize);
    FFrames[Start+i].Right := SignedToSample(R, FSampleSize);
  end;
end;

procedure TXelAudio.InsertSilence(AtTime, Durationn: Extended);
var Start, Len, i: Integer;
begin
  Start := Round(AtTime * FSampleRate);
  if Start < 0 then Start := 0;
  if Start > TotalSamples then Start := TotalSamples;

  Len := Round(Durationn * FSampleRate);
  if Len < 1 then Exit;

  SetLength(FFrames, TotalSamples + Len);

  for i:=TotalSamples-Len-1 downto Start do
    FFrames[i+Len] := FFrames[i];

  for i:=Start to Start+Len-1 do begin
    FFrames[i].Left  := SignedToSample(0, FSampleSize);
    FFrames[i].Right := SignedToSample(0, FSampleSize);
  end;
end;

procedure TXelAudio.Reverse;
var i: Integer;
    Tmp: TXelAudioFrame;
begin
  for i:=0 to (TotalSamples div 2)-1 do begin
    Tmp := FFrames[i];
    FFrames[i] := FFrames[TotalSamples-1-i];
    FFrames[TotalSamples-1-i] := Tmp;
  end;
end;

procedure TXelAudio.Loop(Count: Integer);
var Base, c, i: Integer;
begin
  if Count < 2 then Exit;

  Base := TotalSamples;
  SetLength(FFrames, Base * Count);

  for c:=1 to Count-1 do
    for i:=0 to Base-1 do
      FFrames[c*Base + i] := FFrames[i];
end;

procedure TXelAudio.SwapChannels;
var i: Integer;
    Tmp: Longint;
begin
  for i:=0 to TotalSamples-1 do begin
    Tmp := FFrames[i].Left;
    FFrames[i].Left := FFrames[i].Right;
    FFrames[i].Right := Tmp;
  end;
end;

procedure TXelAudio.MonoToStereo;
var i: Integer;
begin
  //copies the left channel to the right one
  for i:=0 to TotalSamples-1 do
    FFrames[i].Right := FFrames[i].Left;
end;

procedure TXelAudio.StereoToMono;
var i: Integer;
    Avg: LongInt;
begin
  for i:=0 to TotalSamples-1 do begin
    Avg := SignedToSample(
      (Int64(SampleToSigned(FFrames[i].Left,  FSampleSize)) +
       Int64(SampleToSigned(FFrames[i].Right, FSampleSize))) div 2, FSampleSize);

    FFrames[i].Left  := Avg;
    FFrames[i].Right := Avg;
  end;
end;

procedure TXelAudio.Balance(Value: Extended);
var FactorL, FactorR: Extended;
    i: Integer;
begin
  //-1 = only left, 0 = neutral, 1 = only right
  if Value < -1 then Value := -1;
  if Value > 1 then Value := 1;

  FactorL := Min(1, 1 - Value);
  FactorR := Min(1, 1 + Value);

  for i:=0 to TotalSamples-1 do begin
    FFrames[i].Left  := SignedToSample(Round(FactorL * SampleToSigned(FFrames[i].Left,  FSampleSize)), FSampleSize);
    FFrames[i].Right := SignedToSample(Round(FactorR * SampleToSigned(FFrames[i].Right, FSampleSize)), FSampleSize);
  end;
end;

procedure TXelAudio.TrimSilence(ThresholdPercent: Extended);
var Thr: LongInt;
    StartAt, EndAt, i: Integer;

  function IsQuiet(Idx: Integer): Boolean;
  begin
    Result := (abs(SampleToSigned(FFrames[Idx].Left,  FSampleSize)) <= Thr) and
              (abs(SampleToSigned(FFrames[Idx].Right, FSampleSize)) <= Thr);
  end;

begin
  if TotalSamples = 0 then Exit;

  Thr := Round(FullScale(FSampleSize) * ThresholdPercent / 100);

  StartAt := 0;
  while (StartAt < TotalSamples) and IsQuiet(StartAt) do Inc(StartAt);

  if StartAt = TotalSamples then begin //everything is silence
    SetLength(FFrames, 0);
    Exit;
  end;

  EndAt := TotalSamples-1;
  while (EndAt > StartAt) and IsQuiet(EndAt) do Dec(EndAt);

  for i:=StartAt to EndAt do
    FFrames[i-StartAt] := FFrames[i];

  SetLength(FFrames, EndAt - StartAt + 1);
end;

procedure TXelAudio.RemoveDCOffset;
var SumL, SumR: Int64;
    MeanL, MeanR: LongInt;
    i: Integer;
begin
  if TotalSamples = 0 then Exit;

  SumL := 0;
  SumR := 0;

  for i:=0 to TotalSamples-1 do begin
    Inc(SumL, SampleToSigned(FFrames[i].Left,  FSampleSize));
    Inc(SumR, SampleToSigned(FFrames[i].Right, FSampleSize));
  end;

  MeanL := SumL div TotalSamples;
  MeanR := SumR div TotalSamples;

  for i:=0 to TotalSamples-1 do begin
    FFrames[i].Left  := SignedToSample(SampleToSigned(FFrames[i].Left,  FSampleSize) - MeanL, FSampleSize);
    FFrames[i].Right := SignedToSample(SampleToSigned(FFrames[i].Right, FSampleSize) - MeanR, FSampleSize);
  end;
end;

function TXelAudio.GetRMS: Extended;
var Sum: Extended;
    i: Integer;
begin
  //RMS amplitude as a fraction of full scale, 0..1
  if TotalSamples = 0 then Exit(0);

  Sum := 0;
  for i:=0 to TotalSamples-1 do begin
    Sum := Sum + Sqr(Extended(SampleToSigned(FFrames[i].Left,  FSampleSize)));
    Sum := Sum + Sqr(Extended(SampleToSigned(FFrames[i].Right, FSampleSize)));
  end;

  Result := Sqrt(Sum / (2*TotalSamples)) / FullScale(FSampleSize);
end;

function TXelAudio.GetDuration: Extended;
begin
  if FSampleRate < 1 then Exit(0);
  Result := TotalSamples / FSampleRate;
end;

procedure TXelAudio.Waveform(Bmp: TBitmap);
var i, j: Integer;
    FromIdx, ToIdx: Integer;
    MinV, MaxV, V: LongInt;
    HalfHei: Integer;
    YTop, YBottom: Integer;
    Peak: Integer;
begin
  if (TotalSamples < 1) or (Bmp.Width < 1) or (Bmp.Height < 2) then Exit;

  HalfHei := Bmp.Height div 2;

  Peak := FindPeak;
  if Peak < 1 then begin //silence, just the zero line
    Bmp.Canvas.Pen.Color := clRed;
    Bmp.Canvas.MoveTo(0, HalfHei);
    Bmp.Canvas.LineTo(Bmp.Width, HalfHei);
    Exit;
  end;

  Bmp.Canvas.Pen.Color := clRed;

  for i:=0 to Bmp.Width-1 do begin
    FromIdx := Int64(i)   * TotalSamples div Bmp.Width;
    ToIdx   := Int64(i+1) * TotalSamples div Bmp.Width - 1;
    if ToIdx < FromIdx then ToIdx := FromIdx;
    if ToIdx > TotalSamples-1 then ToIdx := TotalSamples-1;

    MinV := 0;
    MaxV := 0;

    for j:=FromIdx to ToIdx do begin
      V := SampleToSigned(FFrames[j].Left, FSampleSize);
      if V < MinV then MinV := V;
      if V > MaxV then MaxV := V;

      V := SampleToSigned(FFrames[j].Right, FSampleSize);
      if V < MinV then MinV := V;
      if V > MaxV then MaxV := V;
    end;

    //positive amplitude goes up
    YTop    := HalfHei - Round(MaxV / Peak * HalfHei);
    YBottom := HalfHei - Round(MinV / Peak * HalfHei);

    if YTop < 0 then YTop := 0;
    if YBottom > Bmp.Height-1 then YBottom := Bmp.Height-1;

    Bmp.Canvas.MoveTo(i, YTop);
    Bmp.Canvas.LineTo(i, YBottom+1);
  end;
end;

function TXelAudio.GetTotalSamples: Integer;
begin
  Result := Length(FFrames);
end;

function TXelAudio.SaveToStream(Str: TStream; Ext: String = ''; Bitrate: Integer = 128): Boolean;
var AClassName: TAudioBaseClass;
    Obj: TAudioBase;
begin
  AClassName := FindFormatByExt(Ext, True);
  if AClassName = nil then raise Exception.Create('Unsupported extension');

  FBitrate := Bitrate;

  Obj := AClassName.Create(Self);
  try
    Result := Obj.SaveToStream(Str);
  finally
    Obj.Free;
  end;
end;

function TXelAudio.LoadFromStream(Str: TStream; Ext: String): Boolean;
var AClassName: TAudioBaseClass;
    Obj: TAudioBase;
begin
  AClassName := FindFormatByExt(Ext);
  if AClassName = nil then raise Exception.Create('Unsupported extension');

  Obj := AClassName.Create(Self);
  try
    Result := Obj.LoadFromStream(Str);
  finally
    Obj.Free;
  end;
end;

function TXelAudio.SaveToFile(Filename: String; Bitrate: Integer = 128): Boolean;
var F: TFileStream;
    Ext: String;
begin
  Ext := LowerCase(ExtractFileExt(Filename));
  Ext := Copy(Ext, 2, 99);

  F := TFileStream.Create(Filename, fmCreate);
  try
    Result := SaveToStream(F, Ext, Bitrate);
  finally
    F.Free;
  end;
end;

function TXelAudio.LoadFromFile(Filename: String): Boolean;
var F: TFileStream;
    Ext: String;
begin
  Ext := LowerCase(ExtractFileExt(Filename));
  Ext := Copy(Ext, 2, 99);

  F := TBufferedFileStream.Create(Filename, fmOpenRead or fmShareDenyNone);
  try
    Result := LoadFromStream(F, Ext);
  finally
    F.Free;
  end;
end;

end.
