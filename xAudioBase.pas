unit xAudioBase;

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

uses Classes, SysUtils, xStreams, Dialogs, xAudio;

type
  { TAudioBase }

  TAudioBase = class
  protected
    FHandle: TXelAudio;
  public
    constructor Create(Obj: TXelAudio);
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

const //IMA ADPCM tables, shared by the WAV and AIFF decoders
  ImaStepTable: array[0..88] of Integer = (
    7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,
    50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,
    337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,
    1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,
    6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,
    22385,24623,27086,29794,32767);
  ImaIndexTable: array[0..15] of Integer = (-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8);

  function MuLaw_Decode2(muLawSample: ShortInt): SmallInt;
  function ALaw_Decode2(aLawSample: ShortInt): SmallInt;

  //frames are stored as raw (possibly unsigned) values; these convert
  //between stored form and signed values, 8 bit is unsigned (WAV style)
  function SampleToSigned(V: LongInt; SampleSize: Byte): LongInt;
  function SignedToSample(V: Int64; SampleSize: Byte): LongInt;
  function SampleToS16(V: LongInt; SampleSize: Byte): SmallInt;

  //QuickTime 'ima4' packets (34 bytes per channel = 64 samples), used by
  //AIFC and CAF; reads AudioDataSize bytes from r, returns the frame count
  function Ima4Decode(r: TReader; Handle: TXelAudio; NumChannels, AudioDataSize: Integer): Integer;

  procedure RegisterAudioFormat(Ext: String; ClassName: TAudioBaseClass; CanSave: Boolean = False);
  function FindFormatByExt(Ext: String; Saving: Boolean = False): TAudioBaseClass;

implementation
var AudioFormatList: array of TAudioFormat;
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

constructor TAudioBase.Create(Obj: TXelAudio);
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



function SampleToSigned(V: LongInt; SampleSize: Byte): LongInt;
begin
  case SampleSize of
    8:  Result := (V and $FF) - 128;
    16: begin
          Result := V and $FFFF;
          if Result >= $8000 then Dec(Result, $10000);
        end;
    24: begin
          Result := V and $FFFFFF;
          if Result >= $800000 then Dec(Result, $1000000);
        end;
    else Result := V;
  end;
end;

function SignedToSample(V: Int64; SampleSize: Byte): LongInt;
begin
  case SampleSize of
    8:  begin
          if V < -128 then V := -128
          else if V > 127 then V := 127;
          Result := V + 128;
        end;
    16: begin
          if V < -32768 then V := -32768
          else if V > 32767 then V := 32767;
          Result := V;
        end;
    24: begin
          if V < -8388608 then V := -8388608
          else if V > 8388607 then V := 8388607;
          Result := V;
        end;
    else begin
          if V < Low(LongInt) then V := Low(LongInt)
          else if V > High(LongInt) then V := High(LongInt);
          Result := V;
        end;
  end;
end;

function SampleToS16(V: LongInt; SampleSize: Byte): SmallInt;
begin
  case SampleSize of
    8:  Result := SampleToSigned(V, 8) * 256;
    16: Result := SampleToSigned(V, 16);
    24: Result := SampleToSigned(V, 24) div 256;
    else Result := SampleToSigned(V, 32) div 65536;
  end;
end;

function Ima4Decode(r: TReader; Handle: TXelAudio; NumChannels, AudioDataSize: Integer): Integer;
var Pred, Idx: array[0..1] of Integer;
    ChanBuf: array[0..1, 0..63] of Integer;
    Blocks, OutPos, blk, c, b, s: Integer;
    Hdr: Word;
    Bt: Byte;
    NewPred, NewIdx: Integer;

  function DecodeNibble(ch, nib: Integer): Integer;
  var Step, Diff: Integer;
  begin
    //QuickTime IMA uses the classic bit-serial difference
    Step := ImaStepTable[Idx[ch]];
    Diff := Step shr 3;
    if (nib and 1) <> 0 then Inc(Diff, Step shr 2);
    if (nib and 2) <> 0 then Inc(Diff, Step shr 1);
    if (nib and 4) <> 0 then Inc(Diff, Step);
    if (nib and 8) <> 0 then Dec(Pred[ch], Diff)
    else                     Inc(Pred[ch], Diff);

    Pred[ch] := SignedToSample(Pred[ch], 16); //clamp

    Idx[ch] := Idx[ch] + ImaIndexTable[nib];
    if Idx[ch] < 0 then Idx[ch] := 0;
    if Idx[ch] > 88 then Idx[ch] := 88;

    Result := Pred[ch];
  end;

begin
  Result := 0;
  if (NumChannels < 1) or (NumChannels > 2) then Exit;

  //packets of 34 bytes per channel: 2 byte header + 32 data bytes = 64 samples
  Blocks := AudioDataSize div (34 * NumChannels);
  SetLength(Handle.FFrames, Blocks * 64);

  Pred[0] := 0; Pred[1] := 0;
  Idx[0]  := 0; Idx[1]  := 0;

  OutPos := 0;

  for blk:=0 to Blocks-1 do begin
    for c:=0 to NumChannels-1 do begin
      Hdr := r.getMU2;
      NewPred := SmallInt(Hdr and $FF80); //top 9 bits: predictor
      NewIdx  := Hdr and $7F;             //low 7 bits: step index
      if NewIdx > 88 then NewIdx := 88;

      //the header predictor is truncated to 9 bits; if it agrees with the
      //running decoder state, keep the state for full precision
      if (Idx[c] <> NewIdx) or (abs(NewPred - Pred[c]) > $7F) then begin
        Pred[c] := NewPred;
        Idx[c]  := NewIdx;
      end;

      for b:=0 to 31 do begin
        Bt := r.getU;
        ChanBuf[c][b*2]   := DecodeNibble(c, Bt and $0F);
        ChanBuf[c][b*2+1] := DecodeNibble(c, Bt shr 4);
      end;
    end;

    for s:=0 to 63 do begin
      Handle.FFrames[OutPos].Left  := ChanBuf[0][s];
      Handle.FFrames[OutPos].Right := ChanBuf[NumChannels-1][s];
      Inc(OutPos);
    end;
  end;

  Result := OutPos;
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
var b, position: Integer;
    decoded: Integer;
begin
  b := Byte(aLawSample) xor $55;

  position := ((b and $70) shr 4) + 4;

  if position <> 4 then
    decoded := ((1 shl position) or
               ((b and $0F) shl (position - 4)) or
               (1 shl (position - 5)))
  else
    decoded := ((b and $0F) shl 1) or 1;

  //in G.711 A-law the sign bit set means a positive value
  if (b and $80) = 0 then decoded := -decoded;

  Result := decoded * 8;
end;

procedure RegisterAudioFormat(Ext: String; ClassName: TAudioBaseClass; CanSave: Boolean);
var Rec: TAudioFormat;
begin
  Rec.ClassName := ClassName;
  Rec.Ext       := LowerCase(Ext);
  Rec.CanSave   := CanSave;

  if AudioFormatListLen >= Length(AudioFormatList) then
    SetLength(AudioFormatList, AudioFormatListLen + 16);

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
