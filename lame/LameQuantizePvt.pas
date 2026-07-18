{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameQuantizePvt;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Translated from quantize_pvt.c and reservoir.c (ResvMaxBits)


interface

uses LameTypes, LameTables, LameUtils, Math, SysUtils;

const
  DBL_EPSILON = 2.2204460492503131e-016;

{ Reservoir }
procedure ResvMaxBits(gfc: PLameInternalFlags; mean_bits: Integer;
                      targ_bits, extra_bits: PInteger; cbr: Integer);

{ Initialization }
procedure iteration_init(gfc: PLameInternalFlags);

{ ATH adjustment (quantize_pvt.c version - returns energy) }
function  athAdjust(a, x, athFloor: TFloat; ATHfixpoint: Single): TFloat;

{ Bit allocation }
function  on_pe(gfc: PLameInternalFlags; pe: PPeArray;
                targ_bits: PIntegerArray; mean_bits, gr, cbr: Integer): Integer;
procedure reduce_side(targ_bits: PIntegerArray; ms_ener_ratio: TFloat;
                      mean_bits, max_bits: Integer);

{ Quantization noise }
function  calc_xmin(gfc: PLameInternalFlags; const ratio: TIIIPsyRatio;
                    cod_info: PGrInfo; pxmin: PSingle): Integer;
function  calc_noise(const cod_info: TGrInfo; l3_xmin: PSingle;
                     distort: PSingle; res: PCalcNoiseResult;
                     prev_noise: PCalcNoiseData): Integer;

implementation

{$POINTERMATH ON}

{ Implementation uses clause:
  huffman_init is in LameTakehiro.pas
  init_xrpow_core_init is in LameQuantize.pas
  Neither of those units uses LameQuantizePvt in their interface,
  so this is a straightforward dependency (no circular issues). }
uses LameTakehiro, LameQuantize;

{ -----------------------------------------------------------------------
  ResvMaxBits (from reservoir.c)
  Returns target bits and extra bits available from reservoir for one granule
  ----------------------------------------------------------------------- }
procedure ResvMaxBits(gfc: PLameInternalFlags; mean_bits: Integer;
                      targ_bits, extra_bits: PInteger; cbr: Integer);
var
  cfg: TSessionConfig_t;
  ResvSize, ResvMax: Integer;
  add_bits, targBits, extraBits: Integer;
begin
  cfg := gfc^.cfg;
  ResvSize := gfc^.sv_enc.ResvSize;
  ResvMax  := gfc^.sv_enc.ResvMax;

  if cbr <> 0 then
    Inc(ResvSize, mean_bits);

  if (gfc^.sv_qnt.substep_shaping and 1) <> 0 then
    ResvMax := Trunc(ResvMax * 0.9);

  targBits := mean_bits;

  if ResvSize * 10 > ResvMax * 9 then
  begin
    add_bits := ResvSize - (ResvMax * 9) div 10;
    Inc(targBits, add_bits);
    gfc^.sv_qnt.substep_shaping := gfc^.sv_qnt.substep_shaping or $80;
  end
  else
  begin
    add_bits := 0;
    gfc^.sv_qnt.substep_shaping := gfc^.sv_qnt.substep_shaping and $7F;
    if (cfg.disable_reservoir = 0) and
       ((gfc^.sv_qnt.substep_shaping and 1) = 0) then
      targBits := targBits - Trunc(0.1 * mean_bits);
  end;

  if ResvSize < (ResvMax * 6) div 10 then
    extraBits := ResvSize
  else
    extraBits := (ResvMax * 6) div 10;
  Dec(extraBits, add_bits);
  if extraBits < 0 then extraBits := 0;

  targ_bits^  := targBits;
  extra_bits^ := extraBits;
end;

{ -----------------------------------------------------------------------
  ATHmdct - ATH formula for MDCT frequency bin, returns energy
  ----------------------------------------------------------------------- }
function ATHmdct(const cfg: TSessionConfig_t; f: TFloat): TFloat;
var
  ath: TFloat;
begin
  ath := ATHformula(cfg, f);
  if cfg.ATHfixpoint > 0 then
    ath := ath - cfg.ATHfixpoint
  else
    ath := ath - NSATHSCALE;
  ath := ath + cfg.ATH_offset_db;
  Result := Power(10.0, ath * 0.1);
end;

{ -----------------------------------------------------------------------
  compute_ath - fill ATH arrays for all scalefactor bands
  ----------------------------------------------------------------------- }
procedure compute_ath(gfc: PLameInternalFlags);
var
  cfg: TSessionConfig_t;
  sfb, i, start, last: Integer;
  ATH_f, samp_freq: TFloat;
begin
  cfg := gfc^.cfg;
  samp_freq := cfg.samplerate_out;

  for sfb := 0 to SBMAX_l - 1 do
  begin
    start := gfc^.scalefac_band.l[sfb];
    last  := gfc^.scalefac_band.l[sfb + 1];
    gfc^.ATH^.l[sfb] := MaxSingle;
    for i := start to last - 1 do
    begin
      ATH_f := ATHmdct(cfg, i * samp_freq / (2 * 576));
      if ATH_f < gfc^.ATH^.l[sfb] then
        gfc^.ATH^.l[sfb] := ATH_f;
    end;
  end;

  for sfb := 0 to PSFB21 - 1 do
  begin
    start := gfc^.scalefac_band.psfb21[sfb];
    last  := gfc^.scalefac_band.psfb21[sfb + 1];
    gfc^.ATH^.psfb21[sfb] := MaxSingle;
    for i := start to last - 1 do
    begin
      ATH_f := ATHmdct(cfg, i * samp_freq / (2 * 576));
      if ATH_f < gfc^.ATH^.psfb21[sfb] then
        gfc^.ATH^.psfb21[sfb] := ATH_f;
    end;
  end;

  for sfb := 0 to SBMAX_s - 1 do
  begin
    start := gfc^.scalefac_band.s[sfb];
    last  := gfc^.scalefac_band.s[sfb + 1];
    gfc^.ATH^.s[sfb] := MaxSingle;
    for i := start to last - 1 do
    begin
      ATH_f := ATHmdct(cfg, i * samp_freq / (2 * 192));
      if ATH_f < gfc^.ATH^.s[sfb] then
        gfc^.ATH^.s[sfb] := ATH_f;
    end;
    gfc^.ATH^.s[sfb] := gfc^.ATH^.s[sfb] *
      (gfc^.scalefac_band.s[sfb + 1] - gfc^.scalefac_band.s[sfb]);
  end;

  for sfb := 0 to PSFB12 - 1 do
  begin
    start := gfc^.scalefac_band.psfb12[sfb];
    last  := gfc^.scalefac_band.psfb12[sfb + 1];
    gfc^.ATH^.psfb12[sfb] := MaxSingle;
    for i := start to last - 1 do
    begin
      ATH_f := ATHmdct(cfg, i * samp_freq / (2 * 192));
      if ATH_f < gfc^.ATH^.psfb12[sfb] then
        gfc^.ATH^.psfb12[sfb] := ATH_f;
    end;
    gfc^.ATH^.psfb12[sfb] := gfc^.ATH^.psfb12[sfb] *
      (gfc^.scalefac_band.s[13] - gfc^.scalefac_band.s[12]);
  end;

  if cfg.noATH <> 0 then
  begin
    for sfb := 0 to SBMAX_l - 1 do  gfc^.ATH^.l[sfb]      := 1E-20;
    for sfb := 0 to PSFB21 - 1 do  gfc^.ATH^.psfb21[sfb]  := 1E-20;
    for sfb := 0 to SBMAX_s - 1 do  gfc^.ATH^.s[sfb]       := 1E-20;
    for sfb := 0 to PSFB12 - 1 do  gfc^.ATH^.psfb12[sfb]   := 1E-20;
  end;

  gfc^.ATH^.floor := 10.0 * log10(ATHmdct(cfg, -1.0));
end;

{ -----------------------------------------------------------------------
  payload tables for iteration_init longfact/shortfact
  ----------------------------------------------------------------------- }
const
  payload_long: array[0..1, 0..3] of Single = (
    (-0.000, -0.000, -0.000, +0.000),
    (-0.500, -0.250, -0.025, +0.500)
  );
  payload_short: array[0..1, 0..3] of Single = (
    (-0.000, -0.000, -0.000, +0.000),
    (-2.000, -1.000, -0.050, +0.500)
  );

{ -----------------------------------------------------------------------
  iteration_init
  ----------------------------------------------------------------------- }
procedure iteration_init(gfc: PLameInternalFlags);
var
  cfg: TSessionConfig_t;
  l3_side: PIIISideInfo;
  i, sel: Integer;
  adjust, db: TFloat;
begin
  if gfc^.iteration_init_init <> 0 then Exit;
  gfc^.iteration_init_init := 1;

  cfg := gfc^.cfg;
  l3_side := @gfc^.l3_side;
  l3_side^.main_data_begin := 0;

  compute_ath(gfc);

  pow43[0] := 0.0;
  for i := 1 to PRECALC_SIZE - 1 do
    pow43[i] := Power(i, 4.0 / 3.0);

  for i := 0 to PRECALC_SIZE - 2 do
    adj43[i] := (i + 1) - Power(0.5 * (pow43[i] + pow43[i + 1]), 0.75);
  adj43[PRECALC_SIZE - 1] := 0.5;

  for i := 0 to Q_MAX - 1 do
    ipow20[i] := Power(2.0, (i - 210) * (-0.1875));
  for i := 0 to Q_MAX + Q_MAX2 do
    pow20[i] := Power(2.0, (i - 210 - Q_MAX2) * 0.25);

  huffman_init(gfc);
  init_xrpow_core_init(gfc);

  sel := 1;

  { long blocks }
  db := cfg.adjust_bass + payload_long[sel][0];
  adjust := Power(10.0, db * 0.1);
  for i := 0 to 6 do
    gfc^.sv_qnt.longfact[i] := adjust;

  db := cfg.adjust_alto + payload_long[sel][1];
  adjust := Power(10.0, db * 0.1);
  for i := 7 to 13 do
    gfc^.sv_qnt.longfact[i] := adjust;

  db := cfg.adjust_treble + payload_long[sel][2];
  adjust := Power(10.0, db * 0.1);
  for i := 14 to 20 do
    gfc^.sv_qnt.longfact[i] := adjust;

  db := cfg.adjust_sfb21_db + payload_long[sel][3];
  adjust := Power(10.0, db * 0.1);
  for i := 21 to SBMAX_l - 1 do
    gfc^.sv_qnt.longfact[i] := adjust;

  { short blocks }
  db := cfg.adjust_bass + payload_short[sel][0];
  adjust := Power(10.0, db * 0.1);
  for i := 0 to 2 do
    gfc^.sv_qnt.shortfact[i] := adjust;

  db := cfg.adjust_alto + payload_short[sel][1];
  adjust := Power(10.0, db * 0.1);
  for i := 3 to 6 do
    gfc^.sv_qnt.shortfact[i] := adjust;

  db := cfg.adjust_treble + payload_short[sel][2];
  adjust := Power(10.0, db * 0.1);
  for i := 7 to 11 do
    gfc^.sv_qnt.shortfact[i] := adjust;

  db := cfg.adjust_sfb21_db + payload_short[sel][3];
  adjust := Power(10.0, db * 0.1);
  for i := 12 to SBMAX_s - 1 do
    gfc^.sv_qnt.shortfact[i] := adjust;
end;

{ -----------------------------------------------------------------------
  athAdjust (quantize_pvt.c version)
  Adjusts ATH keeping original noise floor; returns linear energy value
  ----------------------------------------------------------------------- }
function athAdjust(a, x, athFloor: TFloat; ATHfixpoint: Single): TFloat;
const
  o = 90.30873362;
var
  p, u, v, w: TFloat;
begin
  if ATHfixpoint < 1.0 then
    p := 94.82444863
  else
    p := ATHfixpoint;

  u := LameLog10X(x, 10.0);
  v := a * a;
  w := 0.0;
  u := u - athFloor;
  if v > 1E-20 then
    w := 1.0 + LameLog10X(v, 10.0 / o);
  if w < 0.0 then w := 0.0;
  u := u * w;
  u := u + athFloor + o - p;
  Result := Power(10.0, 0.1 * u);
end;

{ -----------------------------------------------------------------------
  on_pe - allocate bits between channels based on perceptual entropy
  pe[gr][ch] is the perceptual entropy for granule gr, channel ch
  ----------------------------------------------------------------------- }
function on_pe(gfc: PLameInternalFlags; pe: PPeArray;
               targ_bits: PIntegerArray; mean_bits, gr, cbr: Integer): Integer;
var
  cfg: TSessionConfig_t;
  extra_bits, tbits, bits, max_bits: Integer;
  add_bits: array[0..1] of Integer;
  ch: Integer;
begin
  cfg := gfc^.cfg;
  ResvMaxBits(gfc, mean_bits, @tbits, @extra_bits, cbr);
  max_bits := tbits + extra_bits;
  if max_bits > MAX_BITS_PER_GRANULE then
    max_bits := MAX_BITS_PER_GRANULE;

  bits := 0;
  for ch := 0 to cfg.channels_out - 1 do
  begin
    targ_bits^[ch] := Min(MAX_BITS_PER_CHANNEL, tbits div cfg.channels_out);

    add_bits[ch] := Trunc(targ_bits^[ch] * pe^[gr][ch] / 700.0) - targ_bits^[ch];

    if add_bits[ch] > mean_bits * 3 div 4 then
      add_bits[ch] := mean_bits * 3 div 4;
    if add_bits[ch] < 0 then add_bits[ch] := 0;

    if add_bits[ch] + targ_bits^[ch] > MAX_BITS_PER_CHANNEL then
      add_bits[ch] := Max(0, MAX_BITS_PER_CHANNEL - targ_bits^[ch]);

    Inc(bits, add_bits[ch]);
  end;

  if (bits > extra_bits) and (bits > 0) then
  begin
    for ch := 0 to cfg.channels_out - 1 do
      add_bits[ch] := extra_bits * add_bits[ch] div bits;
  end;

  for ch := 0 to cfg.channels_out - 1 do
  begin
    Inc(targ_bits^[ch], add_bits[ch]);
    Dec(extra_bits, add_bits[ch]);
  end;

  bits := 0;
  for ch := 0 to cfg.channels_out - 1 do
    Inc(bits, targ_bits^[ch]);

  if bits > MAX_BITS_PER_GRANULE then
  begin
    for ch := 0 to cfg.channels_out - 1 do
    begin
      targ_bits^[ch] := targ_bits^[ch] * MAX_BITS_PER_GRANULE div bits;
    end;
  end;

  Result := max_bits;
end;

{ -----------------------------------------------------------------------
  reduce_side - adjust M/S bit allocation to favour mid channel
  ----------------------------------------------------------------------- }
procedure reduce_side(targ_bits: PIntegerArray; ms_ener_ratio: TFloat;
                      mean_bits, max_bits: Integer);
var
  move_bits: Integer;
  fac: TFloat;
begin
  fac := 0.33 * (0.5 - ms_ener_ratio) / 0.5;
  if fac < 0.0 then fac := 0.0;
  if fac > 0.5 then fac := 0.5;

  move_bits := Trunc(fac * 0.5 * (targ_bits^[0] + targ_bits^[1]));

  if move_bits > MAX_BITS_PER_CHANNEL - targ_bits^[0] then
    move_bits := MAX_BITS_PER_CHANNEL - targ_bits^[0];
  if move_bits < 0 then move_bits := 0;

  if targ_bits^[1] >= 125 then
  begin
    if targ_bits^[1] - move_bits > 125 then
    begin
      if targ_bits^[0] < mean_bits then
        Inc(targ_bits^[0], move_bits);
      Dec(targ_bits^[1], move_bits);
    end
    else
    begin
      Inc(targ_bits^[0], targ_bits^[1] - 125);
      targ_bits^[1] := 125;
    end;
  end;

  move_bits := targ_bits^[0] + targ_bits^[1];
  if move_bits > max_bits then
  begin
    targ_bits^[0] := (max_bits * targ_bits^[0]) div move_bits;
    targ_bits^[1] := (max_bits * targ_bits^[1]) div move_bits;
  end;
end;

{ -----------------------------------------------------------------------
  calc_xmin - calculate allowed distortion per scalefactor band
  Returns number of sfbs with energy above ATH
  ----------------------------------------------------------------------- }
function calc_xmin(gfc: PLameInternalFlags; const ratio: TIIIPsyRatio;
                   cod_info: PGrInfo; pxmin: PSingle): Integer;
var
  cfg: TSessionConfig_t;
  sfb, gsfb, j, ath_over, k, b, l, width: Integer;
  max_nonzero: Integer;
  ATH: PATHt;
  xr: PSingle;
  en0, xmin, rh1, rh2, rh3, xa, x2, tmpATH, e, x: TFloat;
  pxmin_base: PSingle;
  sfb_l, sfb_s, limit: Integer;
begin
  cfg := gfc^.cfg;
  ATH := gfc^.ATH;
  xr  := @cod_info^.xr[0];
  j   := 0;
  ath_over := 0;
  pxmin_base := pxmin;

  { --- long block loop --- }
  for gsfb := 0 to cod_info^.psy_lmax - 1 do
  begin
    xmin  := athAdjust(ATH^.adjust_factor, ATH^.l[gsfb], ATH^.floor, cfg.ATHfixpoint);
    xmin  := xmin * gfc^.sv_qnt.longfact[gsfb];
    width := cod_info^.width[gsfb];
    rh1   := xmin / width;
    rh2   := DBL_EPSILON;
    en0   := 0.0;
    for l := 0 to width - 1 do
    begin
      xa  := PSingleArray(xr)^[j];
      x2  := xa * xa;
      en0 := en0 + x2;
      if x2 < rh1 then rh2 := rh2 + x2 else rh2 := rh2 + rh1;
      Inc(j);
    end;
    if en0 > xmin then Inc(ath_over);

    if en0 < xmin then
      rh3 := en0
    else if rh2 < xmin then
      rh3 := xmin
    else
      rh3 := rh2;
    xmin := rh3;

    e := ratio.en.l[gsfb];
    if e > 1E-12 then
    begin
      x := en0 * ratio.thm.l[gsfb] / e;
      x := x * gfc^.sv_qnt.longfact[gsfb];
      if xmin < x then xmin := x;
    end;

    if xmin < DBL_EPSILON then xmin := DBL_EPSILON;
    if en0 > xmin + 1E-14 then
      cod_info^.energy_above_cutoff[gsfb] := 1
    else
      cod_info^.energy_above_cutoff[gsfb] := 0;
    pxmin^ := xmin;
    Inc(pxmin);
  end;

  { --- find max non-zero coefficient --- }
  max_nonzero := 0;
  for k := 575 downto 1 do
  begin
    if Abs(PSingleArray(xr)^[k]) > 1E-12 then
    begin
      max_nonzero := k;
      Break;
    end;
  end;

  if cod_info^.block_type <> SHORT_TYPE then
    max_nonzero := max_nonzero or 1
  else
  begin
    max_nonzero := max_nonzero div 6;
    max_nonzero := max_nonzero * 6;
    max_nonzero := max_nonzero + 5;
  end;

  if (gfc^.sv_qnt.sfb21_extra = 0) and (cfg.samplerate_out < 44000) then
  begin
    if cfg.samplerate_out <= 8000 then sfb_l := 17 else sfb_l := 21;
    if cfg.samplerate_out <= 8000 then sfb_s := 9  else sfb_s := 12;
    limit := 575;
    if cod_info^.block_type <> SHORT_TYPE then
      limit := gfc^.scalefac_band.l[sfb_l] - 1
    else
      limit := 3 * gfc^.scalefac_band.s[sfb_s] - 1;
    if max_nonzero > limit then
      max_nonzero := limit;
  end;
  cod_info^.max_nonzero_coeff := max_nonzero;

  { --- short block loop --- }
  gsfb := cod_info^.psy_lmax;
  sfb  := cod_info^.sfb_smin;
  while gsfb < cod_info^.psymax do
  begin
    tmpATH := athAdjust(ATH^.adjust_factor, ATH^.s[sfb], ATH^.floor, cfg.ATHfixpoint);
    tmpATH  := tmpATH * gfc^.sv_qnt.shortfact[sfb];
    width   := cod_info^.width[gsfb];
    for b := 0 to 2 do
    begin
      en0  := 0.0;
      rh1  := tmpATH / width;
      rh2  := DBL_EPSILON;
      for l := 0 to width - 1 do
      begin
        xa  := PSingleArray(xr)^[j];
        x2  := xa * xa;
        en0 := en0 + x2;
        if x2 < rh1 then rh2 := rh2 + x2 else rh2 := rh2 + rh1;
        Inc(j);
      end;
      if en0 > tmpATH then Inc(ath_over);

      if en0 < tmpATH then
        rh3 := en0
      else if rh2 < tmpATH then
        rh3 := tmpATH
      else
        rh3 := rh2;
      xmin := rh3;

      e := ratio.en.s[sfb][b];
      if e > 1E-12 then
      begin
        x := en0 * ratio.thm.s[sfb][b] / e;
        x := x * gfc^.sv_qnt.shortfact[sfb];
        if xmin < x then xmin := x;
      end;

      if xmin < DBL_EPSILON then xmin := DBL_EPSILON;
      if en0 > xmin + 1E-14 then
        cod_info^.energy_above_cutoff[gsfb + b] := 1
      else
        cod_info^.energy_above_cutoff[gsfb + b] := 0;
      pxmin^ := xmin;
      Inc(pxmin);
    end;

    if cfg.use_temporal_masking_effect <> 0 then
    begin
      { pxmin[-3..] points back to the 3 sub-bands just written }
      { Use negative-offset arithmetic via pointer arithmetic }
      if PSingleArray(pxmin_base)^[gsfb]     > PSingleArray(pxmin_base)^[gsfb + 1] then
        PSingleArray(pxmin_base)^[gsfb + 1] := PSingleArray(pxmin_base)^[gsfb + 1] +
          (PSingleArray(pxmin_base)^[gsfb] - PSingleArray(pxmin_base)^[gsfb + 1]) *
           gfc^.cd_psy^.decay;
      if PSingleArray(pxmin_base)^[gsfb + 1] > PSingleArray(pxmin_base)^[gsfb + 2] then
        PSingleArray(pxmin_base)^[gsfb + 2] := PSingleArray(pxmin_base)^[gsfb + 2] +
          (PSingleArray(pxmin_base)^[gsfb + 1] - PSingleArray(pxmin_base)^[gsfb + 2]) *
           gfc^.cd_psy^.decay;
    end;

    Inc(sfb);
    Inc(gsfb, 3);
  end;

  Result := ath_over;
end;

{ -----------------------------------------------------------------------
  calc_noise_core_c - inner loop noise calculation
  ----------------------------------------------------------------------- }
function calc_noise_core_c(const cod_info: TGrInfo; startline: PInteger;
                            l: Integer; step: TFloat): TFloat;
var
  noise: TFloat;
  j: Integer;
  temp: TFloat;
  ix01: array[0..1] of TFloat;
begin
  noise := 0.0;
  j     := startline^;

  if j > cod_info.count1 then
  begin
    while l > 0 do
    begin
      temp  := cod_info.xr[j]; Inc(j); noise := noise + temp * temp;
      temp  := cod_info.xr[j]; Inc(j); noise := noise + temp * temp;
      Dec(l);
    end;
  end
  else if j > cod_info.big_values then
  begin
    ix01[0] := 0.0;
    ix01[1] := step;
    while l > 0 do
    begin
      temp  := Abs(cod_info.xr[j]) - ix01[cod_info.l3_enc[j]]; Inc(j);
      noise := noise + temp * temp;
      temp  := Abs(cod_info.xr[j]) - ix01[cod_info.l3_enc[j]]; Inc(j);
      noise := noise + temp * temp;
      Dec(l);
    end;
  end
  else
  begin
    while l > 0 do
    begin
      temp  := Abs(cod_info.xr[j]) - pow43[cod_info.l3_enc[j]] * step; Inc(j);
      noise := noise + temp * temp;
      temp  := Abs(cod_info.xr[j]) - pow43[cod_info.l3_enc[j]] * step; Inc(j);
      noise := noise + temp * temp;
      Dec(l);
    end;
  end;

  startline^ := j;
  Result := noise;
end;

{ -----------------------------------------------------------------------
  calc_noise - calculate quantization noise vs masking threshold
  Returns number of sfbs with distortion > masking
  ----------------------------------------------------------------------- }
function calc_noise(const cod_info: TGrInfo; l3_xmin: PSingle;
                    distort: PSingle; res: PCalcNoiseResult;
                    prev_noise: PCalcNoiseData): Integer;
var
  sfb, l, over: Integer;
  over_noise_db, tot_noise_db, max_noise: TFloat;
  j: Integer;
  scalefac: PInteger;
  s: Integer;
  r_l3_xmin: TFloat;
  distort_: TFloat;
  noise: TFloat;
  step: TFloat;
  usefullsize: Integer;
  tmp: Integer;
  POW20s: TFloat;
begin
  over      := 0;
  over_noise_db := 0.0;
  tot_noise_db  := 0.0;
  max_noise     := -20.0;
  j             := 0;
  scalefac      := @cod_info.scalefac[0];
  res^.over_SSD := 0;

  for sfb := 0 to cod_info.psymax - 1 do
  begin
    s := cod_info.global_gain
         - ((scalefac^ + (IfThen(cod_info.preflag <> 0, pretab[sfb], 0)))
            shl (cod_info.scalefac_scale + 1))
         - cod_info.subblock_gain[cod_info.window[sfb]] * 8;
    Inc(scalefac);

    r_l3_xmin := 1.0 / l3_xmin^;
    Inc(l3_xmin);
    distort_  := 0.0;
    noise     := 0.0;

    if (prev_noise <> nil) and (prev_noise^.step[sfb] = s) then
    begin
      { reuse cached values }
      Inc(j, cod_info.width[sfb]);
      distort_ := r_l3_xmin * prev_noise^.noise[sfb];
      noise    := prev_noise^.noise_log[sfb];
    end
    else
    begin
      POW20s := pow20[s + Q_MAX2];
      l := cod_info.width[sfb] shr 1;

      if (j + cod_info.width[sfb]) > cod_info.max_nonzero_coeff then
      begin
        usefullsize := cod_info.max_nonzero_coeff - j + 1;
        if usefullsize > 0 then l := usefullsize shr 1
        else l := 0;
      end;

      noise := calc_noise_core_c(cod_info, @j, l, POW20s);

      if prev_noise <> nil then
      begin
        prev_noise^.step[sfb]  := s;
        prev_noise^.noise[sfb] := noise;
      end;

      distort_ := r_l3_xmin * noise;
      noise    := LameLog10(Max(distort_, 1E-20));

      if prev_noise <> nil then
        prev_noise^.noise_log[sfb] := noise;
    end;

    distort^ := distort_;
    Inc(distort);

    if prev_noise <> nil then
      prev_noise^.global_gain := cod_info.global_gain;

    tot_noise_db := tot_noise_db + noise;

    if noise > 0.0 then
    begin
      tmp := Max(Trunc(noise * 10 + 0.5), 1);
      Inc(res^.over_SSD, tmp * tmp);
      Inc(over);
      over_noise_db := over_noise_db + noise;
    end;

    if noise > max_noise then max_noise := noise;
  end;

  res^.over_count := over;
  res^.tot_noise  := tot_noise_db;
  res^.over_noise := over_noise_db;
  res^.max_noise  := max_noise;

  Result := over;
end;

end.
