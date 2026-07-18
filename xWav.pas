unit xWav;

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
  AudioDataSize := Length(FHandle.FFrames) * BlockAlign;
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
  //Result nie byl nigdy ustawiany - wolajacy dostawal smiec ze stosu i mogl
  //losowo zglaszac blad zapisu mimo poprawnie zapisanego pliku
  Result := True;
end;

function TAudioWav.LoadFromStream(Str: TStream): Boolean;
const //MS ADPCM tables
      MsAdapt: array[0..15] of Integer = (230,230,230,230,307,409,512,614,768,614,512,409,307,230,230,230);
      MsCoef1: array[0..6] of Integer = (256,512,0,192,240,460,392);
      MsCoef2: array[0..6] of Integer = (0,-256,0,64,0,-208,-232);
var r: TReader;
    Size, NumChannels, ByteRate, BlockAlign, AudioDataSize: Integer;
    i: Integer;
    Magic, Magic2, ChunkName, Data: String;
    FormatSize, Compression, NumFrames, ExtraLen: Integer;

  procedure DecodeFloat;
  var Bits: Integer;
      V: Extended;
      i: Integer;
  begin
    Bits := FHandle.FSampleSize; //32 or 64 from fmt
    if not (Bits in [32,64]) then Exit;

    NumFrames := AudioDataSize div ((Bits div 8) * NumChannels);
    SetLength(FHandle.FFrames, NumFrames);

    for i:=0 to NumFrames-1 do begin
      if Bits = 64 then V := r.GetD else V := r.GetF;
      FHandle.FFrames[i].Left := SignedToSample(Round(V * 32768), 16);

      FHandle.FFrames[i].Right := 0;
      if NumChannels > 1 then begin
        if Bits = 64 then V := r.GetD else V := r.GetF;
        FHandle.FFrames[i].Right := SignedToSample(Round(V * 32768), 16);
      end;
    end;

    FHandle.FSampleSize := 16;
  end;

  procedure DecodeImaAdpcm;
  var Pred, Idx: array[0..1] of Integer;
      ChanBuf: array[0..1, 0..7] of Integer;
      BytesLeft, BlockBytes, Groups: Integer;
      OutPos, c, g, s, b, n, Step, Diff: Integer;
      Bt: Byte;

    function DecodeNibble(ch, nib: Integer): Integer;
    begin
      Step := ImaStepTable[Idx[ch]];
      Diff := ((2*(nib and 7) + 1) * Step) shr 3;
      if (nib and 8) <> 0 then Dec(Pred[ch], Diff)
      else                     Inc(Pred[ch], Diff);

      Pred[ch] := SignedToSample(Pred[ch], 16); //clamp

      Idx[ch] := Idx[ch] + ImaIndexTable[nib];
      if Idx[ch] < 0 then Idx[ch] := 0;
      if Idx[ch] > 88 then Idx[ch] := 88;

      Result := Pred[ch];
    end;

  begin
    if (NumChannels > 2) or (BlockAlign <= 4*NumChannels) then Exit;

    //upper bound: 1 sample per header + 2 samples per data byte per channel
    SetLength(FHandle.FFrames, (AudioDataSize div BlockAlign + 1) *
              ((BlockAlign - 4*NumChannels) * 2 div NumChannels + 1));

    OutPos := 0;
    BytesLeft := AudioDataSize;

    while BytesLeft >= 4*NumChannels + 4*NumChannels do begin
      BlockBytes := BlockAlign;
      if BlockBytes > BytesLeft then BlockBytes := BytesLeft;
      Dec(BytesLeft, BlockBytes);

      for c:=0 to NumChannels-1 do begin
        Pred[c] := SmallInt(r.getU2);
        Idx[c]  := r.getU;
        if Idx[c] > 88 then Idx[c] := 88;
        r.Skip(1); //reserved
      end;

      //first sample of the block comes from the header
      FHandle.FFrames[OutPos].Left := Pred[0];
      FHandle.FFrames[OutPos].Right := Pred[NumChannels-1];
      Inc(OutPos);

      //data: interleaved groups of 4 bytes (8 samples) per channel
      Groups := (BlockBytes - 4*NumChannels) div (4*NumChannels);

      for g:=0 to Groups-1 do begin
        for c:=0 to NumChannels-1 do
          for b:=0 to 3 do begin
            Bt := r.getU;
            ChanBuf[c][b*2]   := DecodeNibble(c, Bt and $0F);
            ChanBuf[c][b*2+1] := DecodeNibble(c, Bt shr 4);
          end;

        for s:=0 to 7 do begin
          FHandle.FFrames[OutPos].Left  := ChanBuf[0][s];
          FHandle.FFrames[OutPos].Right := ChanBuf[NumChannels-1][s];
          Inc(OutPos);
        end;
      end;

      //trailing bytes of a short block
      r.Skip((BlockBytes - 4*NumChannels) mod (4*NumChannels));
    end;

    SetLength(FHandle.FFrames, OutPos);
    NumFrames := OutPos;
    FHandle.FSampleSize := 16;
  end;

  procedure DecodeMsAdpcm;
  var P, Delta, S1, S2: array[0..1] of Integer;
      BytesLeft, BlockBytes, DataBytes: Integer;
      OutPos, c, b, PredV: Integer;
      Bt: Byte;

    function DecodeNibble(ch, nib: Integer): Integer;
    var sn: Integer;
    begin
      sn := nib;
      if sn >= 8 then sn := sn - 16;

      PredV := SarLongint(S1[ch]*MsCoef1[P[ch]] + S2[ch]*MsCoef2[P[ch]], 8)
               + sn*Delta[ch];
      PredV := SignedToSample(PredV, 16); //clamp

      S2[ch] := S1[ch];
      S1[ch] := PredV;

      Delta[ch] := (MsAdapt[nib] * Delta[ch]) div 256;
      if Delta[ch] < 16 then Delta[ch] := 16;

      Result := PredV;
    end;

  begin
    if (NumChannels > 2) or (BlockAlign <= 7*NumChannels) then Exit;

    //upper bound: 2 header samples + 2 samples per data byte per channel
    SetLength(FHandle.FFrames, (AudioDataSize div BlockAlign + 1) *
              ((BlockAlign - 7*NumChannels) * 2 div NumChannels + 2));

    OutPos := 0;
    BytesLeft := AudioDataSize;

    while BytesLeft > 7*NumChannels do begin
      BlockBytes := BlockAlign;
      if BlockBytes > BytesLeft then BlockBytes := BytesLeft;
      Dec(BytesLeft, BlockBytes);

      for c:=0 to NumChannels-1 do begin
        P[c] := r.getU;
        if P[c] > 6 then P[c] := 6;
      end;
      for c:=0 to NumChannels-1 do Delta[c] := SmallInt(r.getU2);
      for c:=0 to NumChannels-1 do S1[c]    := SmallInt(r.getU2);
      for c:=0 to NumChannels-1 do S2[c]    := SmallInt(r.getU2);

      //the two header samples are output first, oldest first
      FHandle.FFrames[OutPos].Left  := S2[0];
      FHandle.FFrames[OutPos].Right := S2[NumChannels-1];
      Inc(OutPos);
      FHandle.FFrames[OutPos].Left  := S1[0];
      FHandle.FFrames[OutPos].Right := S1[NumChannels-1];
      Inc(OutPos);

      DataBytes := BlockBytes - 7*NumChannels;

      for b:=0 to DataBytes-1 do begin
        Bt := r.getU;

        if NumChannels = 2 then begin
          //high nibble = left, low nibble = right
          FHandle.FFrames[OutPos].Left  := DecodeNibble(0, Bt shr 4);
          FHandle.FFrames[OutPos].Right := DecodeNibble(1, Bt and $0F);
          Inc(OutPos);
        end
        else begin
          FHandle.FFrames[OutPos].Left := DecodeNibble(0, Bt shr 4);
          Inc(OutPos);
          FHandle.FFrames[OutPos].Left := DecodeNibble(0, Bt and $0F);
          Inc(OutPos);
        end;
      end;
    end;

    SetLength(FHandle.FFrames, OutPos);
    NumFrames := OutPos;
    FHandle.FSampleSize := 16;
  end;

  function DecodeMp3: Boolean;
  var AClass: TAudioBaseClass;
      Obj: TAudioBase;
      Mem: TMemoryStream;
      Bytes: TBytes;
  begin
    Result := False;

    //route through the registered mp3 decoder, if compiled in
    AClass := FindFormatByExt('mp3');
    if AClass = nil then Exit;

    Bytes := r.Get(AudioDataSize);
    if Length(Bytes) = 0 then Exit;

    Mem := TMemoryStream.Create;
    Obj := AClass.Create(FHandle);
    try
      Mem.Write(Bytes[0], Length(Bytes));
      Mem.Position := 0;
      Result := Obj.LoadFromStream(Mem);
    finally
      Obj.Free;
      Mem.Free;
    end;

    NumFrames := Length(FHandle.FFrames);
  end;

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

    if (Compression = $FFFE) and (ExtraLen >= 22) then begin
      //WAVE_FORMAT_EXTENSIBLE: real format is in the first 2 bytes of SubFormat GUID
      r.Skip(2); //valid bits per sample
      r.Skip(4); //channel mask
      Compression := r.getU2;
      r.Skip(14); //rest of GUID
      if ExtraLen > 22 then r.Skip(ExtraLen - 22);
    end
    else if ExtraLen > 0 then r.Skip(ExtraLen);
  end;

  //1=PCM, 2=MS ADPCM, 3=IEEE float, 6=alaw, 7=mulaw, $11=IMA ADPCM, $55=MP3
  if not (Compression in [1,2,3,6,7,$11,$55]) then begin
    r.Free;
    Exit;
  end;

  if NumChannels < 1 then begin
    r.Free;
    Exit;
  end;


  ChunkName := '';
  while r.Offset + 8 <= r.Size do begin
    ChunkName := r.getS(4); //'data'
    AudioDataSize := r.getU4;
    if ChunkName = 'data' then break;
    r.skip(AudioDataSize);
    if (AudioDataSize mod 2) <> 0 then r.Skip(1); //chunks are word-aligned
  end;

  if ChunkName <> 'data' then begin
    r.Free;
    Exit;
  end;

  NumFrames := 0;

  if Compression = 2 then DecodeMsAdpcm
  else if Compression = 3 then DecodeFloat
  else if Compression = $11 then DecodeImaAdpcm
  else if Compression = $55 then begin
    if not DecodeMp3 then begin
      r.Free;
      Exit;
    end;
  end
  else if Compression in [6,7] then begin
    //alaw, mulaw: 1 byte per sample
    NumFrames := AudioDataSize div NumChannels;
    SetLength(FHandle.FFrames, NumFrames);
    FHandle.FSampleSize := 16;

    if Compression = 6 then
      for i:=0 to NumFrames-1 do begin
        FHandle.FFrames[i].Left := ALaw_Decode2(r.getI);
        FHandle.FFrames[i].Right := 0;
        if NumChannels>1 then
          FHandle.FFrames[i].Right := ALaw_Decode2(r.getI);
      end
    else
      for i:=0 to NumFrames-1 do begin
        FHandle.FFrames[i].Left := MuLaw_Decode2(r.getI);
        FHandle.FFrames[i].Right := 0;
        if NumChannels>1 then
          FHandle.FFrames[i].Right := MuLaw_Decode2(r.getI);
      end;
  end
  else begin
    //PCM
    if not (FHandle.FSampleSize in [8,16,24,32]) then begin
      r.Free;
      Exit;
    end;

    NumFrames := AudioDataSize div (FHandle.FSampleSize * NumChannels div 8);

    SetLength(FHandle.FFrames, NumFrames);

    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left := 0;
      FHandle.FFrames[i].Right := 0;
    end;

    if FHandle.FSampleSize = 8 then begin
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
  end;

  if NumChannels = 1 then
    for i:=0 to NumFrames-1 do
      FHandle.FFrames[i].Right := FHandle.FFrames[i].Left;

  r.Free;
  Result := True;
end;

initialization
  RegisterAudioFormat('wav', TAudioWav, True);

end.
