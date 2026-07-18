unit xFlac;

{$mode delphi}

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

uses
  Classes, SysUtils, Math, xAudioBase, Dialogs;

type
  TAudioFlac = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
    function SaveToStream(Str: TStream): Boolean; override;
  end;

implementation

const
  FLAC_MARKER: array[0..3] of Byte = (Ord('f'), Ord('L'), Ord('a'), Ord('C'));
  ENCODE_BLOCK_SIZE = 4096;

type
  EFlacError = class(Exception);

  TIntArray = array of Integer;
  TChannels = array of TIntArray;
  TByteArray = array of Byte;

  TFlacStreamInfo = record
    MinBlockSize: Word;
    MaxBlockSize: Word;
    MinFrameSize: Cardinal;
    MaxFrameSize: Cardinal;
    SampleRate: Cardinal;
    Channels: Cardinal;
    BitsPerSample: Cardinal;
    TotalSamples: UInt64;
  end;

  TBitReader = class
  private
    FStream: TStream;
    FCur: Byte;
    FBitsLeft: Integer;
    function ReadByteRaw: Byte;
  public
    constructor Create(AStream: TStream);
    function ReadBits(Count: Integer): UInt64;
    function ReadSignedBits(Count: Integer): Int64;
    function ReadUnary: Cardinal;
    procedure ByteAlign;
  end;

  TBitWriter = class
  private
    FBytes: TByteArray;
    FLen: Integer;
    FCur: Byte;
    FBitsUsed: Integer;
    procedure AppendByte(B: Byte);
  public
    procedure WriteBits(Value: UInt64; Count: Integer);
    procedure WriteSigned(Value: Integer; Count: Integer);
    procedure WriteUnary(Q: Cardinal);
    procedure ByteAlign;
    function Bytes: TByteArray;
  end;

function SignExtend(Value: UInt64; Bits: Integer): Integer;
var
  Mask: UInt64;
begin
  if Bits <= 0 then
    Exit(0);
  Mask := UInt64(1) shl (Bits - 1);
  if (Value and Mask) <> 0 then
    Result := Integer(Int64(Value) - Int64(UInt64(1) shl Bits))
  else
    Result := Integer(Value);
end;

function ReadBE32(S: TStream): Cardinal;
var
  B: array[0..3] of Byte;
begin
  if S.Read(B, 4) <> 4 then
    raise EFlacError.Create('Unexpected end of file');
  Result := (Cardinal(B[0]) shl 24) or (Cardinal(B[1]) shl 16) or
    (Cardinal(B[2]) shl 8) or B[3];
end;

procedure WriteBE16(S: TStream; V: Word);
var
  B: array[0..1] of Byte;
begin
  B[0] := V shr 8;
  B[1] := V and $FF;
  S.WriteBuffer(B, 2);
end;

procedure WriteBE24(S: TStream; V: Cardinal);
var
  B: array[0..2] of Byte;
begin
  B[0] := (V shr 16) and $FF;
  B[1] := (V shr 8) and $FF;
  B[2] := V and $FF;
  S.WriteBuffer(B, 3);
end;

constructor TBitReader.Create(AStream: TStream);
begin
  inherited Create;
  FStream := AStream;
  FBitsLeft := 0;
end;

function TBitReader.ReadByteRaw: Byte;
begin
  if FStream.Read(Result, 1) <> 1 then
    raise EFlacError.Create('Unexpected end of file');
end;

function TBitReader.ReadBits(Count: Integer): UInt64;
var
  Take: Integer;
begin
  Result := 0;
  while Count > 0 do
  begin
    if FBitsLeft = 0 then
    begin
      FCur := ReadByteRaw;
      FBitsLeft := 8;
    end;
    Take := Count;
    if Take > FBitsLeft then
      Take := FBitsLeft;
    Result := (Result shl Take) or ((FCur shr (FBitsLeft - Take)) and ((1 shl Take) - 1));
    Dec(FBitsLeft, Take);
    Dec(Count, Take);
  end;
