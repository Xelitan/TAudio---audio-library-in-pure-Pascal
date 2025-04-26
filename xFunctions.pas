unit xFunctions;

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

uses Classes, SysUtils;

  function Group(A: String; B: String = ''; C: String = ''; D: String = ''; E: String = ''; F: String = ''; G: String = ''; H: String = ''; I: String = ''; J: String = ''): TStringArray;
  operator in (A: String; B: TStringArray): Boolean;

implementation

function Group(A: String; B: String = ''; C: String = ''; D: String = ''; E: String = ''; F: String = ''; G: String = ''; H: String = ''; I: String = ''; J: String = ''): TStringArray;
var z: Integer;
    Ar: TStringArray;
    Len: Integer;
begin
  Ar := TStringArray.Create(A,B,C,D,E, F,G,H,I,J);

  for z:=9 downto 1 do begin
    if Ar[z] <> '' then begin
        Len := z+1;
        break;
      end;
  end;

  SetLength(Result, Len);

  for z:=0 to Len-1 do Result[z] := Ar[z];
end;

operator in (A: String; B: TStringArray): Boolean;
var i: Integer;
begin
  for i:=0 to Length(B)-1 do
    if B[i] = A then Exit(True);

  Result := False;
end;

end.
