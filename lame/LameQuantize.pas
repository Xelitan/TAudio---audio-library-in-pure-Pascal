{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameQuantize;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Quantization outer loop, CBR/ABR/VBR iteration loops
//  Translated from quantize.c


interface

uses LameTypes, LameTables, LameUtils, Math, SysUtils;

{ Initialise the init_xrpow_core function pointer (plain C version) }
procedure init_xrpow_core_init(gfc: PLameInternalFlags);

{ CBR (constant bitrate) iteration loop - encode one full frame }
procedure CBR_iteration_loop(gfc: PLameInternalFlags;
                              pe: PPeArray;
                              ms_ener_ratio: PSingle;
                              ratio: PIIIPsyRatio2x2);

{ ABR (average bitrate) iteration loop }
procedure ABR_iteration_loop(gfc: PLameInternalFlags;
                              pe: PPeArray;
                              ms_ener_ratio: PSingle;
                              ratio: PIIIPsyRatio2x2);

{ VBR "old" iteration loop }
procedure VBR_old_iteration_loop(gfc: PLameInternalFlags;
                                  pe: PPeArray;
                                  ms_ener_ratio: PSingle;
                                  ratio: PIIIPsyRatio2x2);

implementation

{$POINTERMATH ON}

uses LameQuantizePvt, LameTakehiro, LameReservoir, LameBitstream;

procedure calc_target_bits_abr(gfc: PLameInternalFlags;
                                pe: PPeArray;
                                ms_ener_ratio: PSingle;
                                targ_bits: Pointer;
                                out analog_silence_bits: Integer;
                                out max_frame_bits: Integer); forward;

{ -----------------------------------------------------------------------
  Tables referenced from quantize_pvt  (also var-exported there)
----------------------------------------------------------------------- }

{ -----------------------------------------------------------------------
  init_xrpow_core_c  - plain C fallback
----------------------------------------------------------------------- }
procedure init_xrpow_core_c(var cod_info: TGrInfo; xrpow: PSingle;
                             upper: Integer; var sum: TFloat);
var
  i:   Integer;
  tmp: TFloat;
begin
  sum := 0.0;
  for i := 0 to upper do
  begin
    tmp := Abs(cod_info.xr[i]);
    sum := sum + tmp;
    xrpow[i] := Sqrt(tmp * Sqrt(tmp));
    if xrpow[i] > cod_info.xrpow_max then
      cod_info.xrpow_max := xrpow[i];
  end;
end;

procedure init_xrpow_core_init(gfc: PLameInternalFlags);
begin
  gfc^.init_xrpow_core := @init_xrpow_core_c;
end;

{ -----------------------------------------------------------------------
  init_xrpow  - prepare xrpow array for outer_loop; return 1 if non-silent
----------------------------------------------------------------------- }
function init_xrpow(gfc: PLameInternalFlags; cod_info: PGrInfo;
                    xrpow: PSingle): Integer;
var
  sum:   TFloat;
  upper: Integer;
  i, j:  Integer;
begin
  upper := cod_info^.max_nonzero_coeff;
  cod_info^.xrpow_max := 0.0;

  { zero out the tail }
  FillChar((xrpow + upper)^, (576 - upper) * SizeOf(TFloat), 0);

  gfc^.init_xrpow_core(cod_info^, xrpow, upper, sum);

  if sum > 1E-20 then
  begin
    j := 0;
    if (gfc^.sv_qnt.substep_shaping and 2) <> 0 then j := 1;
    for i := 0 to cod_info^.psymax - 1 do
      gfc^.sv_qnt.pseudohalf[i] := j;
    Result := 1;
  end
  else
  begin
    FillChar(cod_info^.l3_enc[0], 576 * SizeOf(Integer), 0);
    Result := 0;
  end;
end;

{ -----------------------------------------------------------------------
  psfb21_analogsilence  - silence detection in partitioned sfb 21/12
----------------------------------------------------------------------- }
procedure psfb21_analogsilence(gfc: PLameInternalFlags; cod_info: PGrInfo);
var
  ATHp:   PATHt;
  j, gsfb, start, stop_flag, block: Integer;
  start_idx, end_idx: Integer;
  ath21, ath12: TFloat;
begin
  ATHp := gfc^.ATH;

  if cod_info^.block_type <> SHORT_TYPE then
  begin
    { long / start / stop type }
    stop_flag := 0;
    gsfb := PSFB21 - 1;
    while (gsfb >= 0) and (stop_flag = 0) do
    begin
      start_idx := gfc^.scalefac_band.psfb21[gsfb];
      end_idx   := gfc^.scalefac_band.psfb21[gsfb + 1];
      ath21 := athAdjust(ATHp^.adjust_factor, ATHp^.psfb21[gsfb], ATHp^.floor, 0);
      if gfc^.sv_qnt.longfact[21] > 1e-12 then
        ath21 := ath21 * gfc^.sv_qnt.longfact[21];
      j := end_idx - 1;
      while j >= start_idx do
      begin
        if Abs(cod_info^.xr[j]) < ath21 then
          cod_info^.xr[j] := 0.0
        else
        begin
          stop_flag := 1;
          Break;
        end;
        Dec(j);
      end;
      Dec(gsfb);
    end;
  end
  else
  begin
    { short blocks - coefficients are already reordered }
    for block := 0 to 2 do
    begin
      stop_flag := 0;
      gsfb := PSFB12 - 1;
      while (gsfb >= 0) and (stop_flag = 0) do
      begin
        start_idx := gfc^.scalefac_band.s[12] * 3 +
          (gfc^.scalefac_band.s[13] - gfc^.scalefac_band.s[12]) * block +
          (gfc^.scalefac_band.psfb12[gsfb] - gfc^.scalefac_band.psfb12[0]);
        end_idx := start_idx +
          (gfc^.scalefac_band.psfb12[gsfb + 1] - gfc^.scalefac_band.psfb12[gsfb]);
        ath12 := athAdjust(ATHp^.adjust_factor, ATHp^.psfb12[gsfb], ATHp^.floor, 0);
        if gfc^.sv_qnt.shortfact[12] > 1e-12 then
          ath12 := ath12 * gfc^.sv_qnt.shortfact[12];
        j := end_idx - 1;
        while j >= start_idx do
        begin
          if Abs(cod_info^.xr[j]) < ath12 then
            cod_info^.xr[j] := 0.0
          else
          begin
            stop_flag := 1;
            Break;
          end;
          Dec(j);
        end;
        Dec(gsfb);
      end;
    end;
  end;
end;

{ -----------------------------------------------------------------------
  init_outer_loop  - initialise cod_info and scalefacs for one granule
----------------------------------------------------------------------- }
procedure init_outer_loop(gfc: PLameInternalFlags; cod_info: PGrInfo);
var
  cfg:    PSessionConfig_t;
  sfb, j: Integer;
  ix:     PSingle;
  ixwork: array[0..575] of TFloat;
  window, l: Integer;
  start_s, end_s: Integer;
begin
  cfg := @gfc^.cfg;

  cod_info^.part2_3_length    := 0;
  cod_info^.big_values        := 0;
  cod_info^.count1            := 0;
  cod_info^.global_gain       := 210;
  cod_info^.scalefac_compress := 0;
  cod_info^.table_select[0]   := 0;
  cod_info^.table_select[1]   := 0;
  cod_info^.table_select[2]   := 0;
  cod_info^.subblock_gain[0]  := 0;
  cod_info^.subblock_gain[1]  := 0;
  cod_info^.subblock_gain[2]  := 0;
  cod_info^.subblock_gain[3]  := 0;
  cod_info^.region0_count     := 0;
  cod_info^.region1_count     := 0;
  cod_info^.preflag            := 0;
  cod_info^.scalefac_scale    := 0;
  cod_info^.count1table_select := 0;
  cod_info^.part2_length      := 0;

  if cfg^.samplerate_out <= 8000 then
  begin
    cod_info^.sfb_lmax := 17;
    cod_info^.sfb_smin := 9;
    cod_info^.psy_lmax := 17;
  end
  else
  begin
    cod_info^.sfb_lmax := SBPSY_l;
    cod_info^.sfb_smin := SBPSY_s;
    if gfc^.sv_qnt.sfb21_extra <> 0 then
      cod_info^.psy_lmax := SBMAX_l
    else
      cod_info^.psy_lmax := SBPSY_l;
  end;

  cod_info^.psymax    := cod_info^.psy_lmax;
  cod_info^.sfbmax    := cod_info^.sfb_lmax;
  cod_info^.sfbdivide := 11;

  for sfb := 0 to SBMAX_l - 1 do
  begin
    cod_info^.width[sfb]  := gfc^.scalefac_band.l[sfb + 1] - gfc^.scalefac_band.l[sfb];
    cod_info^.window[sfb] := 3;
  end;

  if cod_info^.block_type = SHORT_TYPE then
  begin
    cod_info^.sfb_smin := 0;
    cod_info^.sfb_lmax := 0;
    if cod_info^.mixed_block_flag <> 0 then
    begin
      cod_info^.sfb_smin := 3;
      cod_info^.sfb_lmax := cfg^.mode_gr * 2 + 4;
    end;

    if cfg^.samplerate_out <= 8000 then
    begin
      cod_info^.psymax := cod_info^.sfb_lmax + 3 * (9 - cod_info^.sfb_smin);
      cod_info^.sfbmax := cod_info^.sfb_lmax + 3 * (9 - cod_info^.sfb_smin);
    end
    else
    begin
      if gfc^.sv_qnt.sfb21_extra <> 0 then
        cod_info^.psymax := cod_info^.sfb_lmax + 3 * (SBMAX_s - cod_info^.sfb_smin)
      else
        cod_info^.psymax := cod_info^.sfb_lmax + 3 * (SBPSY_s - cod_info^.sfb_smin);
      cod_info^.sfbmax := cod_info^.sfb_lmax + 3 * (SBPSY_s - cod_info^.sfb_smin);
    end;
    cod_info^.sfbdivide := cod_info^.sfbmax - 18;
    cod_info^.psy_lmax  := cod_info^.sfb_lmax;

    { reorder short block coefficients (Takehiro Tominaga's method) }
    ix := @cod_info^.xr[gfc^.scalefac_band.l[cod_info^.sfb_lmax]];
    Move(cod_info^.xr[0], ixwork[0], 576 * SizeOf(TFloat));
    for sfb := cod_info^.sfb_smin to SBMAX_s - 1 do
    begin
      start_s := gfc^.scalefac_band.s[sfb];
      end_s   := gfc^.scalefac_band.s[sfb + 1];
      for window := 0 to 2 do
        for l := start_s to end_s - 1 do
        begin
          ix^ := ixwork[3 * l + window];
          Inc(ix);
        end;
    end;

    j := cod_info^.sfb_lmax;
    for sfb := cod_info^.sfb_smin to SBMAX_s - 1 do
    begin
      cod_info^.width[j] :=
        gfc^.scalefac_band.s[sfb + 1] - gfc^.scalefac_band.s[sfb];
      cod_info^.width[j + 1] := cod_info^.width[j];
      cod_info^.width[j + 2] := cod_info^.width[j];
      cod_info^.window[j]     := 0;
      cod_info^.window[j + 1] := 1;
      cod_info^.window[j + 2] := 2;
      Inc(j, 3);
    end;
  end;

  cod_info^.count1bits          := 0;
  cod_info^.sfb_partition_table := @nr_of_sfb_block[0][0][0];
  cod_info^.slen[0]             := 0;
  cod_info^.slen[1]             := 0;
  cod_info^.slen[2]             := 0;
  cod_info^.slen[3]             := 0;
  cod_info^.max_nonzero_coeff   := 575;

  FillChar(cod_info^.scalefac[0], SFBMAX * SizeOf(Integer), 0);

  { analog silence detection (not for VBR variants) }
  if (cfg^.vbr <> vbr_mt) and (cfg^.vbr <> vbr_mtrh) and
     (cfg^.vbr <> vbr_abr) and (cfg^.vbr <> vbr_off) then
    psfb21_analogsilence(gfc, cod_info);
end;

{ -----------------------------------------------------------------------
  ms_convert  - convert L/R stereo to Mid/Side for one granule
----------------------------------------------------------------------- }
procedure ms_convert(l3_side: PIIISideInfo; gr: Integer);
var
  i:    Integer;
  l, r: TFloat;
const
  SQRT2_HALF = LAME_SQRT2 * 0.5;
begin
  for i := 0 to 575 do
  begin
    l := l3_side^.tt[gr][0].xr[i];
    r := l3_side^.tt[gr][1].xr[i];
    l3_side^.tt[gr][0].xr[i] := (l + r) * SQRT2_HALF;
    l3_side^.tt[gr][1].xr[i] := (l - r) * SQRT2_HALF;
  end;
end;

{ -----------------------------------------------------------------------
  bin_search_StepSize
----------------------------------------------------------------------- }
type
  TBinsearchDir = (bsNone, bsUp, bsDown);

function bin_search_StepSize(gfc: PLameInternalFlags; cod_info: PGrInfo;
                              desired_rate, ch: Integer;
                              xrpow: PSingle): Integer;
var
  nBits:       Integer;
  CurrentStep: Integer;
  flag_GoneOver: Integer;
  Direction:   TBinsearchDir;
  start_gain:  Integer;
  step:        Integer;
begin
  CurrentStep  := gfc^.sv_qnt.CurrentStep[ch];
  flag_GoneOver := 0;
  start_gain   := gfc^.sv_qnt.OldValue[ch];
  Direction    := bsNone;

  cod_info^.global_gain := start_gain;
  Dec(desired_rate, cod_info^.part2_length);

  repeat
    nBits := count_bits(gfc, @xrpow[0], cod_info, nil);
    if (CurrentStep = 1) or (nBits = desired_rate) then Break;

    if nBits > desired_rate then
    begin
      if Direction = bsDown then flag_GoneOver := 1;
      if flag_GoneOver <> 0 then CurrentStep := CurrentStep div 2;
      Direction := bsUp;
      step := CurrentStep;
    end
    else
    begin
      if Direction = bsUp then flag_GoneOver := 1;
      if flag_GoneOver <> 0 then CurrentStep := CurrentStep div 2;
      Direction := bsDown;
      step := -CurrentStep;
    end;

    Inc(cod_info^.global_gain, step);
    if cod_info^.global_gain < 0   then begin cod_info^.global_gain := 0;   flag_GoneOver := 1; end;
    if cod_info^.global_gain > 255 then begin cod_info^.global_gain := 255; flag_GoneOver := 1; end;
  until False;

  while (nBits > desired_rate) and (cod_info^.global_gain < 255) do
  begin
    Inc(cod_info^.global_gain);
    nBits := count_bits(gfc, @xrpow[0], cod_info, nil);
  end;

  if (start_gain - cod_info^.global_gain) >= 4 then
    gfc^.sv_qnt.CurrentStep[ch] := 4
  else
    gfc^.sv_qnt.CurrentStep[ch] := 2;
  gfc^.sv_qnt.OldValue[ch]  := cod_info^.global_gain;
  cod_info^.part2_3_length  := nBits;
  Result := nBits;
end;

{ -----------------------------------------------------------------------
  loop_break  - returns 1 if ALL scalefac bands are already amplified
----------------------------------------------------------------------- }
function loop_break(const cod_info: TGrInfo): Integer;
var sfb: Integer;
begin
  for sfb := 0 to cod_info.sfbmax - 1 do
    if cod_info.scalefac[sfb] +
       cod_info.subblock_gain[cod_info.window[sfb]] = 0 then
    begin
      Result := 0;
      Exit;
    end;
  Result := 1;
end;

{ -----------------------------------------------------------------------
  get_klemm_noise helper
----------------------------------------------------------------------- }
function penalties(noise: Double): Double;
begin
  Result := log10(0.368 + 0.632 * noise * noise * noise);
end;

function get_klemm_noise(distort: PSingle; const gi: TGrInfo): Double;
var
  sfb: Integer;
  klemm_noise: Double;
begin
  klemm_noise := 1E-37;
  for sfb := 0 to gi.psymax - 1 do
    klemm_noise := klemm_noise + penalties(distort[sfb]);
  if klemm_noise < 1e-20 then klemm_noise := 1e-20;
  Result := klemm_noise;
end;

{ -----------------------------------------------------------------------
  quant_compare  - pick best quantization according to quant_comp mode
----------------------------------------------------------------------- }
function quant_compare(quant_comp: Integer;
                       const best: TCalcNoiseResult;
                       var calc: TCalcNoiseResult;
                       const gi: TGrInfo;
                       distort: PSingle): Integer;
var
  better: Integer;
begin
  better := 0;
  case quant_comp of
    0:
      better := Ord(
        (calc.over_count < best.over_count) or
        ((calc.over_count = best.over_count) and (calc.over_noise < best.over_noise)) or
        ((calc.over_count = best.over_count) and (calc.over_noise = best.over_noise) and
         (calc.tot_noise < best.tot_noise)));
    8:
      begin
        calc.max_noise := get_klemm_noise(distort, gi);
        { fall through to case 1 }
        better := Ord(calc.max_noise < best.max_noise);
      end;
    1:
      better := Ord(calc.max_noise < best.max_noise);
    2:
      better := Ord(calc.tot_noise < best.tot_noise);
    3:
      better := Ord((calc.tot_noise < best.tot_noise) and (calc.max_noise < best.max_noise));
    4:
      better := Ord(
        ((calc.max_noise <= 0.0) and (best.max_noise > 0.2)) or
        ((calc.max_noise <= 0.0) and (best.max_noise < 0.0) and
         (best.max_noise > calc.max_noise - 0.2) and (calc.tot_noise < best.tot_noise)) or
        ((calc.max_noise <= 0.0) and (best.max_noise > 0.0) and
         (best.max_noise > calc.max_noise - 0.2) and
         (calc.tot_noise < best.tot_noise + best.over_noise)) or
        ((calc.max_noise > 0.0) and (best.max_noise > -0.05) and
         (best.max_noise > calc.max_noise - 0.1) and
         (calc.tot_noise + calc.over_noise < best.tot_noise + best.over_noise)) or
        ((calc.max_noise > 0.0) and (best.max_noise > -0.1) and
         (best.max_noise > calc.max_noise - 0.15) and
         (calc.tot_noise + calc.over_noise + calc.over_noise <
          best.tot_noise + best.over_noise + best.over_noise)));
    5:
      better := Ord((calc.over_noise < best.over_noise) or
        ((calc.over_noise = best.over_noise) and (calc.tot_noise < best.tot_noise)));
    6:
      better := Ord((calc.over_noise < best.over_noise) or
        ((calc.over_noise = best.over_noise) and
         ((calc.max_noise < best.max_noise) or
          ((calc.max_noise = best.max_noise) and (calc.tot_noise <= best.tot_noise)))));
    7:
      better := Ord((calc.over_count < best.over_count) or (calc.over_noise < best.over_noise));
  else
    { case 9 (default) }
    if best.over_count > 0 then
    begin
      better := Ord(calc.over_SSD <= best.over_SSD);
      if calc.over_SSD = best.over_SSD then
        better := Ord(calc.bits < best.bits);
    end
    else
    begin
      better := Ord((calc.max_noise < 0) and
        ((calc.max_noise * 10 + calc.bits) <= (best.max_noise * 10 + best.bits)));
    end;
  end;

  if best.over_count = 0 then
    better := better and Ord(calc.bits < best.bits);

  Result := better;
end;

{ -----------------------------------------------------------------------
  amp_scalefac_bands  - amplify distorted scalefactor bands
----------------------------------------------------------------------- }
procedure amp_scalefac_bands(gfc: PLameInternalFlags; cod_info: PGrInfo;
                              distort: PSingle; xrpow: PSingle; bRefine: Integer);
const
  IFQSTEP34_HALF: TFloat = 1.29683955465100964055;   { 2^(0.75*0.5) }
  IFQSTEP34_FULL: TFloat = 1.68179283050742922612;   { 2^(0.75*1)   }
var
  cfg:              PSessionConfig_t;
  j, sfb, l, width: Integer;
  ifqstep34, trigger: TFloat;
  noise_shaping_amp: Integer;
begin
  cfg := @gfc^.cfg;

  if cod_info^.scalefac_scale = 0 then
    ifqstep34 := IFQSTEP34_HALF
  else
    ifqstep34 := IFQSTEP34_FULL;

  { find the max distortion }
  trigger := 0.0;
  for sfb := 0 to cod_info^.sfbmax - 1 do
    if trigger < distort[sfb] then trigger := distort[sfb];

  noise_shaping_amp := cfg^.noise_shaping_amp;
  if noise_shaping_amp = 3 then
  begin
    if bRefine = 1 then noise_shaping_amp := 2
    else noise_shaping_amp := 1;
  end;

  case noise_shaping_amp of
    2: { amplify exactly 1 band } ;
    1:
      begin
        if trigger > 1.0 then trigger := Sqrt(trigger)
        else trigger := trigger * 0.95;
      end;
  else
    { 0 - ISO: amplify all with distort > 1 }
    if trigger > 1.0 then trigger := 1.0
    else trigger := trigger * 0.95;
  end;

  j := 0;
  for sfb := 0 to cod_info^.sfbmax - 1 do
  begin
    width := cod_info^.width[sfb];
    Inc(j, width);
    if distort[sfb] < trigger then Continue;

    if (gfc^.sv_qnt.substep_shaping and 2) <> 0 then
    begin
      gfc^.sv_qnt.pseudohalf[sfb] := gfc^.sv_qnt.pseudohalf[sfb] xor 1;
      if (gfc^.sv_qnt.pseudohalf[sfb] = 0) and (cfg^.noise_shaping_amp = 2) then
        Exit;
    end;

    Inc(cod_info^.scalefac[sfb]);
    for l := -width to -1 do
    begin
      xrpow[j + l] := xrpow[j + l] * ifqstep34;
      if xrpow[j + l] > cod_info^.xrpow_max then
        cod_info^.xrpow_max := xrpow[j + l];
    end;

    if cfg^.noise_shaping_amp = 2 then Exit;
  end;
end;

{ -----------------------------------------------------------------------
  inc_scalefac_scale  - enable scalefac_scale=1, halving all scalefacs
----------------------------------------------------------------------- }
procedure inc_scalefac_scale(cod_info: PGrInfo; xrpow: PSingle);
const
  IFQSTEP34: TFloat = 1.29683955465100964055;
var
  l, j, sfb, s, width: Integer;
begin
  j := 0;
  for sfb := 0 to cod_info^.sfbmax - 1 do
  begin
    width := cod_info^.width[sfb];
    s     := cod_info^.scalefac[sfb];
    if cod_info^.preflag <> 0 then
      Inc(s, pretab[sfb]);
    Inc(j, width);
    if (s and 1) <> 0 then
    begin
      Inc(s);
      for l := -width to -1 do
      begin
        xrpow[j + l] := xrpow[j + l] * IFQSTEP34;
        if xrpow[j + l] > cod_info^.xrpow_max then
          cod_info^.xrpow_max := xrpow[j + l];
      end;
    end;
    cod_info^.scalefac[sfb] := s shr 1;
  end;
  cod_info^.preflag        := 0;
  cod_info^.scalefac_scale := 1;
end;

{ -----------------------------------------------------------------------
  inc_subblock_gain  - increase subblock gain and adjust short-block scalefacs
  returns 1 if no adjustment possible (already at max)
----------------------------------------------------------------------- }
function inc_subblock_gain(gfc: PLameInternalFlags; cod_info: PGrInfo;
                            xrpow: PSingle): Integer;
var
  sfb, window, s1, s2, l, j: Integer;
  s:    Integer;
  amp:  TFloat;
  gain: Integer;
  width: Integer;
begin
  { long-block region cannot use subblock_gain }
  for sfb := 0 to cod_info^.sfb_lmax - 1 do
    if cod_info^.scalefac[sfb] >= 16 then
    begin
      Result := 1; Exit;
    end;

  for window := 0 to 2 do
  begin
    s1 := 0; s2 := 0;
    sfb := cod_info^.sfb_lmax + window;
    while sfb < cod_info^.sfbdivide do
    begin
      if s1 < cod_info^.scalefac[sfb] then s1 := cod_info^.scalefac[sfb];
      Inc(sfb, 3);
    end;
    while sfb < cod_info^.sfbmax do
    begin
      if s2 < cod_info^.scalefac[sfb] then s2 := cod_info^.scalefac[sfb];
      Inc(sfb, 3);
    end;

    if (s1 < 16) and (s2 < 8) then Continue;
    if cod_info^.subblock_gain[window] >= 7 then
    begin
      Result := 1; Exit;
    end;

    Inc(cod_info^.subblock_gain[window]);
    j := gfc^.scalefac_band.l[cod_info^.sfb_lmax];
    sfb := cod_info^.sfb_lmax + window;
    while sfb < cod_info^.sfbmax do
    begin
      width := cod_info^.width[sfb];
      s     := cod_info^.scalefac[sfb];
      s     := s - (4 shr cod_info^.scalefac_scale);
      if s >= 0 then
      begin
        cod_info^.scalefac[sfb] := s;
        Inc(j, width * 3);
        Inc(sfb, 3);
        Continue;
      end;
      cod_info^.scalefac[sfb] := 0;
      gain := 210 + (s shl (cod_info^.scalefac_scale + 1));
      amp  := ipow20[gain];
      Inc(j, width * (window + 1));
      for l := -width to -1 do
      begin
        xrpow[j + l] := xrpow[j + l] * amp;
        if xrpow[j + l] > cod_info^.xrpow_max then
          cod_info^.xrpow_max := xrpow[j + l];
      end;
      Inc(j, width * (3 - window - 1));
      Inc(sfb, 3);
    end;
    { handle sfb12 extra }
    amp := ipow20[202];
    width := cod_info^.width[sfb];
    Inc(j, width * (window + 1));
    for l := -width to -1 do
    begin
      xrpow[j + l] := xrpow[j + l] * amp;
      if xrpow[j + l] > cod_info^.xrpow_max then
        cod_info^.xrpow_max := xrpow[j + l];
    end;
  end;
  Result := 0;
end;

{ -----------------------------------------------------------------------
  balance_noise  - main noise-shaping dispatcher
----------------------------------------------------------------------- }
function balance_noise(gfc: PLameInternalFlags; cod_info: PGrInfo;
                       distort: PSingle; xrpow: PSingle; bRefine: Integer): Integer;
var
  cfg:    PSessionConfig_t;
  status: Integer;
begin
  cfg := @gfc^.cfg;

  amp_scalefac_bands(gfc, cod_info, distort, xrpow, bRefine);

  status := loop_break(cod_info^);
  if status <> 0 then begin Result := 0; Exit; end;  { all bands already max }

  status := scale_bitcount(gfc, cod_info);
  if status = 0 then begin Result := 1; Exit; end;   { within limits }

  { scalefactors too large - try scalefac_scale=1 }
  if cfg^.noise_shaping > 1 then
  begin
    FillChar(gfc^.sv_qnt.pseudohalf[0], SFBMAX * SizeOf(Integer), 0);
    if cod_info^.scalefac_scale = 0 then
    begin
      inc_scalefac_scale(cod_info, xrpow);
      status := 0;
    end
    else
    begin
      if (cod_info^.block_type = SHORT_TYPE) and (cfg^.subblock_gain > 0) then
        status := inc_subblock_gain(gfc, cod_info, xrpow) or loop_break(cod_info^);
    end;
  end;

  if status = 0 then
    status := scale_bitcount(gfc, cod_info);

  Result := Ord(status = 0);
end;

{ -----------------------------------------------------------------------
  outer_loop  - main noise-shaping outer loop for one granule/channel
----------------------------------------------------------------------- }
function outer_loop(gfc: PLameInternalFlags; cod_info: PGrInfo;
                    l3_xmin: PSingle; xrpow: PSingle;
                    ch, targ_bits: Integer): Integer;
var
  cfg:             PSessionConfig_t;
  cod_info_w:      TGrInfo;
  save_xrpow:      array[0..575] of TFloat;
  distort:         array[0..SFBMAX - 1] of TFloat;
  best_noise_info: TCalcNoiseResult;
  noise_info:      TCalcNoiseResult;
  prev_noise:      TCalcNoiseData;
  huff_bits, better, age: Integer;
  best_part2_3_length: Integer;
  bEndOfSearch, bRefine, best_ggain_pass1: Integer;
  search_limit, maxggain: Integer;
begin
  cfg := @gfc^.cfg;

  bin_search_StepSize(gfc, cod_info, targ_bits, ch, xrpow);

  if cfg^.noise_shaping = 0 then
  begin
    Result := 100;
    Exit;
  end;

  FillChar(prev_noise, SizeOf(TCalcNoiseData), 0);
  calc_noise(cod_info^, l3_xmin, @distort[0], @best_noise_info, @prev_noise);
  best_noise_info.bits := cod_info^.part2_3_length;

  cod_info_w := cod_info^;
  age        := 0;
  best_part2_3_length := 9999999;
  bEndOfSearch := 0;
  bRefine      := 0;
  best_ggain_pass1 := 0;

  Move(xrpow^, save_xrpow[0], 576 * SizeOf(TFloat));

  while bEndOfSearch = 0 do
  begin
    repeat
      if (gfc^.sv_qnt.substep_shaping and 2) <> 0 then
        search_limit := 20
      else
        search_limit := 3;

      { check sfb21 extra distortion }
      if gfc^.sv_qnt.sfb21_extra <> 0 then
      begin
        if distort[cod_info_w.sfbmax] > 1.0 then Break;
        if (cod_info_w.block_type = SHORT_TYPE) and
           ((distort[cod_info_w.sfbmax + 1] > 1.0) or
            (distort[cod_info_w.sfbmax + 2] > 1.0)) then Break;
      end;

      if balance_noise(gfc, @cod_info_w, @distort[0], xrpow, bRefine) = 0 then Break;
      if cod_info_w.scalefac_scale <> 0 then maxggain := 254 else maxggain := 255;

      huff_bits := targ_bits - cod_info_w.part2_length;
      if huff_bits <= 0 then Break;

      while True do
      begin
        cod_info_w.part2_3_length :=
          count_bits(gfc, xrpow, @cod_info_w, @prev_noise);
        if (cod_info_w.part2_3_length <= huff_bits) or
           (cod_info_w.global_gain > maxggain) then Break;
        Inc(cod_info_w.global_gain);
      end;
      if cod_info_w.global_gain > maxggain then Break;

      if best_noise_info.over_count = 0 then
      begin
        while True do
        begin
          cod_info_w.part2_3_length :=
            count_bits(gfc, xrpow, @cod_info_w, @prev_noise);
          if (cod_info_w.part2_3_length <= best_part2_3_length) or
             (cod_info_w.global_gain > maxggain) then Break;
          Inc(cod_info_w.global_gain);
        end;
        if cod_info_w.global_gain > maxggain then Break;
      end;

      calc_noise(cod_info_w, l3_xmin, @distort[0], @noise_info, @prev_noise);
      noise_info.bits := cod_info_w.part2_3_length;

      if cod_info^.block_type <> SHORT_TYPE then
        better := cfg^.quant_comp
      else
        better := cfg^.quant_comp_short;

      better := quant_compare(better, best_noise_info, noise_info, cod_info_w, @distort[0]);

      if better <> 0 then
      begin
        best_part2_3_length := cod_info^.part2_3_length;
        best_noise_info     := noise_info;
        cod_info^           := cod_info_w;
        age                 := 0;
        Move(xrpow^, save_xrpow[0], 576 * SizeOf(TFloat));
      end
      else
      begin
        if cfg^.full_outer_loop = 0 then
        begin
          Inc(age);
          if (age > search_limit) and (best_noise_info.over_count = 0) then Break;
          if (cfg^.noise_shaping_amp = 3) and (bRefine <> 0) and (age > 30) then Break;
          if (cfg^.noise_shaping_amp = 3) and (bRefine <> 0) and
             ((cod_info_w.global_gain - best_ggain_pass1) > 15) then Break;
        end;
      end;
    until (cod_info_w.global_gain + cod_info_w.scalefac_scale) >= 255;

    if cfg^.noise_shaping_amp = 3 then
    begin
      if bRefine = 0 then
      begin
        cod_info_w := cod_info^;
        Move(save_xrpow[0], xrpow^, 576 * SizeOf(TFloat));
        age              := 0;
        best_ggain_pass1 := cod_info_w.global_gain;
        bRefine          := 1;
      end
      else
        bEndOfSearch := 1;
    end
    else
      bEndOfSearch := 1;
  end;

  { for VBR: restore save_xrpow }
  if (cfg^.vbr = vbr_rh) or (cfg^.vbr = vbr_mtrh) or (cfg^.vbr = vbr_mt) then
    Move(save_xrpow[0], xrpow^, 576 * SizeOf(TFloat))
  else if (gfc^.sv_qnt.substep_shaping and 1) <> 0 then
    { truncate small spectrums - simplified: not implemented in CBR-only build }
    ;

  Result := best_noise_info.over_count;
end;

{ -----------------------------------------------------------------------
  iteration_finish_one
----------------------------------------------------------------------- }
procedure iteration_finish_one(gfc: PLameInternalFlags; gr, ch: Integer);
var
  cod_info: PGrInfo;
begin
  cod_info := @gfc^.l3_side.tt[gr][ch];
  best_scalefac_store(gfc, gr, ch, @gfc^.l3_side);
  if gfc^.cfg.use_best_huffman = 1 then
    best_huffman_divide(gfc, cod_info);
  ResvAdjust(gfc, cod_info^);
end;

{ -----------------------------------------------------------------------
  CBR_iteration_loop  (the only loop needed for vbr_off mode)
----------------------------------------------------------------------- }
procedure CBR_iteration_loop(gfc: PLameInternalFlags;
                              pe: PPeArray;
                              ms_ener_ratio: PSingle;
                              ratio: PIIIPsyRatio2x2);
var
  cfg:     PSessionConfig_t;
  l3_xmin: array[0..SFBMAX - 1] of TFloat;
  xrpow:   array[0..575] of TFloat;
  targ_bits: array[0..1] of Integer;
  mean_bits, max_bits: Integer;
  gr, ch:  Integer;
  cod_info: PGrInfo;
  adjust, masking_lower_db: TFloat;
begin
  cfg := @gfc^.cfg;

  ResvFrameBegin(gfc, mean_bits);

  for gr := 0 to cfg^.mode_gr - 1 do
  begin
    max_bits := on_pe(gfc, pe, @targ_bits, mean_bits, gr, gr);

    if gfc^.ov_enc.mode_ext = Ord(MPG_MD_MS_LR) then
    begin
      ms_convert(@gfc^.l3_side, gr);
      reduce_side(@targ_bits, ms_ener_ratio[gr], mean_bits, max_bits);
    end;

    for ch := 0 to cfg^.channels_out - 1 do
    begin
      cod_info := @gfc^.l3_side.tt[gr][ch];

      if cod_info^.block_type <> SHORT_TYPE then
        masking_lower_db := gfc^.sv_qnt.mask_adjust
      else
        masking_lower_db := gfc^.sv_qnt.mask_adjust_short;
      gfc^.sv_qnt.masking_lower := Power(10.0, masking_lower_db * 0.1);

      init_outer_loop(gfc, cod_info);
      if init_xrpow(gfc, cod_info, @xrpow[0]) <> 0 then
      begin
        calc_xmin(gfc, ratio^[gr][ch], cod_info, @l3_xmin[0]);
        outer_loop(gfc, cod_info, @l3_xmin[0], @xrpow[0], ch, targ_bits[ch]);
      end;

      iteration_finish_one(gfc, gr, ch);
    end;
  end;

  ResvFrameEnd(gfc, mean_bits);
end;

{ -----------------------------------------------------------------------
  ABR_iteration_loop  (average bitrate)
----------------------------------------------------------------------- }
procedure ABR_iteration_loop(gfc: PLameInternalFlags;
                              pe: PPeArray;
                              ms_ener_ratio: PSingle;
                              ratio: PIIIPsyRatio2x2);
var
  cfg:     PSessionConfig_t;
  l3_xmin: array[0..SFBMAX - 1] of TFloat;
  xrpow:   array[0..575] of TFloat;
  targ_bits: array[0..1, 0..1] of Integer;
  mean_bits, max_frame_bits: Integer;
  analog_silence_bits: Integer;
  ch, gr, ath_over: Integer;
  cod_info: PGrInfo;
  masking_lower_db: TFloat;
begin
  cfg := @gfc^.cfg;

  calc_target_bits_abr(gfc, pe, ms_ener_ratio, @targ_bits,
                       analog_silence_bits, max_frame_bits);

  for gr := 0 to cfg^.mode_gr - 1 do
  begin
    if gfc^.ov_enc.mode_ext = Ord(MPG_MD_MS_LR) then
      ms_convert(@gfc^.l3_side, gr);

    for ch := 0 to cfg^.channels_out - 1 do
    begin
      cod_info := @gfc^.l3_side.tt[gr][ch];

      if cod_info^.block_type <> SHORT_TYPE then
        masking_lower_db := gfc^.sv_qnt.mask_adjust
      else
        masking_lower_db := gfc^.sv_qnt.mask_adjust_short;
      gfc^.sv_qnt.masking_lower := Power(10.0, masking_lower_db * 0.1);

      init_outer_loop(gfc, cod_info);
      if init_xrpow(gfc, cod_info, @xrpow[0]) <> 0 then
      begin
        ath_over := calc_xmin(gfc, ratio^[gr][ch], cod_info, @l3_xmin[0]);
        if ath_over = 0 then
          targ_bits[gr][ch] := analog_silence_bits;
        outer_loop(gfc, cod_info, @l3_xmin[0], @xrpow[0], ch, targ_bits[gr][ch]);
      end;
      iteration_finish_one(gfc, gr, ch);
    end;
  end;

  { find bitrate that can refill the reservoir }
  mean_bits := 0;
  while gfc^.ov_enc.bitrate_index <= cfg^.vbr_max_bitrate_index do
  begin
    if ResvFrameBegin(gfc, mean_bits) >= 0 then Break;
    Inc(gfc^.ov_enc.bitrate_index);
  end;

  ResvFrameEnd(gfc, mean_bits);
end;

{ -----------------------------------------------------------------------
  calc_target_bits_abr  - internal helper for ABR
----------------------------------------------------------------------- }
procedure calc_target_bits_abr(gfc: PLameInternalFlags;
                                pe: PPeArray;
                                ms_ener_ratio: PSingle;
                                targ_bits: Pointer;
                                out analog_silence_bits: Integer;
                                out max_frame_bits: Integer);
var
  cfg:     PSessionConfig_t;
  eov:     PEncResult_t;
  res_factor: TFloat;
  gr, ch, totbits, mean_bits: Integer;
  add_bits, sum: Integer;
  framesize: Integer;
  tb: PInteger;
begin
  cfg := @gfc^.cfg;
  eov := @gfc^.ov_enc;

  eov^.bitrate_index := cfg^.vbr_max_bitrate_index;
  max_frame_bits := ResvFrameBegin(gfc, mean_bits);

  eov^.bitrate_index := 1;
  mean_bits := getframebits(gfc) - cfg^.sideinfo_len * 8;
  analog_silence_bits := mean_bits div (cfg^.mode_gr * cfg^.channels_out);

  framesize := 576 * cfg^.mode_gr;
  mean_bits := cfg^.vbr_avg_bitrate_kbps * framesize * 1000;
  if (gfc^.sv_qnt.substep_shaping and 1) <> 0 then
    mean_bits := Round(mean_bits * 1.09);
  mean_bits := mean_bits div cfg^.samplerate_out;
  Dec(mean_bits, cfg^.sideinfo_len * 8);
  mean_bits := mean_bits div (cfg^.mode_gr * cfg^.channels_out);

  res_factor := 0.93 + 0.07 * (11.0 - cfg^.compression_ratio) / (11.0 - 5.5);
  if res_factor < 0.90 then res_factor := 0.90;
  if res_factor > 1.00 then res_factor := 1.00;

  totbits := 0;
  tb := PInteger(targ_bits);
  for gr := 0 to cfg^.mode_gr - 1 do
  begin
    sum := 0;
    for ch := 0 to cfg^.channels_out - 1 do
    begin
      tb^ := Round(res_factor * mean_bits);
      if pe^[gr][ch] > 700 then
      begin
        add_bits := Round((pe^[gr][ch] - 700) / 1.4);
        if gfc^.l3_side.tt[gr][ch].block_type = SHORT_TYPE then
          if add_bits < mean_bits div 2 then add_bits := mean_bits div 2;
        if add_bits > mean_bits * 3 div 2 then add_bits := mean_bits * 3 div 2;
        if add_bits < 0 then add_bits := 0;
        Inc(tb^, add_bits);
      end;
      if tb^ > MAX_BITS_PER_CHANNEL then tb^ := MAX_BITS_PER_CHANNEL;
      Inc(sum, tb^);
      Inc(tb);
    end;
    Dec(tb, cfg^.channels_out);
    if sum > MAX_BITS_PER_GRANULE then
      for ch := 0 to cfg^.channels_out - 1 do
      begin
        tb^ := tb^ * MAX_BITS_PER_GRANULE div sum;
        Inc(tb);
      end
    else
      Inc(tb, cfg^.channels_out);
  end;

  { reduce M/S side }
  if gfc^.ov_enc.mode_ext = Ord(MPG_MD_MS_LR) then
    for gr := 0 to cfg^.mode_gr - 1 do
      reduce_side(PIntegerArray(PByte(targ_bits) + gr * cfg^.channels_out * SizeOf(Integer)),
                  ms_ener_ratio[gr],
                  mean_bits * cfg^.channels_out,
                  MAX_BITS_PER_GRANULE);

  tb := PInteger(targ_bits);
  for gr := 0 to cfg^.mode_gr - 1 do
    for ch := 0 to cfg^.channels_out - 1 do
    begin
      if tb^ > MAX_BITS_PER_CHANNEL then tb^ := MAX_BITS_PER_CHANNEL;
      Inc(totbits, tb^);
      Inc(tb);
    end;

  if (totbits > max_frame_bits) and (totbits > 0) then
  begin
    tb := PInteger(targ_bits);
    for gr := 0 to cfg^.mode_gr - 1 do
      for ch := 0 to cfg^.channels_out - 1 do
      begin
        tb^ := tb^ * max_frame_bits div totbits;
        Inc(tb);
      end;
  end;
end;

{ -----------------------------------------------------------------------
  VBR_old_iteration_loop  - VBR "old" method (rh algorithm)
  Stub: calls CBR loop for now
----------------------------------------------------------------------- }
procedure VBR_old_iteration_loop(gfc: PLameInternalFlags;
                                  pe: PPeArray;
                                  ms_ener_ratio: PSingle;
                                  ratio: PIIIPsyRatio2x2);
begin
  { Full VBR implementation left as extension - route to CBR path }
  CBR_iteration_loop(gfc, pe, ms_ener_ratio, ratio);
end;

end.