end;

function TBitReader.ReadSignedBits(Count: Integer): Int64;
begin
  Result := SignExtend(ReadBits(Count), Count);
end;

function TBitReader.ReadUnary: Cardinal;
begin
  Result := 0;
  while ReadBits(1) = 0 do
    Inc(Result);
end;

procedure TBitReader.ByteAlign;
begin
  FBitsLeft := 0;
end;

procedure TBitWriter.AppendByte(B: Byte);
begin
  if FLen = Length(FBytes) then
  begin
    if FLen = 0 then
      SetLength(FBytes, 4096)
    else
      SetLength(FBytes, FLen * 2);
  end;
  FBytes[FLen] := B;
  Inc(FLen);
end;

procedure TBitWriter.WriteBits(Value: UInt64; Count: Integer);
var
  I: Integer;
begin
  for I := Count - 1 downto 0 do
  begin
    FCur := (FCur shl 1) or Byte((Value shr I) and 1);
    Inc(FBitsUsed);
    if FBitsUsed = 8 then
    begin
      AppendByte(FCur);
      FCur := 0;
      FBitsUsed := 0;
    end;
  end;
end;

procedure TBitWriter.WriteSigned(Value: Integer; Count: Integer);
var
  V: UInt64;
begin
  if Value < 0 then
    V := UInt64(Int64(1) shl Count) + UInt64(Int64(Value))
  else
    V := UInt64(Value);
  WriteBits(V, Count);
end;

procedure TBitWriter.WriteUnary(Q: Cardinal);
begin
  while Q >= 32 do
  begin
    WriteBits(0, 32);
    Dec(Q, 32);
  end;
  WriteBits(1, Q + 1); //Q zero bits followed by a one
end;

procedure TBitWriter.ByteAlign;
begin
  if FBitsUsed <> 0 then
    WriteBits(0, 8 - FBitsUsed);
end;

function TBitWriter.Bytes: TByteArray;
begin
  ByteAlign;
  SetLength(FBytes, FLen);
  Result := FBytes;
end;

function Crc8(const Data: TByteArray): Byte;
var
  I, J: Integer;
begin
  Result := 0;
  for I := 0 to High(Data) do
  begin
    Result := Result xor Data[I];
    for J := 0 to 7 do
      if (Result and $80) <> 0 then
        Result := ((Result shl 1) xor $07) and $FF
      else
        Result := (Result shl 1) and $FF;
  end;
end;

function Crc16(const Data: TByteArray): Word;
var
  I, J: Integer;
begin
  Result := 0;
  for I := 0 to High(Data) do
  begin
    Result := Result xor (Word(Data[I]) shl 8);
    for J := 0 to 7 do
      if (Result and $8000) <> 0 then
        Result := ((Result shl 1) xor $8005) and $FFFF
      else
        Result := (Result shl 1) and $FFFF;
  end;
end;

procedure AppendUtf8Int(var A: TByteArray; V: UInt64);
var
  Tmp: array[0..7] of Byte;
  Count, I, L: Integer;
begin
  L := Length(A);
  if V < $80 then
  begin
    SetLength(A, L + 1);
    A[L] := Byte(V);
    Exit;
  end;

  Count := 0;
  repeat
    Tmp[Count] := $80 or Byte(V and $3F);
    V := V shr 6;
    Inc(Count);
  until V < (UInt64(1) shl (7 - Count - 1));

  SetLength(A, L + Count + 1);
  A[L] := Byte((($FF shl (7 - Count)) and $FF) or V);
  for I := Count - 1 downto 0 do
  begin
    Inc(L);
    A[L] := Tmp[I];
  end;
end;

function ReadUtf8Int(BR: TBitReader): UInt64;
var
  First, B: Byte;
  Count, I: Integer;
