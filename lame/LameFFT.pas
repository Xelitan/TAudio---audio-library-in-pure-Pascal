{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameFFT;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Fast Hartley Transform (FHT) and FFT windowing
//  Translated from fft.c


interface

uses LameTypes, Math;

{ Initialize FFT windows and select FFT function }
procedure init_fft(gfc: PLameInternalFlags);

{ Long-block FFT with Blackman windowing }
procedure fft_long(gfc: PLameInternalFlags; var x: array of TFloat;
                   chn: Integer; const buffer: array of PSample);

{ Short-block FFT with Hann windowing }
procedure fft_short(gfc: PLameInternalFlags;
                    var x_real: array of TFloat;  { [3][BLKSIZE_s] flattened }
                    chn: Integer; const buffer: array of PSample);

{ Fast Hartley Transform (in-place) }
procedure fht(fz: PSingle; n: Integer);

implementation

{$POINTERMATH ON}

const
  TRI_SIZE = 4;  { 5-1 }
  costab: array[0..TRI_SIZE * 2 - 1] of TFloat = (
    9.238795325112867e-01, 3.826834323650898e-01,
    9.951847266721969e-01, 9.801714032956060e-02,
    9.996988186962042e-01, 2.454122852291229e-02,
    9.999811752826011e-01, 6.135884649154475e-03
  );

  rv_tbl: array[0..127] of Byte = (
    $00,$80,$40,$c0,$20,$a0,$60,$e0,$10,$90,$50,$d0,$30,$b0,$70,$f0,
    $08,$88,$48,$c8,$28,$a8,$68,$e8,$18,$98,$58,$d8,$38,$b8,$78,$f8,
    $04,$84,$44,$c4,$24,$a4,$64,$e4,$14,$94,$54,$d4,$34,$b4,$74,$f4,
    $0c,$8c,$4c,$cc,$2c,$ac,$6c,$ec,$1c,$9c,$5c,$dc,$3c,$bc,$7c,$fc,
    $02,$82,$42,$c2,$22,$a2,$62,$e2,$12,$92,$52,$d2,$32,$b2,$72,$f2,
    $0a,$8a,$4a,$ca,$2a,$aa,$6a,$ea,$1a,$9a,$5a,$da,$3a,$ba,$7a,$fa,
    $06,$86,$46,$c6,$26,$a6,$66,$e6,$16,$96,$56,$d6,$36,$b6,$76,$f6,
    $0e,$8e,$4e,$ce,$2e,$ae,$6e,$ee,$1e,$9e,$5e,$de,$3e,$be,$7e,$fe
  );

procedure fht(fz: PSingle; n: Integer);
var
  tri: PSingle;
  k4, i, k1, k2, k3, kx: Integer;
  fi, gi, fn: PSingle;
  s1, c1, c2, s2: TFloat;
  f0, f1, f2, f3, a, b, g0, g1, g2, g3, w: TFloat;
begin
  tri := @costab[0];
  n := n shl 1;
  fn := fz;
  Inc(fn, n);
  k4 := 4;
  repeat
    kx := k4 shr 1;
    k1 := k4;
    k2 := k4 shl 1;
    k3 := k2 + k1;
    k4 := k2 shl 1;
    fi := fz;
    gi := fi;
    Inc(gi, kx);
    repeat
      f1 := fi[0] - fi[k1];
      f0 := fi[0] + fi[k1];
      f3 := fi[k2] - fi[k3];
      f2 := fi[k2] + fi[k3];
      fi[k2] := f0 - f2;
      fi[0]  := f0 + f2;
      fi[k3] := f1 - f3;
      fi[k1] := f1 + f3;
      f1 := gi[0] - gi[k1];
      f0 := gi[0] + gi[k1];
      f3 := LAME_SQRT2 * gi[k3];
      f2 := LAME_SQRT2 * gi[k2];
      gi[k2] := f0 - f2;
      gi[0]  := f0 + f2;
      gi[k3] := f1 - f3;
      gi[k1] := f1 + f3;
      Inc(gi, k4);
      Inc(fi, k4);
    until fi >= fn;
    c1 := tri[0];
    s1 := tri[1];
    for i := 1 to kx - 1 do
    begin
      c2 := 1 - (2 * s1) * s1;
      s2 := (2 * s1) * c1;
      fi := fz;
      Inc(fi, i);
      gi := fz;
      Inc(gi, k1 - i);
      repeat
        b := s2 * fi[k1] - c2 * gi[k1];
        a := c2 * fi[k1] + s2 * gi[k1];
        f1 := fi[0] - a;
        f0 := fi[0] + a;
        g1 := gi[0] - b;
        g0 := gi[0] + b;
        b := s2 * fi[k3] - c2 * gi[k3];
        a := c2 * fi[k3] + s2 * gi[k3];
        f3 := fi[k2] - a;
        f2 := fi[k2] + a;
        g3 := gi[k2] - b;
        g2 := gi[k2] + b;
        b := s1 * f2 - c1 * g3;
        a := c1 * f2 + s1 * g3;
        fi[k2] := f0 - a;
        fi[0]  := f0 + a;
        gi[k3] := g1 - b;
        gi[k1] := g1 + b;
        b := c1 * g2 - s1 * f3;
        a := s1 * g2 + c1 * f3;
        gi[k2] := g0 - a;
        gi[0]  := g0 + a;
        fi[k3] := f1 - b;
        fi[k1] := f1 + b;
        Inc(gi, k4);
        Inc(fi, k4);
      until fi >= fn;
      c2 := c1;
      c1 := c2 * tri[0] - s1 * tri[1];
      s1 := c2 * tri[1] + s1 * tri[0];
    end;
    Inc(tri, 2);
  until k4 >= n;
end;

procedure fft_long(gfc: PLameInternalFlags; var x: array of TFloat;
                   chn: Integer; const buffer: array of PSample);
var
  i, jj: Integer;
  f0, f1, f2, f3, w: TFloat;
  xp: PSingle;
  buf: PSample;
  win: PSingle;
begin
  xp  := @x[BLKSIZE div 2];
  buf := buffer[chn and 1];
  win := @gfc^.cd_psy^.window[0];

  jj := BLKSIZE div 8 - 1;
  repeat
    i := rv_tbl[jj];

    f0 := win[i]         * buf[i];
    w  := win[i + $200]  * buf[i + $200];
    f1 := f0 - w;
    f0 := f0 + w;
    f2 := win[i + $100]  * buf[i + $100];
    w  := win[i + $300]  * buf[i + $300];
    f3 := f2 - w;
    f2 := f2 + w;

    Dec(xp, 4);
    xp[0] := f0 + f2;
    xp[2] := f0 - f2;
    xp[1] := f1 + f3;
    xp[3] := f1 - f3;

    f0 := win[i + 1]        * buf[i + 1];
    w  := win[i + $201]     * buf[i + $201];
    f1 := f0 - w;
    f0 := f0 + w;
    f2 := win[i + $101]     * buf[i + $101];
    w  := win[i + $301]     * buf[i + $301];
    f3 := f2 - w;
    f2 := f2 + w;

    xp[BLKSIZE div 2 + 0] := f0 + f2;
    xp[BLKSIZE div 2 + 2] := f0 - f2;
    xp[BLKSIZE div 2 + 1] := f1 + f3;
    xp[BLKSIZE div 2 + 3] := f1 - f3;

    Dec(jj);
  until jj < 0;

  gfc^.fft_fht(xp, BLKSIZE div 2);
end;

procedure fft_short(gfc: PLameInternalFlags;
                    var x_real: array of TFloat;
                    chn: Integer; const buffer: array of PSample);
var
  b, j, i: Integer;
  k: SmallInt;
  f0, f1, f2, f3, w: TFloat;
  xp: PSingle;
  buf: PSample;
  win_s: PSingle;
begin
  buf   := buffer[chn and 1];
  win_s := @gfc^.cd_psy^.window_s[0];

  for b := 0 to 2 do
  begin
    xp := @x_real[b * BLKSIZE_s + BLKSIZE_s div 2];
    k  := (576 div 3) * (b + 1);
    j  := BLKSIZE_s div 8 - 1;
    repeat
      i := rv_tbl[j shl 2];

      f0 := win_s[i]          * buf[i + k];
      w  := win_s[$7F - i]    * buf[i + k + $80];
      f1 := f0 - w;
      f0 := f0 + w;
      f2 := win_s[i + $40]    * buf[i + k + $40];
      w  := win_s[$3F - i]    * buf[i + k + $C0];
      f3 := f2 - w;
      f2 := f2 + w;

      Dec(xp, 4);
      xp[0] := f0 + f2;
      xp[2] := f0 - f2;
      xp[1] := f1 + f3;
      xp[3] := f1 - f3;

      f0 := win_s[i + 1]      * buf[i + k + 1];
      w  := win_s[$7E - i]    * buf[i + k + $81];
      f1 := f0 - w;
      f0 := f0 + w;
      f2 := win_s[i + $41]    * buf[i + k + $41];
      w  := win_s[$3E - i]    * buf[i + k + $C1];
      f3 := f2 - w;
      f2 := f2 + w;

      xp[BLKSIZE_s div 2 + 0] := f0 + f2;
      xp[BLKSIZE_s div 2 + 2] := f0 - f2;
      xp[BLKSIZE_s div 2 + 1] := f1 + f3;
      xp[BLKSIZE_s div 2 + 3] := f1 - f3;

      Dec(j);
    until j < 0;

    gfc^.fft_fht(xp, BLKSIZE_s div 2);
  end;
end;

procedure init_fft(gfc: PLameInternalFlags);
var i: Integer;
begin
  { Blackman window for long blocks }
  for i := 0 to BLKSIZE - 1 do
    gfc^.cd_psy^.window[i] :=
      0.42
      - 0.5  * Cos(2 * LAME_PI * (i + 0.5) / BLKSIZE)
      + 0.08 * Cos(4 * LAME_PI * (i + 0.5) / BLKSIZE);

  { Hann window for short blocks }
  for i := 0 to BLKSIZE_s div 2 - 1 do
    gfc^.cd_psy^.window_s[i] :=
      0.5 * (1.0 - Cos(2.0 * LAME_PI * (i + 0.5) / BLKSIZE_s));

  gfc^.fft_fht := @fht;
end;

end.
