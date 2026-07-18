unit xCAF;
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
  { TAudioCAF - Apple Core Audio Format }

  TAudioCAF = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
    function SaveToStream(Str: TStream): Boolean; override;
  end;

implementation

const //desc format flags for 'lpcm'
  kCAFLinearPCMFormatFlagIsFloat        = 1;
  kCAFLinearPCMFormatFlagIsLittleEndian = 2;

function TAudioCAF.SaveToStream(Str: TStream): Boolean;
var w: TWriter;
    NumChannels, BytesPerSample: Integer;
    NumFrames, AudioDataSize, i: Integer;
    Rate: Double;
    RateBits: QWord;
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

  w := TWriter.Create(Str);

  w.putS('caff');
  w.putMU2(1); //version
  w.putMU2(0); //flags

  w.putS('desc');
  w.putMU4(0); w.putMU4(32); //chunk size: Int64 BE

  Rate := FHandle.FSampleRate;
  Move(Rate, RateBits, 8);
  w.putMU4(RateBits shr 32); //sample rate: Float64 BE
  w.putMU4(RateBits and $FFFFFFFF);

  w.putS('lpcm');
  w.putMU4(0);                            //flags: big endian signed integer
  w.putMU4(NumChannels * BytesPerSample); //bytes per packet
  w.putMU4(1);                            //frames per packet
  w.putMU4(NumChannels);
  w.putMU4(FHandle.FSampleSize);          //bits per channel

  w.putS('data');
  w.putMU4(0); w.putMU4(4 + AudioDataSize); //chunk size: Int64 BE
  w.putMU4(0); //edit count

  case FHandle.FSampleSize of
    8:  for i:=0 to NumFrames-1 do begin
          //internal 8 bit is unsigned, CAF stores signed
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

function TAudioCAF.LoadFromStream(Str: TStream): Boolean;
var r: TReader;
    Magic, ChunkType, FormatID: String;
    SizeHi, SizeLo: Cardinal;
    ChunkSize, NextChunk: Int64;
    SampleRate: Double;
    FormatFlags, BytesPerPacket, FramesPerPacket: Cardinal;
    NumChannels, BitsPerChannel: Integer;
    HasDesc, IsFloat, IsLE: Boolean;
    AudioDataSize: Int64;
    NumFrames: Integer;
    V: Extended;
    i: Integer;
    Xor8: Byte;