begin
  First := BR.ReadBits(8);
  if (First and $80) = 0 then
    Exit(First);
  Count := 0;
  while ((First shl Count) and $80) <> 0 do
    Inc(Count);
  if (Count < 2) or (Count > 6) then
    raise EFlacError.Create('Invalid UTF-8 frame number');
  Result := First and ((1 shl (7 - Count)) - 1);
  for I := 1 to Count - 1 do
  begin
    B := BR.ReadBits(8);
    if (B and $C0) <> $80 then
      raise EFlacError.Create('Invalid UTF-8 continuation byte');
    Result := (Result shl 6) or (B and $3F);
  end;
end;

function DecodeRiceSigned(U: UInt64): Integer;
begin
  if (U and 1) = 0 then
    Result := Integer(U shr 1)
  else
    Result := -Integer((U shr 1) + 1);
end;

function FixedPredict(const Samples: TIntArray; Index, Order: Integer): Integer;
begin
  case Order of
    0: Result := 0;
    1: Result := Samples[Index - 1];
    2: Result := 2 * Samples[Index - 1] - Samples[Index - 2];
    3: Result := 3 * Samples[Index - 1] - 3 * Samples[Index - 2] + Samples[Index - 3];
    4: Result := 4 * Samples[Index - 1] - 6 * Samples[Index - 2] + 4 * Samples[Index - 3] - Samples[Index - 4];
  else
    raise EFlacError.Create('Unsupported fixed predictor order');
  end;
end;

function ShiftSigned(Value: Int64; Shift: Integer): Int64;
begin
  if Shift < 0 then
    Result := Value shl (-Shift)
  else if Shift = 0 then
    Result := Value
  else if Value >= 0 then
    Result := Value shr Shift
  else
    Result := -(((-Value) + ((Int64(1) shl Shift) - 1)) shr Shift);
end;

procedure DecodeResidual(BR: TBitReader; var Samples: TIntArray; BlockSize, PredictorOrder: Integer);
var
  Method, PartitionOrder, ParamBits, Escape, Part, Parts, StartAt, EndAt: Integer;
  RiceParam, I, Q: Cardinal;
  U: UInt64;
begin
  Method := BR.ReadBits(2);
  if Method > 1 then
    raise EFlacError.Create('Unsupported residual coding method');
  ParamBits := 4;
  Escape := 15;
  if Method = 1 then
  begin
    ParamBits := 5;
    Escape := 31;
  end;
  PartitionOrder := BR.ReadBits(4);
  Parts := 1 shl PartitionOrder;
  if (BlockSize mod Parts) <> 0 then
    raise EFlacError.Create('Invalid residual partition order');

  for Part := 0 to Parts - 1 do
  begin
    StartAt := Part * (BlockSize div Parts);
    EndAt := StartAt + (BlockSize div Parts);
    if Part = 0 then
      Inc(StartAt, PredictorOrder);
    RiceParam := BR.ReadBits(ParamBits);
    if RiceParam = Cardinal(Escape) then
    begin
      RiceParam := BR.ReadBits(5);
      for I := StartAt to EndAt - 1 do
        Samples[I] := Samples[I] + Integer(BR.ReadSignedBits(RiceParam));
    end
    else
      for I := StartAt to EndAt - 1 do
      begin
        Q := BR.ReadUnary;
        U := (UInt64(Q) shl RiceParam) or BR.ReadBits(RiceParam);
        Samples[I] := Samples[I] + DecodeRiceSigned(U);
      end;
  end;
end;

procedure DecodeSubframe(BR: TBitReader; var Samples: TIntArray; BlockSize, Bps: Integer);
var
  Kind, Wasted, I, Order, Precision, Shift, J: Integer;
  Sum: Int64;
  Coeff: array of Integer;
