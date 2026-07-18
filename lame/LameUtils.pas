{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameUtils;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Math utilities: fast_log2, ATH formula, freq2bark, misc helpers


interface

uses LameTypes, LameTables, Math, SysUtils;

const
  MAX_BITS_PER_CHANNEL = 4095;
  MAX_BITS_PER_GRANULE = 7680;
  NSATHSCALE           = 100;

{ Math helpers }
function  fast_log2(x: Single): Single;
procedure init_log_table;

function  LameLog10(x: Single): Single; inline;
function  LameLog10X(x: Single; y: Single): Single; inline;

{ ATH and psychoacoustic helpers }
function  ATHformula_GB(f, value, f_min, f_max: TFloat): TFloat;
function  ATHformula(const cfg: TSessionConfig_t; f: TFloat): TFloat;
function  freq2bark(freq: TFloat): TFloat;
function  athAdjust(a, x, athFloor: TFloat; ATHfixpoint: Single): TFloat;

{ Initialization helpers }
function  FindNearestBitrate(bRate, version, samplerate: Integer): Integer;
function  BitrateIndex(bRate, version, samplerate: Integer): Integer;
function  SampleRateIndex(freq: Integer): Integer;

{ Scalefactor band table initialization }
procedure InitScalefacBand(gfc: PLameInternalFlags);

{ Buffer/memory utilities }
function  lame_calloc_ath: PATHt;
function  lame_calloc_psy: PPsyConst_t;
procedure lame_free_ath(var p: PATHt);
procedure lame_free_psy(var p: PPsyConst_t);

var
  log_table: array[0..LOG2_SIZE] of Single;
  log_table_init: Boolean = False;

implementation

procedure init_log_table;
var j: Integer;
begin
  if log_table_init then Exit;
  for j := 0 to LOG2_SIZE do
    log_table[j] := ln(1.0 + j / LOG2_SIZE) / ln(2.0);
  log_table_init := True;
end;

function fast_log2(x: Single): Single;
var
  fi: record case Boolean of
    True:  (f: Single);
    False: (i: Integer);
  end;
  mantisse, mant_idx: Integer;
  log2val, partial: Single;
begin
  if not log_table_init then init_log_table;
  fi.f := x;
  mantisse := fi.i and $7FFFFF;
  log2val  := ((fi.i shr 23) and $FF) - $7F;
  partial  := (mantisse and ((1 shl (23 - LOG2_SIZE_L2)) - 1));
  partial  := partial * (1.0 / (1 shl (23 - LOG2_SIZE_L2)));
  mant_idx := mantisse shr (23 - LOG2_SIZE_L2);
  log2val  := log2val + log_table[mant_idx] * (1.0 - partial)
                      + log_table[mant_idx + 1] * partial;
  Result := log2val;
end;

function LameLog10(x: Single): Single; inline;
begin
  Result := fast_log2(x) * (LAME_LOG2 / LAME_LOG10);
end;

function LameLog10X(x: Single; y: Single): Single; inline;
begin
  Result := fast_log2(x) * (LAME_LOG2 / LAME_LOG10 * y);
end;

function ATHformula_GB(f, value, f_min, f_max: TFloat): TFloat;
var
  ath: TFloat;
begin
  if f < -0.3 then f := 3410.0;
  f := f * 0.001;
  if f < f_min then f := f_min;
  if f > f_max then f := f_max;
  ath := 3.640 * Power(f, -0.8)
       - 6.800 * Exp(-0.6 * Power(f - 3.4, 2.0))
       + 6.000 * Exp(-0.15 * Power(f - 8.7, 2.0))
       + (0.6 + 0.04 * value) * 0.001 * Power(f, 4.0);
  Result := ath;
end;

function ATHformula(const cfg: TSessionConfig_t; f: TFloat): TFloat;
begin
  case cfg.ATHtype of
    0: Result := ATHformula_GB(f, 9, 0.1, 24.0);
    1: Result := ATHformula_GB(f, -1, 0.1, 24.0);
    2: Result := ATHformula_GB(f, 0, 0.1, 24.0);
    3: Result := ATHformula_GB(f, 1, 0.1, 24.0) + 6;
    4: Result := ATHformula_GB(f, cfg.ATHcurve, 0.1, 24.0);
    5: Result := ATHformula_GB(f, cfg.ATHcurve, 3.41, 16.1);
  else
    Result := ATHformula_GB(f, 0, 0.1, 24.0);
  end;
end;

function freq2bark(freq: TFloat): TFloat;
begin
  if freq < 0 then freq := 0;
  freq := freq * 0.001;
  Result := 13.0 * ArcTan(0.76 * freq) + 3.5 * ArcTan(freq * freq / (7.5 * 7.5));
end;

function athAdjust(a, x, athFloor: TFloat; ATHfixpoint: Single): TFloat;
const
  o = 90.30873362;
  u = 94.82444863;
var
  v: TFloat;
begin
  v := a * x;
  if v > 0.0 then
  begin
    v := 10.0 * log10(v);
    if ATHfixpoint > 0.0 then
      v := Max(athFloor, v)
    else
      v := Max(0.0, v);
    v := (v - u) / (o - u);
    if v < 0.0 then v := 0.0;
    if v > 1.0 then v := 1.0;
  end
  else
    v := 0.0;
  Result := v;
end;

function FindNearestBitrate(bRate, version, samplerate: Integer): Integer;
var
  i, bitrate: Integer;
begin
  if samplerate < 16000 then version := 2;
  bitrate := bitrate_table[version][1];
  for i := 2 to 14 do
  begin
    if bitrate_table[version][i] < 1 then Break;
    if Abs(bitrate_table[version][i] - bRate) < Abs(bitrate - bRate) then
      bitrate := bitrate_table[version][i];
  end;
  Result := bitrate;
end;

function BitrateIndex(bRate, version, samplerate: Integer): Integer;
var i: Integer;
begin
  if samplerate < 16000 then version := 2;
  for i := 0 to 15 do
  begin
    if bitrate_table[version][i] < 0 then Break;
    if bitrate_table[version][i] = bRate then
    begin
      Result := i;
      Exit;
    end;
  end;
  Result := -1;
end;

function SampleRateIndex(freq: Integer): Integer;
var ver, i: Integer;
begin
  for ver := 0 to 2 do
    for i := 0 to 2 do
      if samplerate_table[ver][i] = freq then
      begin
        Result := ver * 4 + i;
        Exit;
      end;
  Result := -1;
end;

procedure InitScalefacBand(gfc: PLameInternalFlags);
var
  idx, sfb: Integer;
  samplerate: Integer;
  ver, sridx: Integer;
begin
  samplerate := gfc^.cfg.samplerate_out;

  { Find index into sfBandIndex tables }
  { version: MPEG2=0, MPEG1=1, MPEG2.5=2 }
  ver := gfc^.cfg.version;
  sridx := gfc^.cfg.samplerate_index;

  { Map (version, samplerate_index) -> sfBandIndex row 0..8 }
  { MPEG2.5=2: row 6,7,8 | MPEG1=1: row 3,4,5 | MPEG2=0: row 0,1,2 }
  case ver of
    1: idx := 3 + sridx;     { MPEG1 }
    0: idx := 0 + sridx;     { MPEG2 }
    2: idx := 6 + sridx;     { MPEG2.5 }
  else
    idx := 3;
  end;
  if idx < 0 then idx := 0;
  if idx > 8 then idx := 8;

  for sfb := 0 to SBMAX_l do
    gfc^.scalefac_band.l[sfb] := sfBandIndex_l[idx][sfb];
  for sfb := 0 to SBMAX_s do
    gfc^.scalefac_band.s[sfb] := sfBandIndex_s[idx][sfb];

  { psfb21/psfb12 - pseudo sub-bands above sfb21/sfb12, set to zero }
  for sfb := 0 to PSFB21 do
    gfc^.scalefac_band.psfb21[sfb] := 0;
  for sfb := 0 to PSFB12 do
    gfc^.scalefac_band.psfb12[sfb] := 0;
end;

function lame_calloc_ath: PATHt;
var p: PATHt;
begin
  New(p);
  FillChar(p^, SizeOf(TATHt), 0);
  Result := p;
end;

function lame_calloc_psy: PPsyConst_t;
var p: PPsyConst_t;
begin
  New(p);
  FillChar(p^, SizeOf(TPsyConst_t), 0);
  Result := p;
end;

procedure lame_free_ath(var p: PATHt);
begin
  if p <> nil then
  begin
    Dispose(p);
    p := nil;
  end;
end;

procedure lame_free_psy(var p: PPsyConst_t);
begin
  if p <> nil then
  begin
    { Free dynamically allocated s3 arrays }
    if p^.l.s3 <> nil then
    begin
      FreeMem(p^.l.s3);
      p^.l.s3 := nil;
    end;
    if p^.s.s3 <> nil then
    begin
      FreeMem(p^.s.s3);
      p^.s.s3 := nil;
    end;
    if p^.l_to_s.s3 <> nil then
    begin
      FreeMem(p^.l_to_s.s3);
      p^.l_to_s.s3 := nil;
    end;
    Dispose(p);
    p := nil;
  end;
end;

initialization
  init_log_table;

end.