begin
  Result := False;

  if Str.Size < 44 then Exit;

  r := TReader.Create(Str);

  Magic := r.getS(4);
  if Magic <> 'caff' then begin
    r.Free;
    Exit;
  end;
  r.Skip(2); //version
  r.Skip(2); //flags

  HasDesc := False;
  NumChannels := 0;
  BitsPerChannel := 0;
  FormatFlags := 0;
  SampleRate := 0;
  FormatID := '';
  NumFrames := 0;

  while r.Offset + 12 <= r.Size do begin
    ChunkType := r.getS(4);
    SizeHi := r.getMU4;
    SizeLo := r.getMU4;
    ChunkSize := (Int64(SizeHi) shl 32) or SizeLo;

    NextChunk := r.Offset + ChunkSize;

    if ChunkType = 'desc' then begin
      SampleRate      := r.getMD; //Float64 BE
      FormatID        := r.getS(4);
      FormatFlags     := r.getMU4;
      BytesPerPacket  := r.getMU4;
      FramesPerPacket := r.getMU4;
      NumChannels     := r.getMU4;
      BitsPerChannel  := r.getMU4;
      HasDesc := True;
    end
    else if ChunkType = 'data' then begin

      if (not HasDesc) or (NumChannels < 1) then begin
        r.Free;
        Exit;
      end;

      r.Skip(4); //edit count

      if ChunkSize = -1 then AudioDataSize := r.Size - r.Offset //until end of file
      else                   AudioDataSize := ChunkSize - 4;

      FHandle.FSampleRate := Round(SampleRate);
      FHandle.FSampleSize := 16;

      if FormatID = 'lpcm' then begin
        IsFloat := (FormatFlags and kCAFLinearPCMFormatFlagIsFloat) <> 0;
        IsLE    := (FormatFlags and kCAFLinearPCMFormatFlagIsLittleEndian) <> 0;

        if IsFloat then begin
          if not (BitsPerChannel in [32,64]) then begin
            r.Free;
            Exit;
          end;

          NumFrames := AudioDataSize div ((BitsPerChannel div 8) * NumChannels);
          SetLength(FHandle.FFrames, NumFrames);

          for i:=0 to NumFrames-1 do begin
            case BitsPerChannel of
              32: if IsLE then V := r.getF else V := r.getMF;
              else if IsLE then V := r.getD else V := r.getMD;
            end;
            FHandle.FFrames[i].Left := SignedToSample(Round(V * 32768), 16);

            FHandle.FFrames[i].Right := 0;
            if NumChannels > 1 then begin
              case BitsPerChannel of
                32: if IsLE then V := r.getF else V := r.getMF;
                else if IsLE then V := r.getD else V := r.getMD;
              end;
              FHandle.FFrames[i].Right := SignedToSample(Round(V * 32768), 16);
            end;
          end;
        end
        else begin
          //integer PCM
          if not (BitsPerChannel in [8,16,24,32]) then begin
            r.Free;
            Exit;
          end;

          FHandle.FSampleSize := BitsPerChannel;
          NumFrames := AudioDataSize div ((BitsPerChannel div 8) * NumChannels);
          SetLength(FHandle.FFrames, NumFrames);

          //CAF 8 bit PCM is signed, internal 8 bit is unsigned
          Xor8 := $80;

          for i:=0 to NumFrames-1 do begin
            case BitsPerChannel of
              8:  FHandle.FFrames[i].Left := r.getU xor Xor8;
              16: if IsLE then FHandle.FFrames[i].Left := r.getU2
                  else         FHandle.FFrames[i].Left := r.getMU2;
              24: if IsLE then FHandle.FFrames[i].Left := r.getU3
                  else         FHandle.FFrames[i].Left := r.getMU3;
              else if IsLE then FHandle.FFrames[i].Left := r.getU4
                  else          FHandle.FFrames[i].Left := r.getMU4;
            end;

            FHandle.FFrames[i].Right := 0;
            if NumChannels > 1 then
              case BitsPerChannel of
                8:  FHandle.FFrames[i].Right := r.getU xor Xor8;
                16: if IsLE then FHandle.FFrames[i].Right := r.getU2
                    else         FHandle.FFrames[i].Right := r.getMU2;
                24: if IsLE then FHandle.FFrames[i].Right := r.getU3
                    else         FHandle.FFrames[i].Right := r.getMU3;
                else if IsLE then FHandle.FFrames[i].Right := r.getU4
                    else          FHandle.FFrames[i].Right := r.getMU4;
              end;
          end;
        end;
      end
      else if FormatID = 'ulaw' then begin
        NumFrames := AudioDataSize div NumChannels;
        SetLength(FHandle.FFrames, NumFrames);

        for i:=0 to NumFrames-1 do begin
          FHandle.FFrames[i].Left := MuLaw_Decode2(r.getI);
          FHandle.FFrames[i].Right := 0;
          if NumChannels > 1 then
            FHandle.FFrames[i].Right := MuLaw_Decode2(r.getI);
        end;
      end
      else if FormatID = 'alaw' then begin
        NumFrames := AudioDataSize div NumChannels;
        SetLength(FHandle.FFrames, NumFrames);

        for i:=0 to NumFrames-1 do begin
          FHandle.FFrames[i].Left := ALaw_Decode2(r.getI);
          FHandle.FFrames[i].Right := 0;
          if NumChannels > 1 then
            FHandle.FFrames[i].Right := ALaw_Decode2(r.getI);
        end;
      end
      else if FormatID = 'ima4' then begin
        NumFrames := Ima4Decode(r, FHandle, NumChannels, AudioDataSize);
      end
      else begin
        //unsupported format
        r.Free;
        Exit;
      end;

      if NumChannels = 1 then
        for i:=0 to NumFrames-1 do
          FHandle.FFrames[i].Right := FHandle.FFrames[i].Left;

      Result := NumFrames > 0;
      break;
    end;

    if ChunkSize < 0 then break; //unknown size is only valid for the data chunk
    r.Offset := NextChunk;
  end;

  r.Free;
end;

initialization
  RegisterAudioFormat('caf', TAudioCAF, True);

end.
