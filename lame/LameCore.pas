{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameCore;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Translated from lame.c


interface

uses LameTypes;

{
  lame_init:
  Allocate and zero-initialise a TLameGlobalFlags structure.
  Returns a pointer to the new structure, or nil on allocation failure.
}
function  lame_init: PLameGlobalFlags;

{
  lame_init_params:
  Configure the encoder based on the settings in gfp.
  Must be called after setting all desired parameters and before encoding.
  Returns 0 on success, negative on error.
}
function  lame_init_params(gfp: PLameGlobalFlags): Integer;

{
  lame_encode_buffer_float:
  Encode nsamples of float PCM (normalised to ±32768).
  pcm_l/pcm_r: pointers to left/right channel sample arrays.
  mp3buf / mp3buf_size: output buffer and its size in bytes (0 = unlimited).
  Returns bytes written, 0 if more samples needed, or negative error code.
}
function  lame_encode_buffer_float(gfp: PLameGlobalFlags;
                                    pcm_l: PSingle;
                                    pcm_r: PSingle;
                                    nsamples: Integer;
                                    mp3buf: PByte;
                                    mp3buf_size: Integer): Integer;

{
  lame_encode_buffer:
  As lame_encode_buffer_float but takes 16-bit signed PCM (range ±32768).
}
function  lame_encode_buffer(gfp: PLameGlobalFlags;
                              pcm_l: PSmallInt;
                              pcm_r: PSmallInt;
                              nsamples: Integer;
                              mp3buf: PByte;
                              mp3buf_size: Integer): Integer;

{
  lame_encode_flush:
  Flush all internally buffered PCM samples to MP3.
  Call once after all input has been submitted.
  Returns bytes written or negative error code.
}
function  lame_encode_flush(gfp: PLameGlobalFlags;
                             mp3buf: PByte;
                             mp3buf_size: Integer): Integer;

{
  lame_close:
  Free all resources associated with gfp.
  Returns 0, or -3 if gfp is invalid.
}
function  lame_close(gfp: PLameGlobalFlags): Integer;

implementation

{$POINTERMATH ON}

uses LameUtils, LameTables, LameBitstream, LameQuantizePvt,
     LamePsyModel, LameEncoder, LameMDCT, Math, SysUtils;

{ -----------------------------------------------------------------------
  Local helpers (mirror of util.c / lame.c static helpers)
----------------------------------------------------------------------- }

{ Convert sample frequency in Hz to MPEG version and samplerate index (0-2).
  Sets version: 1=MPEG-1, 0=MPEG-2, 2=MPEG-2.5
  Returns -1 if freq is not a valid MPEG sample rate. }
function SmpFrqIndex(sample_freq: Integer; out version: Integer): Integer;
begin
  { version: 1 = MPEG-1 (>=32 kHz), 0 = MPEG-2 / MPEG-2.5 (<32 kHz)
    MPEG-2.5 is distinguished by samplerate_out < 16000, not by version. }
  case sample_freq of
    44100: begin version := 1; Result := 0; end;
    48000: begin version := 1; Result := 1; end;
    32000: begin version := 1; Result := 2; end;
    22050: begin version := 0; Result := 0; end;
    24000: begin version := 0; Result := 1; end;
    16000: begin version := 0; Result := 2; end;
    11025: begin version := 0; Result := 0; end;  { MPEG-2.5, uses version=0 }
    12000: begin version := 0; Result := 1; end;  { MPEG-2.5 }
     8000: begin version := 0; Result := 2; end;  { MPEG-2.5 }
  else
    version := 0;
    Result := -1;
  end;
end;

{ Map any sample frequency to the nearest valid MPEG sample rate. }
function map2MP3Frequency(freq: Integer): Integer;
begin
  if freq <=  8000 then Result :=  8000
  else if freq <= 11025 then Result := 11025
  else if freq <= 12000 then Result := 12000
  else if freq <= 16000 then Result := 16000
  else if freq <= 22050 then Result := 22050
  else if freq <= 24000 then Result := 24000
  else if freq <= 32000 then Result := 32000
  else if freq <= 44100 then Result := 44100
  else                       Result := 48000;
end;

{ Number of samples that must be in the internal buffer before a frame
  can be encoded.  Must match MFSIZE constraints. }
function calcNeeded(const cfg: TSessionConfig_t): Integer;
var
  pcm_samples_per_frame: Integer;
begin
  pcm_samples_per_frame := 576 * cfg.mode_gr;
  Result := BLKSIZE + pcm_samples_per_frame - FFTOFFSET;   { for FFT }
  if (512 + pcm_samples_per_frame - 32) > Result then
    Result := 512 + pcm_samples_per_frame - 32;            { for polyphase }
end;

{ -----------------------------------------------------------------------
  filter_coef  (used by lame_init_params_ppflt)
----------------------------------------------------------------------- }
function filter_coef(x: TFloat): TFloat;
begin
  if x > 1.0 then
    Result := 0.0
  else if x <= 0.0 then
    Result := 1.0
  else
    Result := Cos(LAME_PI / 2 * x);
end;

{ -----------------------------------------------------------------------
  lame_init_params_ppflt
  Compute polyphase-filterbank amplitude coefficients for the 32 sub-bands.
----------------------------------------------------------------------- }
procedure lame_init_params_ppflt(gfc: PLameInternalFlags);
var
  cfg:         PSessionConfig_t;
  band:        Integer;
  freq:        TFloat;
  fc1, fc2:    TFloat;
  lowpass_band:  Integer;
  highpass_band: Integer;
  minband, maxband: Integer;
begin
  cfg := @gfc^.cfg;
  lowpass_band  := 32;
  highpass_band := -1;

  if cfg^.lowpass1 > 0 then
  begin
    minband := 999;
    for band := 0 to 31 do
    begin
      freq := band / 31.0;
      if freq >= cfg^.lowpass2 then
      begin
        if lowpass_band > band then lowpass_band := band;
      end;
      if (cfg^.lowpass1 < freq) and (freq < cfg^.lowpass2) then
      begin
        if minband > band then minband := band;
      end;
    end;
    if minband = 999 then
      cfg^.lowpass1 := (lowpass_band - 0.75) / 31.0
    else
      cfg^.lowpass1 := (minband - 0.75) / 31.0;
    cfg^.lowpass2 := lowpass_band / 31.0;
  end;

  if cfg^.highpass2 > 0 then
  begin
    if cfg^.highpass2 < 0.9 * (0.75 / 31.0) then
    begin
      cfg^.highpass1 := 0;
      cfg^.highpass2 := 0;
    end;
  end;

  if cfg^.highpass2 > 0 then
  begin
    maxband := -1;
    for band := 0 to 31 do
    begin
      freq := band / 31.0;
      if freq <= cfg^.highpass1 then
      begin
        if highpass_band < band then highpass_band := band;
      end;
      if (cfg^.highpass1 < freq) and (freq < cfg^.highpass2) then
      begin
        if maxband < band then maxband := band;
      end;
    end;
    cfg^.highpass1 := highpass_band / 31.0;
    if maxband = -1 then
      cfg^.highpass2 := (highpass_band + 0.75) / 31.0
    else
      cfg^.highpass2 := (maxband + 0.75) / 31.0;
  end;

  for band := 0 to 31 do
  begin
    freq := band / 31.0;
    if cfg^.highpass2 > cfg^.highpass1 then
      fc1 := filter_coef((cfg^.highpass2 - freq) /
                         (cfg^.highpass2 - cfg^.highpass1 + 1e-20))
    else
      fc1 := 1.0;
    if cfg^.lowpass2 > cfg^.lowpass1 then
      fc2 := filter_coef((freq - cfg^.lowpass1) /
                         (cfg^.lowpass2 - cfg^.lowpass1 + 1e-20))
    else
      fc2 := 1.0;
    gfc^.sv_enc.amp_filter[band] := fc1 * fc2;
  end;
end;

{ -----------------------------------------------------------------------
  lame_init_qval
  Set internal algorithm flags based on the quality parameter (0=best, 9=fastest).
----------------------------------------------------------------------- }
procedure lame_init_qval(gfp: PLameGlobalFlags);
var
  gfc: PLameInternalFlags;
  cfg: PSessionConfig_t;
begin
  gfc := gfp^.internal_flags;
  cfg := @gfc^.cfg;

  case gfp^.quality of
    9:
    begin
      cfg^.noise_shaping      := 0;
      cfg^.noise_shaping_amp  := 0;
      cfg^.noise_shaping_stop := 0;
      cfg^.use_best_huffman   := 0;
      cfg^.full_outer_loop    := 0;
    end;
    7, 8:
    begin
      if gfp^.quality = 8 then gfp^.quality := 7;
      cfg^.noise_shaping      := 0;
      cfg^.noise_shaping_amp  := 0;
      cfg^.noise_shaping_stop := 0;
      cfg^.use_best_huffman   := 0;
      cfg^.full_outer_loop    := 0;
    end;
    6:
    begin
      if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
      cfg^.noise_shaping_amp  := 0;
      cfg^.noise_shaping_stop := 0;
      if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
      cfg^.use_best_huffman   := 0;
      cfg^.full_outer_loop    := 0;
    end;
    5:
    begin
      if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
      cfg^.noise_shaping_amp  := 0;
      cfg^.noise_shaping_stop := 0;
      if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
      cfg^.use_best_huffman   := 0;
      cfg^.full_outer_loop    := 0;
    end;
    4:
    begin
      if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
      cfg^.noise_shaping_amp  := 0;
      cfg^.noise_shaping_stop := 0;
      if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
      cfg^.use_best_huffman   := 1;
      cfg^.full_outer_loop    := 0;
    end;
    3:
    begin
      if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
      cfg^.noise_shaping_amp  := 1;
      cfg^.noise_shaping_stop := 1;
      if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
      cfg^.use_best_huffman   := 1;
      cfg^.full_outer_loop    := 0;
    end;
    2:
    begin
      if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
      if gfc^.sv_qnt.substep_shaping = 0 then gfc^.sv_qnt.substep_shaping := 2;
      cfg^.noise_shaping_amp  := 1;
      cfg^.noise_shaping_stop := 1;
      if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
      cfg^.use_best_huffman   := 1;
      cfg^.full_outer_loop    := 0;
    end;
    1:
    begin
      if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
      if gfc^.sv_qnt.substep_shaping = 0 then gfc^.sv_qnt.substep_shaping := 2;
      cfg^.noise_shaping_amp  := 2;
      cfg^.noise_shaping_stop := 1;
      if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
      cfg^.use_best_huffman   := 1;
      cfg^.full_outer_loop    := 0;
    end;
    0:
    begin
      if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
      if gfc^.sv_qnt.substep_shaping = 0 then gfc^.sv_qnt.substep_shaping := 2;
      cfg^.noise_shaping_amp  := 2;
      cfg^.noise_shaping_stop := 1;
      if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
      cfg^.use_best_huffman   := 1;
      cfg^.full_outer_loop    := 1;
    end;
  else
    { default quality 3 }
    if cfg^.noise_shaping = 0 then cfg^.noise_shaping := 1;
    cfg^.noise_shaping_amp  := 1;
    cfg^.noise_shaping_stop := 1;
    if cfg^.subblock_gain = -1 then cfg^.subblock_gain := 1;
    cfg^.use_best_huffman   := 1;
    cfg^.full_outer_loop    := 0;
  end;
end;

{ -----------------------------------------------------------------------
  optimum_samplefreq
  Choose the lowest MPEG sample rate that is >= the input sample rate
  and still above the lowpass frequency.
----------------------------------------------------------------------- }
function optimum_samplefreq(lowpassfreq, input_samplefreq: Integer): Integer;
var
  suggested: Integer;
begin
  suggested := 44100;
  if input_samplefreq >= 48000 then suggested := 48000
  else if input_samplefreq >= 44100 then suggested := 44100
  else if input_samplefreq >= 32000 then suggested := 32000
  else if input_samplefreq >= 24000 then suggested := 24000
  else if input_samplefreq >= 22050 then suggested := 22050
  else if input_samplefreq >= 16000 then suggested := 16000
  else if input_samplefreq >= 12000 then suggested := 12000
  else if input_samplefreq >= 11025 then suggested := 11025
  else if input_samplefreq >=  8000 then suggested :=  8000;

  if lowpassfreq = -1 then
  begin
    Result := suggested;
    Exit;
  end;

  if lowpassfreq <= 15960 then suggested := 44100;
  if lowpassfreq <= 15250 then suggested := 32000;
  if lowpassfreq <= 11220 then suggested := 24000;
  if lowpassfreq <=  9970 then suggested := 22050;
  if lowpassfreq <=  7230 then suggested := 16000;
  if lowpassfreq <=  5420 then suggested := 12000;
  if lowpassfreq <=  4510 then suggested := 11025;
  if lowpassfreq <=  3970 then suggested :=  8000;

  if input_samplefreq < suggested then
  begin
    if input_samplefreq > 44100 then begin Result := 48000; Exit; end;
    if input_samplefreq > 32000 then begin Result := 44100; Exit; end;
    if input_samplefreq > 24000 then begin Result := 32000; Exit; end;
    if input_samplefreq > 22050 then begin Result := 24000; Exit; end;
    if input_samplefreq > 16000 then begin Result := 22050; Exit; end;
    if input_samplefreq > 12000 then begin Result := 16000; Exit; end;
    if input_samplefreq > 11025 then begin Result := 12000; Exit; end;
    if input_samplefreq >  8000 then begin Result := 11025; Exit; end;
    Result := 8000;
    Exit;
  end;
  Result := suggested;
end;

{ -----------------------------------------------------------------------
  optimum_bandwidth
  Suggest a lowpass cutoff frequency appropriate for the given bitrate.
----------------------------------------------------------------------- }
function optimum_bandwidth(bitrate: Cardinal): Double;
type
  TBandPass = record bitrate, lowpass: Integer; end;
const
  freq_map: array[0..16] of TBandPass = (
    (bitrate:   8; lowpass:  2000),
    (bitrate:  16; lowpass:  3700),
    (bitrate:  24; lowpass:  3900),
    (bitrate:  32; lowpass:  5500),
    (bitrate:  40; lowpass:  7000),
    (bitrate:  48; lowpass:  7500),
    (bitrate:  56; lowpass: 10000),
    (bitrate:  64; lowpass: 11000),
    (bitrate:  80; lowpass: 13500),
    (bitrate:  96; lowpass: 15100),
    (bitrate: 112; lowpass: 15600),
    (bitrate: 128; lowpass: 17000),
    (bitrate: 160; lowpass: 17500),
    (bitrate: 192; lowpass: 18600),
    (bitrate: 224; lowpass: 19400),
    (bitrate: 256; lowpass: 19700),
    (bitrate: 320; lowpass: 20500)
  );
var
  b: Integer;
  upper_range_kbps, lower_range_kbps: Integer;
  upper_range, lower_range: Integer;
begin
  upper_range_kbps := freq_map[16].bitrate;
  upper_range       := 16;
  lower_range_kbps := freq_map[16].bitrate;
  lower_range       := 16;

  for b := 0 to 15 do
  begin
    if Max(bitrate, Cardinal(freq_map[b + 1].bitrate)) <> bitrate then
    begin
      upper_range_kbps := freq_map[b + 1].bitrate;
      upper_range      := b + 1;
      lower_range_kbps := freq_map[b].bitrate;
      lower_range      := b;
      Break;
    end;
  end;

  { choose closest range }
  if (upper_range_kbps - Integer(bitrate)) > (Integer(bitrate) - lower_range_kbps) then
    Result := freq_map[lower_range].lowpass
  else
    Result := freq_map[upper_range].lowpass;
end;

{ -----------------------------------------------------------------------
  update_inbuffer_size
  Ensure the in_buffer arrays are large enough for nsamples.
----------------------------------------------------------------------- }
function update_inbuffer_size(gfc: PLameInternalFlags; nsamples: Integer): Integer;
var
  esv: PEncStateVar_t;
begin
  esv := @gfc^.sv_enc;
  if (esv^.in_buffer_0 = nil) or (esv^.in_buffer_nsamples < nsamples) then
  begin
    if esv^.in_buffer_0 <> nil then FreeMem(esv^.in_buffer_0);
    if esv^.in_buffer_1 <> nil then FreeMem(esv^.in_buffer_1);
    esv^.in_buffer_0 := AllocMem(nsamples * SizeOf(TSample));
    esv^.in_buffer_1 := AllocMem(nsamples * SizeOf(TSample));
    esv^.in_buffer_nsamples := nsamples;
  end;
  if (esv^.in_buffer_0 = nil) or (esv^.in_buffer_1 = nil) then
  begin
    if esv^.in_buffer_0 <> nil then FreeMem(esv^.in_buffer_0);
    if esv^.in_buffer_1 <> nil then FreeMem(esv^.in_buffer_1);
    esv^.in_buffer_0 := nil;
    esv^.in_buffer_1 := nil;
    esv^.in_buffer_nsamples := 0;
    Result := -2;
  end
  else
    Result := 0;
end;

{ -----------------------------------------------------------------------
  lame_encode_buffer_sample_t
  Inner encoding loop: reads samples already in esv->in_buffer_0/1,
  fills mfbuf, and encodes complete frames.
----------------------------------------------------------------------- }
function lame_encode_buffer_sample_t(gfc: PLameInternalFlags;
                                      nsamples: Integer;
                                      mp3buf: PByte;
                                      mp3buf_size: Integer): Integer;
var
  cfg:                PSessionConfig_t;
  esv:                PEncStateVar_t;
  pcm_samples_per_frame: Integer;
  mp3size:            Integer;
  mp3out:             Integer;
  ret:                Integer;
  ch, i:              Integer;
  n_copy:             Integer;
  buf_size:           Integer;
  mfbuf0, mfbuf1:     PSampleArray;
  ib0, ib1:           PSampleArray;
  ibpos:              Integer;
  mf_needed:          Integer;
  MaxInt32:           Integer;
begin
  MaxInt32 := High(Integer);
  cfg := @gfc^.cfg;
  esv := @gfc^.sv_enc;
  pcm_samples_per_frame := 576 * cfg^.mode_gr;
  mf_needed := calcNeeded(cfg^);

  if gfc^.class_id <> LAME_ID then
  begin
    Result := -3;
    Exit;
  end;

  if nsamples = 0 then
  begin
    Result := 0;
    Exit;
  end;

  mp3size := 0;

  { flush any previously encoded frames sitting in the bit buffer }
  if mp3buf_size = 0 then buf_size := MaxInt32 else buf_size := mp3buf_size;
  mp3out := copy_buffer(gfc, mp3buf, buf_size, 0);
  if mp3out < 0 then
  begin
    Result := mp3out;
    Exit;
  end;
  Inc(mp3buf, mp3out);
  Inc(mp3size, mp3out);

  mfbuf0 := PSampleArray(Pointer(@esv^.mfbuf[0, 0]));
  mfbuf1 := PSampleArray(Pointer(@esv^.mfbuf[1, 0]));
  ib0    := PSampleArray(esv^.in_buffer_0);
  ib1    := PSampleArray(esv^.in_buffer_1);
  ibpos  := 0;

  while nsamples > 0 do
  begin
    { copy min(pcm_samples_per_frame, nsamples) into mfbuf }
    if pcm_samples_per_frame < nsamples then n_copy := pcm_samples_per_frame
    else                                     n_copy := nsamples;

    for ch := 0 to cfg^.channels_out - 1 do
    begin
      if ch = 0 then
        Move(ib0^[ibpos], mfbuf0^[esv^.mf_size], n_copy * SizeOf(TSample))
      else
        Move(ib1^[ibpos], mfbuf1^[esv^.mf_size], n_copy * SizeOf(TSample));
    end;

    Dec(nsamples, n_copy);
    Inc(ibpos, n_copy);
    Inc(esv^.mf_size, n_copy);
    if esv^.mf_samples_to_encode < 1 then
      esv^.mf_samples_to_encode := ENCDELAY + POSTDELAY;
    Inc(esv^.mf_samples_to_encode, n_copy);

    { encode frame(s) while buffer is full enough }
    while esv^.mf_size >= mf_needed do
    begin
      buf_size := mp3buf_size - mp3size;
      if mp3buf_size = 0 then buf_size := MaxInt32;

      ret := lame_encode_mp3_frame(gfc,
                                    @mfbuf0^[0], @mfbuf1^[0],
                                    mp3buf, buf_size);
      if ret < 0 then
      begin
        Result := ret;
        Exit;
      end;
      Inc(mp3buf, ret);
      Inc(mp3size, ret);

      { slide old samples out of mfbuf }
      Dec(esv^.mf_size, pcm_samples_per_frame);
      Dec(esv^.mf_samples_to_encode, pcm_samples_per_frame);
      for ch := 0 to cfg^.channels_out - 1 do
        for i := 0 to esv^.mf_size - 1 do
        begin
          if ch = 0 then
            mfbuf0^[i] := mfbuf0^[i + pcm_samples_per_frame]
          else
            mfbuf1^[i] := mfbuf1^[i + pcm_samples_per_frame];
        end;
    end;
  end;

  Result := mp3size;
end;

{ -----------------------------------------------------------------------
  lame_copy_inbuffer_float
  Copy float PCM into in_buffer, applying the pcm_transform matrix and
  an optional normalisation factor.
----------------------------------------------------------------------- }
procedure lame_copy_inbuffer_float(gfc: PLameInternalFlags;
                                    l: PSingle; r: PSingle;
                                    nsamples: Integer;
                                    jump: Integer;
                                    norm: TFloat);
var
  cfg:  PSessionConfig_t;
  esv:  PEncStateVar_t;
  ib0:  PSampleArray;
  ib1:  PSampleArray;
  m00, m01, m10, m11: TFloat;
  xl, xr, u, v: TFloat;
  i:    Integer;
  lp, rp: PSingle;
begin
  cfg := @gfc^.cfg;
  esv := @gfc^.sv_enc;
  ib0 := PSampleArray(esv^.in_buffer_0);
  ib1 := PSampleArray(esv^.in_buffer_1);

  m00 := norm * cfg^.pcm_transform[0][0];
  m01 := norm * cfg^.pcm_transform[0][1];
  m10 := norm * cfg^.pcm_transform[1][0];
  m11 := norm * cfg^.pcm_transform[1][1];

  lp := l;
  rp := r;
  for i := 0 to nsamples - 1 do
  begin
    xl := lp^;
    xr := rp^;
    u := xl * m00 + xr * m01;
    v := xl * m10 + xr * m11;
    ib0^[i] := u;
    ib1^[i] := v;
    Inc(lp, jump);
    Inc(rp, jump);
  end;
end;

{ -----------------------------------------------------------------------
  lame_copy_inbuffer_short
  Copy 16-bit PCM into in_buffer with transform and optional scale.
----------------------------------------------------------------------- }
procedure lame_copy_inbuffer_short(gfc: PLameInternalFlags;
                                    l: PSmallInt; r: PSmallInt;
                                    nsamples: Integer;
                                    jump: Integer;
                                    norm: TFloat);
var
  cfg:  PSessionConfig_t;
  esv:  PEncStateVar_t;
  ib0:  PSampleArray;
  ib1:  PSampleArray;
  m00, m01, m10, m11: TFloat;
  xl, xr, u, v: TFloat;
  i:    Integer;
  lp, rp: PSmallInt;
begin
  cfg := @gfc^.cfg;
  esv := @gfc^.sv_enc;
  ib0 := PSampleArray(esv^.in_buffer_0);
  ib1 := PSampleArray(esv^.in_buffer_1);

  m00 := norm * cfg^.pcm_transform[0][0];
  m01 := norm * cfg^.pcm_transform[0][1];
  m10 := norm * cfg^.pcm_transform[1][0];
  m11 := norm * cfg^.pcm_transform[1][1];

  lp := l;
  rp := r;
  for i := 0 to nsamples - 1 do
  begin
    xl := lp^;
    xr := rp^;
    u := xl * m00 + xr * m01;
    v := xl * m10 + xr * m11;
    ib0^[i] := u;
    ib1^[i] := v;
    Inc(lp, jump);
    Inc(rp, jump);
  end;
end;

{ -----------------------------------------------------------------------
  freegfc
  Free all sub-allocations inside gfc (does not free gfc itself).
----------------------------------------------------------------------- }
procedure freegfc(gfc: PLameInternalFlags);
begin
  if gfc = nil then Exit;
  lame_free_ath(gfc^.ATH);
  lame_free_psy(gfc^.cd_psy);
  if gfc^.sv_enc.in_buffer_0 <> nil then
  begin
    FreeMem(gfc^.sv_enc.in_buffer_0);
    gfc^.sv_enc.in_buffer_0 := nil;
  end;
  if gfc^.sv_enc.in_buffer_1 <> nil then
  begin
    FreeMem(gfc^.sv_enc.in_buffer_1);
    gfc^.sv_enc.in_buffer_1 := nil;
  end;
  if gfc^.bs.buf <> nil then
  begin
    FreeMem(gfc^.bs.buf);
    gfc^.bs.buf := nil;
  end;
  { free cd_psy s3 arrays are handled by lame_free_psy above }
  Dispose(gfc);
end;

{ -----------------------------------------------------------------------
  lame_init
----------------------------------------------------------------------- }
function lame_init: PLameGlobalFlags;
var
  gfp: PLameGlobalFlags;
  gfc: PLameInternalFlags;
begin
  init_log_table;

  New(gfp);
  FillChar(gfp^, SizeOf(TLameGlobalFlags), 0);

  gfp^.class_id       := LAME_ID;
  gfp^.samplerate_in  := 44100;
  gfp^.num_channels   := 2;
  gfp^.scale          := 1.0;
  gfp^.scale_left     := 1.0;
  gfp^.scale_right    := 1.0;
  gfp^.original       := 1;
  gfp^.mode           := NOT_SET;
  gfp^.VBR            := vbr_off;
  gfp^.VBR_q         := 4;
  gfp^.VBR_mean_bitrate_kbps := 128;
  gfp^.brate          := 128;
  gfp^.quality        := -1;            { -1 = use default (3) }
  gfp^.short_blocks   := short_block_not_set;
  gfp^.lowpassfreq    := 0;
  gfp^.lowpasswidth   := -1;
  gfp^.highpassfreq   := 0;
  gfp^.highpasswidth  := -1;
  gfp^.ATHcurve       := -1;
  gfp^.ATHtype        := -1;
  gfp^.athaa_type     := -1;
  gfp^.useTemporal    := -1;
  gfp^.interChRatio   := -1;
  gfp^.msfix          := -1;
  gfp^.quant_comp     := -1;
  gfp^.quant_comp_short := -1;
  gfp^.strict_ISO     := Ord(MDB_MAXIMUM);
  gfp^.lame_allocated_gfp := 1;

  { allocate and zero-init internal flags }
  New(gfc);
  FillChar(gfc^, SizeOf(TLameInternalFlags), 0);
  gfp^.internal_flags := gfc;

  { set initial sv_qnt defaults }
  gfc^.sv_qnt.OldValue[0]   := 180;
  gfc^.sv_qnt.OldValue[1]   := 180;
  gfc^.sv_qnt.CurrentStep[0] := 4;
  gfc^.sv_qnt.CurrentStep[1] := 4;
  gfc^.sv_qnt.masking_lower  := 1.0;

  { initial mf state }
  gfc^.sv_enc.mf_samples_to_encode := ENCDELAY + POSTDELAY;
  gfc^.sv_enc.mf_size               := ENCDELAY - MDCTDELAY;

  gfc^.ov_enc.encoder_padding := 0;
  gfc^.ov_enc.encoder_delay   := ENCDELAY;

  { allocate ATH struct }
  gfc^.ATH := lame_calloc_ath;
  if gfc^.ATH = nil then
  begin
    Dispose(gfc);
    Dispose(gfp);
    Result := nil;
    Exit;
  end;

  gfc^.cfg.vbr_min_bitrate_index := 1;
  gfc^.cfg.vbr_max_bitrate_index := 13;

  Result := gfp;
end;

{ -----------------------------------------------------------------------
  lame_init_params
----------------------------------------------------------------------- }
function lame_init_params(gfp: PLameGlobalFlags): Integer;
var
  gfc:     PLameInternalFlags;
  cfg:     PSessionConfig_t;
  i, j, k: Integer;
  lowpass: Double;
  sfb_size, sfb_start: Integer;
  exp_bits: Integer;
  adj_value: TFloat;
  m:       array[0..1, 0..1] of TFloat;
begin
  if gfp = nil then begin Result := -1; Exit; end;
  if gfp^.class_id <> LAME_ID then begin Result := -1; Exit; end;

  gfc := gfp^.internal_flags;
  if gfc = nil then begin Result := -1; Exit; end;

  { mark init in progress }
  gfc^.class_id := LAME_ID;
  gfc^.lame_init_params_successful := 0;

  if gfp^.samplerate_in < 1 then begin Result := -1; Exit; end;
  if (gfp^.num_channels < 1) or (gfp^.num_channels > 2) then begin Result := -1; Exit; end;

  cfg := @gfc^.cfg;

  { ---- basic flags ---- }
  cfg^.enforce_min_bitrate := gfp^.VBR_hard_min;
  cfg^.analysis            := gfp^.analysis;
  cfg^.vbr                 := gfp^.VBR;
  cfg^.error_protection    := gfp^.error_protection;
  cfg^.copyright           := gfp^.copyright;
  cfg^.original            := gfp^.original;
  cfg^.extension           := gfp^.extension;
  cfg^.emphasis            := gfp^.emphasis;
  cfg^.free_format         := gfp^.free_format;

  { ---- channel count ---- }
  cfg^.channels_in := gfp^.num_channels;
  if cfg^.channels_in = 1 then gfp^.mode := MONO;
  if gfp^.mode = MONO then cfg^.channels_out := 1 else cfg^.channels_out := 2;
  if gfp^.mode <> JOINT_STEREO then gfp^.force_ms := 0;
  cfg^.force_ms := gfp^.force_ms;

  { ---- VBR bitrate defaults ---- }
  if (cfg^.vbr = vbr_off) and (gfp^.VBR_mean_bitrate_kbps <> 128) and (gfp^.brate = 0) then
    gfp^.brate := gfp^.VBR_mean_bitrate_kbps;
  if (cfg^.vbr = vbr_off) and (gfp^.brate = 0) then
    gfp^.compression_ratio := 11.025;

  { ---- output samplerate ---- }
  if gfp^.samplerate_out = 0 then
  begin
    if cfg^.vbr = vbr_off then
    begin
      lowpass := optimum_bandwidth(gfp^.brate);
      if gfp^.mode = MONO then lowpass := lowpass * 1.5;
      if gfp^.lowpassfreq = 0 then gfp^.lowpassfreq := Round(lowpass);
    end
    else
    begin
      if gfp^.lowpassfreq = 0 then gfp^.lowpassfreq := 17000; { CBR default }
    end;
    if 2 * gfp^.lowpassfreq > gfp^.samplerate_in then
      gfp^.lowpassfreq := gfp^.samplerate_in div 2;
    gfp^.samplerate_out := optimum_samplefreq(gfp^.lowpassfreq, gfp^.samplerate_in);
  end;

  gfp^.lowpassfreq := Min(20500, gfp^.lowpassfreq);
  gfp^.lowpassfreq := Min(gfp^.samplerate_out div 2, gfp^.lowpassfreq);

  if cfg^.vbr = vbr_off then
    gfp^.compression_ratio :=
      gfp^.samplerate_out * 16 * cfg^.channels_out / (1000.0 * gfp^.brate);

  { ---- mode ---- }
  if gfp^.mode = NOT_SET then gfp^.mode := JOINT_STEREO;
  cfg^.mode := gfp^.mode;

  { ---- samplerate and version ---- }
  cfg^.samplerate_in  := gfp^.samplerate_in;
  cfg^.samplerate_out := gfp^.samplerate_out;
  cfg^.samplerate_index := SmpFrqIndex(cfg^.samplerate_out, cfg^.version);
  if cfg^.samplerate_index < 0 then begin Result := -1; Exit; end;

  cfg^.mode_gr := 1;
  if cfg^.samplerate_out > 24000 then cfg^.mode_gr := 2;

  { ---- highpass filter ---- }
  if cfg^.highpassfreq > 0 then
  begin
    cfg^.highpass1 := 2.0 * cfg^.highpassfreq;
    if gfp^.highpasswidth >= 0 then
      cfg^.highpass2 := 2.0 * (cfg^.highpassfreq + gfp^.highpasswidth)
    else
      cfg^.highpass2 := 2.0 * cfg^.highpassfreq;
    cfg^.highpass1 := cfg^.highpass1 / cfg^.samplerate_out;
    cfg^.highpass2 := cfg^.highpass2 / cfg^.samplerate_out;
  end
  else
  begin
    cfg^.highpass1 := 0;
    cfg^.highpass2 := 0;
  end;

  { ---- lowpass filter ---- }
  cfg^.lowpass1 := 0;
  cfg^.lowpass2 := 0;
  cfg^.lowpassfreq  := gfp^.lowpassfreq;
  cfg^.highpassfreq := gfp^.highpassfreq;
  if (cfg^.lowpassfreq > 0) and
     (cfg^.lowpassfreq < cfg^.samplerate_out div 2) then
  begin
    cfg^.lowpass2 := 2.0 * cfg^.lowpassfreq / cfg^.samplerate_out;
    if gfp^.lowpasswidth >= 0 then
    begin
      cfg^.lowpass1 := 2.0 * (cfg^.lowpassfreq - gfp^.lowpasswidth) /
                        cfg^.samplerate_out;
      if cfg^.lowpass1 < 0 then cfg^.lowpass1 := 0;
    end
    else
      cfg^.lowpass1 := cfg^.lowpass2;
  end;

  { ---- polyphase filterbank amplitude coefficients ---- }
  lame_init_params_ppflt(gfc);

  { ---- bitrate index ---- }
  if cfg^.vbr = vbr_off then
  begin
    gfp^.brate := FindNearestBitrate(gfp^.brate, cfg^.version, cfg^.samplerate_out);
    gfc^.ov_enc.bitrate_index :=
      BitrateIndex(gfp^.brate, cfg^.version, cfg^.samplerate_out);
    if gfc^.ov_enc.bitrate_index <= 0 then
      gfc^.ov_enc.bitrate_index := 8;
  end
  else
    gfc^.ov_enc.bitrate_index := 1;

  { ---- bitstream init ---- }
  init_bit_stream_w(gfc);

  { ---- scalefactor band tables ---- }
  j := cfg^.samplerate_index + 3 * cfg^.version +
       6 * Ord(cfg^.samplerate_out < 16000);

  for i := 0 to SBMAX_l do
    gfc^.scalefac_band.l[i] := sfBandIndex_l[j][i];

  { psfb21 pseudo sub-bands above sfb21 }
  sfb_size  := (gfc^.scalefac_band.l[22] - gfc^.scalefac_band.l[21]) div PSFB21;
  for i := 0 to PSFB21 - 1 do
  begin
    sfb_start := gfc^.scalefac_band.l[21] + i * sfb_size;
    gfc^.scalefac_band.psfb21[i] := sfb_start;
  end;
  gfc^.scalefac_band.psfb21[PSFB21] := 576;

  for i := 0 to SBMAX_s do
    gfc^.scalefac_band.s[i] := sfBandIndex_s[j][i];

  { psfb12 pseudo sub-bands above sfb12 }
  sfb_size  := (gfc^.scalefac_band.s[13] - gfc^.scalefac_band.s[12]) div PSFB12;
  for i := 0 to PSFB12 - 1 do
  begin
    sfb_start := gfc^.scalefac_band.s[12] + i * sfb_size;
    gfc^.scalefac_band.psfb12[i] := sfb_start;
  end;
  gfc^.scalefac_band.psfb12[PSFB12] := 192;

  { ---- side information length ---- }
  if cfg^.mode_gr = 2 then  { MPEG-1 }
  begin
    if cfg^.channels_out = 1 then cfg^.sideinfo_len := 4 + 17
    else                           cfg^.sideinfo_len := 4 + 32;
  end
  else                       { MPEG-2 }
  begin
    if cfg^.channels_out = 1 then cfg^.sideinfo_len := 4 + 9
    else                           cfg^.sideinfo_len := 4 + 17;
  end;
  if cfg^.error_protection <> 0 then
    Inc(cfg^.sideinfo_len, 2);

  { ---- pefirbuf initialisation ---- }
  for k := 0 to 18 do
    gfc^.sv_enc.pefirbuf[k] := 700 * cfg^.mode_gr * cfg^.channels_out;

  { ---- ATH type defaults ---- }
  if gfp^.ATHtype = -1 then gfp^.ATHtype := 4;
  if gfp^.ATHcurve < 0 then gfp^.ATHcurve := 4;

  { ---- misc config ---- }
  if gfp^.quant_comp < 0      then gfp^.quant_comp       := 1;
  if gfp^.quant_comp_short < 0 then gfp^.quant_comp_short := 0;
  if gfp^.msfix < 0           then gfp^.msfix            := 0;
  if gfp^.interChRatio < 0    then gfp^.interChRatio      := 0;
  if gfp^.useTemporal < 0     then gfp^.useTemporal       := 1;

  { enable nspsytune psy model }
  gfp^.exp_nspsytune := gfp^.exp_nspsytune or 1;

  { ---- VBR bitrate range ---- }
  if cfg^.vbr <> vbr_off then
  begin
    cfg^.vbr_min_bitrate_index := 1;
    cfg^.vbr_max_bitrate_index := 14;
    if cfg^.samplerate_out < 16000 then
      cfg^.vbr_max_bitrate_index := 8;
    if gfp^.VBR_min_bitrate_kbps > 0 then
    begin
      gfp^.VBR_min_bitrate_kbps :=
        FindNearestBitrate(gfp^.VBR_min_bitrate_kbps, cfg^.version, cfg^.samplerate_out);
      cfg^.vbr_min_bitrate_index :=
        BitrateIndex(gfp^.VBR_min_bitrate_kbps, cfg^.version, cfg^.samplerate_out);
      if cfg^.vbr_min_bitrate_index < 0 then
        cfg^.vbr_min_bitrate_index := 1;
    end;
    if gfp^.VBR_max_bitrate_kbps > 0 then
    begin
      gfp^.VBR_max_bitrate_kbps :=
        FindNearestBitrate(gfp^.VBR_max_bitrate_kbps, cfg^.version, cfg^.samplerate_out);
      cfg^.vbr_max_bitrate_index :=
        BitrateIndex(gfp^.VBR_max_bitrate_kbps, cfg^.version, cfg^.samplerate_out);
      if cfg^.vbr_max_bitrate_index < 0 then
      begin
        if cfg^.samplerate_out < 16000 then cfg^.vbr_max_bitrate_index := 8
        else                                cfg^.vbr_max_bitrate_index := 14;
      end;
    end;
    gfp^.VBR_min_bitrate_kbps :=
      bitrate_table[cfg^.version][cfg^.vbr_min_bitrate_index];
    gfp^.VBR_max_bitrate_kbps :=
      bitrate_table[cfg^.version][cfg^.vbr_max_bitrate_index];
    gfp^.VBR_mean_bitrate_kbps :=
      Min(bitrate_table[cfg^.version][cfg^.vbr_max_bitrate_index],
          gfp^.VBR_mean_bitrate_kbps);
    gfp^.VBR_mean_bitrate_kbps :=
      Max(bitrate_table[cfg^.version][cfg^.vbr_min_bitrate_index],
          gfp^.VBR_mean_bitrate_kbps);
  end;

  cfg^.preset               := gfp^.preset;
  cfg^.write_lame_tag        := gfp^.write_lame_tag;
  cfg^.disable_reservoir     := gfp^.disable_reservoir;
  cfg^.avg_bitrate           := gfp^.brate;
  cfg^.vbr_avg_bitrate_kbps  := gfp^.VBR_mean_bitrate_kbps;
  cfg^.compression_ratio     := gfp^.compression_ratio;

  { ---- quality-based algorithm flags ---- }
  cfg^.noise_shaping  := 0;
  cfg^.subblock_gain  := -1;
  if gfp^.quality < 0 then gfp^.quality := 3;   { LAME_DEFAULT_QUALITY }
  lame_init_qval(gfp);

  { ---- masking adjust ---- }
  gfc^.sv_qnt.mask_adjust       := gfp^.maskingadjust;
  gfc^.sv_qnt.mask_adjust_short := gfp^.maskingadjust_short;

  { ---- ATH ---- }
  if gfp^.athaa_type < 0 then gfc^.ATH^.use_adjust := 3
  else                         gfc^.ATH^.use_adjust := gfp^.athaa_type;
  gfc^.ATH^.aa_sensitivity_p := Power(10.0, gfp^.athaa_sensitivity / -10.0);

  { ---- short block mode ---- }
  if gfp^.short_blocks = short_block_not_set then
    gfp^.short_blocks := short_block_allowed;
  if (gfp^.short_blocks = short_block_allowed) and
     ((cfg^.mode = JOINT_STEREO) or (cfg^.mode = STEREO)) then
    gfp^.short_blocks := short_block_coupled;
  cfg^.short_blocks := gfp^.short_blocks;

  { ---- misc ---- }
  cfg^.quant_comp              := gfp^.quant_comp;
  cfg^.quant_comp_short        := gfp^.quant_comp_short;
  cfg^.use_temporal_masking_effect := gfp^.useTemporal;
  if cfg^.mode = JOINT_STEREO then
    cfg^.use_safe_joint_stereo := gfp^.exp_nspsytune and 2
  else
    cfg^.use_safe_joint_stereo := 0;
  cfg^.interChRatio := gfp^.interChRatio;
  cfg^.msfix        := gfp^.msfix;
  cfg^.ATH_offset_db     := 0 - gfp^.ATH_lower_db;
  cfg^.ATH_offset_factor := Power(10.0, cfg^.ATH_offset_db * 0.1);
  cfg^.ATHcurve  := gfp^.ATHcurve;
  cfg^.ATHtype   := gfp^.ATHtype;
  cfg^.ATHonly   := gfp^.ATHonly;
  cfg^.ATHshort  := gfp^.ATHshort;
  cfg^.noATH     := gfp^.noATH;
  cfg^.ATHfixpoint := gfp^.ATHcurve;

  { ---- sfb21 extra (VBR only) ---- }
  gfc^.sv_qnt.sfb21_extra := 0;
  if (cfg^.vbr = vbr_rh) or (cfg^.vbr = vbr_mt) or (cfg^.vbr = vbr_mtrh) then
  begin
    if gfp^.experimentalY = 0 then
      gfc^.sv_qnt.sfb21_extra := Ord(cfg^.samplerate_out > 44000);
  end;

  { ---- nspsytune band adjustments ---- }
  exp_bits := gfp^.exp_nspsytune;
  adj_value := (exp_bits shr 2) and 63;
  if adj_value >= 32 then adj_value := adj_value - 64;
  cfg^.adjust_bass := adj_value * 0.25;

  adj_value := (exp_bits shr 8) and 63;
  if adj_value >= 32 then adj_value := adj_value - 64;
  cfg^.adjust_alto := adj_value * 0.25;

  adj_value := (exp_bits shr 14) and 63;
  if adj_value >= 32 then adj_value := adj_value - 64;
  cfg^.adjust_treble := adj_value * 0.25;

  adj_value := (exp_bits shr 20) and 63;
  if adj_value >= 32 then adj_value := adj_value - 64;
  cfg^.adjust_sfb21_db := adj_value * 0.25 + cfg^.adjust_treble;

  { ---- PCM transform matrix ---- }
  m[0][0] := gfp^.scale * gfp^.scale_left;
  m[0][1] := gfp^.scale * gfp^.scale_left;     { cross terms start at 0 }
  m[1][0] := gfp^.scale * gfp^.scale_right;
  m[1][1] := gfp^.scale * gfp^.scale_right;
  { identity by default (left -> left, right -> right) }
  m[0][0] := gfp^.scale * gfp^.scale_left;
  m[0][1] := 0;
  m[1][0] := 0;
  m[1][1] := gfp^.scale * gfp^.scale_right;
  { stereo->mono downmix }
  if (cfg^.channels_in = 2) and (cfg^.channels_out = 1) then
  begin
    m[0][0] := 0.5 * gfp^.scale * gfp^.scale_left;
    m[0][1] := 0.5 * gfp^.scale * gfp^.scale_right;
    m[1][0] := 0;
    m[1][1] := 0;
  end;
  cfg^.pcm_transform[0][0] := m[0][0];
  cfg^.pcm_transform[0][1] := m[0][1];
  cfg^.pcm_transform[1][0] := m[1][0];
  cfg^.pcm_transform[1][1] := m[1][1];

  { ---- slot lag for padding ---- }
  gfc^.sv_enc.slot_lag  := 0;
  gfc^.sv_enc.frac_SpF  := 0;
  if cfg^.vbr = vbr_off then
  begin
    gfc^.sv_enc.frac_SpF :=
      ((cfg^.version + 1) * 72000.0 * cfg^.avg_bitrate) mod cfg^.samplerate_out;
    gfc^.sv_enc.slot_lag := gfc^.sv_enc.frac_SpF;
  end;

  { ---- buffer constraint ---- }
  cfg^.buffer_constraint :=
    get_max_frame_buffer_size_by_constraint(cfg^, gfp^.strict_ISO);

  { ---- initialise sub-systems ---- }
  gfc^.ov_enc.frame_number := 0;
  FillChar(gfc^.ov_enc.bitrate_channelmode_hist,
           SizeOf(gfc^.ov_enc.bitrate_channelmode_hist), 0);
  FillChar(gfc^.ov_enc.bitrate_blocktype_hist,
           SizeOf(gfc^.ov_enc.bitrate_blocktype_hist), 0);

  iteration_init(gfc);
  if psymodel_init(gfp) < 0 then begin Result := -1; Exit; end;

  { set choose_table pointer to non-MMX path }
  { (init_xrpow_core_init sets the function pointer on first call) }

  gfc^.lame_init_params_successful := 1;
  Result := 0;
end;

{ -----------------------------------------------------------------------
  lame_encode_buffer_float
----------------------------------------------------------------------- }
function lame_encode_buffer_float(gfp: PLameGlobalFlags;
                                   pcm_l: PSingle;
                                   pcm_r: PSingle;
                                   nsamples: Integer;
                                   mp3buf: PByte;
                                   mp3buf_size: Integer): Integer;
var
  gfc: PLameInternalFlags;
  cfg: PSessionConfig_t;
begin
  if gfp = nil then begin Result := -3; Exit; end;
  if gfp^.class_id <> LAME_ID then begin Result := -3; Exit; end;
  gfc := gfp^.internal_flags;
  if gfc = nil then begin Result := -3; Exit; end;
  if gfc^.lame_init_params_successful <= 0 then begin Result := -3; Exit; end;
  cfg := @gfc^.cfg;
  if nsamples = 0 then begin Result := 0; Exit; end;

  if update_inbuffer_size(gfc, nsamples) <> 0 then
  begin
    Result := -2;
    Exit;
  end;

  { mono: use left channel for both; stereo: normal }
  if cfg^.channels_in > 1 then
  begin
    if (pcm_l = nil) or (pcm_r = nil) then begin Result := 0; Exit; end;
    lame_copy_inbuffer_float(gfc, pcm_l, pcm_r, nsamples, 1, 1.0);
  end
  else
  begin
    if pcm_l = nil then begin Result := 0; Exit; end;
    lame_copy_inbuffer_float(gfc, pcm_l, pcm_l, nsamples, 1, 1.0);
  end;

  Result := lame_encode_buffer_sample_t(gfc, nsamples, mp3buf, mp3buf_size);
end;

{ -----------------------------------------------------------------------
  lame_encode_buffer  (16-bit PCM input)
----------------------------------------------------------------------- }
function lame_encode_buffer(gfp: PLameGlobalFlags;
                             pcm_l: PSmallInt;
                             pcm_r: PSmallInt;
                             nsamples: Integer;
                             mp3buf: PByte;
                             mp3buf_size: Integer): Integer;
var
  gfc: PLameInternalFlags;
  cfg: PSessionConfig_t;
begin
  if gfp = nil then begin Result := -3; Exit; end;
  if gfp^.class_id <> LAME_ID then begin Result := -3; Exit; end;
  gfc := gfp^.internal_flags;
  if gfc = nil then begin Result := -3; Exit; end;
  if gfc^.lame_init_params_successful <= 0 then begin Result := -3; Exit; end;
  cfg := @gfc^.cfg;
  if nsamples = 0 then begin Result := 0; Exit; end;

  if update_inbuffer_size(gfc, nsamples) <> 0 then
  begin
    Result := -2;
    Exit;
  end;

  if cfg^.channels_in > 1 then
  begin
    if (pcm_l = nil) or (pcm_r = nil) then begin Result := 0; Exit; end;
    lame_copy_inbuffer_short(gfc, pcm_l, pcm_r, nsamples, 1, 1.0);
  end
  else
  begin
    if pcm_l = nil then begin Result := 0; Exit; end;
    lame_copy_inbuffer_short(gfc, pcm_l, pcm_l, nsamples, 1, 1.0);
  end;

  Result := lame_encode_buffer_sample_t(gfc, nsamples, mp3buf, mp3buf_size);
end;

{ -----------------------------------------------------------------------
  lame_encode_flush
----------------------------------------------------------------------- }
function lame_encode_flush(gfp: PLameGlobalFlags;
                            mp3buf: PByte;
                            mp3buf_size: Integer): Integer;
var
  gfc:                    PLameInternalFlags;
  cfg:                    PSessionConfig_t;
  esv:                    PEncStateVar_t;
  silence:                array[0..1151] of SmallInt;
  pcm_samples_per_frame:  Integer;
  mf_needed:              Integer;
  samples_to_encode:      Integer;
  end_padding:            Integer;
  frames_left:            Integer;
  frame_num:              Integer;
  bunch:                  Integer;
  mp3count:               Integer;
  mp3buf_remaining:       Integer;
  imp3:                   Integer;
begin
  if gfp = nil then begin Result := -3; Exit; end;
  if gfp^.class_id <> LAME_ID then begin Result := -3; Exit; end;
  gfc := gfp^.internal_flags;
  if gfc = nil then begin Result := -3; Exit; end;
  if gfc^.lame_init_params_successful <= 0 then begin Result := -3; Exit; end;

  cfg := @gfc^.cfg;
  esv := @gfc^.sv_enc;

  if esv^.mf_samples_to_encode < 1 then
  begin
    Result := 0;
    Exit;
  end;

  pcm_samples_per_frame := 576 * cfg^.mode_gr;
  mf_needed             := calcNeeded(cfg^);
  samples_to_encode     := esv^.mf_samples_to_encode - POSTDELAY;

  FillChar(silence, SizeOf(silence), 0);
  mp3count := 0;
  imp3     := 0;

  end_padding := pcm_samples_per_frame - (samples_to_encode mod pcm_samples_per_frame);
  if end_padding < 576 then
    Inc(end_padding, pcm_samples_per_frame);
  gfc^.ov_enc.encoder_padding := end_padding;

  frames_left := (samples_to_encode + end_padding) div pcm_samples_per_frame;

  while (frames_left > 0) and (imp3 >= 0) do
  begin
    frame_num := gfc^.ov_enc.frame_number;
    bunch     := mf_needed - esv^.mf_size;
    if bunch > 1152 then bunch := 1152;
    if bunch <    1 then bunch := 1;

    mp3buf_remaining := mp3buf_size - mp3count;
    if mp3buf_size = 0 then mp3buf_remaining := 0;

    imp3 := lame_encode_buffer(gfp,
                                @silence[0], @silence[0],
                                bunch,
                                mp3buf, mp3buf_remaining);
    Inc(mp3buf, imp3);
    Inc(mp3count, imp3);

    frames_left := frames_left - (gfc^.ov_enc.frame_number - frame_num);
  end;

  esv^.mf_samples_to_encode := 0;

  if imp3 < 0 then
  begin
    Result := imp3;
    Exit;
  end;

  mp3buf_remaining := mp3buf_size - mp3count;
  if mp3buf_size = 0 then mp3buf_remaining := High(Integer);

  { flush the bit buffer }
  flush_bitstream(gfc);
  imp3 := copy_buffer(gfc, mp3buf, mp3buf_remaining, 1);
  if imp3 < 0 then
  begin
    Result := imp3;
    Exit;
  end;
  Inc(mp3count, imp3);

  Result := mp3count;
end;

{ -----------------------------------------------------------------------
  lame_close
----------------------------------------------------------------------- }
function lame_close(gfp: PLameGlobalFlags): Integer;
var
  gfc: PLameInternalFlags;
begin
  if gfp = nil then begin Result := -3; Exit; end;
  if gfp^.class_id <> LAME_ID then begin Result := -3; Exit; end;
  gfp^.class_id := 0;

  gfc := gfp^.internal_flags;
  if gfc <> nil then
  begin
    gfc^.lame_init_params_successful := 0;
    gfc^.class_id := 0;
    freegfc(gfc);           { frees gfc and its sub-allocations }
    gfp^.internal_flags := nil;
  end;

  if gfp^.lame_allocated_gfp <> 0 then
  begin
    gfp^.lame_allocated_gfp := 0;
    Dispose(gfp);
  end;

  Result := 0;
end;

end.
