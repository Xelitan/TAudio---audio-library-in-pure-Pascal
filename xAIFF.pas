unit xAIFF;
{$mode objfpc}{$H+}

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

uses Classes, SysUtils, Math, xStreams, xFunctions, xAudioBase, Dialogs;

type
  TAudioAIFF = class(TAudioBase)
  private
    function SaneDecode(SANE: TBytes): Double;
    procedure SaneEncode(Value: Cardinal; out SANE: TBytes);
  public
    function LoadFromStream(Str: TStream): Boolean; override;
    function SaveToStream(Str: TStream): Boolean; override;
  end;

implementation

procedure TAudioAIFF.SaneEncode(Value: Cardinal; out SANE: TBytes);
var e, i: Integer;
    Exponent: Integer;
    Mantissa: QWord;
begin
  SetLength(SANE, 10);
  for i:=0 to 9 do SANE[i] := 0;

  if Value = 0 then Exit;

  //position of the highest set bit
  e := 31;
  while (Value and (Cardinal(1) shl e)) = 0 do Dec(e);

  Exponent := 16383 + e;
  Mantissa := QWord(Value) shl (63 - e);

  SANE[0] := (Exponent shr 8) and $7F; //sign bit 0
  SANE[1] := Exponent and $FF;

  for i:=0 to 7 do
    SANE[2+i] := (Mantissa shr (56 - i*8)) and $FF;
end;

function TAudioAIFF.SaveToStream(Str: TStream): Boolean;
var w: TWriter;
    NumChannels, BytesPerSample: Integer;
    NumFrames, AudioDataSize, i: Integer;
    SANE: TBytes;
begin
  NumChannels := 2;
  NumFrames := Length(FHandle.FFrames);

  case FHandle.FSampleSize of
    8:  BytesPerSample := 1;
    16: BytesPerSample := 2;
    24: BytesPerSample := 3;
    else BytesPerSample := 4;
  end;

  AudioDataSize := NumFrames * NumChannels * BytesPerSample;
  SaneEncode(FHandle.FSampleRate, SANE);

  w := TWriter.Create(Str);

  w.putS('FORM');
  w.putMU4(4 + (8+18) + (8+8) + AudioDataSize);
  w.putS('AIFF');

  w.putS('COMM');
  w.putMU4(18);
  w.putMU2(NumChannels);
  w.putMU4(NumFrames);
  w.putMU2(FHandle.FSampleSize);
  w.Put(SANE[0], 10);

  w.putS('SSND');
  w.putMU4(8 + AudioDataSize);
  w.putMU4(0); //offset
  w.putMU4(0); //block size

  case FHandle.FSampleSize of
    8:  for i:=0 to NumFrames-1 do begin
          //internal 8 bit is unsigned, AIFF stores signed
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

function TAudioAIFF.SaneDecode(SANE: TBytes): Double;
var
  SignBit: Integer;
  Exponent: Integer;
  Mantissa: UInt64;
  Fraction: Extended;
begin
  // Extract sign (bit 79)
  SignBit := (SANE[0] shr 7) and 1;

  // Extract exponent (15-bit, bits 78-64)
  Exponent := ((SANE[0] and $7F) shl 8) or SANE[1];

  // Extract 64-bit Mantissa (already includes implicit 1)
  Mantissa := (UInt64(SANE[2]) shl 56) or
              (UInt64(SANE[3]) shl 48) or
              (UInt64(SANE[4]) shl 40) or
              (UInt64(SANE[5]) shl 32) or
              (UInt64(SANE[6]) shl 24) or
              (UInt64(SANE[7]) shl 16) or
              (UInt64(SANE[8]) shl 8) or
               UInt64(SANE[9]);

  if Mantissa = 0 then Exit(0);

  Exponent := Exponent - 16383;

  // The 80-bit format stores the integer bit explicitly (bit 63 of mantissa)
  Fraction := Mantissa / Power(2, 63);

  // Compute final value
  Result := Fraction * Power(2, Exponent);

  // Apply sign
  if SignBit = 1 then  Result := -Result;
end;


