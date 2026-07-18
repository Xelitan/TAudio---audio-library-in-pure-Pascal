{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameTypes;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Translated from LAME 3.100 C source


interface

uses SysUtils, Math;

{$PACKRECORDS C}

const
  { Encoder constants from encoder.h }
  ENCDELAY      = 576;
  POSTDELAY     = 1152;
  MDCTDELAY     = 48;
  FFTOFFSET     = 224 + MDCTDELAY;   { = 272 }
  DECDELAY      = 528;
  SBLIMIT       = 32;
  CBANDS        = 64;
  SBPSY_l       = 21;
  SBPSY_s       = 12;
  SBMAX_l       = 22;
  SBMAX_s       = 13;
  PSFB21        = 6;
  PSFB12        = 6;
  BLKSIZE       = 1024;
  HBLKSIZE      = 513;
  BLKSIZE_s     = 256;
  HBLKSIZE_s    = 129;
  SFBMAX        = SBMAX_s * 3;       { = 39 }

  { Block types }
  NORM_TYPE     = 0;
  START_TYPE    = 1;
  SHORT_TYPE    = 2;
  STOP_TYPE     = 3;

  { Bitstream constants }
  MAX_HEADER_BUF = 256;
  MAX_HEADER_LEN = 40;
  BPC            = 320;

  { Buffer size for input }
  MFSIZE = 3 * 1152 + ENCDELAY - MDCTDELAY;   { = 3984 }

  { Quantization constants }
  IXMAX_VAL     = 8206;
  PRECALC_SIZE  = IXMAX_VAL + 2;
  Q_MAX         = 257;    { 256+1 }
  Q_MAX2        = 116;
  LARGE_BITS    = 100000;

  { Huffman table count }
  HTN           = 34;

  { Math constants }
  LAME_PI       = 3.14159265358979323846;
  LAME_LOG2     = 0.69314718055994530942;
  LAME_LOG10    = 2.30258509299404568402;
  LAME_SQRT2    = 1.41421356237309504880;

  { Psychoacoustic model constants }
  DELBARK              = 0.34;
  VO_SCALE             = 1.0 / (14752.0 * 14752.0) / (BLKSIZE / 2);
  temporalmask_sustain = 0.01;
  NS_PREECHO_ATT0      = 0.8;
  NS_PREECHO_ATT1      = 0.6;
  NS_PREECHO_ATT2      = 0.3;
  NS_MSFIX             = 3.5;
  NSATTACKTHRE         = 4.4;
  NSATTACKTHRE_S       = 25.0;

  { Misc }
  LAME_ID       = $FFF88E3B;
  TRUE_VAL      = 1;
  FALSE_VAL     = 0;

  { Log table for fast_log2 }
  LOG2_SIZE     = 512;
  LOG2_SIZE_L2  = 9;

type
  TFloat   = Single;    { 32-bit float, FLOAT in C }
  TFloat8  = Double;    { 64-bit float, FLOAT8 in C }
  TSample  = Single;    { sample_t }
  PSingle   = ^TFloat;
  PPSingle  = ^PSingle;
  PFloat8  = ^TFloat8;
  PSample  = ^TSample;

  TFloatArray = array[0..MaxInt div 4 - 1] of TFloat;
  PSingleArray = ^TFloatArray;
  TSampleArray = array[0..MaxInt div 4 - 1] of TSample;
  PSampleArray = ^TSampleArray;
  TIntegerArray = array[0..MaxInt div 4 - 1] of Integer;
  PIntegerArray = ^TIntegerArray;
  TWordArray    = array[0..MaxInt div 2 - 1] of Word;
  PWordArray    = ^TWordArray;
  TCardinalArray = array[0..MaxInt div 4 - 1] of Cardinal;
  PCardinalArray = ^TCardinalArray;
  TByteArray2   = array[0..MaxInt - 1] of Byte;
  PByteArray2   = ^TByteArray2;

  { --- Enums --- }
  TVbrMode = (
    vbr_off  = 0,   { CBR }
    vbr_mt   = 1,
    vbr_rh   = 2,
    vbr_abr  = 3,
    vbr_mtrh = 4,
    vbr_max_indicator = 5,
    vbr_default = 4
  );

  TMPEGMode = (
    STEREO       = 0,
    JOINT_STEREO = 1,
    DUAL_CHANNEL = 2,
    MONO         = 3,
    NOT_SET      = 4,
    MAX_INDICATOR = 5
  );

  TPaddingType = (
    PAD_NO    = 0,
    PAD_ALL   = 1,
    PAD_ADJUST = 2
  );

  TShortBlockType = (
    short_block_not_set    = -1,
    short_block_allowed    = 0,
    short_block_coupled    = 1,
    short_block_dispensed  = 2,
    short_block_forced     = 3
  );

  TMPEGChannelMode = (
    MPG_MD_LR_LR = 0,
    MPG_MD_LR_I  = 1,
    MPG_MD_MS_LR = 2,
    MPG_MD_MS_I  = 3
  );

  TBufferConstraint = (
    MDB_DEFAULT       = 0,
    MDB_STRICT_ISO    = 1,
    MDB_MAXIMUM       = 2
  );

  { --- Band arrays used by psychoacoustic model --- }
  TCBandArr  = array[0..CBANDS - 1] of TFloat;
  T4CBandArr = array[0..3] of TCBandArr;
  TS3IndArr  = array[0..CBANDS - 1, 0..1] of Integer;
  PS3IndArr  = ^TS3IndArr;

  { --- Layer 3 data structures --- }

  TScalefacStruct = record
    l:      array[0..SBMAX_l] of Integer;
    s:      array[0..SBMAX_s] of Integer;
    psfb21: array[0..6] of Integer;
    psfb12: array[0..6] of Integer;
  end;
  PScalefacStruct = ^TScalefacStruct;

  TIIIPsyXmin = record
    l: array[0..SBMAX_l - 1] of TFloat;
    s: array[0..SBMAX_s - 1, 0..2] of TFloat;
  end;

  TIIIPsyRatio = record
    thm: TIIIPsyXmin;
    en:  TIIIPsyXmin;
  end;
  PIIIPsyRatio = ^TIIIPsyRatio;
  PPIIIPsyRatio = ^PIIIPsyRatio;
  TIIIPsyRatio2x2 = array[0..1, 0..1] of TIIIPsyRatio;
  PIIIPsyRatio2x2 = ^TIIIPsyRatio2x2;

  TGrInfo = record
    xr:                array[0..575] of TFloat;
    l3_enc:            array[0..575] of Integer;
    scalefac:          array[0..SFBMAX - 1] of Integer;
    xrpow_max:         TFloat;
    part2_3_length:    Integer;
    big_values:        Integer;
    count1:            Integer;
    global_gain:       Integer;
    scalefac_compress: Integer;
    block_type:        Integer;
    mixed_block_flag:  Integer;
    table_select:      array[0..2] of Integer;
    subblock_gain:     array[0..3] of Integer;
    region0_count:     Integer;
    region1_count:     Integer;
    preflag:           Integer;
    scalefac_scale:    Integer;
    count1table_select: Integer;
    part2_length:      Integer;
    sfb_lmax:          Integer;
    sfb_smin:          Integer;
    psy_lmax:          Integer;
    sfbmax:            Integer;
    psymax:            Integer;
    sfbdivide:         Integer;
    width:             array[0..38] of Integer;
    window:            array[0..38] of Integer;
    count1bits:        Integer;
    sfb_partition_table: PInteger;
    slen:              array[0..3] of Integer;
    max_nonzero_coeff: Integer;
    energy_above_cutoff: array[0..38] of Byte;
  end;
  PGrInfo = ^TGrInfo;

  TIIISideInfo = record
    tt:            array[0..1, 0..1] of TGrInfo;
    main_data_begin: Integer;
    private_bits:  Integer;
    resvDrain_pre: Integer;
    resvDrain_post: Integer;
    scfsi:         array[0..1, 0..3] of Integer;
  end;

  { --- Bitstream --- }
  TBitStreamStruc = record
    buf:          PByte;
    buf_size:     Integer;
    totbit:       Integer;
    buf_byte_idx: Integer;
    buf_bit_idx:  Integer;
  end;

  { --- ATH --- }
  TATHt = record
    use_adjust:     Integer;
    aa_sensitivity_p: TFloat;
    adjust_factor:  TFloat;
    adjust_limit:   TFloat;
    decay:          TFloat;
    floor:          TFloat;
    l:              array[0..SBMAX_l - 1] of TFloat;
    s:              array[0..SBMAX_s - 1] of TFloat;
    psfb21:         array[0..5] of TFloat;
    psfb12:         array[0..5] of TFloat;
    cb_l:           TCBandArr;
    cb_s:           TCBandArr;
    eql_w:          array[0..BLKSIZE div 2 - 1] of TFloat;
  end;
  PATHt = ^TATHt;

  { --- Psychoacoustic constants per band --- }
  TPsyConstCB2SBt = record
    masking_lower: array[0..CBANDS - 1] of TFloat;
    minval:        array[0..CBANDS - 1] of TFloat;
    rnumlines:     array[0..CBANDS - 1] of TFloat;
    mld_cb:        TCBandArr;
    mld:           array[0..SBMAX_l] of TFloat;
    bo_weight:     array[0..SBMAX_l] of TFloat;
    attack_threshold: TFloat;
    s3ind:         array[0..CBANDS - 1, 0..1] of Integer;
    numlines:      array[0..CBANDS - 1] of Integer;
    bm:            array[0..SBMAX_l] of Integer;
    bo:            array[0..SBMAX_l] of Integer;
    npart:         Integer;
    n_sb:          Integer;
    s3:            PSingle;
  end;
  PPsyConstCB2SBt = ^TPsyConstCB2SBt;

  TPsyConst_t = record
    window:   array[0..BLKSIZE - 1] of TFloat;
    window_s: array[0..BLKSIZE_s div 2 - 1] of TFloat;
    l:        TPsyConstCB2SBt;
    s:        TPsyConstCB2SBt;
    l_to_s:   TPsyConstCB2SBt;
    attack_threshold:   array[0..3] of TFloat;
    decay:    TFloat;
    force_short_block_calc: Integer;
  end;
  PPsyConst_t = ^TPsyConst_t;

  { Psychoacoustic state variables }
  TPsyStateVar_t = record
    nb_l1: array[0..3, 0..CBANDS - 1] of TFloat;
    nb_l2: array[0..3, 0..CBANDS - 1] of TFloat;
    nb_s1: array[0..3, 0..CBANDS - 1] of TFloat;
    nb_s2: array[0..3, 0..CBANDS - 1] of TFloat;
    thm:   array[0..3] of TIIIPsyXmin;
    en:    array[0..3] of TIIIPsyXmin;
    loudness_sq_save: array[0..1] of TFloat;
    tot_ener: array[0..3] of TFloat;
    last_en_subshort: array[0..3, 0..8] of TFloat;
    last_attacks: array[0..3] of Integer;
    blocktype_old: array[0..1] of Integer;
  end;

  PPsyStateVar_t = ^TPsyStateVar_t;

  TPsyResult_t = record
    loudness_sq: array[0..1, 0..1] of TFloat;
  end;

  { Header buffer entry }
  THeaderEntry = record
    write_timing: Integer;
    ptr:          Integer;
    buf:          array[0..MAX_HEADER_LEN - 1] of Byte;
  end;

  { Encoder state variables }
  TEncStateVar_t = record
    sb_sample:   array[0..1, 0..1, 0..17, 0..SBLIMIT - 1] of TFloat;
    amp_filter:  array[0..31] of TFloat;
    itime:       array[0..1] of TFloat8;
    inbuf_old:   array[0..1] of array[0..BLKSIZE + 576 + MDCTDELAY] of TSample;
    blackfilt:   array[0..2 * BPC] of TFloat8;
    pefirbuf:    array[0..18] of TFloat;
    frac_SpF:    TFloat;
    slot_lag:    TFloat;
    header:      array[0..MAX_HEADER_BUF - 1] of THeaderEntry;
    h_ptr:       Integer;
    w_ptr:       Integer;
    ancillary_flag: Integer;
    ResvSize:    Integer;
    ResvMax:     Integer;
    in_buffer_nsamples: Integer;
    in_buffer_0: PSample;
    in_buffer_1: PSample;
    mfbuf:       array[0..1, 0..MFSIZE - 1] of TSample;
    mf_samples_to_encode: Integer;
    mf_size:     Integer;
  end;

  { Encoder output results }
  TEncResult_t = record
    bitrate_channelmode_hist: array[0..15, 0..4] of Integer;
    bitrate_blocktype_hist:   array[0..15, 0..5] of Integer;
    bitrate_index:  Integer;
    frame_number:   Integer;
    padding:        Integer;
    mode_ext:       Integer;
    encoder_delay:  Integer;
    encoder_padding: Integer;
  end;

  { Quantization state }
  TQntStateVar_t = record
    longfact:      array[0..SBMAX_l - 1] of TFloat;
    shortfact:     array[0..SBMAX_s - 1] of TFloat;
    masking_lower: TFloat;
    mask_adjust:   TFloat;
    mask_adjust_short: TFloat;
    OldValue:      array[0..1] of Integer;
    CurrentStep:   array[0..1] of Integer;
    pseudohalf:    array[0..SFBMAX - 1] of Integer;
    sfb21_extra:   Integer;
    substep_shaping: Integer;
    bv_scf:        array[0..575] of Integer;
  end;

  { Session configuration (internal) }
  TSessionConfig_t = record
    version:        Integer;
    samplerate_index: Integer;
    sideinfo_len:   Integer;
    noise_shaping:  Integer;
    subblock_gain:  Integer;
    use_best_huffman: Integer;
    noise_shaping_amp: Integer;
    noise_shaping_stop: Integer;
    full_outer_loop: Integer;
    lowpassfreq:    Integer;
    highpassfreq:   Integer;
    samplerate_in:  Integer;
    samplerate_out: Integer;
    channels_in:    Integer;
    channels_out:   Integer;
    mode_gr:        Integer;
    force_ms:       Integer;
    quant_comp:     Integer;
    quant_comp_short: Integer;
    use_temporal_masking_effect: Integer;
    use_safe_joint_stereo: Integer;
    preset:         Integer;
    vbr:            TVbrMode;
    vbr_avg_bitrate_kbps: Integer;
    vbr_min_bitrate_index: Integer;
    vbr_max_bitrate_index: Integer;
    avg_bitrate:    Integer;
    enforce_min_bitrate: Integer;
    findReplayGain: Integer;
    findPeakSample: Integer;
    decode_on_the_fly: Integer;
    analysis:       Integer;
    disable_reservoir: Integer;
    buffer_constraint: Integer;  { actual max buffer size in bytes }
    free_format:    Integer;
    write_lame_tag: Integer;
    error_protection: Integer;
    copyright:      Integer;
    original:       Integer;
    extension:      Integer;
    emphasis:       Integer;
    mode:           TMPEGMode;
    short_blocks:   TShortBlockType;
    interChRatio:   TFloat;
    msfix:          TFloat;
    ATH_offset_db:  TFloat;
    ATH_offset_factor: TFloat;
    ATHcurve:       TFloat;
    ATHtype:        Integer;
    ATHonly:        Integer;
    ATHshort:       Integer;
    noATH:          Integer;
    ATHfixpoint:    Single;
    adjust_alto:    TFloat;
    adjust_bass:    TFloat;
    adjust_treble:  TFloat;
    adjust_sfb21_db: TFloat;
    compression_ratio: TFloat;
    lowpass1:       TFloat;
    lowpass2:       TFloat;
    highpass1:      TFloat;
    highpass2:      TFloat;
    pcm_transform:  array[0..1, 0..1] of TFloat;
    minval:         TFloat;
  end;

  { Calc noise result }
  TCalcNoiseResult = record
    over_noise: TFloat;
    tot_noise:  TFloat;
    max_noise:  TFloat;
    over_count: Integer;
    over_SSD:   Integer;
    bits:       Integer;
  end;
  PCalcNoiseResult = ^TCalcNoiseResult;

  { Calc noise data (cache) }
  TCalcNoiseData = record
    global_gain: Integer;
    sfb_count1:  Integer;
    step:        array[0..38] of TFloat;
    noise:       array[0..38] of TFloat;
    noise_log:   array[0..38] of TFloat;
  end;
  PCalcNoiseData = ^TCalcNoiseData;

  { 2x2 perceptual entropy array [granule][channel] }
  TPeArray = array[0..1, 0..1] of TFloat;
  PPeArray = ^TPeArray;

  { Pointer to IIISideInfo }
  PIIISideInfo = ^TIIISideInfo;

  { Convenience pointer aliases for sub-records }
  PBitStreamStruc  = ^TBitStreamStruc;
  PSessionConfig_t = ^TSessionConfig_t;
  PEncResult_t     = ^TEncResult_t;
  PEncStateVar_t   = ^TEncStateVar_t;
  PQntStateVar_t   = ^TQntStateVar_t;

  { Huffman code table }
  THuffCodeTab = record
    xlen:   Cardinal;
    linmax: Cardinal;
    table:  PWord;
    hlen:   PByte;
  end;
  PHuffCodeTab = ^THuffCodeTab;

  { Function pointer types }
  TChooseTableProc = function(const ix: PInteger; const ixend: PInteger;
                              var s: Integer): Integer;
  TFftFhtProc = procedure(fz: PSingle; n: Integer);
  TInitXrpowCoreProc = procedure(var cod_info: TGrInfo; xrpow: PSingle;
                                 upper: Integer; var sum: TFloat);

  { VBR seek info (needed even in CBR for struct completeness) }
  PVBRSeekInfo = ^TVBRSeekInfo;
  TVBRSeekInfo = record
    sum:            Integer;
    seen:           Integer;
    want:           Integer;
    pos:            Integer;
    size:           Integer;
    bag:            PInteger;
    nVbrNumFrames:  Cardinal;
    nBytesWritten:  Cardinal;
    TotalFrameSize: Cardinal;
  end;

  { --- Main internal flags structure --- }
  PLameInternalFlags = ^TLameInternalFlags;
  TLameInternalFlags = record
    class_id:     Cardinal;
    lame_encode_frame_init:      Integer;
    lame_init_params_successful: Integer;
    lame_init_bitstream_init:    Integer;
    iteration_init_init:         Integer;  { set to 1 after iteration_init() }

    cfg:      TSessionConfig_t;
    bs:       TBitStreamStruc;
    l3_side:  TIIISideInfo;
    scalefac_band: TScalefacStruct;
    sv_psy:   TPsyStateVar_t;
    ov_psy:   TPsyResult_t;
    sv_enc:   TEncStateVar_t;
    ov_enc:   TEncResult_t;
    sv_qnt:   TQntStateVar_t;
    ATH:      PATHt;
    cd_psy:   PPsyConst_t;
    VBR_seek_table: TVBRSeekInfo;

    { Function pointers }
    choose_table:    TChooseTableProc;
    fft_fht:         TFftFhtProc;
    init_xrpow_core: TInitXrpowCoreProc;

    { CPU features }
    has_MMX:    Integer;
    has_AMD3DN: Integer;
    has_SSE:    Integer;
    has_SSE2:   Integer;

    nMusicCRC:  Word;
  end;

  { --- Public API structure --- }
  PLameGlobalFlags = ^TLameGlobalFlags;
  TLameGlobalFlags = record
    class_id:       Cardinal;
    num_samples:    Int64;
    num_channels:   Integer;
    samplerate_in:  Integer;
    samplerate_out: Integer;
    scale:          Single;
    scale_left:     Single;
    scale_right:    Single;
    analysis:       Integer;
    write_lame_tag: Integer;
    decode_only:    Integer;
    quality:        Integer;
    mode:           TMPEGMode;
    force_ms:       Integer;
    free_format:    Integer;
    findReplayGain: Integer;
    decode_on_the_fly: Integer;
    write_id3tag_automatic: Integer;
    brate:          Integer;
    compression_ratio: Single;
    copyright:      Integer;
    original:       Integer;
    extension:      Integer;
    emphasis:       Integer;
    error_protection: Integer;
    strict_ISO:     Integer;
    disable_reservoir: Integer;
    quant_comp:     Integer;
    quant_comp_short: Integer;
    experimentalY:  Integer;
    experimentalZ:  Integer;
    exp_nspsytune:  Integer;
    preset:         Integer;
    VBR:            TVbrMode;
    VBR_q_frac:     Single;
    VBR_q:          Integer;
    VBR_mean_bitrate_kbps: Integer;
    VBR_min_bitrate_kbps:  Integer;
    VBR_max_bitrate_kbps:  Integer;
    VBR_hard_min:   Integer;
    lowpassfreq:    Integer;
    lowpasswidth:   Integer;
    highpassfreq:   Integer;
    highpasswidth:  Integer;
    maskingadjust:  Single;
    maskingadjust_short: Single;
    ATHonly:        Integer;
    ATHshort:       Integer;
    noATH:          Integer;
    ATHtype:        Integer;
    ATHcurve:       Single;
    ATH_lower_db:   Single;
    athaa_type:     Integer;
    athaa_sensitivity: Single;
    short_blocks:   TShortBlockType;
    useTemporal:    Integer;
    interChRatio:   Single;
    msfix:          Single;
    attackthre:     Single;
    attackthre_s:   Single;
    lame_allocated_gfp: Integer;
    internal_flags: PLameInternalFlags;
  end;

{ --- Global tables --- }
var
  pow20:   array[0..Q_MAX + Q_MAX2] of TFloat;
  ipow20:  array[0..Q_MAX - 1] of TFloat;
  pow43:   array[0..PRECALC_SIZE - 1] of TFloat;
  adj43:   array[0..PRECALC_SIZE - 1] of TFloat;

{ --- Scalefactor band tables (from quantize_pvt.c) --- }
  sfBandIndex: array[0..8] of TScalefacStruct;

implementation

end.
