{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LamePsyModel;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Psychoacoustic model (CBR/VBR unified, vbrpsy path)
//  Translated from psymodel.c


interface

uses LameTypes, LameUtils, LameFFT, Math, SysUtils;

{ Main psychoacoustic analysis. Returns 0 on success. }
function L3psycho_anal_vbr(gfc: PLameInternalFlags;
                            const buffer: array of PSample;
                            gr_out: Integer;
                            masking_ratio: PIIIPsyRatio2x2;
                            masking_MS_ratio: PIIIPsyRatio2x2;
                            percep_entropy: PSingle;
                            percep_MS_entropy: PSingle;
                            energy: PSingle;
                            blocktype_d: PInteger): Integer;

{ Initialize psychoacoustic model constants. Call once after lame_init_params. }
function psymodel_init(gfp: PLameGlobalFlags): Integer;

implementation

{$POINTERMATH ON}

const
  NSFIRLEN = 21;
  LN_TO_LOG10 = 0.2302585093;  { ln(10)/10 }

  rpelev   = 2;
  rpelev2  = 16;
  rpelev_s = 2;
  rpelev2_s = 16;

  { mask_add limits }
  I1LIMIT  = 8;
  I2LIMIT  = 23;
  MLIMIT   = 15;
  ma_max_i1: TFloat = 3.6517412725483771;   { pow(10,(I1LIMIT+1)/16.0) }
  ma_max_i2: TFloat = 31.622776601683793;   { pow(10,(I2LIMIT+1)/16.0) }

  tab: array[0..8] of TFloat = (
    1.0, 0.79433, 0.63096, 0.63096, 0.63096, 0.63096, 0.63096, 0.25119, 0.11749
  );

  tab_mask_add_delta: array[0..8] of Integer = (2, 2, 2, 1, 1, 1, 0, 0, -1);

type
  { Internal array types }
  TFFTEnergy    = array[0..HBLKSIZE - 1] of TFloat;
  TFFTEnergyS   = array[0..2, 0..HBLKSIZE_s - 1] of TFloat;
  TWsampL       = array[0..BLKSIZE - 1] of TFloat;
  TWsampS       = array[0..3 * BLKSIZE_s - 1] of TFloat;  { flat [3][BLKSIZE_s] }
  TCBandMaskIdx = array[0..CBANDS + 1] of Byte;

{ -----------------------------------------------------------------------
  Helpers
  ----------------------------------------------------------------------- }

function mask_add_delta(i: Integer): Integer; inline;
begin
  Result := tab_mask_add_delta[i];
end;

function psycho_loudness_approx(const energy: TFFTEnergy;
                                 const eql_w: array of TFloat): TFloat;
var
  i: Integer;
  lp: TFloat;
begin
  lp := 0.0;
  for i := 0 to BLKSIZE div 2 - 1 do
    lp += energy[i] * eql_w[i];
  lp *= VO_SCALE;
  Result := lp;
end;

function vbrpsy_mask_add(m1, m2: TFloat; b, delta: Integer): TFloat;
const
  table2: array[0..9] of TFloat = (
    1.33352 * 1.33352, 1.35879 * 1.35879, 1.38454 * 1.38454,
    1.39497 * 1.39497, 1.40548 * 1.40548, 1.3537 * 1.3537,
    1.30382 * 1.30382, 1.22321 * 1.22321, 1.14758 * 1.14758,
    1.0
  );
var
  ratio: TFloat;
  i: Integer;
begin
  if m1 < 0 then m1 := 0;
  if m2 < 0 then m2 := 0;
  if m1 <= 0 then begin Result := m2; Exit; end;
  if m2 <= 0 then begin Result := m1; Exit; end;
  if m2 > m1 then ratio := m2 / m1
  else            ratio := m1 / m2;
  if Abs(b) <= delta then
  begin
    if ratio >= ma_max_i1 then
    begin
      Result := m1 + m2;
      Exit;
    end;
    i := Trunc(LameLog10X(ratio, 16.0));
    Result := (m1 + m2) * table2[i];
    Exit;
  end;
  if ratio < ma_max_i2 then
  begin
    Result := m1 + m2;
    Exit;
  end;
  if m1 < m2 then m1 := m2;
  Result := m1;
end;

procedure convert_partition2scalefac(gd: PPsyConstCB2SBt;
                                      const eb, thr: TCBandArr;
                                      enn_out, thm_out: PSingle;
                                      n_sb: Integer);
var
  sb, b, bo_sb, b_lim, npart: Integer;
  enn, thmm, w_curr, w_next: TFloat;
begin
  npart := gd^.npart;
  enn := 0;
  thmm := 0;
  b := 0;
  sb := 0;
  while sb < n_sb do
  begin
    bo_sb := gd^.bo[sb];
    b_lim := bo_sb;
    if b_lim > npart then b_lim := npart;
    while b < b_lim do
    begin
      enn  += eb[b];
      thmm += thr[b];
      Inc(b);
    end;
    if b >= npart then
    begin
      PSingleArray(enn_out)^[sb] := enn;
      PSingleArray(thm_out)^[sb] := thmm;
      Inc(sb);
      { zero rest }
      while sb < n_sb do
      begin
        PSingleArray(enn_out)^[sb] := 0;
        PSingleArray(thm_out)^[sb] := 0;
        Inc(sb);
      end;
      Exit;
    end;
    w_curr := gd^.bo_weight[sb];
    w_next := 1.0 - w_curr;
    enn  += w_curr * eb[b];
    thmm += w_curr * thr[b];
    PSingleArray(enn_out)^[sb] := enn;
    PSingleArray(thm_out)^[sb] := thmm;
    enn  := w_next * eb[b];
    thmm := w_next * thr[b];
    Inc(sb);
  end;
end;

procedure convert_partition2scalefac_s(gfc: PLameInternalFlags;
                                        const eb, thr: TCBandArr;
                                        chn, sblock: Integer);
var
  psv: ^TPsyStateVar_t;
  enn_arr, thm_arr: array[0..SBMAX_s - 1] of TFloat;
  sb: Integer;
begin
  psv := @gfc^.sv_psy;
  convert_partition2scalefac(@gfc^.cd_psy^.s, eb, thr,
                              @enn_arr[0], @thm_arr[0], SBMAX_s);
  for sb := 0 to SBMAX_s - 1 do
  begin
    psv^.en[chn].s[sb][sblock]  := enn_arr[sb];
    psv^.thm[chn].s[sb][sblock] := thm_arr[sb];
  end;
end;

procedure convert_partition2scalefac_l(gfc: PLameInternalFlags;
                                        const eb, thr: TCBandArr;
                                        chn: Integer);
begin
  convert_partition2scalefac(@gfc^.cd_psy^.l, eb, thr,
                              @gfc^.sv_psy.en[chn].l[0],
                              @gfc^.sv_psy.thm[chn].l[0],
                              SBMAX_l);
end;

procedure convert_partition2scalefac_l_to_s(gfc: PLameInternalFlags;
                                              const eb, thr: TCBandArr;
                                              chn: Integer);
var
  enn_arr, thm_arr: array[0..SBMAX_s - 1] of TFloat;
  sb, sblock: Integer;
  scale, tmp_enn, tmp_thm: TFloat;
begin
  convert_partition2scalefac(@gfc^.cd_psy^.l_to_s, eb, thr,
                              @enn_arr[0], @thm_arr[0], SBMAX_s);
  scale := 1.0 / 64.0;
  for sb := 0 to SBMAX_s - 1 do
  begin
    tmp_enn := enn_arr[sb];
    tmp_thm := thm_arr[sb] * scale;
    for sblock := 0 to 2 do
    begin
      gfc^.sv_psy.en[chn].s[sb][sblock]  := tmp_enn;
      gfc^.sv_psy.thm[chn].s[sb][sblock] := tmp_thm;
    end;
  end;
end;

function NS_INTERP(x, y, r: TFloat): TFloat; inline;
begin
  if r >= 1.0 then begin Result := x; Exit; end;
  if r <= 0.0 then begin Result := y; Exit; end;
  if y > 0.0  then begin Result := Power(x / y, r) * y; Exit; end;
  Result := 0.0;
end;

function pecalc_s(const mr: TIIIPsyRatio; masking_lower: TFloat): TFloat;
const
  regcoef_s: array[0..11] of TFloat = (
    11.8, 13.6, 17.2, 32.0, 46.5, 51.3, 57.5, 67.1, 71.5, 84.6, 97.6, 130.0
  );
var
  sb, sblock: Integer;
  pe_s, thm, x, en: TFloat;
begin
  pe_s := 1236.28 / 4;
  for sb := 0 to SBMAX_s - 2 do
    for sblock := 0 to 2 do
    begin
      thm := mr.thm.s[sb][sblock];
      if thm > 0.0 then
      begin
        x  := thm * masking_lower;
        en := mr.en.s[sb][sblock];
        if en > x then
        begin
          if en > x * 1e10 then
            pe_s += regcoef_s[sb] * (10.0 * LAME_LOG10)
          else
            pe_s += regcoef_s[sb] * LameLog10(en / x);
        end;
      end;
    end;
  Result := pe_s;
end;

function pecalc_l(const mr: TIIIPsyRatio; masking_lower: TFloat): TFloat;
const
  regcoef_l: array[0..20] of TFloat = (
    6.8, 5.8, 5.8, 6.4, 6.5, 9.9, 12.1, 14.4, 15.0, 18.9, 21.6,
    26.9, 34.2, 40.2, 46.8, 56.5, 60.7, 73.9, 85.7, 93.4, 126.1
  );
var
  sb: Integer;
  pe_l, thm, x, en: TFloat;
begin
  pe_l := 1124.23 / 4;
  for sb := 0 to SBMAX_l - 2 do
  begin
    thm := mr.thm.l[sb];
    if thm > 0.0 then
    begin
      x  := thm * masking_lower;
      en := mr.en.l[sb];
      if en > x then
      begin
        if en > x * 1e10 then
          pe_l += regcoef_l[sb] * (10.0 * LAME_LOG10)
        else
          pe_l += regcoef_l[sb] * LameLog10(en / x);
      end;
    end;
  end;
  Result := pe_l;
end;

procedure calc_energy(gd: PPsyConstCB2SBt;
                      const fftenergy: TFFTEnergy;
                      var eb, max_, avg: TCBandArr);
var
  b, j, i: Integer;
  ebb, m, el: TFloat;
begin
  j := 0;
  for b := 0 to gd^.npart - 1 do
  begin
    ebb := 0; m := 0;
    for i := 0 to gd^.numlines[b] - 1 do
    begin
      el := fftenergy[j];
      ebb += el;
      if m < el then m := el;
      Inc(j);
    end;
    eb[b]   := ebb;
    max_[b] := m;
    avg[b]  := ebb * gd^.rnumlines[b];
  end;
end;

procedure calc_mask_index_l(gfc: PLameInternalFlags;
                             const max_, avg: TCBandArr;
                             var mask_idx: TCBandMaskIdx);
var
  gdl: PPsyConstCB2SBt;
  m, a: TFloat;
  b, k, last_tab_entry: Integer;
begin
  gdl := @gfc^.cd_psy^.l;
  last_tab_entry := High(tab);

  b := 0;
  a := avg[b] + avg[b + 1];
  if a > 0.0 then
  begin
    m := max_[b];
    if m < max_[b + 1] then m := max_[b + 1];
    a := 20.0 * (m * 2.0 - a) / (a * (gdl^.numlines[b] + gdl^.numlines[b + 1] - 1));
    k := Trunc(a);
    if k > last_tab_entry then k := last_tab_entry;
    mask_idx[b] := k;
  end
  else
    mask_idx[b] := 0;

  for b := 1 to gdl^.npart - 2 do
  begin
    a := avg[b - 1] + avg[b] + avg[b + 1];
    if a > 0.0 then
    begin
      m := max_[b - 1];
      if m < max_[b]     then m := max_[b];
      if m < max_[b + 1] then m := max_[b + 1];
      a := 20.0 * (m * 3.0 - a)
           / (a * (gdl^.numlines[b-1] + gdl^.numlines[b] + gdl^.numlines[b+1] - 1));
      k := Trunc(a);
      if k > last_tab_entry then k := last_tab_entry;
      mask_idx[b] := k;
    end
    else
      mask_idx[b] := 0;
  end;

  b := gdl^.npart - 1;
  a := avg[b - 1] + avg[b];
  if a > 0.0 then
  begin
    m := max_[b - 1];
    if m < max_[b] then m := max_[b];
    a := 20.0 * (m * 2.0 - a) / (a * (gdl^.numlines[b-1] + gdl^.numlines[b] - 1));
    k := Trunc(a);
    if k > last_tab_entry then k := last_tab_entry;
    mask_idx[b] := k;
  end
  else
    mask_idx[b] := 0;
end;

procedure vbrpsy_calc_mask_index_s(gfc: PLameInternalFlags;
                                    const max_, avg: TCBandArr;
                                    var mask_idx: TCBandMaskIdx);
var
  gds: PPsyConstCB2SBt;
  m, a: TFloat;
  b, k, last_tab_entry: Integer;
begin
  gds := @gfc^.cd_psy^.s;
  last_tab_entry := High(tab);

  b := 0;
  a := avg[b] + avg[b + 1];
  if a > 0.0 then
  begin
    m := max_[b];
    if m < max_[b + 1] then m := max_[b + 1];
    a := 20.0 * (m * 2.0 - a) / (a * (gds^.numlines[b] + gds^.numlines[b + 1] - 1));
    k := Trunc(a);
    if k > last_tab_entry then k := last_tab_entry;
    mask_idx[b] := k;
  end
  else
    mask_idx[b] := 0;

  for b := 1 to gds^.npart - 2 do
  begin
    a := avg[b - 1] + avg[b] + avg[b + 1];
    if a > 0.0 then
    begin
      m := max_[b - 1];
      if m < max_[b]     then m := max_[b];
      if m < max_[b + 1] then m := max_[b + 1];
      a := 20.0 * (m * 3.0 - a)
           / (a * (gds^.numlines[b-1] + gds^.numlines[b] + gds^.numlines[b+1] - 1));
      k := Trunc(a);
      if k > last_tab_entry then k := last_tab_entry;
      mask_idx[b] := k;
    end
    else
      mask_idx[b] := 0;
  end;

  b := gds^.npart - 1;
  a := avg[b - 1] + avg[b];
  if a > 0.0 then
  begin
    m := max_[b - 1];
    if m < max_[b] then m := max_[b];
    a := 20.0 * (m * 2.0 - a) / (a * (gds^.numlines[b-1] + gds^.numlines[b] - 1));
    k := Trunc(a);
    if k > last_tab_entry then k := last_tab_entry;
    mask_idx[b] := k;
  end
  else
    mask_idx[b] := 0;
end;

procedure vbrpsy_compute_fft_l(gfc: PLameInternalFlags;
                                const buffer: array of PSample;
                                chn, gr_out: Integer;
                                var fftenergy: TFFTEnergy;
                                var wsamp_L0, wsamp_L1: TWsampL);
var
  psv: ^TPsyStateVar_t;
  sqrt2_half: TFloat;
  l, r: TFloat;
  j: Integer;
  totalenergy: TFloat;
begin
  psv := @gfc^.sv_psy;
  if chn < 2 then
    fft_long(gfc, wsamp_L0, chn, buffer)
  else if chn = 2 then
  begin
    sqrt2_half := LAME_SQRT2 * 0.5;
    for j := BLKSIZE - 1 downto 0 do
    begin
      l := wsamp_L0[j];
      r := wsamp_L1[j];
      wsamp_L0[j] := (l + r) * sqrt2_half;
      wsamp_L1[j] := (l - r) * sqrt2_half;
    end;
  end;

  fftenergy[0] := wsamp_L0[0] * wsamp_L0[0];
  for j := BLKSIZE div 2 - 1 downto 0 do
  begin
    fftenergy[BLKSIZE div 2 - j] :=
      (wsamp_L0[BLKSIZE div 2 - j] * wsamp_L0[BLKSIZE div 2 - j]
       + wsamp_L0[BLKSIZE div 2 + j] * wsamp_L0[BLKSIZE div 2 + j]) * 0.5;
  end;

  totalenergy := 0.0;
  for j := 11 to HBLKSIZE - 1 do
    totalenergy += fftenergy[j];
  psv^.tot_ener[chn] := totalenergy;
end;

procedure vbrpsy_compute_fft_s(gfc: PLameInternalFlags;
                                const buffer: array of PSample;
                                chn, sblock: Integer;
                                var fftenergy_s: TFFTEnergyS;
                                var wsamp_S0, wsamp_S1: TWsampS);
var
  sqrt2_half: TFloat;
  l, r: TFloat;
  j: Integer;
begin
  if (sblock = 0) and (chn < 2) then
    fft_short(gfc, wsamp_S0, chn, buffer);

  if chn = 2 then
  begin
    sqrt2_half := LAME_SQRT2 * 0.5;
    for j := BLKSIZE_s - 1 downto 0 do
    begin
      l := wsamp_S0[sblock * BLKSIZE_s + j];
      r := wsamp_S1[sblock * BLKSIZE_s + j];
      wsamp_S0[sblock * BLKSIZE_s + j] := (l + r) * sqrt2_half;
      wsamp_S1[sblock * BLKSIZE_s + j] := (l - r) * sqrt2_half;
    end;
  end;

  fftenergy_s[sblock][0] := wsamp_S0[sblock * BLKSIZE_s] * wsamp_S0[sblock * BLKSIZE_s];
  for j := BLKSIZE_s div 2 - 1 downto 0 do
  begin
    fftenergy_s[sblock][BLKSIZE_s div 2 - j] :=
      (wsamp_S0[sblock * BLKSIZE_s + BLKSIZE_s div 2 - j]
       * wsamp_S0[sblock * BLKSIZE_s + BLKSIZE_s div 2 - j]
       + wsamp_S0[sblock * BLKSIZE_s + BLKSIZE_s div 2 + j]
       * wsamp_S0[sblock * BLKSIZE_s + BLKSIZE_s div 2 + j]) * 0.5;
  end;
end;

procedure vbrpsy_compute_loudness_approximation_l(gfc: PLameInternalFlags;
                                                   gr_out, chn: Integer;
                                                   const fftenergy: TFFTEnergy);
var
  psv: ^TPsyStateVar_t;
begin
  psv := @gfc^.sv_psy;
  if chn < 2 then
  begin
    gfc^.ov_psy.loudness_sq[gr_out][chn] := psv^.loudness_sq_save[chn];
    psv^.loudness_sq_save[chn] :=
      psycho_loudness_approx(fftenergy, gfc^.ATH^.eql_w);
  end;
end;

procedure vbrpsy_attack_detection(gfc: PLameInternalFlags;
                                   const buffer: array of PSample;
                                   gr_out: Integer;
                                   masking_ratio: PIIIPsyRatio2x2;
                                   masking_MS_ratio: PIIIPsyRatio2x2;
                                   energy: PSingle;
                                   var sub_short_factor: array of TFloat;  { [4][3] flat }
                                   var ns_attacks: array of Integer;       { [4][4] flat }
                                   var uselongblock: array of Integer);
const
  fircoef: array[0..9] of TFloat = (
    -8.65163e-18 * 2, -0.00851586 * 2, -6.74764e-18 * 2,  0.0209036 * 2,
    -3.36639e-17 * 2, -0.0438162  * 2, -1.54175e-17 * 2,  0.0931738 * 2,
    -5.52212e-17 * 2, -0.313819   * 2
  );
var
  ns_hpfsmpl: array[0..1, 0..575] of TFloat;
  cfg: ^TSessionConfig_t;
  psv: ^TPsyStateVar_t;
  n_chn_out, n_chn_psy: Integer;
  chn, i, j: Integer;
  attack_intensity: array[0..11] of TFloat;
  en_subshort: array[0..11] of TFloat;
  en_short: array[0..3] of TFloat;
  pf: PSample;
  pfe: PSample;
  ns_uselongblock: Integer;
  p, u, v, m, enn, factor: TFloat;
  x: TFloat;
  sum1, sum2: TFloat;
  firbuf: PSample;
begin
  cfg := @gfc^.cfg;
  psv := @gfc^.sv_psy;
  n_chn_out := cfg^.channels_out;
  if cfg^.mode = JOINT_STEREO then n_chn_psy := 4 else n_chn_psy := n_chn_out;

  FillChar(ns_hpfsmpl, SizeOf(ns_hpfsmpl), 0);

  for chn := 0 to n_chn_out - 1 do
  begin
    firbuf := buffer[chn];
    Inc(firbuf, 576 - 350 - NSFIRLEN + 192);
    for i := 0 to 575 do
    begin
      sum1 := PSampleArray(firbuf)^[i + 10];
      sum2 := 0.0;
      j := 0;
      while j < (NSFIRLEN - 1) div 2 - 1 do
      begin
        sum1 += fircoef[j]     * (PSampleArray(firbuf)^[i + j]          + PSampleArray(firbuf)^[i + NSFIRLEN - j]);
        sum2 += fircoef[j + 1] * (PSampleArray(firbuf)^[i + j + 1]      + PSampleArray(firbuf)^[i + NSFIRLEN - j - 1]);
        Inc(j, 2);
      end;
      ns_hpfsmpl[chn][i] := sum1 + sum2;
    end;
    masking_ratio^[gr_out][chn].en  := psv^.en[chn];
    masking_ratio^[gr_out][chn].thm := psv^.thm[chn];
    if n_chn_psy > 2 then
    begin
      masking_MS_ratio^[gr_out][chn].en  := psv^.en[chn + 2];
      masking_MS_ratio^[gr_out][chn].thm := psv^.thm[chn + 2];
    end;
  end;

  for chn := 0 to n_chn_psy - 1 do
  begin
    FillChar(en_short, SizeOf(en_short), 0);
    ns_uselongblock := 1;

    if chn = 2 then
    begin
      for i := 0 to 575 do
      begin
        x := ns_hpfsmpl[0][i];
        ns_hpfsmpl[0][i] := x + ns_hpfsmpl[1][i];
        ns_hpfsmpl[1][i] := x - ns_hpfsmpl[1][i];
      end;
    end;

    for i := 0 to 2 do
    begin
      en_subshort[i] := psv^.last_en_subshort[chn][i + 6];
      attack_intensity[i] := en_subshort[i] / psv^.last_en_subshort[chn][i + 4];
      en_short[0] += en_subshort[i];
    end;

    pf := @ns_hpfsmpl[chn and 1][0];
    for i := 0 to 8 do
    begin
      pfe := pf;
      Inc(pfe, 576 div 9);
      p := 1.0;
      while LongWord(pf) < LongWord(pfe) do
      begin
        if p < Abs(pf^) then p := Abs(pf^);
        Inc(pf);
      end;
      psv^.last_en_subshort[chn][i] := p;
      en_subshort[i + 3] := p;
      en_short[1 + i div 3] += p;
      if p > en_subshort[i + 1] then
      begin
        if en_subshort[i + 1] > 0 then
          p := p / en_subshort[i + 1]
        else
          p := 0.0;
      end
      else if en_subshort[i + 1] > p * 10.0 then
      begin
        if p > 0 then
          p := en_subshort[i + 1] / (p * 10.0)
        else
          p := 0.0;
      end
      else
        p := 0.0;
      attack_intensity[i + 3] := p;
    end;

    for i := 0 to 2 do
    begin
      enn := en_subshort[i * 3 + 3] + en_subshort[i * 3 + 4] + en_subshort[i * 3 + 5];
      factor := 1.0;
      if en_subshort[i * 3 + 5] * 6 < enn then
      begin
        factor *= 0.5;
        if en_subshort[i * 3 + 4] * 6 < enn then
          factor *= 0.5;
      end;
      sub_short_factor[chn * 3 + i] := factor;
    end;

    x := gfc^.cd_psy^.attack_threshold[chn];
    for i := 0 to 11 do
    begin
      if ns_attacks[chn * 4 + i div 3] = 0 then
        if attack_intensity[i] > x then
          ns_attacks[chn * 4 + i div 3] := (i mod 3) + 1;
    end;

    for i := 1 to 3 do
    begin
      u := en_short[i - 1];
      v := en_short[i];
      m := u; if v > m then m := v;
      if m < 40000 then
      begin
        if (u < 1.7 * v) and (v < 1.7 * u) then
        begin
          if (i = 1) and (ns_attacks[chn * 4 + 0] <= ns_attacks[chn * 4 + i]) then
            ns_attacks[chn * 4 + 0] := 0;
          ns_attacks[chn * 4 + i] := 0;
        end;
      end;
    end;

    if ns_attacks[chn * 4 + 0] <= psv^.last_attacks[chn] then
      ns_attacks[chn * 4 + 0] := 0;

    if (psv^.last_attacks[chn] = 3) or
       (ns_attacks[chn*4+0] + ns_attacks[chn*4+1] + ns_attacks[chn*4+2] + ns_attacks[chn*4+3] > 0) then
    begin
      ns_uselongblock := 0;
      if (ns_attacks[chn*4+1] <> 0) and (ns_attacks[chn*4+0] <> 0) then
        ns_attacks[chn*4+1] := 0;
      if (ns_attacks[chn*4+2] <> 0) and (ns_attacks[chn*4+1] <> 0) then
        ns_attacks[chn*4+2] := 0;
      if (ns_attacks[chn*4+3] <> 0) and (ns_attacks[chn*4+2] <> 0) then
        ns_attacks[chn*4+3] := 0;
    end;

    if chn < 2 then
      uselongblock[chn] := ns_uselongblock
    else
    begin
      if ns_uselongblock = 0 then
      begin
        uselongblock[0] := 0;
        uselongblock[1] := 0;
      end;
    end;

    PSingleArray(energy)^[chn] := psv^.tot_ener[chn];
  end;
end;

procedure vbrpsy_skip_masking_s(gfc: PLameInternalFlags; chn, sblock: Integer);
var
  b, n: Integer;
begin
  if sblock = 0 then
  begin
    n := gfc^.cd_psy^.s.npart;
    for b := 0 to n - 1 do
      gfc^.sv_psy.nb_s2[chn][b] := gfc^.sv_psy.nb_s1[chn][b];
  end;
end;

procedure vbrpsy_compute_masking_s(gfc: PLameInternalFlags;
                                    const fftenergy_s: TFFTEnergyS;
                                    var eb, thr: TCBandArr;
                                    chn, sblock: Integer);
var
  psv: ^TPsyStateVar_t;
  gds: PPsyConstCB2SBt;
  max_, avg: TCBandArr;
  mask_idx_s: TCBandMaskIdx;
  i, j, b, kk, last, delta, dd, dd_n: Integer;
  ebb, m, el, x, ecb, avg_mask, masking_lower: TFloat;
begin
  psv := @gfc^.sv_psy;
  gds := @gfc^.cd_psy^.s;
  FillChar(max_, SizeOf(max_), 0);
  FillChar(avg,  SizeOf(avg),  0);

  j := 0;
  for b := 0 to gds^.npart - 1 do
  begin
    ebb := 0; m := 0;
    for i := 0 to gds^.numlines[b] - 1 do
    begin
      el := fftenergy_s[sblock][j];
      ebb += el;
      if m < el then m := el;
      Inc(j);
    end;
    eb[b]   := ebb;
    max_[b] := m;
    avg[b]  := ebb * gds^.rnumlines[b];
  end;

  vbrpsy_calc_mask_index_s(gfc, max_, avg, mask_idx_s);

  j := 0;
  for b := 0 to gds^.npart - 1 do
  begin
    kk    := gds^.s3ind[b][0];
    last  := gds^.s3ind[b][1];
    delta := mask_add_delta(mask_idx_s[b]);
    masking_lower := gds^.masking_lower[b] * gfc^.sv_qnt.masking_lower;

    dd   := mask_idx_s[kk];
    dd_n := 1;
    ecb  := gds^.s3[j] * eb[kk] * tab[mask_idx_s[kk]];
    Inc(j); Inc(kk);
    while kk <= last do
    begin
      dd   += mask_idx_s[kk];
      dd_n += 1;
      x    := gds^.s3[j] * eb[kk] * tab[mask_idx_s[kk]];
      ecb  := vbrpsy_mask_add(ecb, x, kk - b, delta);
      Inc(j); Inc(kk);
    end;
    dd := (1 + 2 * dd) div (2 * dd_n);
    avg_mask := tab[dd] * 0.5;
    ecb *= avg_mask;
    thr[b] := ecb;
    psv^.nb_s2[chn][b] := psv^.nb_s1[chn][b];
    psv^.nb_s1[chn][b] := ecb;

    x := max_[b] * gds^.minval[b] * avg_mask;
    if thr[b] > x then thr[b] := x;
    if masking_lower > 1 then thr[b] *= masking_lower;
    if thr[b] > eb[b]    then thr[b] := eb[b];
    if masking_lower < 1 then thr[b] *= masking_lower;
  end;
  for b := gds^.npart to CBANDS - 1 do
  begin
    eb[b]  := 0;
    thr[b] := 0;
  end;
end;

procedure vbrpsy_compute_masking_l(gfc: PLameInternalFlags;
                                    const fftenergy: TFFTEnergy;
                                    var eb_l, thr: TCBandArr;
                                    chn: Integer);
var
  psv: ^TPsyStateVar_t;
  gdl: PPsyConstCB2SBt;
  max_, avg: TCBandArr;
  mask_idx_l: TCBandMaskIdx;
  b, k, kk, last, delta, dd, dd_n: Integer;
  x, ecb, avg_mask, t, masking_lower: TFloat;
  ecb_limit, ecb_limit_1, ecb_limit_2: TFloat;
begin
  psv := @gfc^.sv_psy;
  gdl := @gfc^.cd_psy^.l;

  calc_energy(gdl, fftenergy, eb_l, max_, avg);
  calc_mask_index_l(gfc, max_, avg, mask_idx_l);

  k := 0;
  for b := 0 to gdl^.npart - 1 do
  begin
    masking_lower := gdl^.masking_lower[b] * gfc^.sv_qnt.masking_lower;
    kk    := gdl^.s3ind[b][0];
    last  := gdl^.s3ind[b][1];
    delta := mask_add_delta(mask_idx_l[b]);
    dd    := 0; dd_n := 0;

    dd    := mask_idx_l[kk];
    dd_n  += 1;
    ecb   := gdl^.s3[k] * eb_l[kk] * tab[mask_idx_l[kk]];
    Inc(k); Inc(kk);
    while kk <= last do
    begin
      dd   += mask_idx_l[kk];
      dd_n += 1;
      x    := gdl^.s3[k] * eb_l[kk] * tab[mask_idx_l[kk]];
      ecb  := vbrpsy_mask_add(ecb, x, kk - b, delta);
      Inc(k); Inc(kk);
    end;
    dd := (1 + 2 * dd) div (2 * dd_n);
    avg_mask := tab[dd] * 0.5;
    ecb *= avg_mask;

    if psv^.blocktype_old[chn and 1] = SHORT_TYPE then
    begin
      ecb_limit := rpelev * psv^.nb_l1[chn][b];
      if ecb_limit > 0 then
        thr[b] := Min(ecb, ecb_limit)
      else
        thr[b] := Min(ecb, eb_l[b] * NS_PREECHO_ATT2);
    end
    else
    begin
      ecb_limit_2 := rpelev2 * psv^.nb_l2[chn][b];
      ecb_limit_1 := rpelev  * psv^.nb_l1[chn][b];
      if ecb_limit_2 <= 0 then ecb_limit_2 := ecb;
      if ecb_limit_1 <= 0 then ecb_limit_1 := ecb;
      if psv^.blocktype_old[chn and 1] = NORM_TYPE then
        ecb_limit := Min(ecb_limit_1, ecb_limit_2)
      else
        ecb_limit := ecb_limit_1;
      thr[b] := Min(ecb, ecb_limit);
    end;
    psv^.nb_l2[chn][b] := psv^.nb_l1[chn][b];
    psv^.nb_l1[chn][b] := ecb;

    x := max_[b] * gdl^.minval[b] * avg_mask;
    if thr[b] > x then thr[b] := x;
    if masking_lower > 1 then thr[b] *= masking_lower;
    if thr[b] > eb_l[b]  then thr[b] := eb_l[b];
    if masking_lower < 1 then thr[b] *= masking_lower;
  end;
  for b := gdl^.npart to CBANDS - 1 do
  begin
    eb_l[b] := 0;
    thr[b]  := 0;
  end;
end;

procedure vbrpsy_compute_block_type(cfg: PSessionConfig_t;
                                     var uselongblock: array of Integer);
var
  chn: Integer;
begin
  if (cfg^.short_blocks = short_block_coupled)
     and not((uselongblock[0] <> 0) and (uselongblock[1] <> 0)) then
  begin
    uselongblock[0] := 0;
    uselongblock[1] := 0;
  end;
  for chn := 0 to cfg^.channels_out - 1 do
  begin
    if cfg^.short_blocks = short_block_dispensed then uselongblock[chn] := 1;
    if cfg^.short_blocks = short_block_forced    then uselongblock[chn] := 0;
  end;
end;

procedure vbrpsy_apply_block_type(psv: PPsyStateVar_t; nch: Integer;
                                   const uselongblock: array of Integer;
                                   blocktype_d: PInteger);
var
  chn, blocktype: Integer;
begin
  for chn := 0 to nch - 1 do
  begin
    blocktype := NORM_TYPE;
    if uselongblock[chn] <> 0 then
    begin
      if psv^.blocktype_old[chn] = SHORT_TYPE then
        blocktype := STOP_TYPE;
    end
    else
    begin
      blocktype := SHORT_TYPE;
      if psv^.blocktype_old[chn] = NORM_TYPE then
        psv^.blocktype_old[chn] := START_TYPE;
      if psv^.blocktype_old[chn] = STOP_TYPE then
        psv^.blocktype_old[chn] := SHORT_TYPE;
    end;
    PIntegerArray(blocktype_d)^[chn] := psv^.blocktype_old[chn];
    psv^.blocktype_old[chn] := blocktype;
  end;
end;

procedure vbrpsy_compute_MS_thresholds(const eb: T4CBandArr;
                                        var thr: T4CBandArr;
                                        const cb_mld, ath_cb: TCBandArr;
                                        athlower, msfix: TFloat;
                                        n: Integer);
var
  msfix2, rside, rmid: TFloat;
  ebM, ebS, thmL, thmR, thmM, thmS: TFloat;
  mld_m, mld_s, tmp_m, tmp_s: TFloat;
  thmLR, thmMS, ath, tmp_l, tmp_r, f: TFloat;
  b: Integer;
begin
  msfix2 := msfix * 2.0;
  for b := 0 to n - 1 do
  begin
    ebM  := eb[2][b]; ebS  := eb[3][b];
    thmL := thr[0][b]; thmR := thr[1][b];
    thmM := thr[2][b]; thmS := thr[3][b];

    if (thmL <= 1.58 * thmR) and (thmR <= 1.58 * thmL) then
    begin
      mld_m := cb_mld[b] * ebS;
      mld_s := cb_mld[b] * ebM;
      tmp_m := thmS; if mld_m < tmp_m then tmp_m := mld_m;
      tmp_s := thmM; if mld_s < tmp_s then tmp_s := mld_s;
      rmid  := thmM; if tmp_m > rmid  then rmid  := tmp_m;
      rside := thmS; if tmp_s > rside then rside := tmp_s;
    end
    else
    begin
      rmid  := thmM;
      rside := thmS;
    end;

    if msfix > 0.0 then
    begin
      ath   := ath_cb[b] * athlower;
      tmp_l := thmL; if ath > tmp_l then tmp_l := ath;
      tmp_r := thmR; if ath > tmp_r then tmp_r := ath;
      thmLR := tmp_l; if tmp_r < thmLR then thmLR := tmp_r;
      thmM  := rmid;  if ath > thmM  then thmM  := ath;
      thmS  := rside; if ath > thmS  then thmS  := ath;
      thmMS := thmM + thmS;
      if (thmMS > 0.0) and (thmLR * msfix2 < thmMS) then
      begin
        f     := thmLR * msfix2 / thmMS;
        thmM  *= f;
        thmS  *= f;
      end;
      if thmM  < rmid  then rmid  := thmM;
      if thmS  < rside then rside := thmS;
    end;

    if rmid  > ebM then rmid  := ebM;
    if rside > ebS then rside := ebS;
    thr[2][b] := rmid;
    thr[3][b] := rside;
  end;
end;

{ -----------------------------------------------------------------------
  Main psychoacoustic analysis
  ----------------------------------------------------------------------- }

function L3psycho_anal_vbr(gfc: PLameInternalFlags;
                            const buffer: array of PSample;
                            gr_out: Integer;
                            masking_ratio: PIIIPsyRatio2x2;
                            masking_MS_ratio: PIIIPsyRatio2x2;
                            percep_entropy: PSingle;
                            percep_MS_entropy: PSingle;
                            energy: PSingle;
                            blocktype_d: PInteger): Integer;
var
  cfg: ^TSessionConfig_t;
  psv: ^TPsyStateVar_t;
  gdl: PPsyConstCB2SBt;
  gds: PPsyConstCB2SBt;
  last_thm: array[0..3] of TIIIPsyXmin;

  wsamp_L: array[0..1] of TWsampL;
  wsamp_S: array[0..1] of TWsampS;
  fftenergy: TFFTEnergy;
  fftenergy_s: TFFTEnergyS;
  eb: T4CBandArr;
  thr: T4CBandArr;

  sub_short_factor: array[0..11] of TFloat;   { [4][3] flat }
  ns_attacks: array[0..15] of Integer;         { [4][4] flat }
  uselongblock: array[0..1] of Integer;

  thmm, t1, t2, prev_thm: TFloat;
  new_thmm: array[0..2] of TFloat;
  pcfact, ath_factor: TFloat;

  n_chn_psy: Integer;
  chn, ch01, sb, sblock: Integer;
  force_short: Integer;
  ppe: PSingle;
  mr: ^TIIIPsyRatio;
  block_type: Integer;
begin
  cfg := @gfc^.cfg;
  psv := @gfc^.sv_psy;
  gdl := @gfc^.cd_psy^.l;
  gds := @gfc^.cd_psy^.s;

  pcfact := 0.6;
  if cfg^.msfix > 0.0 then
    ath_factor := cfg^.ATH_offset_factor * gfc^.ATH^.adjust_factor
  else
    ath_factor := 1.0;

  if cfg^.mode = JOINT_STEREO then n_chn_psy := 4 else n_chn_psy := cfg^.channels_out;

  { save previous thresholds }
  Move(psv^.thm[0], last_thm[0], SizeOf(last_thm));

  FillChar(ns_attacks,      SizeOf(ns_attacks),      0);
  FillChar(sub_short_factor, SizeOf(sub_short_factor), 0);

  vbrpsy_attack_detection(gfc, buffer, gr_out, masking_ratio, masking_MS_ratio,
                           energy, sub_short_factor, ns_attacks, uselongblock);
  vbrpsy_compute_block_type(cfg, uselongblock);

  { ---- LONG BLOCK processing ---- }
  for chn := 0 to n_chn_psy - 1 do
  begin
    ch01 := chn and 1;
    vbrpsy_compute_fft_l(gfc, buffer, chn, gr_out, fftenergy,
                          wsamp_L[ch01], wsamp_L[ch01 xor 1]);
    vbrpsy_compute_loudness_approximation_l(gfc, gr_out, chn, fftenergy);
    vbrpsy_compute_masking_l(gfc, fftenergy, eb[chn], thr[chn], chn);
  end;
  if cfg^.mode = JOINT_STEREO then
  begin
    if uselongblock[0] + uselongblock[1] = 2 then
      vbrpsy_compute_MS_thresholds(eb, thr, gdl^.mld_cb, gfc^.ATH^.cb_l,
                                    ath_factor, cfg^.msfix, gdl^.npart);
  end;
  for chn := 0 to n_chn_psy - 1 do
  begin
    convert_partition2scalefac_l(gfc, eb[chn], thr[chn], chn);
    convert_partition2scalefac_l_to_s(gfc, eb[chn], thr[chn], chn);
  end;

  { ---- SHORT BLOCK processing ---- }
  force_short := gfc^.cd_psy^.force_short_block_calc;
  for sblock := 0 to 2 do
  begin
    for chn := 0 to n_chn_psy - 1 do
    begin
      ch01 := chn and 1;
      if (uselongblock[ch01] <> 0) and (force_short = 0) then
        vbrpsy_skip_masking_s(gfc, chn, sblock)
      else
      begin
        vbrpsy_compute_fft_s(gfc, buffer, chn, sblock, fftenergy_s,
                              wsamp_S[ch01], wsamp_S[ch01 xor 1]);
        vbrpsy_compute_masking_s(gfc, fftenergy_s, eb[chn], thr[chn], chn, sblock);
      end;
    end;
    if cfg^.mode = JOINT_STEREO then
    begin
      if uselongblock[0] + uselongblock[1] = 0 then
        vbrpsy_compute_MS_thresholds(eb, thr, gds^.mld_cb, gfc^.ATH^.cb_s,
                                      ath_factor, cfg^.msfix, gds^.npart);
    end;
    for chn := 0 to n_chn_psy - 1 do
    begin
      ch01 := chn and 1;
      if (uselongblock[ch01] = 0) or (force_short <> 0) then
        convert_partition2scalefac_s(gfc, eb[chn], thr[chn], chn, sblock);
    end;
  end;

  { Short block pre-echo control }
  for chn := 0 to n_chn_psy - 1 do
  begin
    for sb := 0 to SBMAX_s - 1 do
    begin
      for sblock := 0 to 2 do
      begin
        thmm := psv^.thm[chn].s[sb][sblock];
        thmm *= NS_PREECHO_ATT0;
        t1 := thmm; t2 := thmm;

        if sblock > 0 then
          prev_thm := new_thmm[sblock - 1]
        else
          prev_thm := last_thm[chn].s[sb][2];

        if (ns_attacks[chn*4 + sblock] >= 2) or (ns_attacks[chn*4 + sblock + 1] = 1) then
          t1 := NS_INTERP(prev_thm, thmm, NS_PREECHO_ATT1 * pcfact);
        thmm := Min(t1, thmm);

        if ns_attacks[chn*4 + sblock] = 1 then
          t2 := NS_INTERP(prev_thm, thmm, NS_PREECHO_ATT2 * pcfact)
        else if ((sblock = 0) and (psv^.last_attacks[chn] = 3))
             or ((sblock > 0) and (ns_attacks[chn*4 + sblock - 1] = 3)) then
        begin
          case sblock of
            0: prev_thm := last_thm[chn].s[sb][1];
            1: prev_thm := last_thm[chn].s[sb][2];
            2: prev_thm := new_thmm[0];
          end;
          t2 := NS_INTERP(prev_thm, thmm, NS_PREECHO_ATT2 * pcfact);
        end;
        thmm := Min(t1, thmm);
        thmm := Min(t2, thmm);
        thmm *= sub_short_factor[chn * 3 + sblock];
        new_thmm[sblock] := thmm;
      end;
      for sblock := 0 to 2 do
        psv^.thm[chn].s[sb][sblock] := new_thmm[sblock];
    end;
  end;

  for chn := 0 to n_chn_psy - 1 do
    psv^.last_attacks[chn] := ns_attacks[chn * 4 + 2];

  { Determine final block type }
  vbrpsy_apply_block_type(psv, cfg^.channels_out, uselongblock, blocktype_d);

  { Compute PE }
  for chn := 0 to n_chn_psy - 1 do
  begin
    if chn > 1 then
    begin
      ppe := PSingle(PByte(percep_MS_entropy) - 2 * SizeOf(TFloat));
      block_type := NORM_TYPE;
      if (PIntegerArray(blocktype_d)^[0] = SHORT_TYPE) or
         (PIntegerArray(blocktype_d)^[1] = SHORT_TYPE) then
        block_type := SHORT_TYPE;
      mr := @masking_MS_ratio^[gr_out][chn - 2];
    end
    else
    begin
      ppe := percep_entropy;
      block_type := PIntegerArray(blocktype_d)^[chn];
      mr := @masking_ratio^[gr_out][chn];
    end;

    if block_type = SHORT_TYPE then
      PSingleArray(ppe)^[chn] := pecalc_s(mr^, gfc^.sv_qnt.masking_lower)
    else
      PSingleArray(ppe)^[chn] := pecalc_l(mr^, gfc^.sv_qnt.masking_lower);
  end;

  Result := 0;
end;

{ -----------------------------------------------------------------------
  Initialization helpers
  ----------------------------------------------------------------------- }

function s3_func(bark: TFloat): TFloat;
var
  tempx, x, tempy, temp: TFloat;
begin
  tempx := bark;
  if tempx >= 0 then tempx *= 3
  else               tempx *= 1.5;

  if (tempx >= 0.5) and (tempx <= 2.5) then
  begin
    temp := tempx - 0.5;
    x := 8.0 * (temp * temp - 2.0 * temp);
  end
  else
    x := 0.0;

  tempx += 0.474;
  tempy := 15.811389 + 7.5 * tempx - 17.5 * Sqrt(1.0 + tempx * tempx);

  if tempy <= -60.0 then begin Result := 0.0; Exit; end;

  tempx := Exp((x + tempy) * LN_TO_LOG10);
  tempx /= 0.6609193;
  Result := tempx;
end;

function stereo_demask(f: Double): TFloat;
var
  arg: Double;
begin
  arg := freq2bark(f);
  if arg > 15.5 then arg := 15.5;
  arg := arg / 15.5;
  Result := Power(10.0, 1.25 * (1.0 - Cos(LAME_PI * arg)) - 2.5);
end;

procedure init_numline(gd: PPsyConstCB2SBt; sfreq: TFloat;
                        fft_size, mdct_size, sbmax: Integer;
                        const scalepos: array of Integer);
var
  b_frq: array[0..CBANDS] of TFloat;
  sfreq_orig: TFloat;
  mdct_freq_frac, deltafreq: TFloat;
  partition: array[0..HBLKSIZE - 1] of Integer;
  i, j, j2, ni, nl, sfb: Integer;
  bark1: TFloat;
  i1, i2, bo: Integer;
  start, end_: Integer;
  f_tmp, bo_w: TFloat;
  freq: TFloat;
  w: Integer;
  bark2: TFloat;
begin
  sfreq_orig     := sfreq;
  mdct_freq_frac := sfreq / (2.0 * mdct_size);
  deltafreq      := fft_size / (2.0 * mdct_size);
  sfreq          /= fft_size;

  FillChar(partition, SizeOf(partition), 0);
  j  := 0;
  ni := 0;

  for i := 0 to CBANDS - 1 do
  begin
    bark1 := freq2bark(sfreq * j);
    b_frq[i] := sfreq * j;

    j2 := j;
    while (freq2bark(sfreq * j2) - bark1 < DELBARK) and (j2 <= fft_size div 2) do
      Inc(j2);

    nl := j2 - j;
    gd^.numlines[i] := nl;
    if nl > 0 then gd^.rnumlines[i] := 1.0 / nl
    else            gd^.rnumlines[i] := 0;
    ni := i + 1;

    while j < j2 do
    begin
      partition[j] := i;
      Inc(j);
    end;
    if j > fft_size div 2 then
    begin
      j := fft_size div 2;
      break;
    end;
  end;
  b_frq[ni] := sfreq * j;

  gd^.n_sb  := sbmax;
  gd^.npart := ni;

  j := 0;
  for i := 0 to gd^.npart - 1 do
  begin
    nl   := gd^.numlines[i];
    freq := sfreq * (j + nl div 2);
    gd^.mld_cb[i] := stereo_demask(freq);
    j += nl;
  end;
  for i := gd^.npart to CBANDS - 1 do
    gd^.mld_cb[i] := 1;

  for sfb := 0 to sbmax - 1 do
  begin
    start := scalepos[sfb];
    end_  := scalepos[sfb + 1];

    i1 := Trunc(0.5 + deltafreq * (start - 0.5));
    if i1 < 0 then i1 := 0;
    i2 := Trunc(0.5 + deltafreq * (end_ - 0.5));
    if i2 > fft_size div 2 then i2 := fft_size div 2;

    bo := partition[i2];
    gd^.bm[sfb] := (partition[i1] + partition[i2]) div 2;
    gd^.bo[sfb] := bo;

    f_tmp := mdct_freq_frac * end_;
    if b_frq[bo + 1] > b_frq[bo] then
      bo_w := (f_tmp - b_frq[bo]) / (b_frq[bo + 1] - b_frq[bo])
    else
      bo_w := 0;
    if bo_w < 0 then bo_w := 0;
    if bo_w > 1 then bo_w := 1;
    gd^.bo_weight[sfb] := bo_w;
    gd^.mld[sfb] := stereo_demask(mdct_freq_frac * start);
  end;
end;

procedure compute_bark_values(gd: PPsyConstCB2SBt; sfreq: TFloat;
                               fft_size: Integer;
                               bval, bval_width: PSingle);
var
  k, j, ni, w: Integer;
  bark1, bark2: TFloat;
begin
  ni   := gd^.npart;
  j    := 0;
  sfreq /= fft_size;
  for k := 0 to ni - 1 do
  begin
    w     := gd^.numlines[k];
    bark1 := freq2bark(sfreq * j);
    bark2 := freq2bark(sfreq * (j + w - 1));
    PSingleArray(bval)^[k] := 0.5 * (bark1 + bark2);

    bark1 := freq2bark(sfreq * (j - 0.5));
    bark2 := freq2bark(sfreq * (j + w - 0.5));
    PSingleArray(bval_width)^[k] := bark2 - bark1;
    j += w;
  end;
end;

function init_s3_values(pp: PPSingle; s3ind: Pointer; npart: Integer;
                         bval, bval_width, norm: PSingle): Integer;
var
  s3: array[0..CBANDS - 1, 0..CBANDS - 1] of TFloat;
  ps3ind: PS3IndArr;
  i, j, k, numberOfNoneZero: Integer;
  v: TFloat;
begin
  ps3ind := s3ind;
  FillChar(s3, SizeOf(s3), 0);
  for i := 0 to npart - 1 do
    for j := 0 to npart - 1 do
    begin
      v := s3_func(PSingleArray(bval)^[i] - PSingleArray(bval)^[j])
           * PSingleArray(bval_width)^[j];
      s3[i][j] := v * PSingleArray(norm)^[i];
    end;

  numberOfNoneZero := 0;
  for i := 0 to npart - 1 do
  begin
    j := 0;
    while (j < npart) and (s3[i][j] <= 0.0) do Inc(j);
    ps3ind^[i][0] := j;

    j := npart - 1;
    while (j > 0) and (s3[i][j] <= 0.0) do Dec(j);
    ps3ind^[i][1] := j;
    numberOfNoneZero += ps3ind^[i][1] - ps3ind^[i][0] + 1;
  end;

  GetMem(pp^, numberOfNoneZero * SizeOf(TFloat));
  if pp^ = nil then begin Result := -1; Exit; end;
  FillChar(pp^^, numberOfNoneZero * SizeOf(TFloat), 0);

  k := 0;
  for i := 0 to npart - 1 do
    for j := ps3ind^[i][0] to ps3ind^[i][1] do
    begin
      PSingleArray(pp^)^[k] := s3[i][j];
      Inc(k);
    end;

  Result := 0;
end;

function psymodel_init(gfp: PLameGlobalFlags): Integer;
var
  gfc: PLameInternalFlags;
  cfg: ^TSessionConfig_t;
  psv: ^TPsyStateVar_t;
  gd: PPsyConst_t;
  i, j, b, sb, k: Integer;
  bvl_a, bvl_b: TFloat;
  snr_l_a, snr_l_b, snr_s_a, snr_s_b: TFloat;
  bval: array[0..CBANDS - 1] of TFloat;
  bval_width: array[0..CBANDS - 1] of TFloat;
  norm: array[0..CBANDS - 1] of TFloat;
  sfreq, xav, xbv, minval_low: TFloat;
  snr: Double;
  x: Double;
  level: TFloat;
  freq, freq_inc, eql_balance: TFloat;
  msfix, sk_s, sk_l, m: TFloat;
  sk: array[0..10] of TFloat;
begin
  gfc := gfp^.internal_flags;
  cfg := @gfc^.cfg;
  psv := @gfc^.sv_psy;

  if gfc^.cd_psy <> nil then begin Result := 0; Exit; end;

  sfreq := cfg^.samplerate_out;

  bvl_a := 13; bvl_b := 24;
  snr_l_a := 0; snr_l_b := 0;
  snr_s_a := -8.25; snr_s_b := -4.5;
  xav := 10; xbv := 12;
  minval_low := 0.0 - cfg^.minval;

  gd := lame_calloc_psy;
  if gd = nil then begin Result := -1; Exit; end;
  gfc^.cd_psy := gd;

  gd^.force_short_block_calc := gfp^.experimentalZ;
  psv^.blocktype_old[0] := NORM_TYPE;
  psv^.blocktype_old[1] := NORM_TYPE;

  for i := 0 to 3 do
  begin
    for j := 0 to CBANDS - 1 do
    begin
      psv^.nb_l1[i][j] := 1e20;
      psv^.nb_l2[i][j] := 1e20;
      psv^.nb_s1[i][j] := 1.0;
      psv^.nb_s2[i][j] := 1.0;
    end;
    for sb := 0 to SBMAX_l - 1 do
    begin
      psv^.en[i].l[sb]  := 1e20;
      psv^.thm[i].l[sb] := 1e20;
    end;
    for j := 0 to 2 do
    begin
      for sb := 0 to SBMAX_s - 1 do
      begin
        psv^.en[i].s[sb][j]  := 1e20;
        psv^.thm[i].s[sb][j] := 1e20;
      end;
      psv^.last_attacks[i] := 0;
    end;
    for j := 0 to 8 do
      psv^.last_en_subshort[i][j] := 10.0;
  end;
  psv^.loudness_sq_save[0] := 0.0;
  psv^.loudness_sq_save[1] := 0.0;

  { Long block psychoacoustic constants }
  init_numline(@gd^.l, sfreq, BLKSIZE, 576, SBMAX_l, gfc^.scalefac_band.l);
  compute_bark_values(@gd^.l, sfreq, BLKSIZE, @bval[0], @bval_width[0]);

  FillChar(norm, SizeOf(norm), 0);
  for i := 0 to gd^.l.npart - 1 do
  begin
    snr := snr_l_a;
    if bval[i] >= bvl_a then
      snr := snr_l_b * (bval[i] - bvl_a) / (bvl_b - bvl_a)
           + snr_l_a * (bvl_b - bval[i]) / (bvl_b - bvl_a);
    norm[i] := Power(10.0, snr / 10.0);
  end;
  i := init_s3_values(@gd^.l.s3, @gd^.l.s3ind, gd^.l.npart,
                       @bval[0], @bval_width[0], @norm[0]);
  if i <> 0 then begin Result := i; Exit; end;

  j := 0;
  for i := 0 to gd^.l.npart - 1 do
  begin
    x := MaxSingle;
    for k := 0 to gd^.l.numlines[i] - 1 do
    begin
      freq := sfreq * j / (1000.0 * BLKSIZE);
      level := ATHformula(cfg^, freq * 1000) - 20;
      level := Power(10.0, 0.1 * level);
      level *= gd^.l.numlines[i];
      if x > level then x := level;
      Inc(j);
    end;
    gfc^.ATH^.cb_l[i] := x;

    x := 20.0 * (bval[i] / xav - 1.0);
    if x > 6 then x := 30;
    if x < minval_low then x := minval_low;
    if cfg^.samplerate_out < 44000 then x := 30;
    x -= 8.0;
    gd^.l.minval[i] := Power(10.0, x / 10.0) * gd^.l.numlines[i];
  end;

  { Short block psychoacoustic constants }
  init_numline(@gd^.s, sfreq, BLKSIZE_s, 192, SBMAX_s, gfc^.scalefac_band.s);
  compute_bark_values(@gd^.s, sfreq, BLKSIZE_s, @bval[0], @bval_width[0]);

  j := 0;
  for i := 0 to gd^.s.npart - 1 do
  begin
    snr := snr_s_a;
    if bval[i] >= bvl_a then
      snr := snr_s_b * (bval[i] - bvl_a) / (bvl_b - bvl_a)
           + snr_s_a * (bvl_b - bval[i]) / (bvl_b - bvl_a);
    norm[i] := Power(10.0, snr / 10.0);

    x := MaxSingle;
    for k := 0 to gd^.s.numlines[i] - 1 do
    begin
      freq := sfreq * j / (1000.0 * BLKSIZE_s);
      level := ATHformula(cfg^, freq * 1000) - 20;
      level := Power(10.0, 0.1 * level);
      level *= gd^.s.numlines[i];
      if x > level then x := level;
      Inc(j);
    end;
    gfc^.ATH^.cb_s[i] := x;

    x := 7.0 * (bval[i] / xbv - 1.0);
    if bval[i] > xbv then x *= 1.0 + Ln(1.0 + x) * 3.1;
    if bval[i] < xbv then x *= 1.0 + Ln(1.0 - x) * 2.3;
    if x > 6 then x := 30;
    if x < minval_low then x := minval_low;
    if cfg^.samplerate_out < 44000 then x := 30;
    x -= 8.0;
    gd^.s.minval[i] := Power(10.0, x / 10.0) * gd^.s.numlines[i];
  end;
  i := init_s3_values(@gd^.s.s3, @gd^.s.s3ind, gd^.s.npart,
                       @bval[0], @bval_width[0], @norm[0]);
  if i <> 0 then begin Result := i; Exit; end;

  init_fft(gfc);

  gd^.decay := Exp(-1.0 * LAME_LOG10 / (temporalmask_sustain * sfreq / 192.0));

  msfix := NS_MSFIX;
  if cfg^.use_safe_joint_stereo <> 0 then msfix := 1.0;
  if Abs(cfg^.msfix) > 0.0 then msfix := cfg^.msfix;
  cfg^.msfix := msfix;

  for b := 0 to gd^.l.npart - 1 do
    if gd^.l.s3ind[b][1] > gd^.l.npart - 1 then
      gd^.l.s3ind[b][1] := gd^.l.npart - 1;

  { ATH auto-adjustment setup }
  gfc^.ATH^.decay        := Power(10.0, -12.0 / 10.0 * (576.0 * cfg^.mode_gr / sfreq));
  gfc^.ATH^.adjust_factor := 0.01;
  gfc^.ATH^.adjust_limit  := 1.0;

  if cfg^.ATHtype <> -1 then
  begin
    freq_inc    := cfg^.samplerate_out / BLKSIZE;
    eql_balance := 0.0;
    freq        := 0.0;
    for i := 0 to BLKSIZE div 2 - 1 do
    begin
      freq += freq_inc;
      gfc^.ATH^.eql_w[i] := 1.0 / Power(10.0, ATHformula(cfg^, freq) / 10.0);
      eql_balance += gfc^.ATH^.eql_w[i];
    end;
    eql_balance := 1.0 / eql_balance;
    for i := BLKSIZE div 2 - 1 downto 0 do
      gfc^.ATH^.eql_w[i] *= eql_balance;
  end;

  { Attack thresholds }
  begin
    x := gfp^.attackthre;
    level := gfp^.attackthre_s;
    if x < 0 then x := NSATTACKTHRE;
    if level < 0 then level := NSATTACKTHRE_S;
    gd^.attack_threshold[0] := x;
    gd^.attack_threshold[1] := x;
    gd^.attack_threshold[2] := x;
    gd^.attack_threshold[3] := level;
  end;

  { masking_lower per partition band }
  begin
    sk[0]  := -7.4; sk[1]  := -7.4; sk[2]  := -7.4; sk[3]  := -9.5;
    sk[4]  := -7.4; sk[5]  := -6.1; sk[6]  := -5.5; sk[7]  := -4.7;
    sk[8]  := -4.7; sk[9]  := -4.7; sk[10] := -4.7;
    sk_s := -10.0; sk_l := -4.7;
    if gfp^.VBR_q < 4 then
    begin
      sk_l := sk[0];
      sk_s := sk[0];
    end
    else
    begin
      sk_l := sk[gfp^.VBR_q] + gfp^.VBR_q_frac * (sk[gfp^.VBR_q] - sk[gfp^.VBR_q + 1]);
      sk_s := sk_l;
    end;

    b := 0;
    while b < gd^.s.npart do
    begin
      m := (gd^.s.npart - b) / gd^.s.npart;
      gd^.s.masking_lower[b] := Power(10.0, sk_s * m * 0.1);
      Inc(b);
    end;
    while b < CBANDS do
    begin
      gd^.s.masking_lower[b] := 1.0;
      Inc(b);
    end;

    b := 0;
    while b < gd^.l.npart do
    begin
      m := (gd^.l.npart - b) / gd^.l.npart;
      gd^.l.masking_lower[b] := Power(10.0, sk_l * m * 0.1);
      Inc(b);
    end;
    while b < CBANDS do
    begin
      gd^.l.masking_lower[b] := 1.0;
      Inc(b);
    end;
  end;

  Move(gd^.l, gd^.l_to_s, SizeOf(gd^.l));
  gd^.l_to_s.s3 := nil;  { shared with l.s3 - prevent double-free }
  init_numline(@gd^.l_to_s, sfreq, BLKSIZE, 192, SBMAX_s, gfc^.scalefac_band.s);

  Result := 0;
end;

end.