function TAudioAIFF.LoadFromStream(Str: TStream): Boolean;
var r: TReader;
    Magic, Magic2, ChunkId: String;
    ChunkSize: Integer;
    Size: Integer;
    Compression, CompressionName: String;
    isAifc: Boolean;
    NumChannels, SampleSize: UInt16;
    SampleRate: Extended;
    AudioDataSize: Integer;
    i: Integer;
    FrameCount, NumSampleFrames: Integer;
    NextChunk, SsndOffset: Integer;
    Xor8: Byte;

  procedure DecodeFloat;
  var Is64: Boolean;
      V: Extended;
      i: Integer;
  begin
    Is64 := Compression in Group('fl64', 'FL64');

    if Is64 then FrameCount := AudioDataSize div (8 * NumChannels)
    else         FrameCount := AudioDataSize div (4 * NumChannels);

    SetLength(FHandle.FFrames, FrameCount);

    for i:=0 to FrameCount-1 do begin
      if Is64 then V := r.getMD else V := r.getMF;
      FHandle.FFrames[i].Left := SignedToSample(Round(V * 32768), 16);

      FHandle.FFrames[i].Right := 0;
      if NumChannels > 1 then begin
        if Is64 then V := r.getMD else V := r.getMF;
        FHandle.FFrames[i].Right := SignedToSample(Round(V * 32768), 16);
      end;
    end;
  end;

  procedure DecodeG711;
  var IsAlaw: Boolean;
      i: Integer;
  begin
    IsAlaw := Compression in Group('alaw', 'ALAW');
    FrameCount := AudioDataSize div NumChannels;

    SetLength(FHandle.FFrames, FrameCount);

    for i:=0 to FrameCount-1 do begin
      if IsAlaw then FHandle.FFrames[i].Left := ALaw_Decode2(r.getI)
      else           FHandle.FFrames[i].Left := MuLaw_Decode2(r.getI);

      FHandle.FFrames[i].Right := 0;
      if NumChannels > 1 then begin
        if IsAlaw then FHandle.FFrames[i].Right := ALaw_Decode2(r.getI)
        else           FHandle.FFrames[i].Right := MuLaw_Decode2(r.getI);
      end;
    end;
  end;

  procedure DecodeIma4;
  begin
    FrameCount := Ima4Decode(r, FHandle, NumChannels, AudioDataSize);
  end;

begin
  Result := False;

  if Str.Size < 54 then Exit;

  r := TReader.Create(Str);

  Magic := r.getS(4);
  Size  := r.getMU4;
  Magic2 := r.getS(4);

  if (Magic <> 'FORM') or (not (Magic2 in Group('AIFF', 'AIFC'))) then begin
    r.Free;
    Exit;
  end;
  isAifc := (Magic2 = 'AIFC');

  NumChannels := 0;
  SampleSize  := 0;
  SampleRate  := 0;
  Compression := 'NONE';

  while r.Offset + 8 <= r.Size do begin
    ChunkId   := r.getS(4);
    ChunkSize := r.getMU4;
    NextChunk := r.Offset + ChunkSize + (ChunkSize mod 2); //chunks are word-aligned

    if ChunkId = 'COMM' then begin
        NumChannels     := r.getMI2;
        NumSampleFrames := r.getMU4;
        SampleSize      := r.getMI2;
        SampleRate      := SaneDecode(r.get(10));

        if ChunkSize >= 24 then begin
          Compression     := r.getS(4);
          CompressionName := r.getPS;
        end
        else begin
          Compression       := 'NONE';
          CompressionName   := '';
        end;
    end
    else if ChunkId in Group('SSND') then begin

      if NumChannels < 1 then begin
        r.Free;
        Exit;
      end;

      FHandle.FSampleSize := 16;
      FHandle.FSampleRate := Round(SampleRate);

      SsndOffset := r.getMU4;
      r.Skip(4); //block size, unused
      r.Skip(SsndOffset);

      AudioDataSize :=  ChunkSize - 8 - SsndOffset;
      FrameCount := 0;

      if Compression in Group('fl32','FL32','fl64','FL64') then DecodeFloat
      else if Compression in Group('ulaw','ULAW','alaw','ALAW') then DecodeG711
      else if Compression = 'ima4' then DecodeIma4
      else if Compression in Group('NONE','twos','sowt','raw ','in24','in32') then begin
      //PCM

      if not (SampleSize in [8,12,16,24,32]) then begin
        r.Free;
        Exit;
      end;

      FHandle.FSampleSize := SampleSize;
      if SampleSize = 12 then FHandle.FSampleSize := 16;

      FrameCount := AudioDataSize div ((FHandle.FSampleSize div 8) * NumChannels);

      SetLength(FHandle.FFrames, FrameCount);
      for i:=0 to FrameCount-1 do begin
        FHandle.FFrames[i].Left := 0;
        FHandle.FFrames[i].Right := 0;
      end;

      //AIFF 8 bit PCM is signed and needs converting to unsigned, except 'raw '
      if Compression = 'raw ' then Xor8 := 0 else Xor8 := $80;

      if Compression = 'sowt' then //Intel
        case SampleSize of
          8:  for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU xor Xor8;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU xor Xor8;
              end;
          12: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU2;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU2;
              end;
          16: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU2;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU2;
              end;
          24: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU3;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU3;
              end;
          32: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU4;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU4;
              end;
        end
      else //Motorola
        case SampleSize of
          8:  for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU xor Xor8;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU xor Xor8;
              end;
          12: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getMU2;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getMU2;
              end;
          16: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getMU2;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getMU2;
              end;
          24: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getMU3 ;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getMU3;
              end;
          32: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getMU4;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getMU4;
              end;
        end;
      end
      else begin
        //unsupported compression type
        r.Free;
        Exit;
      end;

      if NumChannels = 1 then
        for i:=0 to FrameCount-1 do
          FHandle.FFrames[i].Right := FHandle.FFrames[i].Left;

      Result := True;
      break;
    end;

    r.Offset := NextChunk;
  end;

  r.Free;
end;

initialization
  RegisterAudioFormat('aif', TAudioAiff, True);
  RegisterAudioFormat('aiff', TAudioAiff, True);
  RegisterAudioFormat('aff', TAudioAiff, True);

end.

