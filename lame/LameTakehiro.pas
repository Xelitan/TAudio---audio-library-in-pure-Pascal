{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameTakehiro;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Huffman table selection, quantization, scalefactor bit counting
//  Translated from takehiro.c

interface

uses LameTypes, LameTables;

{ Initialize choose_table function pointer and bv_scf table }
procedure huffman_init(gfc: PLameInternalFlags);

{ Count bits needed to encode l3_enc, updating cod_info regions }
function  noquant_count_bits(gfc: PLameInternalFlags;
                             gi: PGrInfo; prev_noise: PCalcNoiseData): Integer;

{ Quantize xr to l3_enc and count bits }
function  count_bits(gfc: PLameInternalFlags; xr: PSingle;
                     gi: PGrInfo; prev_noise: PCalcNoiseData): Integer;

{ Find best Huffman region boundaries by trying alternative divisions }
procedure best_huffman_divide(gfc: PLameInternalFlags; gi: PGrInfo);

{ Optimize scalefac storage: scfsi, preflag, scalefac_scale }
procedure best_scalefac_store(gfc: PLameInternalFlags; gr, ch: Integer;
                              l3_side: PIIISideInfo);

{ Calculate number of bits to encode scalefactors }
function  scale_bitcount(gfc: PLameInternalFlags; cod_info: PGrInfo): Integer;

{ The actual choose_table function (also needed as function pointer) }
function choose_table_nonMMX(const ix: PInteger; const ixend: PInteger;
                             var s: Integer): Integer;

implementation

{$POINTERMATH ON}

{ no additional uses needed }

{ -----------------------------------------------------------------------
  ix_max - find max value in ix[..end)
  ----------------------------------------------------------------------- }
function ix_max(ix: PInteger; const iend: PInteger): Cardinal;
var
  max1, max2, x1, x2: Cardinal;
  p: PInteger;
begin
  max1 := 0; max2 := 0;
  p := ix;
  while LongWord(p) < LongWord(iend) do
  begin
    x1 := Cardinal(p^); Inc(p);
    x2 := Cardinal(p^); Inc(p);
    if max1 < x1 then max1 := x1;
    if max2 < x2 then max2 := x2;
  end;
  if max1 < max2 then max1 := max2;
  Result := max1;
end;

{ -----------------------------------------------------------------------
  count_bit_null - null counter (for max=0)
  ----------------------------------------------------------------------- }
function count_bit_null(ix: PInteger; const iend: PInteger;
                        max: Cardinal; var s: Cardinal): Integer;
begin
  Result := 0;
end;

{ -----------------------------------------------------------------------
  count_bit_noESC - count bits for table 1 (max <= 1)
  ----------------------------------------------------------------------- }
function count_bit_noESC(ix: PInteger; const iend: PInteger;
                         max: Cardinal; var s: Cardinal): Integer;
var
  sum1: Cardinal;
  x0, x1: Cardinal;
begin
  sum1 := 0;
  while LongWord(ix) < LongWord(iend) do
  begin
    x0 := Cardinal(ix^); Inc(ix);
    x1 := Cardinal(ix^); Inc(ix);
    Inc(sum1, PByteArray2(ht[1].hlen)^[x0 + x0 + x1]);
  end;
  Inc(s, sum1);
  Result := 1;
end;

{ -----------------------------------------------------------------------
  count_bit_noESC_from2 - count bits for tables 2..3 (max <= 3)
  ----------------------------------------------------------------------- }
function count_bit_noESC_from2(ix: PInteger; const iend: PInteger;
                                max: Cardinal; var s: Cardinal): Integer;
const
  huf_tbl_noESC: array[0..14] of Integer = (1,2,5,7,7,10,10,13,13,13,13,13,13,13,13);
var
  t1: Integer;
  xlen: Cardinal;
  table: PCardinal;
  sum, sum2: Cardinal;
  x0, x1: Cardinal;
begin
  t1   := huf_tbl_noESC[max - 1];
  xlen := ht[t1].xlen;
  if t1 = 2 then table := @table23[0]
  else table := @table56[0];
  sum := 0;
  while LongWord(ix) < LongWord(iend) do
  begin
    x0 := Cardinal(ix^); Inc(ix);
    x1 := Cardinal(ix^); Inc(ix);
    Inc(sum, PCardinalArray(table)^[x0 * xlen + x1]);
  end;
  sum2 := sum and $FFFF;
  sum  := sum shr 16;
  if sum > sum2 then
  begin
    sum := sum2;
    Inc(t1);
  end;
  Inc(s, sum);
  Result := t1;
end;

{ -----------------------------------------------------------------------
  count_bit_noESC_from3 - count bits for tables 5..15 (max <= 15)
  ----------------------------------------------------------------------- }
function count_bit_noESC_from3(ix: PInteger; const iend: PInteger;
                                max: Cardinal; var s: Cardinal): Integer;
const
  huf_tbl_noESC: array[0..14] of Integer = (1,2,5,7,7,10,10,13,13,13,13,13,13,13,13);
var
  t1, t: Integer;
  xlen: Cardinal;
  sum1, sum2, sum3: Cardinal;
  x0, x1, x: Cardinal;
begin
  t1   := huf_tbl_noESC[max - 1];
  xlen := ht[t1].xlen;
  sum1 := 0; sum2 := 0; sum3 := 0;
  while LongWord(ix) < LongWord(iend) do
  begin
    x0 := Cardinal(ix^); Inc(ix);
    x1 := Cardinal(ix^); Inc(ix);
    x  := x0 * xlen + x1;
    Inc(sum1, PByteArray2(ht[t1].hlen)^[x]);
    Inc(sum2, PByteArray2(ht[t1 + 1].hlen)^[x]);
    Inc(sum3, PByteArray2(ht[t1 + 2].hlen)^[x]);
  end;
  t := t1;
  if sum1 > sum2 then begin sum1 := sum2; Inc(t); end;
  if sum1 > sum3 then begin sum1 := sum3; t := t1 + 2; end;
  Inc(s, sum1);
  Result := t;
end;

{ -----------------------------------------------------------------------
  count_bit_ESC - count bits for tables with linbits (max > 15)
  ----------------------------------------------------------------------- }
function count_bit_ESC(ix: PInteger; const iend: PInteger;
                       t1, t2: Integer; var s: Cardinal): Integer;
var
  linbits: Cardinal;
  sum, sum2, x, y: Cardinal;
begin
  linbits := ht[t1].xlen * 65536 + ht[t2].xlen;
  sum := 0;
  while LongWord(ix) < LongWord(iend) do
  begin
    x := Cardinal(ix^); Inc(ix);
    y := Cardinal(ix^); Inc(ix);
    if x >= 15 then begin x := 15; Inc(sum, linbits); end;
    if y >= 15 then begin y := 15; Inc(sum, linbits); end;
    x := (x shl 4) + y;
    Inc(sum, largetbl[x]);
  end;
  sum2 := sum and $FFFF;
  sum  := sum shr 16;
  if sum > sum2 then begin sum := sum2; t1 := t2; end;
  Inc(s, sum);
  Result := t1;
end;

{ -----------------------------------------------------------------------
  choose_table_nonMMX - select best Huffman table for ix[..end)
  Returns table index; adds bit count to s
  ----------------------------------------------------------------------- }
function choose_table_nonMMX(const ix: PInteger; const ixend: PInteger;
                              var s: Integer): Integer;
var
  us: Cardinal absolute s;
  max: Cardinal;
  choice, choice2: Integer;
begin
  max := ix_max(ix, ixend);
  if max <= 15 then
  begin
    case max of
      0:  Result := count_bit_null(ix, ixend, max, us);
      1:  Result := count_bit_noESC(ix, ixend, max, us);
      2,3: Result := count_bit_noESC_from2(ix, ixend, max, us);
    else
      Result := count_bit_noESC_from3(ix, ixend, max, us);
    end;
    Exit;
  end;
  if max > IXMAX_VAL then
  begin
    s := LARGE_BITS;
    Result := -1;
    Exit;
  end;
  Dec(max, 15);
  choice2 := 24;
  while choice2 < 32 do
  begin
    if ht[choice2].linmax >= max then Break;
    Inc(choice2);
  end;
  choice := choice2 - 8;
  while choice < 24 do
  begin
    if ht[choice].linmax >= max then Break;
    Inc(choice);
  end;
  Result := count_bit_ESC(ix, ixend, choice, choice2, us);
end;

{ -----------------------------------------------------------------------
  huffman_init - set choose_table pointer and build bv_scf lookup
  ----------------------------------------------------------------------- }
procedure huffman_init(gfc: PLameInternalFlags);
var
  i, scfb_anz, bv_index: Integer;
begin
  gfc^.choose_table := @choose_table_nonMMX;

  i := 2;
  while i <= 576 do
  begin
    scfb_anz := 0;
    while gfc^.scalefac_band.l[scfb_anz + 1] < i do
      Inc(scfb_anz);

    bv_index := subdv_table[scfb_anz][0];
    while (bv_index >= 0) and (gfc^.scalefac_band.l[bv_index + 1] > i) do
      Dec(bv_index);
    if bv_index < 0 then
      bv_index := subdv_table[scfb_anz][0];
    gfc^.sv_qnt.bv_scf[i - 2] := bv_index;

    bv_index := subdv_table[scfb_anz][1];
    while (bv_index >= 0) and
          (gfc^.scalefac_band.l[bv_index + gfc^.sv_qnt.bv_scf[i - 2] + 2] > i) do
      Dec(bv_index);
    if bv_index < 0 then
      bv_index := subdv_table[scfb_anz][1];
    gfc^.sv_qnt.bv_scf[i - 1] := bv_index;

    Inc(i, 2);
  end;
end;

{ -----------------------------------------------------------------------
  quantize_lines_xrpow - quantize xr -> ix using adj43 table
  l must be even
  ----------------------------------------------------------------------- }
procedure quantize_lines_xrpow(l: Cardinal; istep: TFloat;
                                xr: PSingle; ix: PInteger);
var
  x0, x1, x2, x3: TFloat;
  rx0, rx1, rx2, rx3: Integer;
  remaining: Cardinal;
begin
  l := l shr 1;
  remaining := l and 1;
  l := l shr 1;
  while l > 0 do
  begin
    x0 := xr^ * istep; Inc(xr);
    x1 := xr^ * istep; Inc(xr);
    rx0 := Trunc(x0);
    x2 := xr^ * istep; Inc(xr);
    rx1 := Trunc(x1);
    x3 := xr^ * istep; Inc(xr);
    rx2 := Trunc(x2);
    x0  := x0 + adj43[rx0];
    rx3 := Trunc(x3);
    x1  := x1 + adj43[rx1];
    ix^ := Trunc(x0); Inc(ix);
    x2  := x2 + adj43[rx2];
    ix^ := Trunc(x1); Inc(ix);
    x3  := x3 + adj43[rx3];
    ix^ := Trunc(x2); Inc(ix);
    ix^ := Trunc(x3); Inc(ix);
    Dec(l);
  end;
  if remaining > 0 then
  begin
    x0 := xr^ * istep; Inc(xr);
    x1 := xr^ * istep; Inc(xr);
    rx0 := Trunc(x0);
    rx1 := Trunc(x1);
    x0 := x0 + adj43[rx0];
    x1 := x1 + adj43[rx1];
    ix^ := Trunc(x0); Inc(ix);
    ix^ := Trunc(x1); Inc(ix);
  end;
end;

{ -----------------------------------------------------------------------
  quantize_lines_xrpow_01 - quantize xr -> ix for range [0,1] only
  ----------------------------------------------------------------------- }
procedure quantize_lines_xrpow_01(l: Cardinal; istep: TFloat;
                                   xr: PSingle; ix: PInteger);
var
  compareval0: TFloat;
  i: Cardinal;
  xr0, xr1: TFloat;
begin
  compareval0 := (1.0 - 0.4054) / istep;
  i := 0;
  while i < l do
  begin
    xr0 := xr^; Inc(xr);
    xr1 := xr^; Inc(xr);
    if compareval0 > xr0 then ix^ := 0 else ix^ := 1; Inc(ix);
    if compareval0 > xr1 then ix^ := 0 else ix^ := 1; Inc(ix);
    Inc(i, 2);
  end;
end;

{ -----------------------------------------------------------------------
  quantize_xrpow - quantize xr[0..576) into ix[], choosing 01 shortcut
  ----------------------------------------------------------------------- }
procedure quantize_xrpow(const xp: PSingle; pi: PInteger; istep: TFloat;
                          const cod_info: TGrInfo; prev_noise: PCalcNoiseData);
var
  sfb, sfbmax, j, l: Integer;
  prev_data_use: Boolean;
  iData, acc_iData: PInteger;
  acc_xp: PSingle;
  accumulate, accumulate01: Integer;
  step: Integer;
  usefullsize: Integer;
  sfb_step: Integer;
begin
  iData      := pi;
  acc_xp     := xp;
  acc_iData  := iData;
  accumulate   := 0;
  accumulate01 := 0;
  j := 0;

  prev_data_use := (prev_noise <> nil) and
                   (cod_info.global_gain = prev_noise^.global_gain);

  if cod_info.block_type = SHORT_TYPE then sfbmax := 38
  else sfbmax := 21;

  sfb := 0;
  while sfb <= sfbmax do
  begin
    step := -1;
    if prev_data_use or (cod_info.block_type = NORM_TYPE) then
    begin
      sfb_step := cod_info.scalefac[sfb] +
        (ord(cod_info.preflag <> 0) * pretab[sfb]);
      step := cod_info.global_gain
              - (sfb_step shl (cod_info.scalefac_scale + 1))
              - cod_info.subblock_gain[cod_info.window[sfb]] * 8;
    end;

    if prev_data_use and (prev_noise^.step[sfb] = step) then
    begin
      { reuse - flush accumulated }
      if accumulate > 0 then
      begin
        quantize_lines_xrpow(accumulate, istep, acc_xp, acc_iData);
        accumulate := 0;
      end;
      if accumulate01 > 0 then
      begin
        quantize_lines_xrpow_01(accumulate01, istep, acc_xp, acc_iData);
        accumulate01 := 0;
      end;
    end
    else
    begin
      l := cod_info.width[sfb];
      if (j + cod_info.width[sfb]) > cod_info.max_nonzero_coeff then
      begin
        usefullsize := cod_info.max_nonzero_coeff - j + 1;
        FillChar((pi + cod_info.max_nonzero_coeff)^, SizeOf(Integer) * (576 - cod_info.max_nonzero_coeff), 0);
        l := usefullsize;
        if l < 0 then l := 0;
        sfb := sfbmax + 1;
      end;

      if (accumulate = 0) and (accumulate01 = 0) then
      begin
        acc_iData := iData;
        acc_xp    := PSingle(PByte(xp) + j * SizeOf(TFloat));
      end;

      if (prev_noise <> nil) and (prev_noise^.sfb_count1 > 0) and
         (sfb >= prev_noise^.sfb_count1) and
         (prev_noise^.step[sfb] > 0) and (step >= prev_noise^.step[sfb]) then
      begin
        if accumulate > 0 then
        begin
          quantize_lines_xrpow(accumulate, istep, acc_xp, acc_iData);
          accumulate := 0;
          acc_iData  := iData;
          acc_xp     := PSingle(PByte(xp) + j * SizeOf(TFloat));
        end;
        Inc(accumulate01, l);
      end
      else
      begin
        if accumulate01 > 0 then
        begin
          quantize_lines_xrpow_01(accumulate01, istep, acc_xp, acc_iData);
          accumulate01 := 0;
          acc_iData    := iData;
          acc_xp       := PSingle(PByte(xp) + j * SizeOf(TFloat));
        end;
        Inc(accumulate, l);
      end;

      if l <= 0 then
      begin
        if accumulate01 > 0 then
        begin
          quantize_lines_xrpow_01(accumulate01, istep, acc_xp, acc_iData);
          accumulate01 := 0;
        end;
        if accumulate > 0 then
        begin
          quantize_lines_xrpow(accumulate, istep, acc_xp, acc_iData);
          accumulate := 0;
        end;
        Break;
      end;
    end;

    if sfb <= sfbmax then
    begin
      Inc(iData, cod_info.width[sfb]);
      Inc(j, cod_info.width[sfb]);
    end;
    Inc(sfb);
  end;

  if accumulate > 0 then
    quantize_lines_xrpow(accumulate, istep, acc_xp, acc_iData);
  if accumulate01 > 0 then
    quantize_lines_xrpow_01(accumulate01, istep, acc_xp, acc_iData);
end;

{ -----------------------------------------------------------------------
  noquant_count_bits - count bits for already-quantized l3_enc
  ----------------------------------------------------------------------- }
function noquant_count_bits(gfc: PLameInternalFlags;
                            gi: PGrInfo; prev_noise: PCalcNoiseData): Integer;
var
  bits, i, a1, a2: Integer;
  ix: PInteger;
  x4, x3, x2, x1, p: Integer;
  sfb: Integer;
begin
  bits := 0;
  ix   := @gi^.l3_enc[0];

  i := ((gi^.max_nonzero_coeff + 2) shr 1) shl 1;
  if i > 576 then i := 576;

  if prev_noise <> nil then prev_noise^.sfb_count1 := 0;

  { find count1 boundary }
  while i > 1 do
  begin
    if (ix[i - 1] or ix[i - 2]) <> 0 then Break;
    Dec(i, 2);
  end;
  gi^.count1 := i;

  { count1 region bits (quadruples) }
  a1 := 0; a2 := 0;
  while i > 3 do
  begin
    x4 := ix[i - 4]; x3 := ix[i - 3];
    x2 := ix[i - 2]; x1 := ix[i - 1];
    if Cardinal(x4 or x3 or x2 or x1) > 1 then Break;
    p := ((x4 * 2 + x3) * 2 + x2) * 2 + x1;
    Inc(a1, t32l[p]);
    Inc(a2, t33l[p]);
    Dec(i, 4);
  end;

  bits := a1;
  gi^.count1table_select := 0;
  if a1 > a2 then
  begin
    bits := a2;
    gi^.count1table_select := 1;
  end;

  gi^.count1bits := bits;
  gi^.big_values := i;

  if i = 0 then
  begin
    Result := bits;
    Exit;
  end;

  if gi^.block_type = SHORT_TYPE then
  begin
    a1 := 3 * gfc^.scalefac_band.s[3];
    if a1 > gi^.big_values then a1 := gi^.big_values;
    a2 := gi^.big_values;
  end
  else if gi^.block_type = NORM_TYPE then
  begin
    a1 := gi^.region0_count;
    a2 := gi^.region1_count;
    a1 := gfc^.sv_qnt.bv_scf[i - 2];
    a2 := gfc^.sv_qnt.bv_scf[i - 1];
    gi^.region0_count := a1;
    gi^.region1_count := a2;
    a2 := gfc^.scalefac_band.l[a1 + a2 + 2];
    a1 := gfc^.scalefac_band.l[a1 + 1];
    if a2 < i then
      gi^.table_select[2] := gfc^.choose_table(ix + a2, ix + i, bits);
  end
  else
  begin
    gi^.region0_count := 7;
    gi^.region1_count := SBMAX_l - 1 - 7 - 1;
    a1 := gfc^.scalefac_band.l[8];
    a2 := i;
    if a1 > a2 then a1 := a2;
  end;

  if a1 > i then a1 := i;
  if a2 > i then a2 := i;

  if a1 > 0 then
    gi^.table_select[0] := gfc^.choose_table(ix, ix + a1, bits);
  if a1 < a2 then
    gi^.table_select[1] := gfc^.choose_table(ix + a1, ix + a2, bits);

  if gfc^.cfg.use_best_huffman = 2 then
  begin
    gi^.part2_3_length := bits;
    best_huffman_divide(gfc, gi);
    bits := gi^.part2_3_length;
  end;

  if prev_noise <> nil then
  begin
    if gi^.block_type = NORM_TYPE then
    begin
      sfb := 0;
      while gfc^.scalefac_band.l[sfb] < gi^.big_values do
        Inc(sfb);
      prev_noise^.sfb_count1 := sfb;
    end;
  end;

  Result := bits;
end;

{ -----------------------------------------------------------------------
  count_bits - quantize then count bits
  ----------------------------------------------------------------------- }
function count_bits(gfc: PLameInternalFlags; xr: PSingle;
                    gi: PGrInfo; prev_noise: PCalcNoiseData): Integer;
var
  ix: PInteger;
  w: TFloat;
  sfb, j, k, width, gain: Integer;
  roundfac: TFloat;
begin
  ix := @gi^.l3_enc[0];
  w  := IXMAX_VAL / ipow20[gi^.global_gain];

  if gi^.xrpow_max > w then
  begin
    Result := LARGE_BITS;
    Exit;
  end;

  quantize_xrpow(xr, ix, ipow20[gi^.global_gain], gi^, prev_noise);

  if (gfc^.sv_qnt.substep_shaping and 2) <> 0 then
  begin
    { substep shaping - apply roundfac }
    { 0.634521682242439 = 0.5946 * 2^(0.5*0.1875) }
    gain    := gi^.global_gain + gi^.scalefac_scale;
    roundfac := 0.634521682242439 / ipow20[gain];
    j := 0;
    for sfb := 0 to gi^.sfbmax - 1 do
    begin
      width := gi^.width[sfb];
      if gfc^.sv_qnt.pseudohalf[sfb] = 0 then
        Inc(j, width)
      else
        for k := j to j + width - 1 do
        begin
          if PSingleArray(xr)^[k] < roundfac then ix[k] := 0;
          Inc(j);
        end;
    end;
  end;

  Result := noquant_count_bits(gfc, gi, prev_noise);
end;

{ -----------------------------------------------------------------------
  recalc_divide_init - precompute region0/region1 bit costs
  ----------------------------------------------------------------------- }
procedure recalc_divide_init(gfc: PLameInternalFlags;
                              cod_info: PGrInfo; ix: PInteger;
                              r01_bits, r01_div, r0_tbl, r1_tbl: PIntegerArray);
var
  r0, r1, bigv, a1, a2, r0bits, r0t, r1t, bits: Integer;
begin
  bigv := cod_info^.big_values;
  for r0 := 0 to 7 + 15 do
    r01_bits^[r0] := LARGE_BITS;

  for r0 := 0 to 15 do
  begin
    a1 := gfc^.scalefac_band.l[r0 + 1];
    if a1 >= bigv then Break;
    r0bits := 0;
    r0t    := gfc^.choose_table(ix, ix + a1, r0bits);

    for r1 := 0 to 7 do
    begin
      a2 := gfc^.scalefac_band.l[r0 + r1 + 2];
      if a2 >= bigv then Break;
      bits := r0bits;
      r1t  := gfc^.choose_table(ix + a1, ix + a2, bits);
      if r01_bits^[r0 + r1] > bits then
      begin
        r01_bits^[r0 + r1] := bits;
        r01_div^[r0 + r1]  := r0;
        r0_tbl^[r0 + r1]   := r0t;
        r1_tbl^[r0 + r1]   := r1t;
      end;
    end;
  end;
end;

{ -----------------------------------------------------------------------
  recalc_divide_sub - find best region2 to minimize bits
  ----------------------------------------------------------------------- }
procedure recalc_divide_sub(gfc: PLameInternalFlags;
                             const cod_info2: TGrInfo; gi: PGrInfo; ix: PInteger;
                             const r01_bits, r01_div, r0_tbl, r1_tbl: PIntegerArray);
var
  r2, a2, bigv, bits, r2t: Integer;
begin
  bigv := cod_info2.big_values;
  for r2 := 2 to SBMAX_l do
  begin
    a2 := gfc^.scalefac_band.l[r2];
    if a2 >= bigv then Break;
    bits := r01_bits^[r2 - 2] + cod_info2.count1bits;
    if gi^.part2_3_length <= bits then Break;
    r2t := gfc^.choose_table(ix + a2, ix + bigv, bits);
    if gi^.part2_3_length <= bits then Continue;
    Move(cod_info2, gi^, SizeOf(TGrInfo));
    gi^.part2_3_length := bits;
    gi^.region0_count  := r01_div^[r2 - 2];
    gi^.region1_count  := r2 - 2 - r01_div^[r2 - 2];
    gi^.table_select[0] := r0_tbl^[r2 - 2];
    gi^.table_select[1] := r1_tbl^[r2 - 2];
    gi^.table_select[2] := r2t;
  end;
end;

{ -----------------------------------------------------------------------
  best_huffman_divide - try extending count1 region by 2 or using better
  region boundaries to save bits
  ----------------------------------------------------------------------- }
procedure best_huffman_divide(gfc: PLameInternalFlags; gi: PGrInfo);
var
  cfg: TSessionConfig_t;
  i, a1, a2: Integer;
  cod_info2: TGrInfo;
  ix: PInteger;
  p: Integer;
  r01_bits: array[0..7 + 15] of Integer;
  r01_div:  array[0..7 + 15] of Integer;
  r0_tbl:   array[0..7 + 15] of Integer;
  r1_tbl:   array[0..7 + 15] of Integer;
begin
  cfg := gfc^.cfg;
  if (gi^.block_type = SHORT_TYPE) and (cfg.mode_gr = 1) then Exit;

  Move(gi^, cod_info2, SizeOf(TGrInfo));
  ix := @gi^.l3_enc[0];

  if gi^.block_type = NORM_TYPE then
  begin
    recalc_divide_init(gfc, gi, ix,
      @r01_bits, @r01_div, @r0_tbl, @r1_tbl);
    recalc_divide_sub(gfc, cod_info2, gi, ix,
      @r01_bits, @r01_div, @r0_tbl, @r1_tbl);
  end;

  i := cod_info2.big_values;
  if (i = 0) or (Cardinal(ix[i - 2] or ix[i - 1]) > 1) then Exit;

  i := gi^.count1 + 2;
  if i > 576 then Exit;

  Move(gi^, cod_info2, SizeOf(TGrInfo));
  cod_info2.count1 := i;
  a1 := 0; a2 := 0;

  while i > cod_info2.big_values do
  begin
    p  := ((ix[i - 4] * 2 + ix[i - 3]) * 2 + ix[i - 2]) * 2 + ix[i - 1];
    Inc(a1, t32l[p]);
    Inc(a2, t33l[p]);
    Dec(i, 4);
  end;
  cod_info2.big_values := i;
  cod_info2.count1table_select := 0;
  if a1 > a2 then begin a1 := a2; cod_info2.count1table_select := 1; end;
  cod_info2.count1bits := a1;

  if cod_info2.block_type = NORM_TYPE then
    recalc_divide_sub(gfc, cod_info2, gi, ix,
      @r01_bits, @r01_div, @r0_tbl, @r1_tbl)
  else
  begin
    cod_info2.part2_3_length := a1;
    a1 := gfc^.scalefac_band.l[8];
    if a1 > i then a1 := i;
    if a1 > 0 then
      cod_info2.table_select[0] :=
        gfc^.choose_table(ix, ix + a1, cod_info2.part2_3_length);
    if i > a1 then
      cod_info2.table_select[1] :=
        gfc^.choose_table(ix + a1, ix + i, cod_info2.part2_3_length);
    if gi^.part2_3_length > cod_info2.part2_3_length then
      Move(cod_info2, gi^, SizeOf(TGrInfo));
  end;
end;

{ -----------------------------------------------------------------------
  scfsi_calc - calculate scfsi flags for granule 1
  ----------------------------------------------------------------------- }
procedure scfsi_calc(ch: Integer; l3_side: PIIISideInfo);
const
  slen1_n: array[0..15] of Integer = (1,1,1,1,8,2,2,2,4,4,4,8,8,8,16,16);
  slen2_n: array[0..15] of Integer = (1,2,4,8,1,2,4,8,2,4,8,2,4,8,4,8);
var
  i, s1, s2, c1, c2, sfb, c: Integer;
  gi: PGrInfo;
  g0: PGrInfo;
begin
  gi := @l3_side^.tt[1][ch];
  g0 := @l3_side^.tt[0][ch];

  for i := 0 to 3 do
  begin
    sfb := scfsi_band[i];
    while sfb < scfsi_band[i + 1] do
    begin
      if (g0^.scalefac[sfb] <> gi^.scalefac[sfb]) and (gi^.scalefac[sfb] >= 0) then
        Break;
      Inc(sfb);
    end;
    if sfb = scfsi_band[i + 1] then
    begin
      sfb := scfsi_band[i];
      while sfb < scfsi_band[i + 1] do
      begin
        gi^.scalefac[sfb] := -1;
        Inc(sfb);
      end;
      l3_side^.scfsi[ch][i] := 1;
    end;
  end;

  s1 := 0; c1 := 0;
  for sfb := 0 to 10 do
  begin
    if gi^.scalefac[sfb] = -1 then Continue;
    Inc(c1);
    if s1 < gi^.scalefac[sfb] then s1 := gi^.scalefac[sfb];
  end;
  s2 := 0; c2 := 0;
  for sfb := 11 to SBPSY_l - 1 do
  begin
    if gi^.scalefac[sfb] = -1 then Continue;
    Inc(c2);
    if s2 < gi^.scalefac[sfb] then s2 := gi^.scalefac[sfb];
  end;

  for i := 0 to 15 do
  begin
    if (s1 < slen1_n[i]) and (s2 < slen2_n[i]) then
    begin
      c := slen1_tab[i] * c1 + slen2_tab[i] * c2;
      if gi^.part2_length > c then
      begin
        gi^.part2_length := c;
        gi^.scalefac_compress := i;
      end;
    end;
  end;
end;

{ -----------------------------------------------------------------------
  best_scalefac_store - optimize scalefac storage
  ----------------------------------------------------------------------- }
procedure best_scalefac_store(gfc: PLameInternalFlags; gr, ch: Integer;
                              l3_side: PIIISideInfo);
var
  cfg: TSessionConfig_t;
  gi: PGrInfo;
  sfb, i, j, l, s, recalc: Integer;
begin
  cfg := gfc^.cfg;
  gi  := @l3_side^.tt[gr][ch];
  recalc := 0;
  j := 0;
  for sfb := 0 to gi^.sfbmax - 1 do
  begin
    l := gi^.width[sfb];
    i := j;
    while i < j + l do
    begin
      if gi^.l3_enc[i] <> 0 then Break;
      Inc(i);
    end;
    if i = j + l then
      gi^.scalefac[sfb] := -2;
    Inc(j, l);
  end;

  if (gi^.scalefac_scale = 0) and (gi^.preflag = 0) then
  begin
    s := 0;
    for sfb := 0 to gi^.sfbmax - 1 do
      if gi^.scalefac[sfb] > 0 then
        s := s or gi^.scalefac[sfb];

    if ((s and 1) = 0) and (s <> 0) then
    begin
      for sfb := 0 to gi^.sfbmax - 1 do
        if gi^.scalefac[sfb] > 0 then
          gi^.scalefac[sfb] := gi^.scalefac[sfb] shr 1;
      gi^.scalefac_scale := 1;
      recalc := 1;
    end;
  end;

  if (gi^.preflag = 0) and (gi^.block_type <> SHORT_TYPE) and (cfg.mode_gr = 2) then
  begin
    sfb := 11;
    while sfb < SBPSY_l do
    begin
      if (gi^.scalefac[sfb] < pretab[sfb]) and (gi^.scalefac[sfb] <> -2) then
        Break;
      Inc(sfb);
    end;
    if sfb = SBPSY_l then
    begin
      for sfb := 11 to SBPSY_l - 1 do
        if gi^.scalefac[sfb] > 0 then
          Dec(gi^.scalefac[sfb], pretab[sfb]);
      gi^.preflag := 1;
      recalc := 1;
    end;
  end;

  for i := 0 to 3 do
    l3_side^.scfsi[ch][i] := 0;

  if (cfg.mode_gr = 2) and (gr = 1) and
     (l3_side^.tt[0][ch].block_type <> SHORT_TYPE) and
     (l3_side^.tt[1][ch].block_type <> SHORT_TYPE) then
  begin
    scfsi_calc(ch, l3_side);
    recalc := 0;
  end;

  for sfb := 0 to gi^.sfbmax - 1 do
    if gi^.scalefac[sfb] = -2 then
      gi^.scalefac[sfb] := 0;

  if recalc <> 0 then
    scale_bitcount(gfc, gi);
end;

{ -----------------------------------------------------------------------
  mpeg1_scale_bitcount
  ----------------------------------------------------------------------- }
function mpeg1_scale_bitcount(gfc: PLameInternalFlags; cod_info: PGrInfo): Integer;
const
  scale_short: array[0..15] of Integer = (0,18,36,54,54,36,54,72,54,72,90,72,90,108,108,126);
  scale_mixed: array[0..15] of Integer = (0,18,36,54,51,35,53,71,52,70,88,69,87,105,104,122);
  scale_long:  array[0..15] of Integer = (0,10,20,30,33,21,31,41,32,42,52,43,53,63,64,74);
  slen1_n: array[0..15] of Integer = (1,1,1,1,8,2,2,2,4,4,4,8,8,8,16,16);
  slen2_n: array[0..15] of Integer = (1,2,4,8,1,2,4,8,2,4,8,2,4,8,4,8);
var
  k, sfb, max_slen1, max_slen2: Integer;
  tab: PInteger;
  scalefac: PInteger;
begin
  scalefac  := @cod_info^.scalefac[0];
  max_slen1 := 0;
  max_slen2 := 0;

  if cod_info^.block_type = SHORT_TYPE then
  begin
    if cod_info^.mixed_block_flag <> 0 then tab := @scale_mixed[0]
    else tab := @scale_short[0];
  end
  else
  begin
    tab := @scale_long[0];
    if cod_info^.preflag = 0 then
    begin
      sfb := 11;
      while sfb < SBPSY_l do
      begin
        if PIntegerArray(scalefac)^[sfb] < pretab[sfb] then Break;
        Inc(sfb);
      end;
      if sfb = SBPSY_l then
      begin
        cod_info^.preflag := 1;
        for sfb := 11 to SBPSY_l - 1 do
          Dec(PIntegerArray(scalefac)^[sfb], pretab[sfb]);
      end;
    end;
  end;

  for sfb := 0 to cod_info^.sfbdivide - 1 do
    if max_slen1 < PIntegerArray(scalefac)^[sfb] then max_slen1 := PIntegerArray(scalefac)^[sfb];
  for sfb := cod_info^.sfbdivide to cod_info^.sfbmax - 1 do
    if max_slen2 < PIntegerArray(scalefac)^[sfb] then max_slen2 := PIntegerArray(scalefac)^[sfb];

  cod_info^.part2_length := LARGE_BITS;
  for k := 0 to 15 do
  begin
    if (max_slen1 < slen1_n[k]) and (max_slen2 < slen2_n[k]) and
       (cod_info^.part2_length > PIntegerArray(tab)^[k]) then
    begin
      cod_info^.part2_length   := PIntegerArray(tab)^[k];
      cod_info^.scalefac_compress := k;
    end;
  end;
  if cod_info^.part2_length = LARGE_BITS then Result := 1 else Result := 0;
end;

{ -----------------------------------------------------------------------
  mpeg2_scale_bitcount
  ----------------------------------------------------------------------- }
function mpeg2_scale_bitcount(gfc: PLameInternalFlags; cod_info: PGrInfo): Integer;
const
  log2tab: array[0..15] of Integer = (0,1,2,2,3,3,3,3,4,4,4,4,4,4,4,4);
  max_range_sfac_tab: array[0..5, 0..3] of Integer = (
    (15,15,7,7),(15,15,7,0),(7,3,0,0),(15,31,31,0),(7,7,7,0),(3,3,0,0));
var
  table_number, row_in_table, partition, nr_sfb, window, over: Integer;
  i, sfb: Integer;
  max_sfac: array[0..3] of Integer;
  partition_table: PInteger;
  scalefac: PInteger;
  slen1, slen2, slen3, slen4: Integer;
begin
  scalefac := @cod_info^.scalefac[0];
  if cod_info^.preflag <> 0 then table_number := 2 else table_number := 0;
  for i := 0 to 3 do max_sfac[i] := 0;

  if cod_info^.block_type = SHORT_TYPE then
  begin
    row_in_table := 1;
    partition_table := @nr_of_sfb_block[table_number][row_in_table][0];
    sfb := 0; partition := 0;
    while partition < 4 do
    begin
      nr_sfb := PIntegerArray(partition_table)^[partition] div 3;
      for i := 0 to nr_sfb - 1 do
      begin
        for window := 0 to 2 do
          if PIntegerArray(scalefac)^[sfb * 3 + window] > max_sfac[partition] then
            max_sfac[partition] := PIntegerArray(scalefac)^[sfb * 3 + window];
        Inc(sfb);
      end;
      Inc(partition);
    end;
  end
  else
  begin
    row_in_table := 0;
    partition_table := @nr_of_sfb_block[table_number][row_in_table][0];
    sfb := 0; partition := 0;
    while partition < 4 do
    begin
      nr_sfb := PIntegerArray(partition_table)^[partition];
      for i := 0 to nr_sfb - 1 do
      begin
        if PIntegerArray(scalefac)^[sfb] > max_sfac[partition] then
          max_sfac[partition] := PIntegerArray(scalefac)^[sfb];
        Inc(sfb);
      end;
      Inc(partition);
    end;
  end;

  over := 0;
  for partition := 0 to 3 do
    if max_sfac[partition] > max_range_sfac_tab[table_number][partition] then
      Inc(over);

  if over = 0 then
  begin
    cod_info^.sfb_partition_table :=
      @nr_of_sfb_block[table_number][row_in_table][0];
    for partition := 0 to 3 do
      cod_info^.slen[partition] := log2tab[max_sfac[partition]];
    slen1 := cod_info^.slen[0]; slen2 := cod_info^.slen[1];
    slen3 := cod_info^.slen[2]; slen4 := cod_info^.slen[3];
    case table_number of
      0: cod_info^.scalefac_compress :=
           (((slen1 * 5) + slen2) shl 4) + (slen3 shl 2) + slen4;
      1: cod_info^.scalefac_compress :=
           400 + (((slen1 * 5) + slen2) shl 2) + slen3;
      2: cod_info^.scalefac_compress := 500 + (slen1 * 3) + slen2;
    end;

    cod_info^.part2_length := 0;
    for partition := 0 to 3 do
      Inc(cod_info^.part2_length,
          cod_info^.slen[partition] *
          PIntegerArray(cod_info^.sfb_partition_table)^[partition]);
  end;
  Result := over;
end;

{ -----------------------------------------------------------------------
  scale_bitcount - dispatch to MPEG1 or MPEG2 variant
  ----------------------------------------------------------------------- }
function scale_bitcount(gfc: PLameInternalFlags; cod_info: PGrInfo): Integer;
begin
  if gfc^.cfg.mode_gr = 2 then
    Result := mpeg1_scale_bitcount(gfc, cod_info)
  else
    Result := mpeg2_scale_bitcount(gfc, cod_info);
end;

end.
