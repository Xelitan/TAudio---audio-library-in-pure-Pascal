{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameVbrTag;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Xing/Info VBR tag writer and reader
//  Translated from VbrTag.c

interface

uses
  LameTypes, LameTables, LameUtils, LameBitstream, Classes, SysUtils;

const
  FRAMES_FLAG    = $0001;
  BYTES_FLAG     = $0002;
  TOC_FLAG       = $0004;
  VBR_SCALE_FLAG = $0008;
  NUMTOCENTRIES  = 100;

type
  TVbrTagData = record
    h_id:        Integer;
    samprate:    Integer;
    flags:       Integer;
    frames:      Integer;
    bytes:       Integer;
    vbr_scale:   Integer;
    toc:         array[0..NUMTOCENTRIES - 1] of Byte;
    headersize:  Integer;
    enc_delay:   Integer;
    enc_padding: Integer;
  end;
  PVbrTagData = ^TVbrTagData;

{ Initialise VBR/Info tag and write placeholder frame to bitstream }
function  InitVbrTag(gfp: PLameGlobalFlags): Integer;

{ Update seek table with current frame's bitrate }
procedure AddVbrFrame(gfc: PLameInternalFlags);

{ Update 16-bit CRC over a buffer of bytes }
procedure UpdateMusicCRC(crc: PWord; buffer: PByte; size: Integer);

{ Read an existing Xing/Info tag from a raw MP3 buffer }
function  GetVbrTag(pTagData: PVbrTagData; buf: PByte): Integer;

{ Build the complete Info/Xing tag frame into caller-supplied buffer.
  Returns the number of bytes needed/written, or 0 on error. }
function  lame_get_lametag_frame(gfp: PLameGlobalFlags;
                                  buffer: PByte; size: Cardinal): Cardinal;

{ Seek back to beginning of fpStream and overwrite the placeholder
  frame with the final Info/Xing tag. Returns 0 on success, <0 on error. }
function  PutVbrTag(gfp: PLameGlobalFlags; fpStream: TStream): Integer;

implementation

{$POINTERMATH ON}

{ -----------------------------------------------------------------------
  Constants
  ----------------------------------------------------------------------- }

const
  VBRHEADERSIZE = NUMTOCENTRIES + 4 + 4 + 4 + 4 + 4;
  LAMEHEADERSIZE = VBRHEADERSIZE + 9 + 1 + 1 + 8 + 1 + 1 + 3 + 1 + 1 + 2 + 4 + 2 + 2;

  XING_BITRATE1  = 128;
  XING_BITRATE2  = 64;
  XING_BITRATE25 = 32;

  MAXFRAMESIZE = 2880;

  VBRTag0: array[0..3] of Byte = (Ord('X'), Ord('i'), Ord('n'), Ord('g'));
  VBRTag1: array[0..3] of Byte = (Ord('I'), Ord('n'), Ord('f'), Ord('o'));

  { Short version string embedded in the LAME tag, max 9 chars, must start with LAME }
  LAME_SHORT_VERSION = 'LAME3.100';

  { CRC-16 lookup table (polynomial x^16+x^15+x^2+1) }
  crc16_lookup: array[0..255] of Word = (
    $0000, $C0C1, $C181, $0140, $C301, $03C0, $0280, $C241,
    $C601, $06C0, $0780, $C741, $0500, $C5C1, $C481, $0440,
    $CC01, $0CC0, $0D80, $CD41, $0F00, $CFC1, $CE81, $0E40,
    $0A00, $CAC1, $CB81, $0B40, $C901, $09C0, $0880, $C841,
    $D801, $18C0, $1980, $D941, $1B00, $DBC1, $DA81, $1A40,
    $1E00, $DEC1, $DF81, $1F40, $DD01, $1DC0, $1C80, $DC41,
    $1400, $D4C1, $D581, $1540, $D701, $17C0, $1680, $D641,
    $D201, $12C0, $1380, $D341, $1100, $D1C1, $D081, $1040,
    $F001, $30C0, $3180, $F141, $3300, $F3C1, $F281, $3240,
    $3600, $F6C1, $F781, $3740, $F501, $35C0, $3480, $F441,
    $3C00, $FCC1, $FD81, $3D40, $FF01, $3FC0, $3E80, $FE41,
    $FA01, $3AC0, $3B80, $FB41, $3900, $F9C1, $F881, $3840,
    $2800, $E8C1, $E981, $2940, $EB01, $2BC0, $2A80, $EA41,
    $EE01, $2EC0, $2F80, $EF41, $2D00, $EDC1, $EC81, $2C40,
    $E401, $24C0, $2580, $E541, $2700, $E7C1, $E681, $2640,
    $2200, $E2C1, $E381, $2340, $E101, $21C0, $2080, $E041,
    $A001, $60C0, $6180, $A141, $6300, $A3C1, $A281, $6240,
    $6600, $A6C1, $A781, $6740, $A501, $65C0, $6480, $A441,
    $6C00, $ACC1, $AD81, $6D40, $AF01, $6FC0, $6E80, $AE41,
    $AA01, $6AC0, $6B80, $AB41, $6900, $A9C1, $A881, $6840,
    $7800, $B8C1, $B981, $7940, $BB01, $7BC0, $7A80, $BA41,
    $BE01, $7EC0, $7F80, $BF41, $7D00, $BDC1, $BC81, $7C40,
    $B401, $74C0, $7580, $B541, $7700, $B7C1, $B681, $7640,
    $7200, $B2C1, $B381, $7340, $B101, $71C0, $7080, $B041,
    $5000, $90C1, $9181, $5140, $9301, $53C0, $5280, $9241,
    $9601, $56C0, $5780, $9741, $5500, $95C1, $9481, $5440,
    $9C01, $5CC0, $5D80, $9D41, $5F00, $9FC1, $9E81, $5E40,
    $5A00, $9AC1, $9B81, $5B40, $9901, $59C0, $5880, $9841,
    $8801, $48C0, $4980, $8941, $4B00, $8BC1, $8A81, $4A40,
    $4E00, $8EC1, $8F81, $4F40, $8D01, $4DC0, $4C80, $8C41,
    $4400, $84C1, $8581, $4540, $8701, $47C0, $4680, $8641,
    $8201, $42C0, $4380, $8341, $4100, $81C1, $8081, $4040
  );

{ -----------------------------------------------------------------------
  Internal helpers
  ----------------------------------------------------------------------- }

function CRC_update_lookup(value: Word; crc: Word): Word;
var
  tmp: Word;
begin
  tmp := crc xor value;
  Result := (crc shr 8) xor crc16_lookup[tmp and $FF];
end;

procedure UpdateMusicCRC(crc: PWord; buffer: PByte; size: Integer);
var
  i: Integer;
begin
  for i := 0 to size - 1 do
    crc^ := CRC_update_lookup(buffer[i], crc^);
end;

function ExtractI4(buf: PByte): Integer;
begin
  Result := buf[0];
  Result := (Result shl 8) or buf[1];
  Result := (Result shl 8) or buf[2];
  Result := (Result shl 8) or buf[3];
end;

procedure CreateI4(buf: PByte; nValue: Cardinal);
begin
  buf[0] := (nValue shr 24) and $FF;
  buf[1] := (nValue shr 16) and $FF;
  buf[2] := (nValue shr 8) and $FF;
  buf[3] := nValue and $FF;
end;

procedure CreateI2(buf: PByte; nValue: Integer);
begin
  buf[0] := (nValue shr 8) and $FF;
  buf[1] := nValue and $FF;
end;

function IsVbrTag(buf: PByte): Boolean;
var
  isTag0, isTag1: Boolean;
begin
  isTag0 := (buf[0] = VBRTag0[0]) and (buf[1] = VBRTag0[1])
            and (buf[2] = VBRTag0[2]) and (buf[3] = VBRTag0[3]);
  isTag1 := (buf[0] = VBRTag1[0]) and (buf[1] = VBRTag1[1])
            and (buf[2] = VBRTag1[2]) and (buf[3] = VBRTag1[3]);
  Result := isTag0 or isTag1;
end;

procedure addVbr(v: PVBRSeekInfo; bitrate: Integer);
var
  i: Integer;
begin
  Inc(v^.nVbrNumFrames);
  Inc(v^.sum, bitrate);
  Inc(v^.seen);

  if v^.seen < v^.want then
    Exit;

  if v^.pos < v^.size then
  begin
    PIntegerArray(v^.bag)^[v^.pos] := v^.sum;
    Inc(v^.pos);
    v^.seen := 0;
  end;
  if v^.pos = v^.size then
  begin
    i := 1;
    while i < v^.size do
    begin
      PIntegerArray(v^.bag)^[i div 2] := PIntegerArray(v^.bag)^[i];
      Inc(i, 2);
    end;
    v^.want := v^.want * 2;
    v^.pos  := v^.pos div 2;
  end;
end;

procedure Xing_seek_table(v: PVBRSeekInfo; t: PByte);
var
  i, indx, seek_point: Integer;
  j, act, sum: Double;
begin
  if v^.pos <= 0 then
    Exit;

  for i := 1 to NUMTOCENTRIES - 1 do
  begin
    j    := i / NUMTOCENTRIES;
    indx := Trunc(j * v^.pos);
    if indx > v^.pos - 1 then indx := v^.pos - 1;
    act  := PIntegerArray(v^.bag)^[indx];
    sum  := v^.sum;
    seek_point := Trunc(256.0 * act / sum);
    if seek_point > 255 then seek_point := 255;
    t[i] := Byte(seek_point);
  end;
end;

{ Writes the 4-byte MPEG frame header for the Info/Xing placeholder frame }
procedure setLameTagFrameHeader(gfc: PLameInternalFlags; buffer: PByte);
var
  cfg: PSessionConfig_t;
  eov: PEncResult_t;
  abyte, bbyte: Byte;
  bitrate: Integer;
begin
  cfg := @gfc^.cfg;
  eov := @gfc^.ov_enc;

  { Byte 0: sync word $FF }
  buffer[0] := $FF;

  { Byte 1: sync(3) + MPEG ID + layer + protection }
  buffer[1] := $E0;                             { sync bits 11..8 }
  if cfg^.samplerate_out >= 16000 then
    buffer[1] := buffer[1] or $08;              { MPEG-1 or MPEG-2 id bit }
  buffer[1] := buffer[1] or (cfg^.version shl 3) and $08;
  buffer[1] := buffer[1] or $02;               { layer 3 = %01 }
  if cfg^.error_protection = 0 then
    buffer[1] := buffer[1] or $01;             { no CRC }

  { Byte 2: bitrate index + samplerate index + padding + private }
  buffer[2] := (eov^.bitrate_index shl 4) and $F0;
  buffer[2] := buffer[2] or ((cfg^.samplerate_index shl 2) and $0C);
  buffer[2] := buffer[2] or (cfg^.extension and $01);

  { Byte 3: channel mode + mode ext + copyright + original + emphasis }
  buffer[3] := (Ord(cfg^.mode) shl 6) and $C0;
  buffer[3] := buffer[3] or ((eov^.mode_ext shl 4) and $30);
  buffer[3] := buffer[3] or ((cfg^.copyright shl 3) and $08);
  buffer[3] := buffer[3] or ((cfg^.original shl 2) and $04);
  buffer[3] := buffer[3] or (cfg^.emphasis and $03);

  { Now override bytes 1 and 2 to use the fixed Xing bitrate, keeping
    the mode/samplerate/copyright bits from the real frames }
  buffer[0] := $FF;
  abyte := buffer[1] and $F1;   { keep sync, MPEG id, protection; clear layer bits }

  if cfg^.version = 1 then
    bitrate := XING_BITRATE1
  else if cfg^.samplerate_out < 16000 then
    bitrate := XING_BITRATE25
  else
    bitrate := XING_BITRATE2;

  if cfg^.vbr = vbr_off then
    bitrate := cfg^.avg_bitrate;

  if cfg^.free_format <> 0 then
    bbyte := $00
  else
    bbyte := Byte(16 * BitrateIndex(bitrate, cfg^.version, cfg^.samplerate_out));

  if cfg^.version = 1 then
  begin
    buffer[1] := abyte or $0A;
    abyte := buffer[2] and $0D;
    buffer[2] := bbyte or abyte;
  end
  else
  begin
    buffer[1] := abyte or $02;
    abyte := buffer[2] and $0D;
    buffer[2] := bbyte or abyte;
  end;
end;

{ -----------------------------------------------------------------------
  LAME extension block written after the Xing table
  ----------------------------------------------------------------------- }

function PutLameVBR(gfp: PLameGlobalFlags; nMusicLength: Cardinal;
                    pbtStreamBuffer: PByte; crc: Word): Integer;
var
  gfc:    PLameInternalFlags;
  cfg:    PSessionConfig_t;
  nBytesWritten: Integer;
  i:      Integer;

  enc_delay, enc_padding: Integer;
  nQuality:   Integer;
  szVersion:  array[0..8] of Byte;  { 9 bytes, no null needed }
  nVBR:       Byte;
  nRevMethod: Byte;
  nLowpass:   Byte;
  nPeakSignalAmplitude: Cardinal;
  nRadioReplayGain:    Word;
  nAudiophileReplayGain: Word;
  nNoiseShaping: Byte;
  nStereoMode:   Byte;
  bNonOptimal:   Integer;
  nSourceFreq:   Byte;
  nMisc:         Byte;
  nMusicCRC:     Word;
  bExpNPsyTune:  Byte;
  bSafeJoint:    Byte;
  bNoGapMore:    Byte;
  bNoGapPrevious: Byte;
  nAthType:      Byte;
  nFlags:        Byte;
  nABRBitrate:   Integer;
  vbr_type_translator: array[0..6] of Byte;
begin
  gfc := gfp^.internal_flags;
  cfg := @gfc^.cfg;
  nBytesWritten := 0;

  enc_delay   := gfc^.ov_enc.encoder_delay;
  enc_padding := gfc^.ov_enc.encoder_padding;

  nQuality := 100 - 10 * gfp^.VBR_q - gfp^.quality;

  { Version string: "LAME3.100" padded/truncated to 9 bytes }
  FillChar(szVersion, SizeOf(szVersion), Ord(' '));
  for i := 0 to Length(LAME_SHORT_VERSION) - 1 do
    szVersion[i] := Ord(LAME_SHORT_VERSION[i + 1]);

  vbr_type_translator[0] := 1;
  vbr_type_translator[1] := 5;
  vbr_type_translator[2] := 3;
  vbr_type_translator[3] := 2;
  vbr_type_translator[4] := 4;
  vbr_type_translator[5] := 0;
  vbr_type_translator[6] := 3;

  { Lowpass byte: frequency / 100, clamped to 255 }
  nLowpass := 0;
  if cfg^.lowpassfreq > 0 then
  begin
    i := (cfg^.lowpassfreq div 100);
    if cfg^.lowpassfreq mod 100 >= 50 then Inc(i);
    if i > 255 then i := 255;
    nLowpass := Byte(i);
  end;

  nPeakSignalAmplitude  := 0;
  nRadioReplayGain      := 0;
  nAudiophileReplayGain := 0;

  { NoGap: not supported in this translation — report as standalone file }
  bNoGapMore     := 0;
  bNoGapPrevious := 0;

  nAthType := Byte(cfg^.ATHtype and $0F);
  bExpNPsyTune := 1;
  bSafeJoint   := Byte(ord(cfg^.use_safe_joint_stereo <> 0));

  nFlags := nAthType
            or (bExpNPsyTune shl 4)
            or (bSafeJoint   shl 5)
            or (bNoGapMore   shl 6)
            or (bNoGapPrevious shl 7);

  if nQuality < 0 then nQuality := 0;

  { Stereo mode }
  case cfg^.mode of
    MONO:          nStereoMode := 0;
    STEREO:        nStereoMode := 1;
    DUAL_CHANNEL:  nStereoMode := 2;
    JOINT_STEREO:
      if cfg^.force_ms <> 0 then nStereoMode := 4
      else                        nStereoMode := 3;
    else           nStereoMode := 7;
  end;

  { Source sample-rate category }
  if cfg^.samplerate_in <= 32000 then
    nSourceFreq := $00
  else if cfg^.samplerate_in = 48000 then
    nSourceFreq := $02
  else if cfg^.samplerate_in > 48000 then
    nSourceFreq := $03
  else
    nSourceFreq := $01;

  { Non-optimal flag }
  bNonOptimal := 0;
  if (cfg^.short_blocks = short_block_forced)
     or (cfg^.short_blocks = short_block_dispensed)
     or ((cfg^.lowpassfreq = -1) and (cfg^.highpassfreq = -1))
     or ((cfg^.disable_reservoir <> 0) and (cfg^.avg_bitrate < 320))
     or (cfg^.noATH <> 0)
     or (cfg^.ATHonly <> 0)
     or (nAthType = 0)
     or (cfg^.samplerate_in <= 32000) then
    bNonOptimal := 1;

  nNoiseShaping := Byte(cfg^.noise_shaping and $03);
  nMisc := nNoiseShaping
            or (nStereoMode  shl 2)
            or (bNonOptimal  shl 5)
            or (nSourceFreq  shl 6);

  nMusicCRC := gfc^.nMusicCRC;

  { VBR method byte }
  if Ord(cfg^.vbr) < Length(vbr_type_translator) then
    nVBR := vbr_type_translator[Ord(cfg^.vbr)]
  else
    nVBR := 0;
  nRevMethod := ($10 * 0) + nVBR;  { revision 0 }

  { ABR / CBR bitrate for tag }
  case cfg^.vbr of
    vbr_abr: nABRBitrate := cfg^.vbr_avg_bitrate_kbps;
    vbr_off: nABRBitrate := cfg^.avg_bitrate;
    else     nABRBitrate := bitrate_table[cfg^.version][cfg^.vbr_min_bitrate_index];
  end;

  { Write fields }
  CreateI4(@pbtStreamBuffer[nBytesWritten], nQuality);
  Inc(nBytesWritten, 4);

  Move(szVersion[0], pbtStreamBuffer[nBytesWritten], 9);
  Inc(nBytesWritten, 9);

  pbtStreamBuffer[nBytesWritten] := nRevMethod;
  Inc(nBytesWritten);

  pbtStreamBuffer[nBytesWritten] := nLowpass;
  Inc(nBytesWritten);

  CreateI4(@pbtStreamBuffer[nBytesWritten], nPeakSignalAmplitude);
  Inc(nBytesWritten, 4);

  CreateI2(@pbtStreamBuffer[nBytesWritten], nRadioReplayGain);
  Inc(nBytesWritten, 2);

  CreateI2(@pbtStreamBuffer[nBytesWritten], nAudiophileReplayGain);
  Inc(nBytesWritten, 2);

  pbtStreamBuffer[nBytesWritten] := nFlags;
  Inc(nBytesWritten);

  if nABRBitrate >= 255 then
    pbtStreamBuffer[nBytesWritten] := $FF
  else
    pbtStreamBuffer[nBytesWritten] := Byte(nABRBitrate);
  Inc(nBytesWritten);

  pbtStreamBuffer[nBytesWritten]     := Byte(enc_delay shr 4);
  pbtStreamBuffer[nBytesWritten + 1] := Byte((enc_delay shl 4) or (enc_padding shr 8));
  pbtStreamBuffer[nBytesWritten + 2] := Byte(enc_padding);
  Inc(nBytesWritten, 3);

  pbtStreamBuffer[nBytesWritten] := nMisc;
  Inc(nBytesWritten);

  pbtStreamBuffer[nBytesWritten] := 0;  { unused in rev0 }
  Inc(nBytesWritten);

  CreateI2(@pbtStreamBuffer[nBytesWritten], cfg^.preset);
  Inc(nBytesWritten, 2);

  CreateI4(@pbtStreamBuffer[nBytesWritten], nMusicLength);
  Inc(nBytesWritten, 4);

  CreateI2(@pbtStreamBuffer[nBytesWritten], nMusicCRC);
  Inc(nBytesWritten, 2);

  { CRC covers everything written so far }
  for i := 0 to nBytesWritten - 1 do
    crc := CRC_update_lookup(pbtStreamBuffer[i], crc);

  CreateI2(@pbtStreamBuffer[nBytesWritten], crc);
  Inc(nBytesWritten, 2);

  Result := nBytesWritten;
end;

{ Skip an ID3v2 tag at the start of fpStream.
  Returns the tag size in bytes (0 if none), or <0 on error. }
function skipId3v2(fpStream: TStream): Int64;
var
  id3v2Header: array[0..9] of Byte;
  nbytes: Integer;
begin
  try
    fpStream.Seek(0, soBeginning);
  except
    Result := -2;
    Exit;
  end;

  try
    nbytes := fpStream.Read(id3v2Header, SizeOf(id3v2Header));
  except
    nbytes := 0;
  end;

  if nbytes <> SizeOf(id3v2Header) then
  begin
    Result := -3;
    Exit;
  end;

  if (id3v2Header[0] = Ord('I')) and (id3v2Header[1] = Ord('D'))
     and (id3v2Header[2] = Ord('3')) then
  begin
    Result := ((Int64(id3v2Header[6] and $7F) shl 21)
              or (Int64(id3v2Header[7] and $7F) shl 14)
              or (Int64(id3v2Header[8] and $7F) shl 7)
              or  Int64(id3v2Header[9] and $7F))
              + SizeOf(id3v2Header);
  end
  else
    Result := 0;
end;

function is_lame_flags_valid(gfc: PLameInternalFlags): Boolean;
begin
  Result := (gfc <> nil)
            and (gfc^.class_id = LAME_ID)
            and (gfc^.lame_init_params_successful > 0);
end;

{ -----------------------------------------------------------------------
  Public interface
  ----------------------------------------------------------------------- }

procedure AddVbrFrame(gfc: PLameInternalFlags);
var
  kbps: Integer;
begin
  kbps := bitrate_table[gfc^.cfg.version][gfc^.ov_enc.bitrate_index];
  addVbr(@gfc^.VBR_seek_table, kbps);
end;

function InitVbrTag(gfp: PLameGlobalFlags): Integer;
var
  gfc: PLameInternalFlags;
  cfg: PSessionConfig_t;
  kbps_header, total_frame_size, header_size: Integer;
  buffer: array[0..MAXFRAMESIZE - 1] of Byte;
  i, n: Integer;
begin
  gfc := gfp^.internal_flags;
  cfg := @gfc^.cfg;

  if cfg^.version = 1 then
    kbps_header := XING_BITRATE1
  else if cfg^.samplerate_out < 16000 then
    kbps_header := XING_BITRATE25
  else
    kbps_header := XING_BITRATE2;

  if cfg^.vbr = vbr_off then
    kbps_header := cfg^.avg_bitrate;

  total_frame_size := ((cfg^.version + 1) * 72000 * kbps_header) div cfg^.samplerate_out;
  header_size      := cfg^.sideinfo_len + LAMEHEADERSIZE;
  gfc^.VBR_seek_table.TotalFrameSize := total_frame_size;

  if (total_frame_size < header_size) or (total_frame_size > MAXFRAMESIZE) then
  begin
    gfc^.cfg.write_lame_tag := 0;
    Result := 0;
    Exit;
  end;

  gfc^.VBR_seek_table.nVbrNumFrames := 0;
  gfc^.VBR_seek_table.nBytesWritten := 0;
  gfc^.VBR_seek_table.sum  := 0;
  gfc^.VBR_seek_table.seen := 0;
  gfc^.VBR_seek_table.want := 1;
  gfc^.VBR_seek_table.pos  := 0;

  if gfc^.VBR_seek_table.bag = nil then
  begin
    GetMem(gfc^.VBR_seek_table.bag, 400 * SizeOf(Integer));
    if gfc^.VBR_seek_table.bag <> nil then
    begin
      FillChar(gfc^.VBR_seek_table.bag^, 400 * SizeOf(Integer), 0);
      gfc^.VBR_seek_table.size := 400;
    end
    else
    begin
      gfc^.VBR_seek_table.size := 0;
      gfc^.cfg.write_lame_tag := 0;
      Result := -1;
      Exit;
    end;
  end;

  { Write dummy placeholder frame of all zeros }
  FillChar(buffer, SizeOf(buffer), 0);
  setLameTagFrameHeader(gfc, @buffer[0]);
  n := gfc^.VBR_seek_table.TotalFrameSize;
  for i := 0 to n - 1 do
    add_dummy_byte(gfc, buffer[i], 1);

  Result := 0;
end;

function GetVbrTag(pTagData: PVbrTagData; buf: PByte): Integer;
var
  head_flags: Integer;
  h_bitrate, h_id, h_mode, h_sr_index, h_layer: Integer;
  enc_delay, enc_padding: Integer;
  i: Integer;
begin
  pTagData^.flags := 0;

  h_layer    := (buf[1] shr 1) and 3;
  if h_layer <> $01 then
  begin
    Result := 0;
    Exit;
  end;
  h_id       := (buf[1] shr 3) and 1;
  h_sr_index := (buf[2] shr 2) and 3;
  h_mode     := (buf[3] shr 6) and 3;
  h_bitrate  := (buf[2] shr 4) and $0F;
  h_bitrate  := bitrate_table[h_id][h_bitrate];

  if (buf[1] shr 4) = $0E then
    pTagData^.samprate := samplerate_table[2][h_sr_index]
  else
    pTagData^.samprate := samplerate_table[h_id][h_sr_index];

  { Advance buf past the MPEG header + side info to where the tag lives }
  if h_id <> 0 then
  begin
    if h_mode <> 3 then Inc(buf, 32 + 4)
    else                 Inc(buf, 17 + 4);
  end
  else
  begin
    if h_mode <> 3 then Inc(buf, 17 + 4)
    else                 Inc(buf, 9 + 4);
  end;

  if not IsVbrTag(buf) then
  begin
    Result := 0;
    Exit;
  end;
  Inc(buf, 4);

  pTagData^.h_id := h_id;

  head_flags     := ExtractI4(buf);
  pTagData^.flags := head_flags;
  Inc(buf, 4);

  if (head_flags and FRAMES_FLAG) <> 0 then
  begin
    pTagData^.frames := ExtractI4(buf);
    Inc(buf, 4);
  end;

  if (head_flags and BYTES_FLAG) <> 0 then
  begin
    pTagData^.bytes := ExtractI4(buf);
    Inc(buf, 4);
  end;

  if (head_flags and TOC_FLAG) <> 0 then
  begin
    for i := 0 to NUMTOCENTRIES - 1 do
      pTagData^.toc[i] := buf[i];
    Inc(buf, NUMTOCENTRIES);
  end;

  pTagData^.vbr_scale := -1;

  if (head_flags and VBR_SCALE_FLAG) <> 0 then
  begin
    pTagData^.vbr_scale := ExtractI4(buf);
    Inc(buf, 4);
  end;

  pTagData^.headersize := ((h_id + 1) * 72000 * h_bitrate) div pTagData^.samprate;

  Inc(buf, 21);
  enc_delay   := (Integer(buf[0]) shl 4) or (buf[1] shr 4);
  enc_padding := ((buf[1] and $0F) shl 8) or buf[2];

  if (enc_delay < 0) or (enc_delay > 3000) then enc_delay := -1;
  if (enc_padding < 0) or (enc_padding > 3000) then enc_padding := -1;

  pTagData^.enc_delay   := enc_delay;
  pTagData^.enc_padding := enc_padding;

  Result := 1;
end;

function lame_get_lametag_frame(gfp: PLameGlobalFlags;
                                 buffer: PByte; size: Cardinal): Cardinal;
var
  gfc: PLameInternalFlags;
  cfg: PSessionConfig_t;
  stream_size: Cardinal;
  nStreamIndex: Cardinal;
  btToc: array[0..NUMTOCENTRIES - 1] of Byte;
  i: Integer;
  crc: Word;
begin
  Result := 0;
  if gfp = nil then Exit;
  gfc := gfp^.internal_flags;
  if gfc = nil then Exit;
  if not is_lame_flags_valid(gfc) then Exit;

  cfg := @gfc^.cfg;
  if cfg^.write_lame_tag = 0 then Exit;
  if gfc^.VBR_seek_table.pos <= 0 then Exit;

  if size < gfc^.VBR_seek_table.TotalFrameSize then
  begin
    Result := gfc^.VBR_seek_table.TotalFrameSize;
    Exit;
  end;
  if buffer = nil then Exit;

  FillChar(buffer^, gfc^.VBR_seek_table.TotalFrameSize, 0);

  setLameTagFrameHeader(gfc, buffer);

  FillChar(btToc, SizeOf(btToc), 0);
  if cfg^.free_format <> 0 then
  begin
    for i := 1 to NUMTOCENTRIES - 1 do
      btToc[i] := Byte(255 * i div 100);
  end
  else
    Xing_seek_table(@gfc^.VBR_seek_table, @btToc[0]);

  nStreamIndex := cfg^.sideinfo_len;
  if cfg^.error_protection <> 0 then
    Dec(nStreamIndex, 2);

  { Write "Info" (CBR) or "Xing" (VBR) tag }
  if cfg^.vbr = vbr_off then
  begin
    buffer[nStreamIndex] := VBRTag1[0]; Inc(nStreamIndex);
    buffer[nStreamIndex] := VBRTag1[1]; Inc(nStreamIndex);
    buffer[nStreamIndex] := VBRTag1[2]; Inc(nStreamIndex);
    buffer[nStreamIndex] := VBRTag1[3]; Inc(nStreamIndex);
  end
  else
  begin
    buffer[nStreamIndex] := VBRTag0[0]; Inc(nStreamIndex);
    buffer[nStreamIndex] := VBRTag0[1]; Inc(nStreamIndex);
    buffer[nStreamIndex] := VBRTag0[2]; Inc(nStreamIndex);
    buffer[nStreamIndex] := VBRTag0[3]; Inc(nStreamIndex);
  end;

  CreateI4(@buffer[nStreamIndex], FRAMES_FLAG or BYTES_FLAG or TOC_FLAG or VBR_SCALE_FLAG);
  Inc(nStreamIndex, 4);

  CreateI4(@buffer[nStreamIndex], gfc^.VBR_seek_table.nVbrNumFrames);
  Inc(nStreamIndex, 4);

  stream_size := gfc^.VBR_seek_table.nBytesWritten + gfc^.VBR_seek_table.TotalFrameSize;
  CreateI4(@buffer[nStreamIndex], stream_size);
  Inc(nStreamIndex, 4);

  Move(btToc[0], buffer[nStreamIndex], NUMTOCENTRIES);
  Inc(nStreamIndex, NUMTOCENTRIES);

  if cfg^.error_protection <> 0 then
    CRC_writeheader(gfc, @buffer[0]);

  { CRC over everything written so far, then append LAME extension block }
  crc := 0;
  for i := 0 to Integer(nStreamIndex) - 1 do
    crc := CRC_update_lookup(buffer[i], crc);

  Inc(nStreamIndex,
      PutLameVBR(gfp, stream_size, @buffer[nStreamIndex], crc));

  Result := gfc^.VBR_seek_table.TotalFrameSize;
end;

function PutVbrTag(gfp: PLameGlobalFlags; fpStream: TStream): Integer;
var
  gfc: PLameInternalFlags;
  lFileSize: Int64;
  id3v2TagSize: Int64;
  nbytes: Cardinal;
  buffer: array[0..MAXFRAMESIZE - 1] of Byte;
begin
  gfc := gfp^.internal_flags;

  if gfc^.VBR_seek_table.pos <= 0 then
  begin
    Result := -1;
    Exit;
  end;

  fpStream.Seek(0, soEnd);
  lFileSize := fpStream.Position;

  if lFileSize = 0 then
  begin
    Result := -1;
    Exit;
  end;

  id3v2TagSize := skipId3v2(fpStream);
  if id3v2TagSize < 0 then
  begin
    Result := Integer(id3v2TagSize);
    Exit;
  end;

  fpStream.Seek(id3v2TagSize, soBeginning);

  nbytes := lame_get_lametag_frame(gfp, @buffer[0], SizeOf(buffer));
  if nbytes > SizeOf(buffer) then
  begin
    Result := -1;
    Exit;
  end;

  if nbytes < 1 then
  begin
    Result := 0;
    Exit;
  end;

  if fpStream.Write(buffer[0], nbytes) <> Integer(nbytes) then
  begin
    Result := -1;
    Exit;
  end;

  Result := 0;
end;

end.
