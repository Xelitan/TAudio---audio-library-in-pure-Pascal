unit xAudio;

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

uses MMSystem, Graphics, Classes, SysUtils, Math, BufStream, xStreams, Dialogs;

type
  TAudioFrame = record
    Left: Longint;
    Right: Longint;
  end;

  { TAudio }

  TAudio = class
  private
    function GetTotalSamples: Integer;
  public
    FSampleSize: Byte;
    FSampleRate: Integer;
    FFrames: array of TAudioFrame;
  public
    function SaveToStream(Str: TStream; Ext: String = ''): Boolean;
    function LoadFromStream(Str: TStream; Ext: String = ''): Boolean;
    function SaveToFile(Filename: String): Boolean;
    function LoadFromFile(Filename: String): Boolean;

    function FindPeak: Integer;
    procedure Cut(FromTime, ToTime: Integer);
    procedure FadeOut(Durationn: Integer);
    procedure Waveform(Bmp: TBitmap);
    procedure Play;
    procedure Stop;
    procedure Normalize;
    procedure SetSampleRate(Rate: Cardinal);

    property TotalSamples: Integer read GetTotalSamples;
  end;

implementation

uses xAudioBase;

function TAudio.FindPeak: Integer;
var Minn, Maxx: Integer;
    i: Integer;
begin
  for i:=0 to Length(FFrames)-1 do begin
    Minn := Min(Minn, FFrames[i].Left);
    Maxx := Max(Maxx, FFrames[i].Right);
  end;

  Minn := abs(Minn);
  if Minn > Maxx then Maxx := Minn;

  Result := Maxx;
end;

procedure TAudio.SetSampleRate(Rate: Cardinal);
var Divv: Integer;
    i,j: Integer;
    Sum: Extended;
    Samples2: array of TAudioFrame;
    TotalSamples2: Integer;
begin
  Divv := Floor(FSampleRate / Rate);

  TotalSamples2 := Floor(TotalSamples/Divv);

  SetLength(Samples2, TotalSamples2);

  for j:=0 to TotalSamples2-1 do begin

    Sum := 0;

    for i:=0 to Divv-1 do begin
      Sum := Sum + FFrames[j*Divv+i].Left;
    end;

    Sum := Sum / Divv;

    Samples2[j].Left := Round(Sum);
  end;


 SetLength(FFrames, TotalSamples2);

 //copy
 for j:=0 to TotalSamples2-1 do begin
   FFrames[j].Left := Samples2[j].Left;
 end;

end;

procedure TAudio.Play;
var Mem: TMemoryStream;
begin
  Mem := TMemoryStream.Create;

  SaveToStream(Mem, 'wav');
  Mem.Position := 0;

  sndPlaySound(Mem.Memory, (SND_SYNC or SND_MEMORY));
  Mem.Free;
end;

procedure TAudio.Stop;
begin
  sndPlaySound(nil, SND_ASYNC);
end;

procedure TAudio.Normalize;
var Peak: Integer;
    TargetMax: Integer;
    MaxReduce: Extended;
    ValAbs: Integer;
    Factor: Extended;
    i: Integer;
begin
  Peak := FindPeak;

  TargetMax := 8000;

  for i:=0 to TotalSamples-1 do begin

    MaxReduce := 1 - TargetMax/Peak;

    ValAbs := abs(FFrames[i].Left);

    Factor := maxReduce * ValAbs/Peak;

    FFrames[0].Left := Round((1 - Factor) * FFrames[i].Left);
  end;
end;

procedure TAudio.Cut(FromTime, ToTime: Integer);
var Fromm, Too: Integer;
    Samples2: array of TAudioFrame;
    Len: Integer;
    i: Integer;
begin
  Fromm := Round(FromTime * FSampleRate);
  Too   := Round(ToTime * FSampleRate);
  Len   := Too - Fromm;

  SetLength(Samples2, Len);

  for i:=0 to Len-1 do
    Samples2[i].Left := FFrames[i+Fromm].Left;

  FFrames := Samples2;
end;

procedure TAudio.FadeOut(Durationn: Integer);
var i: Integer;
    Fromm: Integer;
    Len: Integer;
    Val: Extended;
begin
  Fromm := TotalSamples - Round(Durationn*FSampleRate);

  Len := TotalSamples - Fromm;

  for i:=0 to Len-1 do begin
    Val := 1 - (i/Len);

    FFrames[i+Fromm].Left := Round(FFrames[i+Fromm].Left * Val);
  end;

end;

procedure TAudio.Waveform(Bmp: TBitmap);
var i: Integer;
    ScaleX, ScaleY: Extended;
    j: Integer;
    Sum: Extended;
    Divv: Integer;
    HalfHei: Integer;
begin
  Divv := Floor(TotalSamples / Bmp.Width);

  HalfHei := Bmp.Height div 2;

  Bmp.Canvas.Pen.Color := clRed;

  for i:=0 to Bmp.Width-1 do begin

    Sum := 0;

    for j:=0 to Divv-1 do begin
      Sum := Sum + FFrames[i*Divv+j].Left;
    end;

    Sum := Sum / Divv;

    if Sum > 0 then Sum := (Sum/4000) * HalfHei
    else            Sum := (Sum/-4000) * -HalfHei;

    Bmp.Canvas.MoveTo(i, HalfHei);
    Bmp.Canvas.LineTo(i, HalfHei+Round(Sum));

  end;
end;

function TAudio.GetTotalSamples: Integer;
begin
  Result := Length(FFrames);
end;

function TAudio.SaveToStream(Str: TStream; Ext: String = ''): Boolean;
var AClassName: TAudioBaseClass;
    Obj: TAudioBase;
begin
  AClassName := FindFormatByExt(Ext, True);
  if AClassName = nil then raise Exception.Create('Unsupported extension');

  Obj := AClassName.Create(Self);
  try
    Result := Obj.SaveToStream(Str);
  finally
    Obj.Free;
  end;
end;

function TAudio.LoadFromStream(Str: TStream; Ext: String): Boolean;
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

function TAudio.SaveToFile(Filename: String): Boolean;
var F: TFileStream;
    Ext: String;
begin
  Ext := LowerCase(ExtractFileExt(Filename));
  Ext := Copy(Ext, 2, 99);

  F := TFileStream.Create(Filename, fmCreate);
  try
    Result := SaveToStream(F, Ext);
  finally
    F.Free;
  end;
end;

function TAudio.LoadFromFile(Filename: String): Boolean;
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
