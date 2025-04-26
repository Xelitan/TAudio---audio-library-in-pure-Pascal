unit xStreams;

interface

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	TAudio - convert and modify sound files                       //
// Version:	0.1                                                           //
// Date:	26-APR-2025                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Based on:    PascalVault                                                   //
// Copyright:	(c) 2025 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

uses Classes, SysUtils, Dialogs;

type
   { TReader }

   TReader = class
   private
     FStream: TStream;
     FSize: Integer;
     Buf: array of Byte;
     FPos: Integer;

     procedure SetOffset(Offset: Integer);
     function GetOffset: Integer;
     procedure SetAtLeast(Amount: Integer);
   public
     function GetU: Byte; inline;
     function GetU2: Word; inline;
     function GetU3: Cardinal; inline;
     function GetU4: Cardinal; inline;

     function GetMU2: Word; inline;
     function GetMU3: Cardinal; inline;
     function GetMU4: Cardinal; inline;

     function GetI: ShortInt; inline;
     function GetI2: Smallint; inline;
     function GetI4: LongInt; inline;
     function GetMI2: Smallint; inline;
     function GetMI3: LongInt; inline;
     function GetMI4: LongInt; inline;

     function GetF: Single; inline;
     function GetMF: Single; inline; //Single
     function GetV: Int64; inline; //variable-length integer

     function GetLn(UntilCh: String = ''): String;

     property Offset: Integer read GetOffset write SetOffset;
     property AtLeast: Integer write SetAtLeast;
     property Size: Integer read FSize;

     function Get(var Buffer; Count: Longint): Longint; overload;
     function Get(Count: Longint): TBytes; overload;
     function GetC: Char; inline;
     function GetNum: Integer;
     function GetWhite: String;
     function GetPS: String; //Pascal String
     function GetS(Count: Integer = -1): String;
     procedure Skip(Count: Integer);
     function Eof: Boolean;
     constructor Create(Str: TStream; Length: Integer = -1);
   end;

   { TPV_Writer }

   { TWriter }

   TWriter = class
   private
     FStream: TStream;
     Buf: array of Byte;
     FPos: Integer;
     FSize: Integer;
   public
     procedure Flush;

     procedure Put(const Buffer; Count: Integer);
     procedure PutU(V: Byte); inline;
     procedure PutU2(V: Word); inline;
     procedure PutU3(V: Cardinal); inline;
     procedure PutU4(V: Cardinal); inline;
     procedure PutMU2(V: Word); inline;
     procedure PutMU4(V: Cardinal); inline;

     procedure PutI(V: ShortInt); inline;
     procedure PutI2(V: Smallint); inline;
     procedure PutI4(V: LongInt); inline;
     procedure PutMI2(V: Smallint); inline;
     procedure PutMI4(V: LongInt); inline;

     procedure PutMF(V: Single); inline;
     procedure PutF(V: Single); inline;

     procedure PutV(V: Word); inline;

     procedure Skip(Len: Integer);

     procedure PutS(S: String); inline;
     procedure CopyFrom(Str: TStream; Count: Integer);

     constructor Create(Str: TStream);
     destructor Destroy; override;
   end;

   function Getbits(Val: Word; Index, Count: Integer): Word;

implementation

function Getbits(Val: Word; Index, Count: Integer): Word;
var Res: Word;
begin
  Res := Val shr Index;
  case Count of
    0: Result := 0;
    1: Result := Res and 1;
    2: Result := Res and 3;
    3: Result := Res and 7;
    4: Result := Res and 15;
    5: Result := Res and 31;
    6: Result := Res and 63;
    7: Result := Res and 127;

    8: Result := Res and 255;
    9: Result := Res and 511;
    10: Result := Res and 1023;
    11: Result := Res and 2047;
    12: Result := Res and 4095;
    13: Result := Res and 8191;
    14: Result := Res and 16383;
    15: Result := Res and 32767;
  end;
end;

{ TReader }

procedure TReader.SetOffset(Offset: Integer);
begin
  FPos := Offset;
end;

function TReader.GetOffset: Integer;
begin
  Result := FPos;
end;

procedure TReader.SetAtLeast(Amount: Integer);
begin
  if FSize-FPos < Amount then SetLength(Buf, FPos+Amount);
end;

function TReader.GetU: Byte;
begin
  Result := Buf[FPos];
  Inc(FPos);
end;

function TReader.GetU2: Word;
begin
  Move(Buf[FPos], Result, 2);
  Inc(FPos, 2);
end;

function TReader.GetU3: Cardinal;
begin
  Result := 0;
  Move(Buf[FPos], Result, 3);
  Inc(FPos, 3);
end;

function TReader.GetU4: Cardinal;
begin
  Move(Buf[FPos], Result, 4);
  Inc(FPos, 4);
end;

