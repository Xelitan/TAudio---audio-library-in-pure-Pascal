unit xAudioBase;

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

uses Classes, SysUtils, xStreams, Dialogs, xAudio;

type
  { TAudioBase }

  TAudioBase = class
  protected
    FHandle: TAudio;
  public
    constructor Create(Obj: TAudio);
    function SaveToStream(Str: TStream): Boolean; virtual; abstract;
    function LoadFromStream(Str: TStream): Boolean; virtual; abstract;
    function LoadFromFile(Filename: String): Boolean;
    function SaveToFile(Filename: String): Boolean;
  end;

  TAudioBaseClass = class of TAudioBase;

  TAudioFormat = record
    Ext: String;
    ClassName: TAudioBaseClass;
    CanSave: Boolean;
  end;

  function MuLaw_Decode2(muLawSample: ShortInt): SmallInt;
  function ALaw_Decode2(aLawSample: ShortInt): SmallInt;

  procedure RegisterAudioFormat(Ext: String; ClassName: TAudioBaseClass; CanSave: Boolean = False);
  function FindFormatByExt(Ext: String; Saving: Boolean = False): TAudioBaseClass;

implementation
var AudioFormatList: array[0..20] of TAudioFormat;
    AudioFormatListLen: Integer = 0;

function TAudioBase.SaveToFile(Filename: String): Boolean;
var F: TFileStream;
begin
  F := TFileStream.Create(Filename, fmCreate);
  try
    Result := SaveToStream(F);
  finally
    F.Free;
  end;
end;

constructor TAudioBase.Create(Obj: TAudio);
begin
  inherited Create;
  FHandle := Obj;
end;

function TAudioBase.LoadFromFile(Filename: String): Boolean;
var F: TFileStream;
begin
  F := TFileStream.Create(Filename, fmOpenRead or fmShareDenyNone);
  try
    Result := LoadFromStream(F);
  finally
    F.Free;
  end;
end;



function MuLaw_Decode2(muLawSample: ShortInt): SmallInt;
const decodeTable: array[0..7] of Integer = (0,132,396,924,1980,4092,8316,16764);
var sign: Integer;
    exponent: Integer;
    mantissa: Integer;
    sample: Integer;
begin
  muLawSample := not muLawSample;

  sign := (muLawSample and $80);
  exponent := (muLawSample shr 4) and $07;
  mantissa := muLawSample and $0F;

  sample := decodeTable[exponent] + (mantissa shl (exponent+3));

  if (sign <> 0) then sample := -sample;

  Result := sample;
end;

function ALaw_Decode2(aLawSample: ShortInt): SmallInt;
var position: Integer;
    decoded: Integer;
begin
  aLawSample := aLawSample xor $55;

  // Extract sign
  if (aLawSample and $80) <> 0 then
  begin
    aLawSample := aLawSample and $7F; // clear sign bit
    position := ((aLawSample and $F0) shr 4) + 4;

    if position <> 4 then
      decoded := ((1 shl position) or
                 ((aLawSample and $0F) shl (position - 4)) or
                 (1 shl (position - 5)))
    else
      decoded := (aLawSample shl 1) or 1;

    decoded := -decoded;
  end
  else
  begin
    position := ((aLawSample and $F0) shr 4) + 4;

    if position <> 4 then
      decoded := ((1 shl position) or
                 ((aLawSample and $0F) shl (position - 4)) or
                 (1 shl (position - 5)))
    else
      decoded := (aLawSample shl 1) or 1;
  end;

  Result := decoded * 8;
end;

procedure RegisterAudioFormat(Ext: String; ClassName: TAudioBaseClass; CanSave: Boolean);
var Rec: TAudioFormat;
begin
  Rec.ClassName := ClassName;
  Rec.Ext       := LowerCase(Ext);
  Rec.CanSave   := CanSave;

  AudioFormatList[AudioFormatListLen] := Rec;
  Inc(AudioFormatListLen);
end;

function FindFormatByExt(Ext: String; Saving: Boolean): TAudioBaseClass;
var i: Integer;
begin
  Ext := LowerCase(Ext);
  Result := nil;

  for i:=0 to AudioFormatListLen-1 do
    if AudioFormatList[i].Ext = Ext then begin
      if not Saving then Exit(AudioFormatList[i].ClassName);

      if Saving and AudioFormatList[i].CanSave then Exit(AudioFormatList[i].ClassName);
    end;
end;

end.