begin
  if BR.ReadBits(1) <> 0 then
    raise EFlacError.Create('Invalid subframe padding bit');
  Kind := BR.ReadBits(6);
  Wasted := 0;
  if BR.ReadBits(1) <> 0 then
    Wasted := BR.ReadUnary + 1;
  Dec(Bps, Wasted);

  SetLength(Samples, BlockSize);
  if Kind = 0 then
  begin
    Samples[0] := Integer(BR.ReadSignedBits(Bps));
    for I := 1 to BlockSize - 1 do
      Samples[I] := Samples[0];
  end
  else if Kind = 1 then
  begin
    for I := 0 to BlockSize - 1 do
      Samples[I] := Integer(BR.ReadSignedBits(Bps));
  end
  else if (Kind >= 8) and (Kind <= 12) then
  begin
    Order := Kind - 8;
    for I := 0 to Order - 1 do
      Samples[I] := Integer(BR.ReadSignedBits(Bps));
    for I := Order to BlockSize - 1 do
      Samples[I] := 0;
    DecodeResidual(BR, Samples, BlockSize, Order);
    //the prediction must use the already reconstructed previous samples,
    //so it is added after the residual, walking forward
    for I := Order to BlockSize - 1 do
      Samples[I] := Samples[I] + FixedPredict(Samples, I, Order);
  end
  else if (Kind >= 32) and (Kind <= 63) then
  begin
    Order := Kind - 31;
    for I := 0 to Order - 1 do
      Samples[I] := Integer(BR.ReadSignedBits(Bps));
    for I := Order to BlockSize - 1 do
      Samples[I] := 0;
    Precision := BR.ReadBits(4) + 1;
    Shift := BR.ReadSignedBits(5);
    SetLength(Coeff, Order);
    for I := 0 to Order - 1 do
      Coeff[I] := Integer(BR.ReadSignedBits(Precision));
    DecodeResidual(BR, Samples, BlockSize, Order);
    for I := Order to BlockSize - 1 do
    begin
      Sum := 0;
      for J := 0 to Order - 1 do
        Inc(Sum, Coeff[J] * Samples[I - J - 1]);
      Samples[I] := Samples[I] + Integer(ShiftSigned(Sum, Shift));
    end;
  end
  else
    raise EFlacError.CreateFmt('Unsupported subframe type %d', [Kind]);

  if Wasted > 0 then
    for I := 0 to BlockSize - 1 do
      Samples[I] := Samples[I] shl Wasted;
end;

procedure ParseStreamInfo(const Buf: TByteArray; var Info: TFlacStreamInfo);
var
  X: UInt64;
begin
  if Length(Buf) < 34 then
    raise EFlacError.Create('STREAMINFO block is too short');
  Info.MinBlockSize := (Word(Buf[0]) shl 8) or Buf[1];
  Info.MaxBlockSize := (Word(Buf[2]) shl 8) or Buf[3];
  Info.MinFrameSize := (Cardinal(Buf[4]) shl 16) or (Cardinal(Buf[5]) shl 8) or Buf[6];
  Info.MaxFrameSize := (Cardinal(Buf[7]) shl 16) or (Cardinal(Buf[8]) shl 8) or Buf[9];
  X := (UInt64(Buf[10]) shl 56) or (UInt64(Buf[11]) shl 48) or
    (UInt64(Buf[12]) shl 40) or (UInt64(Buf[13]) shl 32) or
    (UInt64(Buf[14]) shl 24) or (UInt64(Buf[15]) shl 16) or
    (UInt64(Buf[16]) shl 8) or Buf[17];
  Info.SampleRate := (X shr 44) and $FFFFF;
  Info.Channels := ((X shr 41) and 7) + 1;
  Info.BitsPerSample := ((X shr 36) and $1F) + 1;
  Info.TotalSamples := X and $FFFFFFFFF;
end;

procedure ReadMetadata(S: TStream; var Info: TFlacStreamInfo);
var
  Marker: array[0..3] of Byte;
  Header, BlockType, Len: Cardinal;
  Last: Boolean;
  Buf: TByteArray;