function TReader.GetMU2: Word;
begin
  Move(Buf[FPos], Result, 2);

  Result := SwapEndian(Result);
  Inc(FPos, 2);
end;

function TReader.GetMU3: Cardinal;
begin
  Move(Buf[FPos], Result, 3);

  Result := SwapEndian(Result);
  Inc(FPos, 3);
end;

function TReader.GetMU4: Cardinal;
begin
  Move(Buf[FPos], Result, 4);

  Result := SwapEndian(Result);
  Inc(FPos, 4);
end;

function TReader.GetI: ShortInt;
begin
  Move(Buf[FPos], Result, 1);
  Inc(FPos);
end;

function TReader.GetI2: Smallint;
begin
  Move(Buf[FPos], Result, 2);
  Inc(FPos, 2);
end;

function TReader.GetI4: LongInt;
begin
  Move(Buf[FPos], Result, 4);
  Inc(FPos, 4);
end;

function TReader.GetMI2: Smallint;
begin
  Move(Buf[FPos], Result, 2);

  Result := SwapEndian(Result);
  Inc(FPos, 2);
end;

function TReader.GetMI3: LongInt;
begin
  Move(Buf[FPos], Result, 3);

  Result := SwapEndian(Result);
  Inc(FPos, 3);
end;

function TReader.GetMI4: LongInt;
begin
  Move(Buf[FPos], Result, 4);

  Result := SwapEndian(Result);
  Inc(FPos, 4);
end;

function TReader.GetF: Single;
var Temp: Cardinal absolute Result;
begin
  Move(Buf[FPos], Temp, 4);

  Inc(FPos, 4);
end;

function TReader.GetMF: Single;
var Temp: Cardinal absolute Result;
begin
  Move(Buf[FPos], Temp, 4);

  Temp := SwapEndian(Temp);

  Inc(FPos, 4);
end;

function TReader.GetV: Int64;
var i: Integer;
    Val,Cont: Byte;
    V: Byte;
begin
  Result := 0;

  while True do begin
    V := Buf[FPos];
    Inc(FPos);

    Cont := V shr 7;
    Val  := V and $7F;

    Result := (Result shl 7) + Val;

    if Cont=0 then Exit;
  end;
end;

function TReader.GetLn(UntilCh: String): String;
var A,B: Integer;
    Count: Integer;
    i: Integer;
