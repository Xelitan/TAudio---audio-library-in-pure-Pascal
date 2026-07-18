{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameReservoir;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Bit reservoir management: frame budget, reservoir limits, drain
//  Translated from reservoir.c


interface

uses LameTypes, LameBitstream, Math;

{
  ResvFrameBegin:
  Called at the beginning of a frame.  Updates the maximum size of the
  bit reservoir and returns the total bits available for this frame.
  Also sets *mean_bits to the average bits per granule for this frame.
}
function ResvFrameBegin(gfc: PLameInternalFlags;
                        out mean_bits: Integer): Integer;

{
  ResvMaxBits:
  Returns targ_bits (target bits for one granule) and extra_bits
  (bits available from the reservoir above the target).
  cbr = 1 when called from the first granule of a CBR frame.
}
procedure ResvMaxBits(gfc: PLameInternalFlags;
                      mean_bits: Integer;
                      out targ_bits: Integer;
                      out extra_bits: Integer;
                      cbr: Integer);

{
  ResvAdjust:
  Called after a granule is coded.  Deducts the bits used from the
  reservoir size.
}
procedure ResvAdjust(gfc: PLameInternalFlags; const gi: TGrInfo);

{
  ResvFrameEnd:
  Called after all granules in a frame are coded.  Ensures the reservoir
  does not exceed its maximum, adding stuffing bits into ancillary data
  as needed.
}
procedure ResvFrameEnd(gfc: PLameInternalFlags; mean_bits: Integer);

implementation

{ -----------------------------------------------------------------------
  ResvFrameBegin
----------------------------------------------------------------------- }

function ResvFrameBegin(gfc: PLameInternalFlags;
                        out mean_bits: Integer): Integer;
var
  cfg:           PSessionConfig_t;
  esv:           PEncStateVar_t;
  l3side:        PIIISideInfo;
  frameLength:   Integer;
  meanBits:      Integer;
  resvLimit:     Integer;
  maxmp3buf:     Integer;
  fullFrameBits: Integer;
begin
  cfg    := @gfc^.cfg;
  esv    := @gfc^.sv_enc;
  l3side := @gfc^.l3_side;

  frameLength := getframebits(gfc);
  meanBits    := (frameLength - cfg^.sideinfo_len * 8) div cfg^.mode_gr;

  { main_data_begin has 9 bits in MPEG-1, 8 bits in MPEG-2 }
  resvLimit := (8 * 256) * cfg^.mode_gr - 8;

  { maximum allowed frame size }
  maxmp3buf    := cfg^.buffer_constraint;
  esv^.ResvMax := maxmp3buf - frameLength;
  if esv^.ResvMax > resvLimit then esv^.ResvMax := resvLimit;
  if (esv^.ResvMax < 0) or (cfg^.disable_reservoir <> 0) then
    esv^.ResvMax := 0;

  fullFrameBits := meanBits * cfg^.mode_gr +
                   Min(esv^.ResvSize, esv^.ResvMax);
  if fullFrameBits > maxmp3buf then
    fullFrameBits := maxmp3buf;

  l3side^.resvDrain_pre := 0;

  mean_bits := meanBits;
  Result    := fullFrameBits;
end;

{ -----------------------------------------------------------------------
  ResvMaxBits
----------------------------------------------------------------------- }

procedure ResvMaxBits(gfc: PLameInternalFlags;
                      mean_bits: Integer;
                      out targ_bits: Integer;
                      out extra_bits: Integer;
                      cbr: Integer);
var
  cfg:       PSessionConfig_t;
  esv:       PEncStateVar_t;
  add_bits:  Integer;
  targBits:  Integer;
  extraBits: Integer;
  ResvSize:  Integer;
  ResvMax:   Integer;
begin
  cfg     := @gfc^.cfg;
  esv     := @gfc^.sv_enc;
  ResvSize := esv^.ResvSize;
  ResvMax  := esv^.ResvMax;

  { compensate bits saved/used in the first granule of CBR }
  if cbr <> 0 then
    Inc(ResvSize, mean_bits);

  if (gfc^.sv_qnt.substep_shaping and 1) <> 0 then
    ResvMax := Round(ResvMax * 0.9);

  targBits := mean_bits;

  { extra bits if the reservoir is nearly full }
  if ResvSize * 10 > ResvMax * 9 then
  begin
    add_bits  := ResvSize - (ResvMax * 9) div 10;
    Inc(targBits, add_bits);
    gfc^.sv_qnt.substep_shaping := gfc^.sv_qnt.substep_shaping or $80;
  end
  else
  begin
    add_bits := 0;
    gfc^.sv_qnt.substep_shaping := gfc^.sv_qnt.substep_shaping and $7F;
    { build up reservoir a little more slowly than FhG }
    if (cfg^.disable_reservoir = 0) and
       ((gfc^.sv_qnt.substep_shaping and 1) = 0) then
      targBits := targBits - Round(0.1 * mean_bits);
  end;

  { amount from reservoir we may use: ISO says 6/10 }
  if ResvSize < (ResvMax * 6) div 10 then
    extraBits := ResvSize
  else
    extraBits := (ResvMax * 6) div 10;
  Dec(extraBits, add_bits);
  if extraBits < 0 then extraBits := 0;

  targ_bits  := targBits;
  extra_bits := extraBits;
end;

{ -----------------------------------------------------------------------
  ResvAdjust
----------------------------------------------------------------------- }

procedure ResvAdjust(gfc: PLameInternalFlags; const gi: TGrInfo);
begin
  Dec(gfc^.sv_enc.ResvSize, gi.part2_3_length + gi.part2_length);
end;

{ -----------------------------------------------------------------------
  ResvFrameEnd
----------------------------------------------------------------------- }

procedure ResvFrameEnd(gfc: PLameInternalFlags; mean_bits: Integer);
var
  cfg:          PSessionConfig_t;
  esv:          PEncStateVar_t;
  l3side:       PIIISideInfo;
  stuffingBits: Integer;
  over_bits:    Integer;
  mdb_bytes:    Integer;
begin
  cfg    := @gfc^.cfg;
  esv    := @gfc^.sv_enc;
  l3side := @gfc^.l3_side;

  Inc(esv^.ResvSize, mean_bits * cfg^.mode_gr);
  stuffingBits          := 0;
  l3side^.resvDrain_post := 0;
  l3side^.resvDrain_pre  := 0;

  { must be byte-aligned }
  over_bits := esv^.ResvSize mod 8;
  if over_bits <> 0 then
    Inc(stuffingBits, over_bits);

  { must not exceed ResvMax }
  over_bits := (esv^.ResvSize - stuffingBits) - esv^.ResvMax;
  if over_bits > 0 then
    Inc(stuffingBits, over_bits);

  { drain into previous frame's ancillary data first (NEW_DRAIN) }
  mdb_bytes := Min(l3side^.main_data_begin * 8, stuffingBits) div 8;
  Inc(l3side^.resvDrain_pre, 8 * mdb_bytes);
  Dec(stuffingBits, 8 * mdb_bytes);
  Dec(esv^.ResvSize, 8 * mdb_bytes);
  Dec(l3side^.main_data_begin, mdb_bytes);

  { drain the rest into this frame's ancillary data }
  Inc(l3side^.resvDrain_post, stuffingBits);
  Dec(esv^.ResvSize, stuffingBits);
end;

end.