begin
  if (S.Read(Marker, 4) <> 4) or not CompareMem(@Marker[0], @FLAC_MARKER[0], 4) then
    raise EFlacError.Create('Input is not a native FLAC stream');

  FillChar(Info, SizeOf(Info), 0);
  repeat
    Header := ReadBE32(S);
    Last := (Header and $80000000) <> 0;
    BlockType := (Header shr 24) and $7F;
    Len := Header and $FFFFFF;
    SetLength(Buf, Len);
    if (Len > 0) and (S.Read(Buf[0], Len) <> Integer(Len)) then
      raise EFlacError.Create('Unexpected end of metadata');
    if BlockType = 0 then
      ParseStreamInfo(Buf, Info);
  until Last;

  if Info.SampleRate = 0 then
    raise EFlacError.Create('Missing STREAMINFO metadata');
end;

function ReadFrame(BR: TBitReader; const Info: TFlacStreamInfo; var Ch: TChannels;
  var BlockSize: Integer): Boolean;
var
  Sync, Blocking, BlockCode, RateCode, ChanAsn, BpsCode, I, Bps: Integer;
  FrameOrSample: UInt64;
begin
  Result := False;
  try
    Sync := BR.ReadBits(14);
  except
    Exit(False);
  end;
  if Sync <> $3FFE then
    raise EFlacError.Create('Frame sync not found');
  if BR.ReadBits(1) <> 0 then
    raise EFlacError.Create('Reserved frame bit is set');
  Blocking := BR.ReadBits(1);
  BlockCode := BR.ReadBits(4);
  RateCode := BR.ReadBits(4);
  ChanAsn := BR.ReadBits(4);
  BpsCode := BR.ReadBits(3);
  if BR.ReadBits(1) <> 0 then
    raise EFlacError.Create('Reserved sample-size bit is set');
  FrameOrSample := ReadUtf8Int(BR);
  if FrameOrSample = UInt64(-1) then
    raise EFlacError.Create('Invalid frame number');

  case BlockCode of
    1: BlockSize := 192;
    2..5: BlockSize := 576 shl (BlockCode - 2);
    6: BlockSize := BR.ReadBits(8) + 1;
    7: BlockSize := BR.ReadBits(16) + 1;
    8..15: BlockSize := 256 shl (BlockCode - 8);
  else
    raise EFlacError.Create('Reserved block-size code');
  end;

  case RateCode of
    0: ;
    12: BR.ReadBits(8);
    13, 14: BR.ReadBits(16);
    15: raise EFlacError.Create('Reserved sample-rate code');
  end;

  Bps := Info.BitsPerSample;
  case BpsCode of
    0: ;
    1: Bps := 8;
    2: Bps := 12;
    4: Bps := 16;
    5: Bps := 20;
    6: Bps := 24;
  else
    raise EFlacError.Create('Reserved bits-per-sample code');
  end;

  BR.ReadBits(8); // header CRC-8
  if ChanAsn <= 7 then
    SetLength(Ch, ChanAsn + 1)
  else if ChanAsn <= 10 then
    SetLength(Ch, 2)
  else
    raise EFlacError.Create('Reserved channel assignment');

  for I := 0 to High(Ch) do
    if ((ChanAsn = 8) and (I = 1)) or ((ChanAsn = 9) and (I = 0)) or ((ChanAsn = 10) and (I = 1)) then
      DecodeSubframe(BR, Ch[I], BlockSize, Bps + 1)
    else
      DecodeSubframe(BR, Ch[I], BlockSize, Bps);
  BR.ByteAlign;
  BR.ReadBits(16); // footer CRC-16

  if ChanAsn = 8 then
    // left-side: ch1 = left - side
    for I := 0 to BlockSize - 1 do
      Ch[1][I] := Ch[0][I] - Ch[1][I]
  else if ChanAsn = 9 then
    // right-side: ch0 = right + side
    for I := 0 to BlockSize - 1 do
      Ch[0][I] := Ch[0][I] + Ch[1][I]
  else if ChanAsn = 10 then
    // mid = (left+right)>>1, side = left-right
    // mid2 = (mid<<1)|(side&1) = left+right; left = (mid2+side)/2; right = left-side
    for I := 0 to BlockSize - 1 do
    begin
      Ch[0][I] := (Ch[0][I] shl 1) or (Ch[1][I] and 1);
      Ch[0][I] := (Ch[0][I] + Ch[1][I]) div 2;
      Ch[1][I] := Ch[0][I] - Ch[1][I];
    end;

  Result := True;