begin
  if UntilCh = '' then begin
    Count := 10000;
    if Count > FSize-FPos then Count := FSize-FPos;

    SetLength(Result, Count);
    Move(Buf[FPos], Result[1], Count);

    A := 0;
    for i:=1 to Length(Result) do
      if (Result[i] = #13) or (Result[i] = #10) then begin
        A := i;
        break;
      end;

    Result := Copy(Result, 1, A-1);
    Inc(FPos, A);
    Exit;
  end;

  Count := 10000;
  if Count > FSize-FPos then Count := FSize-FPos;

  SetLength(Result, Count);
  Move(Buf[FPos], Result[1], Count);

  A := Pos(UntilCh, Result);

  Result := Copy(Result, 1, A-1);
  Inc(FPos, A);
  Exit;
end;

function TReader.GetC: Char;
begin
  Result := chr(Buf[FPos]);
  Inc(FPos);
end;

function TReader.Get(var Buffer; Count: Longint): Longint;
var Count2: Integer;
    i: Integer;
begin
  Count2 := FSize-FPos;
  if Count2 < Count then Count := Count2;

  Move(Buf[FPos], Buffer, Count);

  Result := Count;
  Inc(FPos, Count);
end;

function TReader.Get(Count: Longint): TBytes;
var Count2: Integer;
begin
  Count2 := FSize-FPos;
  if Count2 < Count then Count := Count2;

  SetLength(Result, Count);
  Move(Buf[FPos], Result[0], Count);
  Inc(FPos, Count);
end;

function TReader.GetNum: Integer;
var Res: String;
begin
  Res := '';

  while FPos < FSize do begin
    if Buf[FPos] in [48..57] then Res := Res + chr(Buf[FPos])
    else break;

    Inc(FPos);
  end;

  Result := StrToInt64Def(Res, 0);
end;

function TReader.GetWhite: String;
begin
  Result := '';

  while FPos < FSize do begin
    if Buf[FPos] in [32,13,10,09] then Result := Result + chr(Buf[FPos])
    else break;

    Inc(FPos);
  end;
end;

function TReader.GetPS: String;
var Len: Integer;
begin
  Len := GetU;
  Result := GetS(Len);
  if Len mod 2 = 0 then GetU; //padding byte
end;

function TReader.GetS(Count: Integer): String;
begin
  if Count = -1 then Count := FSize;

  SetLength(Result, Count);
  Move(Buf[FPos], Result[1], Count);
  Inc(FPos, Count);
end;

procedure TReader.Skip(Count: Integer);
begin
  Inc(FPos, Count);
end;

function TReader.Eof: Boolean;
begin
  Result := FPos = FSize;
end;

constructor TReader.Create(Str: TStream; Length: Integer);
begin
  FStream := Str;

  if Length = -1 then FSize := Str.Size
  else                FSize := Length;

  SetLength(Buf, FSize);
  Str.Read(Buf[0], FSize);

  FPos := 0;
end;

{ TWriter }

procedure TWriter.Flush;
begin
  if FPos < 1 then Exit;

  FStream.Write(Buf[0], FPos);
  FPos := 0;
end;

procedure TWriter.Put(const Buffer; Count: Integer);
begin
  if FPos+Count > FSize then Flush;

  Move(Buffer, Buf[FPos], Count);
  Inc(FPos, Count);
end;

procedure TWriter.PutU(V: Byte);
begin
  if FPos+1 > FSize then Flush;

  Buf[FPos] := V;
  Inc(FPos);
end;

procedure TWriter.PutU2(V: Word);
begin
  if FPos+2 > FSize then Flush;

  Move(V, Buf[FPos], 2);
  Inc(FPos, 2);
end;

procedure TWriter.PutU3(V: Cardinal);
begin
  if FPos+3 > FSize then Flush;

  Move(V, Buf[FPos], 3);
  Inc(FPos, 3);
end;

procedure TWriter.PutU4(V: Cardinal);
begin
  if FPos+4 > FSize then Flush;

  Move(V, Buf[FPos], 4);
  Inc(FPos, 4);
end;

procedure TWriter.PutMU2(V: Word);
begin
  if FPos+2 > FSize then Flush;

  V := SwapEndian(V);

  Move(V, Buf[FPos], 2);
  Inc(FPos, 2);
end;

procedure TWriter.PutMU4(V: Cardinal);
begin
  if FPos+4 > FSize then Flush;

  V := SwapEndian(V);

  Move(V, Buf[FPos], 4);
  Inc(FPos, 4);
end;

procedure TWriter.PutI(V: ShortInt);
begin
  if FPos+1 > FSize then Flush;

  Move(V, Buf[FPos], 1);
  Inc(FPos, 1);
end;

procedure TWriter.PutI2(V: Smallint);
begin
  if FPos+2 > FSize then Flush;

  Move(V, Buf[FPos], 2);
  Inc(FPos, 2);
end;

procedure TWriter.PutI4(V: LongInt);
begin
  if FPos+4 > FSize then Flush;

  Move(V, Buf[FPos], 4);
  Inc(FPos, 4);
end;

procedure TWriter.PutMI2(V: Smallint);
begin
  if FPos+2 > FSize then Flush;

  V := SwapEndian(V);

  Move(V, Buf[FPos], 2);
  Inc(FPos, 2);
end;

procedure TWriter.PutMI4(V: LongInt);
begin
  if FPos+4 > FSize then Flush;

  V := SwapEndian(V);

  Move(V, Buf[FPos], 4);
  Inc(FPos, 4);
end;

procedure TWriter.PutMF(V: Single);
var VV: Cardinal;
begin
  if FPos+4 > FSize then Flush;

  Move(V, VV, 4);

  VV := SwapEndian(VV);

  Move(VV, Buf[FPos], 4);
  Inc(FPos, 4);
end;

procedure TWriter.PutF(V: Single);
var VV: Cardinal;
begin
  if FPos+4 > FSize then Flush;

  Move(V, VV, 4);

  Move(VV, Buf[FPos], 4);
  Inc(FPos, 4);
end;

procedure TWriter.PutV(V: Word);
var A,B: Byte;
begin
  //not really variable-length
  A := (V shr 7) + $80;
  B := (V and $7F);

  PutU(A);
  PutU(B);
end;

procedure TWriter.Skip(Len: Integer);
var i: Integer;
begin
  for i:=0 to Len-1 do
    PutU(0);
end;

procedure TWriter.PutS(S: String);
var Len: Integer;
begin
  Len := Length(S);
  if FPos+Len > FSize then Flush;

  Move(S[1], Buf[FPos], Len);
  Inc(FPos, Len);
end;

procedure TWriter.CopyFrom(Str: TStream; Count: Integer);
var Buff: array of Byte;
    BuffSize: Integer;
    Len: Integer;
begin
  Flush;
  FPos := 0;

  BuffSize := 40960;

  if BuffSize > Count then BuffSize := Count;
  SetLength(Buff, BuffSize);

  while Count >0 do begin
    Len := Str.Read(Buff[0], BuffSize);

    FStream.Write(Buff[0], Len);
    Dec(Count, Len);
  end;
end;

constructor TWriter.Create(Str: TStream);
begin
  FStream := Str;
  FPos := 0;
  FSize := 409600;
  SetLength(Buf, FSize);
end;

destructor TWriter.Destroy;
begin
  Flush;

  inherited Destroy;
end;

end.
