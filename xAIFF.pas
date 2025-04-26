unit xAIFF;
{$mode objfpc}{$H+}

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

uses Classes, SysUtils, Math, xStreams, xFunctions, xAudioBase, Dialogs;

type
  TAudioAIFF = class(TAudioBase)
  private
    function SaneDecode(SANE: TBytes): Double;
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

implementation

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

  Exponent := Exponent - 16383;

  // Normalize mantissa (explicit 1 included)
  Fraction := 1.0 + (Mantissa / Power(2, 64));

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
begin
  Result := False;

  if Str.Size < 54 then Exit;

  r := TReader.Create(Str);

  Magic := r.getS(4);
  Size  := r.getMU4;
  Magic2 := r.getS(4);

  if (Magic <> 'FORM') or (not (Magic2 in Group('AIFF', 'AIFC'))) then Exit;
  isAifc := (Magic2 = 'AIFC');

  while not r.eof do begin
    ChunkId   := r.getS(4);
    ChunkSize := r.getMU4;

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
        ChunkSize := 0; //whole chunk read
    end
    else if ChunkId in Group('SSND') then begin

      FHandle.FSampleSize := SampleSize;
      if SampleSize = 12 then FHandle.FSampleSize := 16;
      FHandle.FSampleRate := Round(SampleRate);

      AudioDataSize :=  ChunkSize - 8;
      FrameCount := AudioDataSize div ((FHandle.FSampleSize div 8) * NumChannels);

      SetLength(FHandle.FFrames, FrameCount);
      for i:=0 to FrameCount-1 do begin
        FHandle.FFrames[i].Left := 0;
        FHandle.FFrames[i].Right := 0;
      end;

      if Compression = 'sowt' then //Intel
        case SampleSize of
          8:  for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU +128;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU +128;
              end;
          12: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU2 and $FFF0;
                FHandle.FFrames[i].Right := r.getU2 and $FFF0;
              end;
          16: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU2;
                FHandle.FFrames[i].Right := r.getU2;
              end;
          24: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU3 ;
                FHandle.FFrames[i].Right := r.getU3;
              end;
          32: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU4;
                FHandle.FFrames[i].Right := r.getU4;
              end;
        end
      else //Motorola
        case SampleSize of
          8:  for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getU +128;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getU +128;
              end;
          12: for i:=0 to FrameCount-1 do begin
                FHandle.FFrames[i].Left  := r.getMU2 and $FFF0;
                if NumChannels>1 then
                  FHandle.FFrames[i].Right := r.getMU2 and $FFF0;
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

      ChunkSize := 0; //whole chunk read
      break; //should work without this
    end;

    r.Skip(ChunkSize);
    if (ChunkSize mod 2) <> 0 then r.Skip(1);
  end;

  r.Free;
  Result := True;
end;

initialization
  RegisterAudioFormat('aif', TAudioAiff);
  RegisterAudioFormat('aiff', TAudioAiff);
  RegisterAudioFormat('aff', TAudioAiff);

end.