end;

{ ---------------------------------------------------------------------------
  Encoder
  --------------------------------------------------------------------------- }

function SampleRateCode(Rate: Cardinal): Integer;
begin
  case Rate of
    88200: Result := 1;
    176400: Result := 2;
    192000: Result := 3;
    8000: Result := 4;
    16000: Result := 5;
    22050: Result := 6;
    24000: Result := 7;
    32000: Result := 8;
    44100: Result := 9;
    48000: Result := 10;
    96000: Result := 11;
  else
    if Rate <= 65535 then Result := 13  //16-bit rate in Hz follows the header
    else Result := 0;                   //take the rate from STREAMINFO
  end;
end;

function ZigZag(V: Integer): Cardinal; inline;
begin
  if V >= 0 then Result := Cardinal(V) * 2
  else Result := Cardinal(-(V + 1)) * 2 + 1;
end;

procedure WriteVerbatim(BW: TBitWriter; const S: TIntArray; BlockSize, Bps: Integer);
var
  I: Integer;
begin
  BW.WriteBits(0, 1);
  BW.WriteBits(1, 6); //verbatim
  BW.WriteBits(0, 1);
  for I := 0 to BlockSize - 1 do
    BW.WriteSigned(S[I], Bps);
end;

//encodes one channel as CONSTANT, FIXED with a single Rice partition,
//or VERBATIM, whichever is smallest
procedure EncodeSubframe(BW: TBitWriter; const S: TIntArray; BlockSize, Bps: Integer);
var
  Diff: array[0..4] of TIntArray;
  Sums: array[0..4] of UInt64;
  BestOrder, O, I, K, BestK: Integer;
  RiceBits, BestBits, TotalBits, VerbatimBits: Int64;
  Res: TIntArray;
  Zig: Cardinal;
  AllSame: Boolean;
begin
  AllSame := True;
  for I := 1 to BlockSize - 1 do
    if S[I] <> S[0] then
    begin
      AllSame := False;
      Break;
    end;

  if AllSame then
  begin
    BW.WriteBits(0, 1);
    BW.WriteBits(0, 6); //constant
    BW.WriteBits(0, 1);
    BW.WriteSigned(S[0], Bps);
    Exit;
  end;

  if BlockSize <= 4 then
  begin
    WriteVerbatim(BW, S, BlockSize, Bps);
    Exit;
  end;

  //successive differences = residuals of the fixed predictors
  Diff[0] := S;
  for O := 1 to 4 do
  begin
    SetLength(Diff[O], BlockSize);
    for I := O to BlockSize - 1 do
      Diff[O][I] := Diff[O - 1][I] - Diff[O - 1][I - 1];
  end;

  for O := 0 to 4 do
  begin
    Sums[O] := 0;
    for I := 4 to BlockSize - 1 do
      Sums[O] := Sums[O] + Cardinal(Abs(Int64(Diff[O][I])));
  end;

  BestOrder := 0;
  for O := 1 to 4 do
    if Sums[O] < Sums[BestOrder] then
      BestOrder := O;

  Res := Diff[BestOrder];

  //single Rice partition; pick the parameter with the smallest output
  BestK := 0;
  BestBits := High(Int64);
  for K := 0 to 14 do
  begin
    RiceBits := 0;
    for I := BestOrder to BlockSize - 1 do
      RiceBits := RiceBits + (ZigZag(Res[I]) shr K) + 1 + K;
    if RiceBits < BestBits then
    begin
      BestBits := RiceBits;
      BestK := K;
    end;
  end;

  TotalBits := Int64(BestOrder) * Bps + 2 + 4 + 4 + BestBits;
  VerbatimBits := Int64(BlockSize) * Bps;

  if TotalBits >= VerbatimBits then
  begin
    WriteVerbatim(BW, S, BlockSize, Bps);
    Exit;
  end;

  BW.WriteBits(0, 1);
  BW.WriteBits(8 + BestOrder, 6); //fixed, given order
  BW.WriteBits(0, 1);

  for I := 0 to BestOrder - 1 do
    BW.WriteSigned(S[I], Bps);

  BW.WriteBits(0, 2);     //residual method: 4-bit Rice
  BW.WriteBits(0, 4);     //partition order 0
  BW.WriteBits(BestK, 4); //Rice parameter

  for I := BestOrder to BlockSize - 1 do
  begin
    Zig := ZigZag(Res[I]);
    BW.WriteUnary(Zig shr BestK);
    if BestK > 0 then
      BW.WriteBits(Zig and ((Cardinal(1) shl BestK) - 1), BestK);
  end;
