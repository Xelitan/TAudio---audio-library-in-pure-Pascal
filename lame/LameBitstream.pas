{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameBitstream;

// LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
// Author: www.xelitan.com
// MP3 bitstream output: frame headers, Huffman coding, bit reservoir output
// Translated from bitstream.c  (and UpdateMusicCRC from VbrTag.c)

interface

uses LameTypes, LameTables, Math, SysUtils;

const
  MAX_LENGTH       = 32;
  CRC16_POLYNOMIAL = $8005;
  LAME_MAXMP3BUFFER = 147456; { 16384 + 131072 (128 KB album art) }
  BUFFER_SIZE      = LAME_MAXMP3BUFFER;

{ Compute frame length in bits for given kbps and padding flag }
function  calcFrameLength(const cfg: TSessionConfig_t; kbps, pad: Integer): Integer;

{ Compute bits per frame using current bitrate_index / avg_bitrate }
function  getframebits(gfc: PLameInternalFlags): Integer;

{ Compute maximum mp3 output buffer size for a given constraint (0/1/2) }
function  get_max_frame_buffer_size_by_constraint(
            const cfg: TSessionConfig_t; constraint: Integer): Integer;

{ Write CRC-16 protection into frame header bytes 4-5 }
procedure CRC_writeheader(gfc: PLameInternalFlags; header: PByte);

{ Update the music CRC (CRC-16 Modbus style, lookup-table version) }
procedure UpdateMusicCRC(var crc: Word; buffer: PByte; size: Integer);

{ Return bits needed to flush all buffered mp3 frames; also sets
  total_bytes_output to total output byte count if flushed right now }
function  compute_flushbits(gfc: PLameInternalFlags;
                             out total_bytes_output: Integer): Integer;

{ Pad to byte boundary and clear the bit reservoir }
procedure flush_bitstream(gfc: PLameInternalFlags);

{ Append n copies of byte val to the bitstream (used for VBR tag padding) }
procedure add_dummy_byte(gfc: PLameInternalFlags; val: Byte; n: Cardinal);

{ Format one complete frame: ancillary drain + side-info + main-data }
function  format_bitstream(gfc: PLameInternalFlags): Integer;

{ Copy internal mp3 byte buffer to caller-supplied buffer.
  mp3data <> 0 means this is real mp3 data (updates CRC and byte counter). }
function  copy_buffer(gfc: PLameInternalFlags; buffer: PByte;
                      size: Integer; mp3data: Integer): Integer;

{ Initialise the bit-stream state at the start of encoding }
procedure init_bit_stream_w(gfc: PLameInternalFlags);

implementation

{$POINTERMATH ON}

{ -----------------------------------------------------------------------
  CRC-16 lookup table  (same polynomial as used in UpdateMusicCRC / VbrTag.c)
----------------------------------------------------------------------- }
const
  crc16_lookup: array[0..255] of Word = (
    $0000,$C0C1,$C181,$0140,$C301,$03C0,$0280,$C241,
    $C601,$06C0,$0780,$C741,$0500,$C5C1,$C481,$0440,
    $CC01,$0CC0,$0D80,$CD41,$0F00,$CFC1,$CE81,$0E40,
    $0A00,$CAC1,$CB81,$0B40,$C901,$09C0,$0880,$C841,
    $D801,$18C0,$1980,$D941,$1B00,$DBC1,$DA81,$1A40,
    $1E00,$DEC1,$DF81,$1F40,$DD01,$1DC0,$1C80,$DC41,
    $1400,$D4C1,$D581,$1540,$D701,$17C0,$1680,$D641,
    $D201,$12C0,$1380,$D341,$1100,$D1C1,$D081,$1040,
    $F001,$30C0,$3180,$F141,$3300,$F3C1,$F281,$3240,
    $3600,$F6C1,$F781,$3740,$F501,$35C0,$3480,$F441,
    $3C00,$FCC1,$FD81,$3D40,$FF01,$3FC0,$3E80,$FE41,
    $FA01,$3AC0,$3B80,$FB41,$3900,$F9C1,$F881,$3840,
    $2800,$E8C1,$E981,$2940,$EB01,$2BC0,$2A80,$EA41,
    $EE01,$2EC0,$2F80,$EF41,$2D00,$EDC1,$EC81,$2C40,
    $E401,$24C0,$2580,$E541,$2700,$E7C1,$E681,$2640,
    $2200,$E2C1,$E381,$2340,$E101,$21C0,$2080,$E041,
    $A001,$60C0,$6180,$A141,$6300,$A3C1,$A281,$6240,
    $6600,$A6C1,$A781,$6740,$A501,$65C0,$6480,$A441,
    $6C00,$ACC1,$AD81,$6D40,$AF01,$6FC0,$6E80,$AE41,
    $AA01,$6AC0,$6B80,$AB41,$6900,$A9C1,$A881,$6840,
    $7800,$B8C1,$B981,$7940,$BB01,$7BC0,$7A80,$BA41,
    $BE01,$7EC0,$7F80,$BF41,$7D00,$BDC1,$BC81,$7C40,
    $B401,$74C0,$7580,$B541,$7700,$B7C1,$B681,$7640,
    $7200,$B2C1,$B381,$7340,$B101,$71C0,$7080,$B041,
    $5000,$90C1,$9181,$5140,$9301,$53C0,$5280,$9241,
    $9601,$56C0,$5780,$9741,$5500,$95C1,$9481,$5440,
    $9C01,$5CC0,$5D80,$9D41,$5F00,$9FC1,$9E81,$5E40,
    $5A00,$9AC1,$9B81,$5B40,$9901,$59C0,$5880,$9841,
    $8801,$48C0,$4980,$8941,$4B00,$8BC1,$8A81,$4A40,
    $4E00,$8EC1,$8F81,$4F40,$8D01,$4DC0,$4C80,$8C41,
    $4400,$84C1,$8581,$4540,$8701,$47C0,$4680,$8641,
    $8201,$42C0,$4380,$8341,$4100,$81C1,$8081,$4040
  );

{ -----------------------------------------------------------------------
  Public utilities
----------------------------------------------------------------------- }

function calcFrameLength(const cfg: TSessionConfig_t; kbps, pad: Integer): Integer;
begin
  Result := 8 * ((cfg.version + 1) * 72000 * kbps div cfg.samplerate_out + pad);
end;

function getframebits(gfc: PLameInternalFlags): Integer;
var
  bit_rate: Integer;
begin
  if gfc^.ov_enc.bitrate_index <> 0 then
    bit_rate := bitrate_table[gfc^.cfg.version][gfc^.ov_enc.bitrate_index]
  else
    bit_rate := gfc^.cfg.avg_bitrate;
  Result := calcFrameLength(gfc^.cfg, bit_rate, gfc^.ov_enc.padding);
end;

function get_max_frame_buffer_size_by_constraint(
           const cfg: TSessionConfig_t; constraint: Integer): Integer;
var
  max_kbps: Integer;
begin
  if cfg.avg_bitrate > 320 then
  begin
    if constraint = Ord(MDB_STRICT_ISO) then
      Result := calcFrameLength(cfg, cfg.avg_bitrate, 0)
    else
      Result := 7680 * (cfg.version + 1);
  end
  else
  begin
    if cfg.samplerate_out < 16000 then
      max_kbps := bitrate_table[cfg.version][8]
    else
      max_kbps := bitrate_table[cfg.version][14];

    case constraint of
      Ord(MDB_STRICT_ISO): Result := calcFrameLength(cfg, max_kbps, 0);
      Ord(MDB_MAXIMUM):    Result := 7680 * (cfg.version + 1);
    else
      Result := 8 * 1440;   { MDB_DEFAULT }
    end;
  end;
end;

{ -----------------------------------------------------------------------
  CRC helpers
----------------------------------------------------------------------- }

function CRC_update_byte(value: Word; crc: Word): Word;
var tmp: Word;
begin
  tmp    := crc xor value;
  Result := (crc shr 8) xor crc16_lookup[tmp and $FF];
end;

function CRC_update(value, crc: Integer): Integer;
var
  i: Integer;
begin
  value := value shl 8;
  for i := 0 to 7 do
  begin
    value := value shl 1;
    crc   := crc   shl 1;
    if ((crc xor value) and $10000) <> 0 then
      crc := crc xor CRC16_POLYNOMIAL;
  end;
  Result := crc;
end;

procedure CRC_writeheader(gfc: PLameInternalFlags; header: PByte);
var
  crc, i: Integer;
begin
  crc := $FFFF;
  crc := CRC_update(header[2], crc);
  crc := CRC_update(header[3], crc);
  for i := 6 to gfc^.cfg.sideinfo_len - 1 do
    crc := CRC_update(header[i], crc);
  header[4] := Byte(crc shr 8);
  header[5] := Byte(crc and 255);
end;

procedure UpdateMusicCRC(var crc: Word; buffer: PByte; size: Integer);
var
  i: Integer;
begin
  for i := 0 to size - 1 do
    crc := CRC_update_byte(buffer[i], crc);
end;

{ -----------------------------------------------------------------------
  Low-level bit writers
----------------------------------------------------------------------- }

{ Insert the current pending header into the bit buffer }
procedure putheader_bits(gfc: PLameInternalFlags);
var
  bs:  PBitStreamStruc;
  esv: PEncStateVar_t;
begin
  bs  := @gfc^.bs;
  esv := @gfc^.sv_enc;
  Move(esv^.header[esv^.w_ptr].buf[0],
       bs^.buf[bs^.buf_byte_idx],
       gfc^.cfg.sideinfo_len);
  Inc(bs^.buf_byte_idx, gfc^.cfg.sideinfo_len);
  Inc(bs^.totbit, gfc^.cfg.sideinfo_len * 8);
  esv^.w_ptr := (esv^.w_ptr + 1) and (MAX_HEADER_BUF - 1);
end;

{ Write j bits of val, inserting frame headers at the right bit position }
procedure putbits2(gfc: PLameInternalFlags; val, j: Integer);
var
  bs:  PBitStreamStruc;
  esv: PEncStateVar_t;
  k:   Integer;
begin
  bs  := @gfc^.bs;
  esv := @gfc^.sv_enc;

  while j > 0 do
  begin
    if bs^.buf_bit_idx = 0 then
    begin
      bs^.buf_bit_idx := 8;
      Inc(bs^.buf_byte_idx);
      { insert header if its write_timing matches current bit position }
      if esv^.header[esv^.w_ptr].write_timing = bs^.totbit then
        putheader_bits(gfc);
      bs^.buf[bs^.buf_byte_idx] := 0;
    end;

    k := j;
    if k > bs^.buf_bit_idx then k := bs^.buf_bit_idx;
    Dec(j, k);
    Dec(bs^.buf_bit_idx, k);
    bs^.buf[bs^.buf_byte_idx] :=
      bs^.buf[bs^.buf_byte_idx] or Byte((val shr j) shl bs^.buf_bit_idx);
    Inc(bs^.totbit, k);
  end;
end;

{ Write j bits of val with no header insertion (for ancillary/padding data) }
procedure putbits_noheaders(gfc: PLameInternalFlags; val, j: Integer);
var
  bs: PBitStreamStruc;
  k:  Integer;
begin
  bs := @gfc^.bs;
  while j > 0 do
  begin
    if bs^.buf_bit_idx = 0 then
    begin
      bs^.buf_bit_idx := 8;
      Inc(bs^.buf_byte_idx);
      bs^.buf[bs^.buf_byte_idx] := 0;
    end;
    k := j;
    if k > bs^.buf_bit_idx then k := bs^.buf_bit_idx;
    Dec(j, k);
    Dec(bs^.buf_bit_idx, k);
    bs^.buf[bs^.buf_byte_idx] :=
      bs^.buf[bs^.buf_byte_idx] or Byte((val shr j) shl bs^.buf_bit_idx);
    Inc(bs^.totbit, k);
  end;
end;

{ Fill remainingBits with the LAME ancillary signature + version string }
procedure drain_into_ancillary(gfc: PLameInternalFlags; remainingBits: Integer);
const
  version_str: AnsiString = '3.100';
var
  i:   Integer;
  esv: PEncStateVar_t;
begin
  esv := @gfc^.sv_enc;

  if remainingBits >= 8 then begin putbits2(gfc, $4C, 8); Dec(remainingBits, 8); end;
  if remainingBits >= 8 then begin putbits2(gfc, $41, 8); Dec(remainingBits, 8); end;
  if remainingBits >= 8 then begin putbits2(gfc, $4D, 8); Dec(remainingBits, 8); end;
  if remainingBits >= 8 then begin putbits2(gfc, $45, 8); Dec(remainingBits, 8); end;

  if remainingBits >= 32 then
    for i := 1 to Length(version_str) do
    begin
      if remainingBits < 8 then Break;
      putbits2(gfc, Ord(version_str[i]), 8);
      Dec(remainingBits, 8);
    end;

  while remainingBits >= 1 do
  begin
    putbits2(gfc, esv^.ancillary_flag, 1);
    if gfc^.cfg.disable_reservoir = 0 then
      esv^.ancillary_flag := esv^.ancillary_flag xor 1;
    Dec(remainingBits);
  end;
end;

{ -----------------------------------------------------------------------
  Header assembly
----------------------------------------------------------------------- }

{ Append j bits of val to the current header buffer (bit by bit) }
procedure writeheader(gfc: PLameInternalFlags; val, j: Integer);
var
  esv: PEncStateVar_t;
  ptr, k: Integer;
begin
  esv := @gfc^.sv_enc;
  ptr := esv^.header[esv^.h_ptr].ptr;
  while j > 0 do
  begin
    k := 8 - (ptr and 7);
    if k > j then k := j;
    Dec(j, k);
    esv^.header[esv^.h_ptr].buf[ptr shr 3] :=
      esv^.header[esv^.h_ptr].buf[ptr shr 3] or
      Byte((val shr j) shl (8 - (ptr and 7) - k));
    Inc(ptr, k);
  end;
  esv^.header[esv^.h_ptr].ptr := ptr;
end;

{ Build the complete MPEG side-info header for one frame }
procedure encodeSideInfo2(gfc: PLameInternalFlags; bitsPerFrame: Integer);
var
  cfg:    PSessionConfig_t;
  eov:    PEncResult_t;
  esv:    PEncStateVar_t;
  l3side: PIIISideInfo;
  gr, ch, band: Integer;
  gi:     PGrInfo;
  old:    Integer;
begin
  cfg    := @gfc^.cfg;
  eov    := @gfc^.ov_enc;
  esv    := @gfc^.sv_enc;
  l3side := @gfc^.l3_side;

  esv^.header[esv^.h_ptr].ptr := 0;
  FillChar(esv^.header[esv^.h_ptr].buf[0], cfg^.sideinfo_len, 0);

  if cfg^.samplerate_out < 16000 then
    writeheader(gfc, $FFE, 12)
  else
    writeheader(gfc, $FFF, 12);
  writeheader(gfc, cfg^.version,         1);
  writeheader(gfc, 4 - 3,                2);  { layer III }
  if cfg^.error_protection <> 0 then writeheader(gfc, 0, 1)
                                 else writeheader(gfc, 1, 1);
  writeheader(gfc, eov^.bitrate_index,   4);
  writeheader(gfc, cfg^.samplerate_index,2);
  writeheader(gfc, eov^.padding,         1);
  writeheader(gfc, cfg^.extension,       1);
  writeheader(gfc, Ord(cfg^.mode),       2);
  writeheader(gfc, eov^.mode_ext,        2);
  writeheader(gfc, cfg^.copyright,       1);
  writeheader(gfc, cfg^.original,        1);
  writeheader(gfc, cfg^.emphasis,        2);
  if cfg^.error_protection <> 0 then
    writeheader(gfc, 0, 16);  { placeholder - filled by CRC_writeheader }

  if cfg^.version = 1 then
  begin
    { --- MPEG-1 --- }
    writeheader(gfc, l3side^.main_data_begin, 9);
    if cfg^.channels_out = 2 then
      writeheader(gfc, l3side^.private_bits, 3)
    else
      writeheader(gfc, l3side^.private_bits, 5);

    for ch := 0 to cfg^.channels_out - 1 do
      for band := 0 to 3 do
        writeheader(gfc, l3side^.scfsi[ch][band], 1);

    for gr := 0 to 1 do
      for ch := 0 to cfg^.channels_out - 1 do
      begin
        gi := @l3side^.tt[gr][ch];
        writeheader(gfc, gi^.part2_3_length + gi^.part2_length, 12);
        writeheader(gfc, gi^.big_values div 2,   9);
        writeheader(gfc, gi^.global_gain,        8);
        writeheader(gfc, gi^.scalefac_compress,  4);
        if gi^.block_type <> NORM_TYPE then
        begin
          writeheader(gfc, 1,                    1);
          writeheader(gfc, gi^.block_type,       2);
          writeheader(gfc, gi^.mixed_block_flag, 1);
          if gi^.table_select[0] = 14 then gi^.table_select[0] := 16;
          writeheader(gfc, gi^.table_select[0],  5);
          if gi^.table_select[1] = 14 then gi^.table_select[1] := 16;
          writeheader(gfc, gi^.table_select[1],  5);
          writeheader(gfc, gi^.subblock_gain[0], 3);
          writeheader(gfc, gi^.subblock_gain[1], 3);
          writeheader(gfc, gi^.subblock_gain[2], 3);
        end
        else
        begin
          writeheader(gfc, 0,                    1);
          if gi^.table_select[0] = 14 then gi^.table_select[0] := 16;
          writeheader(gfc, gi^.table_select[0],  5);
          if gi^.table_select[1] = 14 then gi^.table_select[1] := 16;
          writeheader(gfc, gi^.table_select[1],  5);
          if gi^.table_select[2] = 14 then gi^.table_select[2] := 16;
          writeheader(gfc, gi^.table_select[2],  5);
          writeheader(gfc, gi^.region0_count,    4);
          writeheader(gfc, gi^.region1_count,    3);
        end;
        writeheader(gfc, gi^.preflag,            1);
        writeheader(gfc, gi^.scalefac_scale,     1);
        writeheader(gfc, gi^.count1table_select, 1);
      end;
  end
  else
  begin
    { --- MPEG-2 --- }
    writeheader(gfc, l3side^.main_data_begin, 8);
    writeheader(gfc, l3side^.private_bits, cfg^.channels_out);
    gr := 0;
    for ch := 0 to cfg^.channels_out - 1 do
    begin
      gi := @l3side^.tt[gr][ch];
      writeheader(gfc, gi^.part2_3_length + gi^.part2_length, 12);
      writeheader(gfc, gi^.big_values div 2,   9);
      writeheader(gfc, gi^.global_gain,        8);
      writeheader(gfc, gi^.scalefac_compress,  9);
      if gi^.block_type <> NORM_TYPE then
      begin
        writeheader(gfc, 1,                    1);
        writeheader(gfc, gi^.block_type,       2);
        writeheader(gfc, gi^.mixed_block_flag, 1);
        if gi^.table_select[0] = 14 then gi^.table_select[0] := 16;
        writeheader(gfc, gi^.table_select[0],  5);
        if gi^.table_select[1] = 14 then gi^.table_select[1] := 16;
        writeheader(gfc, gi^.table_select[1],  5);
        writeheader(gfc, gi^.subblock_gain[0], 3);
        writeheader(gfc, gi^.subblock_gain[1], 3);
        writeheader(gfc, gi^.subblock_gain[2], 3);
      end
      else
      begin
        writeheader(gfc, 0,                    1);
        if gi^.table_select[0] = 14 then gi^.table_select[0] := 16;
        writeheader(gfc, gi^.table_select[0],  5);
        if gi^.table_select[1] = 14 then gi^.table_select[1] := 16;
        writeheader(gfc, gi^.table_select[1],  5);
        if gi^.table_select[2] = 14 then gi^.table_select[2] := 16;
        writeheader(gfc, gi^.table_select[2],  5);
        writeheader(gfc, gi^.region0_count,    4);
        writeheader(gfc, gi^.region1_count,    3);
      end;
      writeheader(gfc, gi^.scalefac_scale,     1);
      writeheader(gfc, gi^.count1table_select, 1);
    end;
  end;

  if cfg^.error_protection <> 0 then
    CRC_writeheader(gfc, @esv^.header[esv^.h_ptr].buf[0]);

  { advance header pointer and set the timing for the next frame }
  old := esv^.h_ptr;
  esv^.h_ptr := (old + 1) and (MAX_HEADER_BUF - 1);
  esv^.header[esv^.h_ptr].write_timing :=
    esv^.header[old].write_timing + bitsPerFrame;
end;

{ -----------------------------------------------------------------------
  Huffman coding
----------------------------------------------------------------------- }

{ Encode the count1 region (quads of 0/1 values) using table 32 or 33 }
function huffman_coder_count1(gfc: PLameInternalFlags;
                               const gi: TGrInfo): Integer;
var
  h:           PHuffCodeTab;
  i, bits:     Integer;
  p, v, huffbits: Integer;
  ix, xr:      Integer;  { base indices }
begin
  h    := @ht[gi.count1table_select + 32];
  bits := 0;
  ix   := gi.big_values;
  xr   := gi.big_values;

  i := (gi.count1 - gi.big_values) div 4;
  while i > 0 do
  begin
    huffbits := 0;
    p        := 0;

    v := gi.l3_enc[ix + 0];
    if v <> 0 then
    begin
      Inc(p, 8);
      if gi.xr[xr + 0] < 0.0 then Inc(huffbits);
    end;

    v := gi.l3_enc[ix + 1];
    if v <> 0 then
    begin
      Inc(p, 4);
      huffbits := huffbits * 2;
      if gi.xr[xr + 1] < 0.0 then Inc(huffbits);
    end;

    v := gi.l3_enc[ix + 2];
    if v <> 0 then
    begin
      Inc(p, 2);
      huffbits := huffbits * 2;
      if gi.xr[xr + 2] < 0.0 then Inc(huffbits);
    end;

    v := gi.l3_enc[ix + 3];
    if v <> 0 then
    begin
      Inc(p, 1);
      huffbits := huffbits * 2;
      if gi.xr[xr + 3] < 0.0 then Inc(huffbits);
    end;

    Inc(ix, 4);
    Inc(xr, 4);

    putbits2(gfc, huffbits + h^.table[p], h^.hlen[p]);
    Inc(bits, h^.hlen[p]);
    Dec(i);
  end;
  Result := bits;
end;

{ Encode a range of big-value pairs using the specified Huffman table }
function Huffmancode(gfc: PLameInternalFlags; tableindex: Cardinal;
                     istart, istop: Integer; const gi: TGrInfo): Integer;
var
  h:           PHuffCodeTab;
  linbits:     Cardinal;
  i, bits:     Integer;
  cbits:       Integer;
  xbits:       Cardinal;
  xlen:        Cardinal;
  ext:         Cardinal;
  x1, x2:     Cardinal;
  linbits_x:   Cardinal;
begin
  bits := 0;
  if tableindex = 0 then begin Result := 0; Exit; end;

  h       := @ht[tableindex];
  linbits := h^.xlen;
  i       := istart;

  while i < istop do
  begin
    cbits := 0;
    xbits := 0;
    xlen  := h^.xlen;
    ext   := 0;
    x1    := gi.l3_enc[i];
    x2    := gi.l3_enc[i + 1];

    if x1 <> 0 then
    begin
      if gi.xr[i] < 0.0 then Inc(ext);
      Dec(cbits);
    end;

    if tableindex > 15 then
    begin
      { ESC-word encoding }
      if x1 >= 15 then
      begin
        linbits_x := x1 - 15;
        ext       := ext or (linbits_x shl 1);
        xbits     := linbits;
        x1        := 15;
      end;
      if x2 >= 15 then
      begin
        linbits_x := x2 - 15;
        ext       := (ext shl linbits) or linbits_x;
        Inc(xbits, linbits);
        x2        := 15;
      end;
      xlen := 16;
    end;

    if x2 <> 0 then
    begin
      ext := ext shl 1;
      if gi.xr[i + 1] < 0.0 then Inc(ext);
      Dec(cbits);
    end;

    x1 := x1 * xlen + x2;

    { xbits -= cbits  (cbits is negative or zero, so this adds to xbits) }
    if cbits < 0 then
      Inc(xbits, Cardinal(-cbits))
    else
      Dec(xbits, Cardinal(cbits));

    cbits := cbits + Integer(h^.hlen[x1]);

    putbits2(gfc, h^.table[x1], cbits);
    putbits2(gfc, Integer(ext), Integer(xbits));
    Inc(bits, cbits + Integer(xbits));

    Inc(i, 2);
  end;
  Result := bits;
end;

{ Huffman-code the big-values for a SHORT block (two regions, no region2) }
function ShortHuffmancodebits(gfc: PLameInternalFlags;
                               const gi: TGrInfo): Integer;
var
  region1Start: Integer;
begin
  region1Start := 3 * gfc^.scalefac_band.s[3];
  if region1Start > gi.big_values then
    region1Start := gi.big_values;

  Result := Huffmancode(gfc, gi.table_select[0], 0, region1Start, gi) +
            Huffmancode(gfc, gi.table_select[1], region1Start, gi.big_values, gi);
end;

{ Huffman-code the big-values for a LONG block (three regions) }
function LongHuffmancodebits(gfc: PLameInternalFlags;
                              const gi: TGrInfo): Integer;
var
  bigvalues, region1Start, region2Start: Integer;
  idx: Cardinal;
begin
  bigvalues := gi.big_values;
  idx := Cardinal(gi.region0_count + 1);
  region1Start := gfc^.scalefac_band.l[idx];
  Inc(idx, Cardinal(gi.region1_count + 1));
  region2Start := gfc^.scalefac_band.l[idx];

  if region1Start > bigvalues then region1Start := bigvalues;
  if region2Start > bigvalues then region2Start := bigvalues;

  Result :=
    Huffmancode(gfc, gi.table_select[0], 0,            region1Start, gi) +
    Huffmancode(gfc, gi.table_select[1], region1Start, region2Start, gi) +
    Huffmancode(gfc, gi.table_select[2], region2Start, bigvalues,    gi);
end;

{ Write all scalefactors and Huffman data for all granules/channels }
function writeMainData(gfc: PLameInternalFlags): Integer;
var
  cfg:          PSessionConfig_t;
  l3side:       PIIISideInfo;
  gr, ch, sfb: Integer;
  i, sfb_partition: Integer;
  data_bits, scale_bits, tot_bits: Integer;
  gi:           PGrInfo;
  slen1, slen2: Integer;
  sfbs, slen:   Integer;
begin
  cfg      := @gfc^.cfg;
  l3side   := @gfc^.l3_side;
  tot_bits := 0;

  if cfg^.version = 1 then
  begin
    { MPEG-1: 2 granules }
    for gr := 0 to 1 do
      for ch := 0 to cfg^.channels_out - 1 do
      begin
        gi        := @l3side^.tt[gr][ch];
        slen1     := slen1_tab[gi^.scalefac_compress];
        slen2     := slen2_tab[gi^.scalefac_compress];
        data_bits := 0;

        { scalefactors part 1 }
        for sfb := 0 to gi^.sfbdivide - 1 do
        begin
          if gi^.scalefac[sfb] = -1 then Continue;  { shared via scfsi }
          putbits2(gfc, gi^.scalefac[sfb], slen1);
          Inc(data_bits, slen1);
        end;
        { scalefactors part 2 }
        sfb := gi^.sfbdivide;
        while sfb < gi^.sfbmax do
        begin
          if gi^.scalefac[sfb] <> -1 then
          begin
            putbits2(gfc, gi^.scalefac[sfb], slen2);
            Inc(data_bits, slen2);
          end;
          Inc(sfb);
        end;

        if gi^.block_type = SHORT_TYPE then
          Inc(data_bits, ShortHuffmancodebits(gfc, gi^))
        else
          Inc(data_bits, LongHuffmancodebits(gfc, gi^));
        Inc(data_bits, huffman_coder_count1(gfc, gi^));
        Inc(tot_bits, data_bits);
      end;
  end
  else
  begin
    { MPEG-2: 1 granule }
    gr := 0;
    for ch := 0 to cfg^.channels_out - 1 do
    begin
      gi            := @l3side^.tt[gr][ch];
      data_bits     := 0;
      scale_bits    := 0;
      sfb           := 0;
      sfb_partition := 0;

      if gi^.block_type = SHORT_TYPE then
      begin
        while sfb_partition < 4 do
        begin
          sfbs := gi^.sfb_partition_table[sfb_partition] div 3;
          slen := gi^.slen[sfb_partition];
          for i := 0 to sfbs - 1 do
          begin
            putbits2(gfc, Math.Max(gi^.scalefac[sfb * 3 + 0], 0), slen);
            putbits2(gfc, Math.Max(gi^.scalefac[sfb * 3 + 1], 0), slen);
            putbits2(gfc, Math.Max(gi^.scalefac[sfb * 3 + 2], 0), slen);
            Inc(scale_bits, 3 * slen);
            Inc(sfb);
          end;
          Inc(sfb_partition);
        end;
        Inc(data_bits, ShortHuffmancodebits(gfc, gi^));
      end
      else
      begin
        while sfb_partition < 4 do
        begin
          sfbs := gi^.sfb_partition_table[sfb_partition];
          slen := gi^.slen[sfb_partition];
          for i := 0 to sfbs - 1 do
          begin
            putbits2(gfc, Math.Max(gi^.scalefac[sfb], 0), slen);
            Inc(scale_bits, slen);
            Inc(sfb);
          end;
          Inc(sfb_partition);
        end;
        Inc(data_bits, LongHuffmancodebits(gfc, gi^));
      end;
      Inc(data_bits, huffman_coder_count1(gfc, gi^));
      Inc(tot_bits, scale_bits + data_bits);
    end;
  end;

  Result := tot_bits;
end;

{ -----------------------------------------------------------------------
  Public functions
----------------------------------------------------------------------- }

function compute_flushbits(gfc: PLameInternalFlags;
                            out total_bytes_output: Integer): Integer;
var
  cfg:                PSessionConfig_t;
  esv:                PEncStateVar_t;
  flushbits:          Integer;
  remaining_headers:  Integer;
  bitsPerFrame:       Integer;
  last_ptr, first_ptr: Integer;
begin
  cfg       := @gfc^.cfg;
  esv       := @gfc^.sv_enc;
  first_ptr := esv^.w_ptr;
  last_ptr  := esv^.h_ptr - 1;
  if last_ptr = -1 then last_ptr := MAX_HEADER_BUF - 1;

  flushbits          := esv^.header[last_ptr].write_timing - gfc^.bs.totbit;
  total_bytes_output := flushbits;

  if flushbits >= 0 then
  begin
    remaining_headers := 1 + last_ptr - first_ptr;
    if last_ptr < first_ptr then
      Inc(remaining_headers, MAX_HEADER_BUF);
    Dec(flushbits, remaining_headers * 8 * cfg^.sideinfo_len);
  end;

  bitsPerFrame := getframebits(gfc);
  Inc(flushbits, bitsPerFrame);
  Inc(total_bytes_output, bitsPerFrame);

  if total_bytes_output mod 8 <> 0 then
    total_bytes_output := 1 + total_bytes_output div 8
  else
    total_bytes_output := total_bytes_output div 8;
  Inc(total_bytes_output, gfc^.bs.buf_byte_idx + 1);

  Result := flushbits;
end;

procedure flush_bitstream(gfc: PLameInternalFlags);
var
  esv:      PEncStateVar_t;
  l3side:   PIIISideInfo;
  nbytes:   Integer;
  flushbits: Integer;
begin
  esv    := @gfc^.sv_enc;
  l3side := @gfc^.l3_side;

  flushbits := compute_flushbits(gfc, nbytes);
  if flushbits < 0 then Exit;
  drain_into_ancillary(gfc, flushbits);
  esv^.ResvSize           := 0;
  l3side^.main_data_begin := 0;
end;

procedure add_dummy_byte(gfc: PLameInternalFlags; val: Byte; n: Cardinal);
var
  esv: PEncStateVar_t;
  i:   Integer;
begin
  esv := @gfc^.sv_enc;
  while n > 0 do
  begin
    putbits_noheaders(gfc, val, 8);
    for i := 0 to MAX_HEADER_BUF - 1 do
      Inc(esv^.header[i].write_timing, 8);
    Dec(n);
  end;
end;

function format_bitstream(gfc: PLameInternalFlags): Integer;
var
  cfg:          PSessionConfig_t;
  esv:          PEncStateVar_t;
  l3side:       PIIISideInfo;
  bits, nbytes: Integer;
  bitsPerFrame: Integer;
  i:            Integer;
begin
  cfg    := @gfc^.cfg;
  esv    := @gfc^.sv_enc;
  l3side := @gfc^.l3_side;

  bitsPerFrame := getframebits(gfc);
  drain_into_ancillary(gfc, l3side^.resvDrain_pre);

  encodeSideInfo2(gfc, bitsPerFrame);
  bits := 8 * cfg^.sideinfo_len;
  Inc(bits, writeMainData(gfc));
  drain_into_ancillary(gfc, l3side^.resvDrain_post);
  Inc(bits, l3side^.resvDrain_post);

  Inc(l3side^.main_data_begin, (bitsPerFrame - bits) div 8);

  { prevent totbit overflow (e.g. after 8 h at 128 kbps) }
  if gfc^.bs.totbit > 1000000000 then
  begin
    for i := 0 to MAX_HEADER_BUF - 1 do
      Dec(esv^.header[i].write_timing, gfc^.bs.totbit);
    gfc^.bs.totbit := 0;
  end;

  { verify reservoir consistency (non-fatal in Pascal release build) }
  if compute_flushbits(gfc, nbytes) <> esv^.ResvSize then
    esv^.ResvSize := l3side^.main_data_begin * 8;
  if (l3side^.main_data_begin * 8) <> esv^.ResvSize then
    esv^.ResvSize := l3side^.main_data_begin * 8;

  Result := 0;
end;

function copy_buffer(gfc: PLameInternalFlags; buffer: PByte;
                     size: Integer; mp3data: Integer): Integer;
var
  bs:      PBitStreamStruc;
  minimum: Integer;
begin
  bs      := @gfc^.bs;
  minimum := bs^.buf_byte_idx + 1;
  if minimum <= 0 then begin Result := 0; Exit; end;
  if minimum > size then begin Result := -1; Exit; end;

  Move(bs^.buf^, buffer^, minimum);
  bs^.buf_byte_idx := -1;
  bs^.buf_bit_idx  := 0;

  if (minimum > 0) and (mp3data <> 0) then
  begin
    UpdateMusicCRC(gfc^.nMusicCRC, buffer, minimum);
    Inc(gfc^.VBR_seek_table.nBytesWritten, minimum);
  end;

  Result := minimum;
end;

procedure init_bit_stream_w(gfc: PLameInternalFlags);
var
  esv: PEncStateVar_t;
begin
  esv        := @gfc^.sv_enc;
  esv^.h_ptr := 0;
  esv^.w_ptr := 0;
  esv^.header[0].write_timing := 0;

  GetMem(gfc^.bs.buf, BUFFER_SIZE);
  FillChar(gfc^.bs.buf^, BUFFER_SIZE, 0);
  gfc^.bs.buf_size     := BUFFER_SIZE;
  gfc^.bs.buf_byte_idx := -1;
  gfc^.bs.buf_bit_idx  := 0;
  gfc^.bs.totbit       := 0;
end;

end.
