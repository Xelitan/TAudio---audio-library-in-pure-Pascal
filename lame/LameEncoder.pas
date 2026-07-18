{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameEncoder;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Main frame encoding loop: psychoacoustics, MDCT, quantization, bitstream
//  Translated from encoder.c


interface

uses LameTypes;

{
  lame_encode_mp3_frame:
  Encode one frame of PCM audio into MP3 data.
  Parameters:
    gfc         - encoder internal state
    inbuf_l     - left-channel PCM samples (pointer to at least 576*mode_gr+272 samples)
    inbuf_r     - right-channel PCM samples (ignored for mono)
    mp3buf      - output buffer for MP3 bytes
    mp3buf_size - size of mp3buf in bytes (0 = no limit)
  Returns number of bytes written to mp3buf, or a negative error code:
    -4  psychoacoustic model failure
}
function lame_encode_mp3_frame(gfc: PLameInternalFlags;
                                inbuf_l: PSample;
                                inbuf_r: PSample;
                                mp3buf:  PByte;
                                mp3buf_size: Integer): Integer;

implementation

{$POINTERMATH ON}

uses LameMDCT, LamePsyModel, LameQuantize, LameBitstream, Math;

{ -----------------------------------------------------------------------
  AddVbrFrame stub
  (VBR tag writing not yet implemented; does nothing in CBR mode)
----------------------------------------------------------------------- }
procedure AddVbrFrame(gfc: PLameInternalFlags);
begin
  { stub — LameVbrTag.pas not yet translated }
end;

{ -----------------------------------------------------------------------
  adjust_ATH
  Auto-adjust the ATH scaling factor based on measured programme loudness.
  Called once per frame before quantization.
----------------------------------------------------------------------- }
procedure adjust_ATH(gfc: PLameInternalFlags);
var
  cfg:         PSessionConfig_t;
  max_pow:     TFloat;
  gr2_max:     TFloat;
  adj_lim_new: TFloat;
begin
  cfg := @gfc^.cfg;

  if gfc^.ATH^.use_adjust = 0 then
  begin
    gfc^.ATH^.adjust_factor := 1.0;
    Exit;
  end;

  { use granule with maximum combined loudness }
  max_pow := gfc^.ov_psy.loudness_sq[0][0];
  gr2_max := gfc^.ov_psy.loudness_sq[1][0];
  if cfg^.channels_out = 2 then
  begin
    max_pow := max_pow + gfc^.ov_psy.loudness_sq[0][1];
    gr2_max := gr2_max + gfc^.ov_psy.loudness_sq[1][1];
  end
  else
  begin
    max_pow := max_pow + max_pow;
    gr2_max := gr2_max + gr2_max;
  end;
  if cfg^.mode_gr = 2 then
    max_pow := Max(max_pow, gr2_max);
  max_pow := max_pow * 0.5;

  max_pow := max_pow * gfc^.ATH^.aa_sensitivity_p;

  if max_pow > 0.03125 then
  begin
    { signal is loud — clamp adjust_factor to 1.0 }
    if gfc^.ATH^.adjust_factor >= 1.0 then
      gfc^.ATH^.adjust_factor := 1.0
    else
    begin
      if gfc^.ATH^.adjust_factor < gfc^.ATH^.adjust_limit then
        gfc^.ATH^.adjust_factor := gfc^.ATH^.adjust_limit;
    end;
    gfc^.ATH^.adjust_limit := 1.0;
  end
  else
  begin
    { signal is quiet — apply adjustment curve (~32 dB max reduction) }
    adj_lim_new := 31.98 * max_pow + 0.000625;
    if gfc^.ATH^.adjust_factor >= adj_lim_new then
    begin
      { descend gradually }
      gfc^.ATH^.adjust_factor := gfc^.ATH^.adjust_factor *
                                  (adj_lim_new * 0.075 + 0.925);
      if gfc^.ATH^.adjust_factor < adj_lim_new then
        gfc^.ATH^.adjust_factor := adj_lim_new;
    end
    else
    begin
      { ascend }
      if gfc^.ATH^.adjust_limit >= adj_lim_new then
        gfc^.ATH^.adjust_factor := adj_lim_new
      else
      begin
        if gfc^.ATH^.adjust_factor < gfc^.ATH^.adjust_limit then
          gfc^.ATH^.adjust_factor := gfc^.ATH^.adjust_limit;
      end;
    end;
    gfc^.ATH^.adjust_limit := adj_lim_new;
  end;
end;

{ -----------------------------------------------------------------------
  updateStats
  Accumulate per-frame bitrate/block-type histograms for statistics.
----------------------------------------------------------------------- }
procedure updateStats(gfc: PLameInternalFlags);
var
  cfg: PSessionConfig_t;
  eov: PEncResult_t;
  gr, ch, bt: Integer;
begin
  cfg := @gfc^.cfg;
  eov := @gfc^.ov_enc;

  Inc(eov^.bitrate_channelmode_hist[eov^.bitrate_index][4]);
  Inc(eov^.bitrate_channelmode_hist[15][4]);

  if cfg^.channels_out = 2 then
  begin
    Inc(eov^.bitrate_channelmode_hist[eov^.bitrate_index][eov^.mode_ext]);
    Inc(eov^.bitrate_channelmode_hist[15][eov^.mode_ext]);
  end;

  for gr := 0 to cfg^.mode_gr - 1 do
    for ch := 0 to cfg^.channels_out - 1 do
    begin
      bt := gfc^.l3_side.tt[gr][ch].block_type;
      if gfc^.l3_side.tt[gr][ch].mixed_block_flag <> 0 then
        bt := 4;
      Inc(eov^.bitrate_blocktype_hist[eov^.bitrate_index][bt]);
      Inc(eov^.bitrate_blocktype_hist[eov^.bitrate_index][5]);
      Inc(eov^.bitrate_blocktype_hist[15][bt]);
      Inc(eov^.bitrate_blocktype_hist[15][5]);
    end;
end;

{ -----------------------------------------------------------------------
  lame_encode_frame_init
  Called on the very first frame to prime the MDCT polyphase filterbank
  with a synthetic short block so there is no startup transient.
  Sets gfc^.lame_encode_frame_init := 1 when done.
----------------------------------------------------------------------- }
procedure lame_encode_frame_init(gfc: PLameInternalFlags;
                                  const inbuf: array of PSample);
const
  PRIME_SIZE = 286 + 1152 + 576;   { 2014 samples }
var
  cfg:        PSessionConfig_t;
  primebuff0: array[0..PRIME_SIZE - 1] of TSample;
  primebuff1: array[0..PRIME_SIZE - 1] of TSample;
  framesize:  Integer;
  i, j, gr, ch: Integer;
begin
  cfg := @gfc^.cfg;

  gfc^.lame_encode_frame_init := 1;
  framesize := 576 * cfg^.mode_gr;

  FillChar(primebuff0, SizeOf(primebuff0), 0);
  FillChar(primebuff1, SizeOf(primebuff1), 0);

  j := 0;
  for i := 0 to 286 + 576 * (1 + cfg^.mode_gr) - 1 do
  begin
    if i >= framesize then
    begin
      primebuff0[i] := PSampleArray(inbuf[0])^[j];
      if cfg^.channels_out = 2 then
        primebuff1[i] := PSampleArray(inbuf[1])^[j];
      Inc(j);
    end;
    { else primebuff stays zero (from FillChar) }
  end;

  { prime with short blocks so the MDCT startup is clean }
  for gr := 0 to cfg^.mode_gr - 1 do
    for ch := 0 to cfg^.channels_out - 1 do
      gfc^.l3_side.tt[gr][ch].block_type := SHORT_TYPE;

  mdct_sub48(gfc, @primebuff0[0], @primebuff1[0]);
end;

{ -----------------------------------------------------------------------
  lame_encode_mp3_frame
----------------------------------------------------------------------- }
function lame_encode_mp3_frame(gfc: PLameInternalFlags;
                                inbuf_l: PSample;
                                inbuf_r: PSample;
                                mp3buf:  PByte;
                                mp3buf_size: Integer): Integer;
const
  fircoef: array[0..8] of TFloat = (
    -0.0207887 * 5, -0.0378413 * 5, -0.0432472 * 5, -0.031183  * 5,
     7.79609e-18*5,  0.0467745 * 5,  0.10091   * 5,  0.151365  * 5,
     0.187098  * 5
  );
var
  cfg:           PSessionConfig_t;
  masking_LR:    TIIIPsyRatio2x2;
  masking_MS:    TIIIPsyRatio2x2;
  inbuf:         array[0..1] of PSample;
  tot_ener:      array[0..1, 0..3] of TFloat;
  ms_ener_ratio: array[0..1] of TFloat;
  pe:            array[0..1, 0..1] of TFloat;
  pe_MS:         array[0..1, 0..1] of TFloat;
  use_MS:        Boolean;
  bufp:          array[0..1] of PSample;
  blocktype:     array[0..1] of Integer;
  sum_pe_MS:     TFloat;
  sum_pe_LR:     TFloat;
  gr, ch:        Integer;
  ret:           Integer;
  f:             TFloat;
  i:             Integer;
  mp3count:      Integer;
begin
  cfg := @gfc^.cfg;

  inbuf[0] := inbuf_l;
  inbuf[1] := inbuf_r;

  { initialise local arrays }
  FillChar(pe,      SizeOf(pe),      0);
  FillChar(pe_MS,   SizeOf(pe_MS),   0);
  ms_ener_ratio[0] := 0.5;
  ms_ener_ratio[1] := 0.5;

  { ---- first-run initialisation ---- }
  if gfc^.lame_encode_frame_init = 0 then
    lame_encode_frame_init(gfc, inbuf);

  { ---- padding decision ---- }
  { Slot-lag method from "MPEG-Layer3 / Bitstream Syntax and Decoding",
    Sieler & Sperschneider.  No padding for the very first frame. }
  gfc^.ov_enc.padding := 0;
  gfc^.sv_enc.slot_lag := gfc^.sv_enc.slot_lag - gfc^.sv_enc.frac_SpF;
  if gfc^.sv_enc.slot_lag < 0 then
  begin
    gfc^.sv_enc.slot_lag := gfc^.sv_enc.slot_lag + cfg^.samplerate_out;
    gfc^.ov_enc.padding := 1;
  end;

  { ===================================================
    Stage 1: psychoacoustic model
    The psy model operates one granule ahead of the MDCT
    (576-sample delay compensated here).
    =================================================== }
  for gr := 0 to cfg^.mode_gr - 1 do
  begin
    { point bufp[ch] at inbuf[ch][576 + gr*576 - FFTOFFSET] }
    for ch := 0 to cfg^.channels_out - 1 do
      bufp[ch] := PSample(PByte(inbuf[ch]) +
                          SizeOf(TSample) * (576 + gr * 576 - FFTOFFSET));

    ret := L3psycho_anal_vbr(gfc, bufp, gr,
                              @masking_LR, @masking_MS,
                              @pe[gr][0], @pe_MS[gr][0],
                              @tot_ener[gr][0], @blocktype[0]);
    if ret <> 0 then
    begin
      Result := -4;
      Exit;
    end;

    if cfg^.mode = JOINT_STEREO then
    begin
      ms_ener_ratio[gr] := tot_ener[gr][2] + tot_ener[gr][3];
      if ms_ener_ratio[gr] > 0 then
        ms_ener_ratio[gr] := tot_ener[gr][3] / ms_ener_ratio[gr];
    end;

    for ch := 0 to cfg^.channels_out - 1 do
    begin
      gfc^.l3_side.tt[gr][ch].block_type      := blocktype[ch];
      gfc^.l3_side.tt[gr][ch].mixed_block_flag := 0;
    end;
  end;

  { auto-adjust ATH }
  adjust_ATH(gfc);

  { ===================================================
    Stage 2: MDCT / polyphase filterbank
    =================================================== }
  mdct_sub48(gfc, inbuf[0], inbuf[1]);

  { ===================================================
    Stage 3: MS / LR stereo decision
    =================================================== }
  gfc^.ov_enc.mode_ext := Ord(MPG_MD_LR_LR);

  if cfg^.force_ms <> 0 then
    gfc^.ov_enc.mode_ext := Ord(MPG_MD_MS_LR)
  else if cfg^.mode = JOINT_STEREO then
  begin
    { compare aggregate perceptual entropy for MS vs LR }
    sum_pe_MS := 0;
    sum_pe_LR := 0;
    for gr := 0 to cfg^.mode_gr - 1 do
      for ch := 0 to cfg^.channels_out - 1 do
      begin
        sum_pe_MS := sum_pe_MS + pe_MS[gr][ch];
        sum_pe_LR := sum_pe_LR + pe[gr][ch];
      end;

    { choose MS if it uses no more bits and block types are compatible }
    if sum_pe_MS <= 1.00 * sum_pe_LR then
      if (gfc^.l3_side.tt[0][0].block_type =
          gfc^.l3_side.tt[0][1].block_type) and
         (gfc^.l3_side.tt[cfg^.mode_gr - 1][0].block_type =
          gfc^.l3_side.tt[cfg^.mode_gr - 1][1].block_type) then
        gfc^.ov_enc.mode_ext := Ord(MPG_MD_MS_LR);
  end;

  use_MS := (gfc^.ov_enc.mode_ext = Ord(MPG_MD_MS_LR));

  { ===================================================
    Stage 4: quantization / bit allocation
    =================================================== }

  { FIR-smoothed PE: used by CBR and ABR to detect transients }
  if (cfg^.vbr = vbr_off) or (cfg^.vbr = vbr_abr) then
  begin
    for i := 0 to 17 do
      gfc^.sv_enc.pefirbuf[i] := gfc^.sv_enc.pefirbuf[i + 1];

    f := 0.0;
    for gr := 0 to cfg^.mode_gr - 1 do
      for ch := 0 to cfg^.channels_out - 1 do
        if use_MS then
          f := f + pe_MS[gr][ch]
        else
          f := f + pe[gr][ch];
    gfc^.sv_enc.pefirbuf[18] := f;

    f := gfc^.sv_enc.pefirbuf[9];
    for i := 0 to 8 do
      f := f + (gfc^.sv_enc.pefirbuf[i] +
                gfc^.sv_enc.pefirbuf[18 - i]) * fircoef[i];

    if f > 0.0 then
      f := (670 * 5 * cfg^.mode_gr * cfg^.channels_out) / f
    else
      f := 1.0;

    for gr := 0 to cfg^.mode_gr - 1 do
      for ch := 0 to cfg^.channels_out - 1 do
        if use_MS then
          pe_MS[gr][ch] := pe_MS[gr][ch] * f
        else
          pe[gr][ch] := pe[gr][ch] * f;
  end;

  case cfg^.vbr of
    vbr_abr:
      if use_MS then
        ABR_iteration_loop(gfc, @pe_MS, @ms_ener_ratio[0], @masking_MS)
      else
        ABR_iteration_loop(gfc, @pe,    @ms_ener_ratio[0], @masking_LR);
    vbr_rh:
      if use_MS then
        VBR_old_iteration_loop(gfc, @pe_MS, @ms_ener_ratio[0], @masking_MS)
      else
        VBR_old_iteration_loop(gfc, @pe,    @ms_ener_ratio[0], @masking_LR);
    else { vbr_off (CBR) and anything else }
      if use_MS then
        CBR_iteration_loop(gfc, @pe_MS, @ms_ener_ratio[0], @masking_MS)
      else
        CBR_iteration_loop(gfc, @pe,    @ms_ener_ratio[0], @masking_LR);
  end;

  { ===================================================
    Stage 5: bitstream formatting
    =================================================== }
  format_bitstream(gfc);

  mp3count := copy_buffer(gfc, mp3buf, mp3buf_size, 1);

  { optional: write/update Xing/LAME VBR seek tag }
  if cfg^.write_lame_tag <> 0 then
    AddVbrFrame(gfc);

  Inc(gfc^.ov_enc.frame_number);
  updateStats(gfc);

  Result := mp3count;
end;

end.