end;

procedure WriteFrame(S: TStream; const Samples: TChannels; Channels, Bps, BlockSize,
  FrameNo: Integer; SampleRate: Cardinal);
var
  BW: TBitWriter;
  Data, Header: TByteArray;
  I, C, RateCode, BpsCode: Integer;
  Crc: Word;
begin
  BW := TBitWriter.Create;
  try
    BW.WriteBits($3FFE, 14);
    BW.WriteBits(0, 1);
    BW.WriteBits(0, 1); // fixed block-size stream
    if BlockSize = ENCODE_BLOCK_SIZE then
      BW.WriteBits(12, 4)
    else
      BW.WriteBits(7, 4);
    RateCode := SampleRateCode(SampleRate);
    BW.WriteBits(RateCode, 4);
    BW.WriteBits(Channels - 1, 4);
    if Bps = 16 then BpsCode := 4 else BpsCode := 0;
    BW.WriteBits(BpsCode, 3);
    BW.WriteBits(0, 1);
    Header := BW.Bytes;
    AppendUtf8Int(Header, FrameNo);
    if BlockSize <> ENCODE_BLOCK_SIZE then
    begin
      SetLength(Header, Length(Header) + 2);
      Header[High(Header) - 1] := ((BlockSize - 1) shr 8) and $FF;
      Header[High(Header)] := (BlockSize - 1) and $FF;
    end;
    if RateCode = 13 then
    begin
      SetLength(Header, Length(Header) + 2);
      Header[High(Header) - 1] := (SampleRate shr 8) and $FF;
      Header[High(Header)] := SampleRate and $FF;
    end;
    I := Length(Header);
    SetLength(Header, I + 1);
    Header[I] := Crc8(Copy(Header, 0, I));

    BW.Free;
    BW := TBitWriter.Create;
    for C := 0 to Channels - 1 do
      EncodeSubframe(BW, Samples[C], BlockSize, Bps);
    Data := BW.Bytes;

    SetLength(Header, Length(Header) + Length(Data));
    Move(Data[0], Header[Length(Header) - Length(Data)], Length(Data));
    Crc := Crc16(Header);
    S.WriteBuffer(Header[0], Length(Header));
    WriteBE16(S, Crc);
  finally
    BW.Free;
  end;
end;

procedure WriteStreamInfo(S: TStream; SampleRate, Channels, Bps, TotalSamples: Cardinal);
var
  X: UInt64;
  I: Integer;
begin
  S.WriteBuffer(FLAC_MARKER, 4);
  S.WriteByte($80); // last metadata block, STREAMINFO
  WriteBE24(S, 34);
  WriteBE16(S, ENCODE_BLOCK_SIZE);
  WriteBE16(S, ENCODE_BLOCK_SIZE);
  WriteBE24(S, 0);
  WriteBE24(S, 0);
  X := (UInt64(SampleRate) shl 44) or (UInt64(Channels - 1) shl 41) or
    (UInt64(Bps - 1) shl 36) or TotalSamples;
  for I := 7 downto 0 do
    S.WriteByte(Byte((X shr (I * 8)) and $FF));
  for I := 0 to 15 do
    S.WriteByte(0); //MD5 unknown
end;

{ ---------------------------------------------------------------------------
  TAudioFlac
  --------------------------------------------------------------------------- }

function TAudioFlac.LoadFromStream(Str: TStream): Boolean;
var
  Info: TFlacStreamInfo;
  BR: TBitReader;
  Ch: TChannels;
  BlockSize, I, Scale: Integer;
  Written, Base: UInt64;
  L, R: Integer;
begin
  Result := False;

  try
    ReadMetadata(Str, Info);
  except
    on EFlacError do Exit;
  end;

  if (Info.Channels < 1) or
     (not (Info.BitsPerSample in [8, 12, 16, 20, 24, 32])) then Exit;

  FHandle.FSampleRate := Info.SampleRate;

  //odd bit depths are scaled up to the next byte-aligned size
  Scale := 0;
  case Info.BitsPerSample of
    12: begin FHandle.FSampleSize := 16; Scale := 4; end;
    20: begin FHandle.FSampleSize := 24; Scale := 4; end;
    else FHandle.FSampleSize := Info.BitsPerSample;
  end;

  SetLength(FHandle.FFrames, Info.TotalSamples);

  BR := TBitReader.Create(Str);
  try
    Written := 0;
    try
      while (Info.TotalSamples = 0) or (Written < Info.TotalSamples) do
      begin
        if not ReadFrame(BR, Info, Ch, BlockSize) then
          Break;

        if Info.TotalSamples = 0 then
          SetLength(FHandle.FFrames, Written + UInt64(BlockSize));

        Base := Written;
        for I := 0 to BlockSize - 1 do
        begin
          if (Info.TotalSamples <> 0) and (Base + UInt64(I) >= Info.TotalSamples) then
            Break;

          L := Ch[0][I] shl Scale;
          if Info.Channels > 1 then R := Ch[1][I] shl Scale
          else R := L;

          if FHandle.FSampleSize = 8 then
          begin
            //internal 8 bit is unsigned
            FHandle.FFrames[Base + UInt64(I)].Left := SignedToSample(L, 8);
            FHandle.FFrames[Base + UInt64(I)].Right := SignedToSample(R, 8);
          end
          else
          begin
            FHandle.FFrames[Base + UInt64(I)].Left := L;
            FHandle.FFrames[Base + UInt64(I)].Right := R;
          end;
        end;
        Inc(Written, BlockSize);
      end;
    except
      on EFlacError do ; //keep what was decoded from a truncated stream
    end;

    if Written < UInt64(Length(FHandle.FFrames)) then
      SetLength(FHandle.FFrames, Written);
  finally
    BR.Free;
  end;

  Result := Length(FHandle.FFrames) > 0;
end;

function TAudioFlac.SaveToStream(Str: TStream): Boolean;
var
  Ch: TChannels;
  NumFrames, Done, ThisBlock, FrameNo, I: Integer;
begin
  NumFrames := Length(FHandle.FFrames);

  WriteStreamInfo(Str, FHandle.FSampleRate, 2, 16, NumFrames);

  SetLength(Ch, 2);
  Done := 0;
  FrameNo := 0;

  while Done < NumFrames do
  begin
    ThisBlock := NumFrames - Done;
    if ThisBlock > ENCODE_BLOCK_SIZE then
      ThisBlock := ENCODE_BLOCK_SIZE;

    SetLength(Ch[0], ThisBlock);
    SetLength(Ch[1], ThisBlock);

    for I := 0 to ThisBlock - 1 do
    begin
      Ch[0][I] := SampleToS16(FHandle.FFrames[Done + I].Left, FHandle.FSampleSize);
      Ch[1][I] := SampleToS16(FHandle.FFrames[Done + I].Right, FHandle.FSampleSize);
    end;

    WriteFrame(Str, Ch, 2, 16, ThisBlock, FrameNo, FHandle.FSampleRate);
    Inc(FrameNo);
    Inc(Done, ThisBlock);
  end;

  Result := True;
end;

initialization
  RegisterAudioFormat('flac', TAudioFlac, True);

end.
