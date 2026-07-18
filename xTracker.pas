unit xTracker;

{$mode delphi}{$H+}

interface

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	XelTAudio - convert and modify sound files                    //
//              Tracker module player: MOD, XM, S3M, IT                       //
// Version:	0.2                                                           //
// Date:	16-JUL-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// The IT 2.14/2.15 sample decompression is an adaptation of the algorithm   //
// from the go-zikmu project (https://github.com/olivierh59500/go-zikmu),     //
// MIT License, Copyright (c) 2026 Olivier Houte.                             //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

uses SysUtils, Classes, Math, xAudio, xAudioBase;

type
  ETrackerError = class(Exception);

  TCell = packed record
    Note, Instrument, Volume, Effect, Param: Byte;
  end;

  TPattern = record
    Rows: Integer;
    Cells: array of TCell;
  end;

  TSample = record
    Name: string;
    Data: array of SmallInt;
    LoopStart, LoopEnd: Integer;
    LoopEnabled, PingPong: Boolean;
    Volume, Panning: Integer;
    GlobalVolume: Integer;   //IT GvL 0..64; 64 = neutral for other formats
    C5Speed: Double;
    RelativeNote: Integer;
    //auto-wibrato sampla (XM/IT): typ przebiegu 0..3, glebokosc, tempo, sweep
    VibType, VibDepth, VibRate, VibSweep: Integer;
  end;

  TEnvPoint = record
    X, Y: Integer; //tick, value 0..64
  end;

  TInstrument = record
    Name: string;
    GlobalVolume: Integer;   //IT GbV 0..128; 128 = neutralnie (XM nie ma tego pola)
    NoteSample: array[0..119] of Integer;
    NoteTranspose: array[0..119] of Integer;
    //volume envelope; sustain is a loop (XM uses a single point = empty loop)
    EnvOn, EnvSustain, EnvLoop: Boolean;
    Env: array of TEnvPoint;
    EnvSusStart, EnvSusEnd: Integer;   //point indices
    EnvLoopStart, EnvLoopEnd: Integer;
    FadeOut: Integer;                  //per-tick decrement on a 0..65536 scale
    NNA: Integer;                      //IT: 0=cut, 1=continue, 2=note off, 3=fade
    DCT: Integer;                      //IT Duplicate Check Type: 0=off,1=nuta,2=sampel,3=instrument
    DCA: Integer;                      //IT Duplicate Check Action: 0=cut,1=note off,2=fade
  end;

  TModule = class
  public
    Title, FormatName: string;
    Channels, InitialSpeed, InitialTempo, Restart: Integer;
    LinearPeriods: Boolean;
    FastVolSlides: Boolean;  //S3M: volume slides also run on tick 0
    FineVolSlides: Boolean;  //S3M/IT: DxF/DFx fine slide encodings
    MixVolume: Integer;      //preamp: IT mv / S3M mastervolume / MOD 256 div kanaly; 128 = neutralnie
    GlobalSongVolume: Integer; //IT gv 0..128 / S3M gv*2; 128 = neutralnie (MOD/XM)
    PortaScale: Integer;     //pitch slide units: 1 for MOD, 4 for XM/S3M/IT
    VibCycle: Integer;       //vibrato cycle in ticks at speed 1: 128 MOD/XM, 64 S3M/IT
    Orders: array of Integer;
    Patterns: array of TPattern;
    Samples: array of TSample;
    Instruments: array of TInstrument;
    ChannelPan: array of Integer;
    constructor Create;
    procedure LoadFromStream(Str: TStream);
  end;

  { TAudioTracker }

  TAudioTracker = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

var
  //settings used when a module is loaded through TAudio
  TrackerSampleRate: Integer = 44100;
  TrackerMaxSeconds: Integer = 600;

procedure RenderModule(Module: TModule; Audio: TXelAudio;
  SampleRate: Integer = 44100; MaxSeconds: Integer = 600);

implementation

const
  FX_NONE       = 0;
  FX_ARPEGGIO   = 1;
  FX_PORTA_UP   = 2;
  FX_PORTA_DOWN = 3;
  FX_TONE_PORTA = 4;
  FX_VIBRATO    = 5;
  FX_VOLSLIDE   = 6;
  FX_JUMP       = 7;
  FX_BREAK      = 8;
  FX_SPEED      = 9;
  FX_TEMPO      = 10;
  FX_OFFSET     = 11;
  FX_PAN        = 12;
  FX_SETVOL     = 13;
  FX_RETRIG     = 14;
  FX_NOTECUT    = 15;
  FX_NOTEDELAY  = 16;
  FX_PATLOOP    = 17;
  FX_PATDELAY   = 18;
  FX_FINEUP     = 19;
  FX_FINEDOWN   = 20;
  FX_SETPAN4    = 21;
  FX_TREMOLO    = 22;
  FX_TREMOR     = 23;
  FX_FINEVIB    = 24; //Uxy (S3M/IT): vibrato o glebokosci 1/4 zwyklego
  FX_VIBVOL     = 25; //Kxy (S3M/IT): vibrato z pamieci + volume slide xy
  FX_PORTAVOL   = 26; //Lxy (S3M/IT): tone portamento z pamieci + volume slide xy
  FX_GLOBALVOL  = 27; //Vxx (S3M/IT): globalna glosnosc w czasie odtwarzania
  FX_VIBWAVE    = 28; //E4x (MOD/XM) / S3x (S3M/IT): przebieg wibrata
  FX_TREMWAVE   = 29; //E7x (MOD/XM) / S4x (S3M/IT): przebieg tremola
  FX_GLISSANDO  = 30; //E3x (MOD/XM) / S1x (S3M/IT): tone porta skokami po poltonach

type

  { TModReader - byte-level access to the whole module in memory }

  TModReader = class
  private
    FData: TBytes;
    FPos: Integer;
  public
    constructor Create(Str: TStream);
    function Size: Integer;
    procedure Seek(P: Integer);
    procedure Skip(N: Integer);
    function Pos: Integer;
    function U8: Byte;
    function S8: ShortInt;
    function U16LE: Word;
    function U16BE: Word;
    function U32LE: Cardinal;
    function FixedString(N: Integer): string;
    function Bytes(N: Integer): TBytes;
    function AtU8(P: Integer): Byte;
    function AtU16LE(P: Integer): Word;
    function AtU32LE(P: Integer): Cardinal;
    function AtString(P, N: Integer): string;
  end;

constructor TModReader.Create(Str: TStream);
var Len: Int64;
begin
  inherited Create;

  Len := Str.Size - Str.Position;
  if Len > MaxInt then raise ETrackerError.Create('Module file is too big');

  SetLength(FData, Len);
  if Len > 0 then Str.ReadBuffer(FData[0], Len);

  FPos := 0;
end;

function TModReader.Size: Integer;
begin
  Result := Length(FData);
end;

function TModReader.Pos: Integer;
begin
  Result := FPos;
end;

procedure TModReader.Seek(P: Integer);
begin
  if (P < 0) or (P > Size) then raise ETrackerError.Create('Bad offset in module');
  FPos := P;
end;

procedure TModReader.Skip(N: Integer);
begin
  Seek(FPos + N);
end;

function TModReader.U8: Byte;
begin
  if FPos >= Size then raise ETrackerError.Create('Unexpected end of module');
  Result := FData[FPos];
  Inc(FPos);
end;

function TModReader.S8: ShortInt;
begin
  Result := ShortInt(U8);
end;

function TModReader.U16LE: Word;
begin
  Result := U8;
  Result := Result or (Word(U8) shl 8);
end;

function TModReader.U16BE: Word;
begin
  Result := Word(U8) shl 8;
  Result := Result or U8;
end;

function TModReader.U32LE: Cardinal;
begin
  Result := U16LE;
  Result := Result or (Cardinal(U16LE) shl 16);
end;

function TModReader.FixedString(N: Integer): string;
var i: Integer;
    B: Byte;
begin
  Result := '';
  for i:=1 to N do begin
    B := U8;
    if B <> 0 then Result := Result + Chr(B);
  end;
  Result := TrimRight(Result);
end;

function TModReader.Bytes(N: Integer): TBytes;
begin
  Result := nil;
  if (N < 0) or (FPos + N > Size) then raise ETrackerError.Create('Corrupted module data');

  SetLength(Result, N);
  if N > 0 then Move(FData[FPos], Result[0], N);
  Inc(FPos, N);
end;

function TModReader.AtU8(P: Integer): Byte;
begin
  Seek(P);
  Result := U8;
end;

function TModReader.AtU16LE(P: Integer): Word;
begin
  Seek(P);
  Result := U16LE;
end;

function TModReader.AtU32LE(P: Integer): Cardinal;
begin
  Seek(P);
  Result := U32LE;
end;

function TModReader.AtString(P, N: Integer): string;
begin
  Seek(P);
  Result := FixedString(N);
end;

{ TModule }

constructor TModule.Create;
begin
  inherited Create;
  InitialSpeed := 6;
  InitialTempo := 125;
  MixVolume := 128; //neutralne; nadpisuja LoadIT/LoadS3M/LoadMOD
  GlobalSongVolume := 128;
  PortaScale := 4;
  VibCycle := 64;
end;

procedure InitInstrument(var I: TInstrument; DefaultSample: Integer);
var N: Integer;
begin
  for N:=0 to 119 do begin
    I.NoteSample[N] := DefaultSample;
    I.NoteTranspose[N] := N + 1;
  end;

  I.EnvOn := False;
  I.EnvSustain := False;
  I.EnvLoop := False;
  I.Env := nil;
  I.EnvSusStart := 0;
  I.EnvSusEnd := 0;
  I.EnvLoopStart := 0;
  I.EnvLoopEnd := 0;
  I.FadeOut := 0;
  I.NNA := 0;
  I.DCT := 0;
  I.DCA := 0;
  I.GlobalVolume := 128; //neutralnie; nadpisuje tylko loader IT (GbV)
end;

function ClampI(X, Lo, Hi: Integer): Integer;
begin
  if X < Lo then Result := Lo
  else if X > Hi then Result := Hi
  else Result := X;
end;

//Amiga period 428 plays the sample at ~8363 Hz; that must land on note 61,
//the note at which NoteStep() plays a sample at its C5Speed
function MODNote(Period: Integer): Integer;
begin
  if Period <= 0 then Exit(0);
  Result := ClampI(Round(61 + 12 * Log2(428.0 / Period)), 1, 120);
end;

procedure TranslateMODEffect(var C: TCell; E, P: Byte);
begin
  C.Param := P;

  case E of
    $0: if P <> 0 then C.Effect := FX_ARPEGGIO;
    $1: C.Effect := FX_PORTA_UP;
    $2: C.Effect := FX_PORTA_DOWN;
    $3: C.Effect := FX_TONE_PORTA;
    $4: C.Effect := FX_VIBRATO;
    $5: C.Effect := FX_TONE_PORTA; //volume slide is also applied by renderer
    $6: C.Effect := FX_VIBRATO;
    $7: C.Effect := FX_TREMOLO;
    $8: C.Effect := FX_PAN;
    $9: C.Effect := FX_OFFSET;
    $A: C.Effect := FX_VOLSLIDE;
    $B: C.Effect := FX_JUMP;
    $C: C.Effect := FX_SETVOL;
    $D: C.Effect := FX_BREAK;
    $E: case P shr 4 of
          $1: begin C.Effect := FX_FINEUP;    C.Param := P and 15; end;
          $2: begin C.Effect := FX_FINEDOWN;  C.Param := P and 15; end;
          $3: begin C.Effect := FX_GLISSANDO; C.Param := P and 15; end;
          $4: begin C.Effect := FX_VIBWAVE;   C.Param := P and 15; end;
          $6: begin C.Effect := FX_PATLOOP;   C.Param := P and 15; end;
          $7: begin C.Effect := FX_TREMWAVE;  C.Param := P and 15; end;
          $8: begin C.Effect := FX_SETPAN4;   C.Param := P and 15; end;
          $9: begin C.Effect := FX_RETRIG;    C.Param := P and 15; end;
          $C: begin C.Effect := FX_NOTECUT;   C.Param := P and 15; end;
          $D: begin C.Effect := FX_NOTEDELAY; C.Param := P and 15; end;
          $E: begin C.Effect := FX_PATDELAY;  C.Param := P and 15; end;
        end;
    $F: if P < 32 then C.Effect := FX_SPEED
        else C.Effect := FX_TEMPO;
    //efekty > $F wystepuja tylko w XM (loader podaje pelny bajt komendy)
    $10: C.Effect := FX_GLOBALVOL; //Gxx, 0..64 (handler podwaja do 0..128)
    $1B: C.Effect := FX_RETRIG;    //Rxy: multi-retrig z tabela glosnosci
    $1D: C.Effect := FX_TREMOR;    //Txy
  end;
end;

procedure LoadMOD(M: TModule; R: TModReader);
var i, j, k: Integer;
    PCount, SongLen, SamplePos, Period, Code, MaxPat: Integer;
    NSmp, OrdPos, PatPos: Integer;
    Sig: string;
    Lens, LS, LL: array[0..30] of Integer;
    B: Byte;
    M15: Boolean;
    C: TCell;
begin
  M.FormatName := 'MOD';
  M.Title := R.AtString(0, 20);
  M.PortaScale := 1; //MOD slides are in single period units
  //ModSinusTable ma 64 pozycje (pos and $3F, Sndmix.cpp GetVibratoDelta)
  M.VibCycle := 64;

  M15 := False;
  Sig := R.AtString(1080, 4);
  if (Sig = 'M.K.') or (Sig = 'M!K!') or (Sig = 'FLT4') then M.Channels := 4
  else if (Length(Sig) = 4) and (Sig[2] = 'C') and (Sig[3] = 'H') and (Sig[4] = 'N') then
    M.Channels := Ord(Sig[1]) - 48
  else if (Length(Sig) = 4) and (Sig[3] = 'C') and (Sig[4] = 'H') then
    M.Channels := (Ord(Sig[1]) - 48)*10 + Ord(Sig[2]) - 48
  else begin
    //brak tagu: 15-samplowy Soundtracker (M15). Nie ma pola magicznego,
    //wiec walidujemy naglowek: dlugosc utworu 1..128, glosnosci <= 64,
    //numery patternow <= 63 i miejsce na co najmniej jeden pattern.
    M15 := (R.Size >= 600 + 1024) and (R.AtU8(470) >= 1) and (R.AtU8(470) <= 128);
    if M15 then
      for i:=0 to 14 do
        if R.AtU8(20 + i*30 + 25) > 64 then M15 := False;
    if M15 then
      for i:=0 to 127 do
        if R.AtU8(472 + i) > 63 then M15 := False;
    if not M15 then
      raise ETrackerError.Create('Unsupported MOD tag: ' + Sig);
    M.Channels := 4;
  end;

  if M15 then begin NSmp := 15; OrdPos := 470; PatPos := 600; end
  else begin NSmp := 31; OrdPos := 950; PatPos := 1084; end;

  //przedwzmocnienie MOD jak w OpenMPT (Load_mod.cpp:433): 256/kanaly z widelkami
  //32..128; bez tego 4-kanalowe MOD-y graly rowno 1,5x za glosno
  M.MixVolume := ClampI(256 div Max(1, M.Channels), 32, 128);

  SetLength(M.Samples, NSmp);
  SetLength(M.Instruments, NSmp);

  for i:=0 to NSmp-1 do begin
    R.Seek(20 + i*30);
    M.Samples[i].Name := R.FixedString(22);
    Lens[i] := R.U16BE * 2;
    M.Samples[i].RelativeNote := 0;

    B := R.U8; //finetune, signed nibble in 1/8 semitone steps
    if M15 then B := 0; //Soundtracker nie ma finetune (bajt bywa smieciowy)
    if B > 7 then B := B - 16;
    M.Samples[i].C5Speed := 8363 * Power(2, ShortInt(B)/96.0);

    M.Samples[i].Volume := ClampI(R.U8, 0, 64); M.Samples[i].GlobalVolume := 64;
    M.Samples[i].Panning := 128;
    if M15 then LS[i] := R.U16BE //Soundtracker: powtorka w BAJTACH, nie slowach
    else LS[i] := R.U16BE * 2;
    LL[i] := R.U16BE * 2;

    InitInstrument(M.Instruments[i], i);
  end;

  R.Seek(OrdPos);
  SongLen := R.U8;
  B := R.U8;
  //w M15 bajt 471 to historycznie tempo/licznik (czesto 120), nie restart
  if M15 then M.Restart := 0 else M.Restart := B;
  SetLength(M.Orders, SongLen);
  MaxPat := 0;

  for i:=0 to 127 do begin
    B := R.U8;
    if i < SongLen then begin
      M.Orders[i] := B;
      if B > MaxPat then MaxPat := B;
    end;
  end;

  PCount := MaxPat + 1;
  SetLength(M.Patterns, PCount);
  R.Seek(PatPos);

  for i:=0 to PCount-1 do begin
    M.Patterns[i].Rows := 64;
    SetLength(M.Patterns[i].Cells, 64 * M.Channels);

    for j:=0 to 63 do
      for k:=0 to M.Channels-1 do begin
        Code := R.U8 shl 24;
        Code := Code or (R.U8 shl 16);
        Code := Code or (R.U8 shl 8);
        Code := Code or R.U8;

        FillChar(C, SizeOf(C), 0);
        C.Instrument := ((Code shr 24) and $F0) or ((Code shr 12) and $0F);
        Period := (Code shr 16) and $FFF;
        C.Note := MODNote(Period);
        TranslateMODEffect(C, (Code shr 8) and 15, Code and $FF);

        M.Patterns[i].Cells[j*M.Channels + k] := C;
      end;
  end;

  SamplePos := R.Pos;

  for i:=0 to NSmp-1 do begin
    SetLength(M.Samples[i].Data, Lens[i]);
    R.Seek(Min(SamplePos, R.Size));

    for j:=0 to Lens[i]-1 do
      if R.Pos < R.Size then M.Samples[i].Data[j] := SmallInt(ShortInt(R.U8)) shl 8
      else M.Samples[i].Data[j] := 0;

    Inc(SamplePos, Lens[i]);
    M.Samples[i].LoopStart := LS[i];
    M.Samples[i].LoopEnd := Min(Lens[i], LS[i] + LL[i]);
    M.Samples[i].LoopEnabled := LL[i] > 2;
  end;

  SetLength(M.ChannelPan, M.Channels);
  for i:=0 to M.Channels-1 do
    if (i and 3) in [0, 3] then M.ChannelPan[i] := 48
    else M.ChannelPan[i] := 208;
end;

procedure LoadXM(M: TModule; R: TModReader);
var HeaderSize, PatCount, InsCount: Integer;
    i, j, k, N: Integer;
    PackedSize, PH, Rows, Start, IH, NS, SH, DataStart: Integer;
    B, Mask: Byte;
    C: TCell;
    SL, LS, LL: array of Cardinal;
    Typ: array of Byte;
    Raw: TBytes;
    Acc: Integer;
    EnvPts: array of TEnvPoint;
    NVol, Sus, LSp, LEp, VType, FadeVal: Integer;
    AVType, AVSweep, AVDepth, AVRate: Integer;
begin
  if Copy(R.AtString(0, 17), 1, 16) <> 'Extended Module:' then
    raise ETrackerError.Create('Bad XM header');

  M.FormatName := 'XM';
  //Przedwzmocnienie XM ustalone empirycznie na plikach testowych z czystym
  //torem (panning-law 2,02 / position-jump 1,89 / tremolo 1,75 przy 128):
  //baza ~x2 za glosno => 64. OpenMPT trzyma dla XM domyslne 48, ale jego tor
  //ma inne stale miksu - kryterium jest rmsRatio=1,0 wzgledem libopenmpt.
  M.MixVolume := 64;
  M.Title := R.AtString(17, 20);
  M.VibCycle := 64; //ModSinusTable: 64 pozycje (pos and $3F)

  R.Seek(60);
  HeaderSize := R.U32LE;
  N := R.U16LE; //song length
  M.Restart := R.U16LE;
  M.Channels := R.U16LE;
  PatCount := R.U16LE;
  InsCount := R.U16LE;
  M.LinearPeriods := (R.U16LE and 1) <> 0;
  M.InitialSpeed := R.U16LE;
  M.InitialTempo := R.U16LE;

  SetLength(M.Orders, N);
  for i:=0 to 255 do begin
    B := R.U8;
    if i < N then M.Orders[i] := B;
  end;

  SetLength(M.Patterns, PatCount);
  R.Seek(60 + HeaderSize);

  for i:=0 to PatCount-1 do begin
    Start := R.Pos;
    PH := R.U32LE;   //pattern header length
    R.U8;            //packing type
    Rows := R.U16LE;
    PackedSize := R.U16LE;

    M.Patterns[i].Rows := Rows;
    SetLength(M.Patterns[i].Cells, Rows * M.Channels);
    R.Seek(Start + PH);
    DataStart := R.Pos;

    for j:=0 to Rows-1 do
      for k:=0 to M.Channels-1 do begin
        FillChar(C, SizeOf(C), 0);

        if R.Pos >= DataStart + PackedSize then begin
          M.Patterns[i].Cells[j*M.Channels + k] := C;
          Continue;
        end;

        B := R.U8;
        if (B and $80) <> 0 then begin
          //packed cell: the mask says which fields follow
          Mask := B;
          if (Mask and 1) <> 0 then C.Note := R.U8;
          if (Mask and 2) <> 0 then C.Instrument := R.U8;
          if (Mask and 4) <> 0 then C.Volume := R.U8;
          if (Mask and 8) <> 0 then B := R.U8 else B := 0;
          if (Mask and 16) <> 0 then Mask := R.U8 else Mask := 0;
        end
        else begin
          //unpacked cell: all five bytes present
          C.Note := B;
          C.Instrument := R.U8;
          C.Volume := R.U8;
          B := R.U8;
          Mask := R.U8;
        end;

        if C.Note = 97 then C.Note := 255; //key off

        //volume column: only plain "set volume" is supported
        if (C.Volume >= $10) and (C.Volume <= $50) then C.Volume := C.Volume - $0F
        else C.Volume := 0;

        TranslateMODEffect(C, B, Mask);
        M.Patterns[i].Cells[j*M.Channels + k] := C;
      end;

    R.Seek(DataStart + PackedSize);
  end;

  SetLength(M.Instruments, InsCount);

  for i:=0 to InsCount-1 do begin
    Start := R.Pos;
    IH := R.U32LE; //instrument header size
    M.Instruments[i].Name := R.FixedString(22);
    R.U8; //instrument type
    NS := R.U16LE; //number of samples
    InitInstrument(M.Instruments[i], -1);

    if NS = 0 then begin
      R.Seek(Start + IH);
      Continue;
    end;

    AVType := 0; AVSweep := 0; AVDepth := 0; AVRate := 0;
    SH := R.U32LE; //sample header size

    for j:=0 to 95 do begin
      B := R.U8;
      M.Instruments[i].NoteSample[j] := Length(M.Samples) + B;
      M.Instruments[i].NoteTranspose[j] := j + 1;
    end;

    //volume envelope, sustain point, loop and fadeout
    if IH >= 241 then begin
      SetLength(EnvPts, 12);
      for j:=0 to 11 do begin
        EnvPts[j].X := R.U16LE;
        EnvPts[j].Y := R.U16LE;
      end;
      R.Skip(48); //panning envelope points

      NVol := R.U8;
      R.U8; //panning point count
      Sus := R.U8;
      LSp := R.U8;
      LEp := R.U8;
      R.Skip(3); //panning sustain and loop
      VType := R.U8;
      R.U8; //panning type
      AVType := R.U8;  //auto-wibrato: typ przebiegu (0=sin,1=sqr,2=up,3=down)
      AVSweep := R.U8; //ile tickow do pelnej glebokosci
      AVDepth := R.U8; //glebokosc w jednostkach okresu
      AVRate := R.U8;  //przyrost pozycji na tick
      FadeVal := R.U16LE;

      if NVol > 12 then NVol := 12;

      with M.Instruments[i] do begin
        Env := Copy(EnvPts, 0, NVol);
        EnvOn := ((VType and 1) <> 0) and (NVol > 0);
        EnvSustain := (VType and 2) <> 0;
        EnvLoop := (VType and 4) <> 0;
        EnvSusStart := ClampI(Sus, 0, NVol-1); //XM sustain is a single point
        EnvSusEnd := EnvSusStart;
        EnvLoopStart := ClampI(LSp, 0, NVol-1);
        EnvLoopEnd := ClampI(LEp, 0, NVol-1);
        FadeOut := FadeVal * 2;
      end;
    end;

    R.Seek(Start + IH);
    N := Length(M.Samples);
    SetLength(M.Samples, N + NS);
    SetLength(SL, NS);
    SetLength(LS, NS);
    SetLength(LL, NS);
    SetLength(Typ, NS);

    for j:=0 to NS-1 do begin
      SL[j] := R.U32LE;
      LS[j] := R.U32LE;
      LL[j] := R.U32LE;
      M.Samples[N+j].Volume := ClampI(R.U8, 0, 64); M.Samples[N+j].GlobalVolume := 64;
      M.Samples[N+j].RelativeNote := 0;

      k := R.S8; //finetune, -128..127 = -1..+1 semitone
      //FT2 plays a sample at 8363 Hz on note 49 (C-4); NoteStep() centers
      //on note 61, hence the doubling
      M.Samples[N+j].C5Speed := 2 * 8363 * Power(2, k/1536.0);

      Typ[j] := R.U8;
      M.Samples[N+j].Panning := R.U8;
      M.Samples[N+j].RelativeNote := R.S8;
      R.U8; //reserved
      M.Samples[N+j].Name := R.FixedString(22);
      if SH > 40 then R.Skip(SH - 40);
      //auto-wibrato XM jest per-instrument - kopiujemy na kazdy sampel
      M.Samples[N+j].VibType := AVType and 3;
      M.Samples[N+j].VibSweep := AVSweep;
      M.Samples[N+j].VibDepth := AVDepth;
      M.Samples[N+j].VibRate := AVRate;
    end;

    for j:=0 to NS-1 do begin
      Raw := R.Bytes(SL[j]);

      if (Typ[j] and $10) <> 0 then begin
        //16-bit delta encoded
        SetLength(M.Samples[N+j].Data, SL[j] div 2);
        Acc := 0;
        for k:=0 to High(M.Samples[N+j].Data) do begin
          Acc := SmallInt(Acc + SmallInt(Raw[k*2] or (Raw[k*2+1] shl 8)));
          M.Samples[N+j].Data[k] := Acc;
        end;
        SL[j] := SL[j] div 2;
        LS[j] := LS[j] div 2;
        LL[j] := LL[j] div 2;
      end
      else begin
        //8-bit delta encoded
        SetLength(M.Samples[N+j].Data, SL[j]);
        Acc := 0;
        for k:=0 to Integer(SL[j])-1 do begin
          Acc := ShortInt(Acc + ShortInt(Raw[k]));
          M.Samples[N+j].Data[k] := SmallInt(ShortInt(Acc)) shl 8;
        end;
      end;

      M.Samples[N+j].LoopStart := LS[j];
      M.Samples[N+j].LoopEnd := Min(SL[j], LS[j] + LL[j]);
      M.Samples[N+j].LoopEnabled := (Typ[j] and 3) <> 0;
      M.Samples[N+j].PingPong := (Typ[j] and 3) = 2;
    end;
  end;

  SetLength(M.ChannelPan, M.Channels);
  for i:=0 to M.Channels-1 do M.ChannelPan[i] := 128;
end;

function S3MEffect(E: Byte): Byte;
begin
  case E of
    1:  Result := FX_SPEED;
    2:  Result := FX_JUMP;
    3:  Result := FX_BREAK;
    4:  Result := FX_VOLSLIDE;
    5:  Result := FX_PORTA_DOWN;
    6:  Result := FX_PORTA_UP;
    7:  Result := FX_TONE_PORTA;
    8:  Result := FX_VIBRATO;
    9:  Result := FX_TREMOR;
    10: Result := FX_ARPEGGIO;
    11: Result := FX_VIBVOL;   //Kxy
    12: Result := FX_PORTAVOL; //Lxy
    15: Result := FX_OFFSET;
    17: Result := FX_RETRIG;
    18: Result := FX_TREMOLO;
    20: Result := FX_TEMPO;
    21: Result := FX_FINEVIB; //Uxy
    22: Result := FX_GLOBALVOL; //Vxx
    24: Result := FX_PAN;
    else Result := FX_NONE;
  end;
end;

//effect 19 (Sxy) subcommands shared by S3M and IT
procedure TranslateSCommand(var C: TCell; P: Byte);
begin
  case P shr 4 of
    //uwaga: S2x to set finetune (nieobslugiwane), NIE fine porta - fine
    //slajdy S3M/IT ida przez DxF/DFy oraz EFx/FFx
    1:  begin C.Effect := FX_GLISSANDO; C.Param := P and 15; end;
    3:  begin C.Effect := FX_VIBWAVE;   C.Param := P and 15; end;
    4:  begin C.Effect := FX_TREMWAVE;  C.Param := P and 15; end;
    $B: begin C.Effect := FX_PATLOOP;   C.Param := P and 15; end;
    $C: begin C.Effect := FX_NOTECUT;   C.Param := P and 15; end;
    $D: begin C.Effect := FX_NOTEDELAY; C.Param := P and 15; end;
    $E: begin C.Effect := FX_PATDELAY;  C.Param := P and 15; end;
  end;
end;

procedure LoadS3M(M: TModule; R: TModReader);
var OrdN, InsN, PatN: Integer;
    i, j, Row, Ch, Active, N, Off, Len, Flags, C2, Seg, PackEnd: Integer;
    B, What, E, P: Byte;
    C: TCell;
    InsPtr, PatPtr: array of Integer;
    LastS: array[0..31] of Byte; //pamiec parametru S per kanal (S00 w ST3)
begin
  if R.AtString(44, 4) <> 'SCRM' then raise ETrackerError.Create('Bad S3M header');

  M.FormatName := 'S3M';
  M.Title := R.AtString(0, 28);
  OrdN := R.AtU16LE(32);
  InsN := R.AtU16LE(34);
  PatN := R.AtU16LE(36);
  M.FastVolSlides := ((R.AtU16LE(38) and 64) <> 0) or (R.AtU16LE(40) = $1300);
  M.FineVolSlides := True;
  M.InitialSpeed := R.AtU8(49);
  //ST3 nie przyjmuje tempa < 33 - zostaje domyslne 125 (Load_s3m.cpp:478;
  //pattern-loop.s3m ma w naglowku 32 i gral u nas 3,9x za wolno)
  M.InitialTempo := R.AtU8(50);
  if M.InitialTempo < 33 then M.InitialTempo := 125;
  //Glosnosc globalna utworu (0..64, *2 do skali 0..128) i przedwzmocnienie
  //z masterVolume - pelna logika Load_s3m.cpp:486-515. Ich brak gral kazdy
  //S3M ok. 2,7-3,0x za glosno (zmierzone na pitch-slides/vibrato-fine).
  M.GlobalSongVolume := ClampI(R.AtU8(48) * 2, 0, 128);
  if (M.GlobalSongVolume = 0) and (R.AtU16LE(40) < $1320) then M.GlobalSongVolume := 128;
  N := R.AtU8(51); //masterVolume
  if (R.AtU16LE(42) = 1) and (N < 8) then M.MixVolume := Min((N + 1) * $10, $7F)
  else if (N = 2) or (N = (2 or $10)) then M.MixVolume := $20
  else if (N and $7F) = 0 then M.MixVolume := 48
  else M.MixVolume := Max(N and $7F, $10);
  if (N and $80) = 0 then //mono: cichiej o 8/11 jak w OpenMPT
    M.MixVolume := (M.MixVolume * 8 + 5) div 11;

  R.Seek(64);
  Active := 0;
  SetLength(M.ChannelPan, 32);

  for i:=0 to 31 do begin
    B := R.U8;
    if B < 16 then begin
      Inc(Active);
      if B < 8 then M.ChannelPan[i] := 48
      else M.ChannelPan[i] := 208;
    end
    else M.ChannelPan[i] := -1; //channel disabled
  end;

  M.Channels := Active;
  SetLength(M.Orders, OrdN);
  R.Seek(96);
  for i:=0 to OrdN-1 do M.Orders[i] := R.U8;

  SetLength(InsPtr, InsN);
  for i:=0 to InsN-1 do InsPtr[i] := R.U16LE * 16;
  SetLength(PatPtr, PatN);
  for i:=0 to PatN-1 do PatPtr[i] := R.U16LE * 16;
  FillChar(LastS, SizeOf(LastS), 0);

  SetLength(M.Samples, InsN);
  SetLength(M.Instruments, InsN);

  for i:=0 to InsN-1 do begin
    Off := InsPtr[i];
    InitInstrument(M.Instruments[i], i);
    if (Off = 0) or (R.AtU8(Off) <> 1) then Continue; //not a sample-based instrument

    R.Seek(Off + 13);
    Seg := R.U8 shl 16;
    Seg := Seg or R.U16LE;
    Seg := Seg * 16;
    Len := R.U32LE;
    M.Samples[i].LoopStart := R.U32LE;
    M.Samples[i].LoopEnd := R.U32LE;
    M.Samples[i].Volume := ClampI(R.U8, 0, 64); M.Samples[i].GlobalVolume := 64;
    R.Skip(2);
    Flags := R.U8;

    C2 := R.U32LE;
    if C2 = 0 then C2 := 8363;
    //ST3 plays a sample at C2SPD on note 49 (C-4); NoteStep() centers
    //on note 61, hence the doubling
    M.Samples[i].C5Speed := 2 * C2;

    M.Samples[i].Panning := 128;
    M.Samples[i].Name := R.AtString(Off + 48, 28);
    M.Samples[i].LoopEnabled := (Flags and 1) <> 0;

    SetLength(M.Samples[i].Data, Len);
    R.Seek(Seg);

    if (Flags and 4) <> 0 then
      for j:=0 to Len-1 do M.Samples[i].Data[j] := SmallInt(R.U16LE)
    else
      for j:=0 to Len-1 do M.Samples[i].Data[j] := SmallInt(Integer(R.U8) - 128) shl 8;
  end;

  SetLength(M.Patterns, PatN);

  for i:=0 to PatN-1 do begin
    M.Patterns[i].Rows := 64;
    SetLength(M.Patterns[i].Cells, 64 * M.Channels);
    if PatPtr[i] = 0 then Continue;

    R.Seek(PatPtr[i]);
    PackEnd := R.Pos + 2 + R.U16LE;
    Row := 0;

    while (Row < 64) and (R.Pos < PackEnd) do begin
      What := R.U8;
      if What = 0 then begin
        Inc(Row);
        Continue;
      end;

      Ch := What and 31;
      FillChar(C, SizeOf(C), 0);

      //map the physical channel to an active channel index
      if Ch < 32 then begin
        N := 0;
        for j:=0 to Ch-1 do
          if M.ChannelPan[j] >= 0 then Inc(N);
        if M.ChannelPan[Ch] < 0 then N := -1;
      end
      else N := -1;

      if (What and 32) <> 0 then begin
        B := R.U8;
        C.Instrument := R.U8;
        if B = $FE then C.Note := 254 //note cut
        else if B < $FE then C.Note := (B shr 4)*12 + (B and 15) + 1;
      end;

      if (What and 64) <> 0 then begin
        B := R.U8;
        if B <= 64 then C.Volume := B + 1;
      end;

      if (What and 128) <> 0 then begin
        E := R.U8;
        P := R.U8;
        //ST3: S00 powtarza ostatni parametr komendy S na tym kanale
        //(pattern-loop.s3m uzywa S00 zamiast pelnych SBx w wierszach 4-7)
        if E = 19 then begin
          if P = 0 then P := LastS[Ch] else LastS[Ch] := P;
        end;
        C.Effect := S3MEffect(E);
        C.Param := P;
        if E = 19 then TranslateSCommand(C, P);
      end;

      if N >= 0 then M.Patterns[i].Cells[Row*M.Channels + N] := C;
    end;
  end;

  //collapse physical channel settings to active channels
  N := 0;
  for i:=0 to 31 do
    if M.ChannelPan[i] >= 0 then begin
      M.ChannelPan[N] := M.ChannelPan[i];
      Inc(N);
    end;
  SetLength(M.ChannelPan, M.Channels);
end;

{ IT 2.14/2.15 compressed samples; adaptation of the go-zikmu algorithm }

type
  TITBitReader = record
    Data: TBytes;
    Pos, Bits: Integer;
    Buf: Cardinal;
  end;

function ITReadBits(var BR: TITBitReader; N: Integer): Cardinal;
var Mask: Cardinal;
begin
  while BR.Bits < N do begin
    if BR.Pos >= Length(BR.Data) then
      raise ETrackerError.Create('Corrupted compressed IT sample');
    BR.Buf := BR.Buf or (Cardinal(BR.Data[BR.Pos]) shl BR.Bits);
    Inc(BR.Pos);
    Inc(BR.Bits, 8);
  end;

  if N = 32 then Mask := $FFFFFFFF
  else Mask := (Cardinal(1) shl N) - 1;

  Result := BR.Buf and Mask;
  BR.Buf := BR.Buf shr N;
  Dec(BR.Bits, N);
end;

function SignExtend(X: Cardinal; Bits: Integer): Integer;
begin
  Result := Integer(X);
  if (X and (Cardinal(1) shl (Bits-1))) <> 0 then
    Result := Result - (1 shl Bits);
end;

procedure DecodeITBlock8(const Data: TBytes; var OutData: array of SmallInt; Start, Count: Integer);
var BR: TITBitReader;
    Bits, i, Y, Last: Integer;
    X: Cardinal;
    NewCount: Boolean;
begin
  BR.Data := Data;
  BR.Pos := 0;
  BR.Bits := 0;
  BR.Buf := 0;
  Bits := 9;
  NewCount := False;
  Last := 0;
  i := 0;

  while i < Count do begin
    if NewCount then X := ITReadBits(BR, 3)
    else X := ITReadBits(BR, Bits);

    if NewCount then begin
      NewCount := False;
      Inc(X);
      if X >= Cardinal(Bits) then Inc(X);
      Bits := X;
      Continue;
    end;

    if Bits < 7 then begin
      if X = Cardinal(1 shl (Bits-1)) then begin
        NewCount := True;
        Continue;
      end;
      Last := ShortInt(Last + SignExtend(X, Bits));
    end
    else if Bits < 9 then begin
      Y := ($FF shr (9-Bits)) - 4;
      if (X > Cardinal(Y)) and (X <= Cardinal(Y+8)) then begin
        Dec(X, Y);
        if X >= Cardinal(Bits) then Inc(X);
        Bits := X;
        Continue;
      end;
      //jak w wariancie 16-bit: delta ze znakiem o szerokosci Bits; dla Bits=7
      //truncacja ShortInt nie ratuje i ujemne delty psuly akumulator
      Last := ShortInt(Last + SignExtend(X, Bits));
    end
    else begin
      if X >= $100 then begin
        Bits := X - $100 + 1;
        Continue;
      end;
      Last := ShortInt(Last + Integer(X));
    end;

    OutData[Start+i] := SmallInt(ShortInt(Last)) shl 8;
    Inc(i);
  end;
end;

procedure DecodeITBlock16(const Data: TBytes; var OutData: array of SmallInt; Start, Count: Integer);
var BR: TITBitReader;
    Bits, i, Y, Last: Integer;
    X: Cardinal;
    NewCount: Boolean;
begin
  BR.Data := Data;
  BR.Pos := 0;
  BR.Bits := 0;
  BR.Buf := 0;
  Bits := 17;
  NewCount := False;
  Last := 0;
  i := 0;

  while i < Count do begin
    if NewCount then X := ITReadBits(BR, 4)
    else X := ITReadBits(BR, Bits);

    if NewCount then begin
      NewCount := False;
      Inc(X);
      if X >= Cardinal(Bits) then Inc(X);
      Bits := X;
      Continue;
    end;

    if Bits < 7 then begin
      if X = Cardinal(1 shl (Bits-1)) then begin
        NewCount := True;
        Continue;
      end;
      Last := SmallInt(Last + SignExtend(X, Bits));
    end
    else if Bits < 17 then begin
      Y := ($FFFF shr (17-Bits)) - 8;
      if (X > Cardinal(Y)) and (X <= Cardinal(Y+16)) then begin
        Dec(X, Y);
        if X >= Cardinal(Bits) then Inc(X);
        Bits := X;
        Continue;
      end;
      //delta jest liczba ze znakiem o szerokosci Bits - bez rozszerzenia znaku
      //ujemne delty wchodzily jako dodatnie +2^Bits i akumulator uciekal
      //(zmierzone na zogma.it: narastajace wielokrotnosci 2^10/2^12, zgrzyt
      //zcr 1,45x przy identycznych dolnych bajtach kazdej probki)
      Last := SmallInt(Last + SignExtend(X, Bits));
    end
    else begin
      if X >= $10000 then begin
        Bits := X - $10000 + 1;
        Continue;
      end;
      Last := SmallInt(Last + Integer(X));
    end;

    OutData[Start+i] := SmallInt(Last);
    Inc(i);
  end;
end;

procedure DecodeITPacked(R: TModReader; var S: TSample; Count: Integer; Is16: Boolean);
var Done, N, CL: Integer;
    Block: TBytes;
begin
  SetLength(S.Data, Count);
  Done := 0;

  while Done < Count do begin
    CL := R.U16LE;
    Block := R.Bytes(CL);

    if Is16 then N := Min(Count - Done, $4000)
    else N := Min(Count - Done, $8000);

    if Is16 then DecodeITBlock16(Block, S.Data, Done, N)
    else DecodeITBlock8(Block, S.Data, Done, N);

    Inc(Done, N);
  end;
end;

procedure LoadIT(M: TModule; R: TModReader);
var OrdN, InsN, SmpN, PatN, Flags: Integer;
    i, j, N, Off, Rows, PackEnd, Row, Ch, Len, SFlags, Convert, C5, Ptr, PhysMax: Integer;
    EFlg, ENum: Integer;
    InsPtr, SmpPtr, PatPtr: array of Integer;
    Mask, B, E, P: Byte;
    Masks, LastNote, LastIns, LastVol, LastFx, LastPar: array[0..63] of Byte;
    C: TCell;
    RightSample: TSample;
    Acc: SmallInt;
begin
  if R.AtString(0, 4) <> 'IMPM' then raise ETrackerError.Create('Bad IT header');

  M.FormatName := 'IT';
  M.Title := R.AtString(4, 26);
  M.FineVolSlides := True;
  OrdN := R.AtU16LE(32);
  InsN := R.AtU16LE(34);
  SmpN := R.AtU16LE(36);
  PatN := R.AtU16LE(38);
  Flags := R.AtU16LE(44);
  M.LinearPeriods := (Flags and 8) <> 0;
  M.InitialSpeed := R.AtU8(50);
  M.InitialTempo := R.AtU8(51);
  //mv (mixing volume / sample preamp, 0..128) z naglowka IT - offset 0x31.
  //Pomijanie go gralo kazdy IT za glosno o 128/mv (zmierzone: zogma 2,68x
  //przy mv=48), co przy wyjsciu *24576 konczylo sie twardym clippingiem.
  M.MixVolume := ClampI(R.AtU8(49), 1, 128);
  M.GlobalSongVolume := ClampI(R.AtU8(48), 0, 128); //IT gv (0..128)

  R.Seek(64);
  SetLength(M.ChannelPan, 64);
  for i:=0 to 63 do begin
    B := R.U8;
    if (B and $80) <> 0 then M.ChannelPan[i] := -1
    else M.ChannelPan[i] := ClampI((B and $7F) * 4, 0, 255);
  end;

  R.Seek($C0);
  SetLength(M.Orders, OrdN);
  for i:=0 to OrdN-1 do M.Orders[i] := R.U8;

  SetLength(InsPtr, InsN);
  for i:=0 to InsN-1 do InsPtr[i] := R.U32LE;
  SetLength(SmpPtr, SmpN);
  for i:=0 to SmpN-1 do SmpPtr[i] := R.U32LE;
  SetLength(PatPtr, PatN);
  for i:=0 to PatN-1 do PatPtr[i] := R.U32LE;

  SetLength(M.Samples, SmpN);
  SetLength(M.Instruments, InsN);

  for i:=0 to InsN-1 do begin
    InitInstrument(M.Instruments[i], -1);
    Off := InsPtr[i];
    if (Off = 0) or (R.AtString(Off, 4) <> 'IMPI') then Continue;

    M.Instruments[i].Name := R.AtString(Off + 32, 26);
    M.Instruments[i].NNA := R.AtU8(Off + 17);
    M.Instruments[i].DCT := R.AtU8(Off + 18);
    M.Instruments[i].DCA := R.AtU8(Off + 19);
    M.Instruments[i].GlobalVolume := ClampI(R.AtU8(Off + 24), 0, 128); //IT GbV
    //IT fadeout is subtracted from a 0..1024 scale each tick
    M.Instruments[i].FadeOut := R.AtU16LE(Off + 20) * 64;

    //IT instruments keep a 120-entry note/sample table at offset +64
    R.Seek(Off + 64);
    for j:=0 to 119 do begin
      B := R.U8; //note
      N := R.U8; //sample, 1-based
      M.Instruments[i].NoteTranspose[j] := B + 1;
      if N = 0 then M.Instruments[i].NoteSample[j] := -1
      else M.Instruments[i].NoteSample[j] := N - 1;
    end;

    //volume envelope at +304: flags, point count, loop, sustain loop, 25 nodes
    EFlg := R.AtU8(Off + 304);
    ENum := R.AtU8(Off + 305);
    if ENum > 25 then ENum := 25;

    with M.Instruments[i] do begin
      EnvOn := ((EFlg and 1) <> 0) and (ENum > 0);
      EnvLoop := (EFlg and 2) <> 0;
      EnvSustain := (EFlg and 4) <> 0;
      EnvLoopStart := ClampI(R.AtU8(Off + 306), 0, ENum-1);
      EnvLoopEnd := ClampI(R.AtU8(Off + 307), 0, ENum-1);
      EnvSusStart := ClampI(R.AtU8(Off + 308), 0, ENum-1);
      EnvSusEnd := ClampI(R.AtU8(Off + 309), 0, ENum-1);

      R.Seek(Off + 310);
      SetLength(Env, ENum);
      for j:=0 to ENum-1 do begin
        Env[j].Y := R.S8;
        Env[j].X := R.U16LE;
      end;
    end;
  end;

  for i:=0 to SmpN-1 do begin
    Off := SmpPtr[i];
    if (Off = 0) or (R.AtString(Off, 4) <> 'IMPS') then Continue;

    M.Samples[i].Name := R.AtString(Off + 20, 26);
    SFlags := R.AtU8(Off + 18);
    M.Samples[i].Volume := ClampI(R.AtU8(Off + 19), 0, 64);
    M.Samples[i].GlobalVolume := ClampI(R.AtU8(Off + 17), 0, 64); //IT GvL
    M.Samples[i].Panning := 128;
    Convert := R.AtU8(Off + 46);
    Len := R.AtU32LE(Off + 48);
    M.Samples[i].LoopStart := R.AtU32LE(Off + 52);
    M.Samples[i].LoopEnd := R.AtU32LE(Off + 56);

    C5 := R.AtU32LE(Off + 60);
    if C5 = 0 then C5 := 8363;
    M.Samples[i].C5Speed := C5;

    Ptr := R.AtU32LE(Off + 72);
    M.Samples[i].LoopEnabled := (SFlags and $10) <> 0;
    M.Samples[i].PingPong := (SFlags and $40) <> 0;

    if (SFlags and 1) = 0 then Continue; //no sample data
    R.Seek(Ptr);

    if (SFlags and 8) <> 0 then begin
      //IT 2.14/2.15 compressed
      DecodeITPacked(R, M.Samples[i], Len, (SFlags and 2) <> 0);

      if (SFlags and 4) <> 0 then begin //stereo: right channel follows
        DecodeITPacked(R, RightSample, Len, (SFlags and 2) <> 0);
        if (Convert and 4) <> 0 then begin //delta encoded
          Acc := 0;
          for j:=0 to Len-1 do begin
            Acc := SmallInt(Acc + RightSample.Data[j]);
            RightSample.Data[j] := Acc;
          end;
        end;
      end;
    end
    else begin
      SetLength(M.Samples[i].Data, Len);

      if (SFlags and 2) <> 0 then
        for j:=0 to Len-1 do begin
          N := R.U16LE;
          if (Convert and 1) = 0 then N := N - $8000; //unsigned
          M.Samples[i].Data[j] := SmallInt(N);
        end
      else
        for j:=0 to Len-1 do begin
          N := R.U8;
          if (Convert and 1) = 0 then N := N - 128
          else N := ShortInt(N);
          M.Samples[i].Data[j] := SmallInt(N) shl 8;
        end;

      if (SFlags and 4) <> 0 then begin //stereo: right channel follows
        SetLength(RightSample.Data, Len);

        if (SFlags and 2) <> 0 then
          for j:=0 to Len-1 do begin
            N := R.U16LE;
            if (Convert and 1) = 0 then N := N - $8000;
            RightSample.Data[j] := SmallInt(N);
          end
        else
          for j:=0 to Len-1 do begin
            N := R.U8;
            if (Convert and 1) = 0 then N := N - 128
            else N := ShortInt(N);
            RightSample.Data[j] := SmallInt(N) shl 8;
          end;
      end;
    end;

    if (Convert and 4) <> 0 then begin //delta encoded
      Acc := 0;
      for j:=0 to Len-1 do begin
        Acc := SmallInt(Acc + M.Samples[i].Data[j]);
        M.Samples[i].Data[j] := Acc;
      end;
    end;

    //mix stereo samples down to mono
    if (SFlags and 4) <> 0 then
      for j:=0 to Len-1 do
        M.Samples[i].Data[j] :=
          SmallInt((Integer(M.Samples[i].Data[j]) + Integer(RightSample.Data[j])) div 2);
  end;

  //sample mode: every sample is its own instrument
  if InsN = 0 then begin
    SetLength(M.Instruments, SmpN);
    for i:=0 to SmpN-1 do InitInstrument(M.Instruments[i], i);
  end;

  //first pass over patterns: find the highest used channel
  PhysMax := 0;
  FillChar(Masks, SizeOf(Masks), 0);

  for i:=0 to PatN-1 do begin
    if PatPtr[i] = 0 then Continue;

    Len := R.AtU16LE(PatPtr[i]); //packed data length
    R.Seek(PatPtr[i] + 8);
    PackEnd := R.Pos + Len;

    while R.Pos < PackEnd do begin
      B := R.U8;
      if B = 0 then Continue;

      Ch := (B - 1) and 63;
      if Ch > PhysMax then PhysMax := Ch;

      if (B and $80) <> 0 then begin
        Mask := R.U8;
        Masks[Ch] := Mask;
      end
      else Mask := Masks[Ch];

      if (Mask and 1) <> 0 then R.U8;
      if (Mask and 2) <> 0 then R.U8;
      if (Mask and 4) <> 0 then R.U8;
      if (Mask and 8) <> 0 then begin
        R.U8;
        R.U8;
      end;
    end;
  end;

  M.Channels := PhysMax + 1;
  SetLength(M.ChannelPan, M.Channels);
  SetLength(M.Patterns, PatN);

  FillChar(Masks, SizeOf(Masks), 0);
  FillChar(LastNote, SizeOf(LastNote), 0);
  FillChar(LastIns, SizeOf(LastIns), 0);
  FillChar(LastVol, SizeOf(LastVol), 0);
  FillChar(LastFx, SizeOf(LastFx), 0);
  FillChar(LastPar, SizeOf(LastPar), 0);

  for i:=0 to PatN-1 do begin
    if PatPtr[i] = 0 then begin
      M.Patterns[i].Rows := 64;
      SetLength(M.Patterns[i].Cells, 64 * M.Channels);
      Continue;
    end;

    R.Seek(PatPtr[i]);
    Len := R.U16LE;
    Rows := R.U16LE;
    R.Skip(4);
    PackEnd := R.Pos + Len;

    M.Patterns[i].Rows := Rows;
    SetLength(M.Patterns[i].Cells, Rows * M.Channels);
    Row := 0;

    while (Row < Rows) and (R.Pos < PackEnd) do begin
      B := R.U8;
      if B = 0 then begin
        Inc(Row);
        Continue;
      end;

      Ch := (B - 1) and 63;
      if (B and $80) <> 0 then begin
        Mask := R.U8;
        Masks[Ch] := Mask;
      end
      else Mask := Masks[Ch];

      FillChar(C, SizeOf(C), 0);

      if (Mask and 1) <> 0 then begin
        C.Note := R.U8;
        LastNote[Ch] := C.Note;
      end
      else if (Mask and 16) <> 0 then C.Note := LastNote[Ch];

      //IT notes are 0-119 with C-5=60; shift to the internal 1-120 range
      if (C.Note > 0) and (C.Note < 120) then Inc(C.Note)
      else if C.Note = 254 then C.Note := 254 //note cut
      else if C.Note >= 120 then C.Note := 255; //note off/fade

      if (Mask and 2) <> 0 then begin
        C.Instrument := R.U8;
        LastIns[Ch] := C.Instrument;
      end
      else if (Mask and 32) <> 0 then C.Instrument := LastIns[Ch];

      if (Mask and 4) <> 0 then begin
        B := R.U8;
        LastVol[Ch] := B;
        if B <= 64 then C.Volume := B + 1;
      end
      else if (Mask and 64) <> 0 then begin
        B := LastVol[Ch];
        if B <= 64 then C.Volume := B + 1;
      end;

      if (Mask and 8) <> 0 then begin
        E := R.U8;
        P := R.U8;
        LastFx[Ch] := E;
        LastPar[Ch] := P;
      end
      else if (Mask and 128) <> 0 then begin
        E := LastFx[Ch];
        P := LastPar[Ch];
      end
      else begin
        E := 0;
        P := 0;
      end;

      C.Effect := S3MEffect(E);
      C.Param := P;
      if E = 19 then TranslateSCommand(C, P);

      if Ch < M.Channels then M.Patterns[i].Cells[Row*M.Channels + Ch] := C;
    end;
  end;

  //--- Model glosnosci ModPluga (MixLevels) ---------------------------------
  //OpenMPT gra pliki zrobione ModPlugiem w trybie MixLevels::Original: preamp
  //idzie przez globalny pre-amp z tlumieniem zaleznym od LICZBY KANALOW
  //(Sndmix.cpp:2143-2170, PreAmpTable) zamiast plaskiego mv jak w trybie
  //Compatible. Netto na glos: Original/Compatible = 64/att. Bez tego
  //zelda (ModPlug 1.16, 12 kan., att=$90) grala 2,25x za glosno, a
  //better off alone (PMM.=0 w rozszerzeniach, 4 kan., att=$60) 1,5x.
  N := -1; //tryb: -1 = Compatible (bez korekty)
  //1) jawnie zapisany: blok rozszerzen "STPM", tag ".MMP" (PMM. = mixlevels)
  for i := 192 to R.Size - 12 do
    if (R.AtU8(i) = $53) and (R.AtU8(i+1) = $54) and (R.AtU8(i+2) = $50) and
       (R.AtU8(i+3) = $4D) then begin //"STPM"
      j := i + 4;
      while j + 6 <= R.Size do begin
        Len := R.AtU8(j+4) or (R.AtU8(j+5) shl 8); //rozmiar pola
        if (R.AtU8(j) = $2E) and (R.AtU8(j+1) = $4D) and (R.AtU8(j+2) = $4D) and
           (R.AtU8(j+3) = $50) and (Len >= 1) then begin //".MMP"
          N := R.AtU8(j + 6);
          Break;
        end;
        if (Len > 256) or (R.AtU8(j) < $20) then Break; //koniec sensownych tagow
        j := j + 6 + Len;
      end;
      Break;
    end;
  //2) heurystyka ModPlug 1.09-1.16 (Load_it.cpp:727): cwt=0217 cmwt=0200
  //reserved=0 + slad ModPluga ($FF w tabeli pan nieuzywanych kanalow)
  if (N < 0) and (R.AtU16LE(40) = $0217) and (R.AtU16LE(42) = $0200) and
     (R.AtU32LE(60) = 0) then
    for i := 64 to 127 do
      if R.AtU8(i) = $FF then begin N := 0; Break; end;
  if (N >= 0) and (N <= 2) then begin //Original / v1_17RC1 / v1_17RC2
    i := ClampI(M.Channels, 1, 31) div 2;
    case i of
      0..2: j := $60; 3: j := $70; 4: j := $80; 5: j := $88; 6: j := $90;
      7: j := $98; 8: j := $A0; 9: j := $A4; 10: j := $A8; 11: j := $AC;
      12: j := $B0; 13: j := $B4; 14: j := $B8; else j := $BC;
    end;
    M.MixVolume := ClampI(Round(M.MixVolume * 64 / j), 1, 255);
  end
  else if N = 3 then //v1_17RC3: bez global pre-amp, extra atten 0 => 2x glosniej
    M.MixVolume := ClampI(M.MixVolume * 2, 1, 255);
end;

procedure TModule.LoadFromStream(Str: TStream);
var R: TModReader;
begin
  R := TModReader.Create(Str);
  try
    if R.Size < 4 then raise ETrackerError.Create('File is too short');

    if R.AtString(0, 4) = 'IMPM' then LoadIT(Self, R)
    else if Copy(R.AtString(0, 17), 1, 16) = 'Extended Module:' then LoadXM(Self, R)
    else if (R.Size > 48) and (R.AtString(44, 4) = 'SCRM') then LoadS3M(Self, R)
    else LoadMOD(Self, R);
  finally
    R.Free;
  end;
end;

{ Renderer }

type
  TVoice = record
    Sample, Instrument, Note, Volume, Pan: Integer;
    Pos, Step, BaseStep: Double;
    Direction: Integer;
    Active: Boolean;
    Fx, Param, MemPorta, MemVol, MemVib, VibPos, LoopRow, LoopCount: Integer;
    MemTrem, TremPos, TremVol, MemTremor, TremorPos, MemRetrig: Integer;
    VibWave, TremWave: Byte; //E4x/E7x (MOD/XM), S3x/S4x (S3M/IT); +4 = bez resetu fazy
    AVPos, AVDepth: Integer; //auto-wibrato sampla: pozycja i narastajaca glebokosc
    AVDelta: Double;         //biezaca delta okresu z auto-wibrata (jednostki PT*4)
    Glissando: Boolean;      //E3x/S1x: slyszalny okres tone porta skacze po poltonach
    HostCh: Integer;         //kanal patternu, z ktorego pochodzi glos (dla NNA/DCT)
    Delayed: TCell;
    HasDelay: Boolean;
    //volume envelope and fadeout state
    EnvPos: Integer;
    EnvVol, Fade: Double;
    FadeDec: Integer;
    KeyOff, Fading: Boolean;
  end;

//linear interpolation of an envelope at a tick position
function EnvInterp(const E: array of TEnvPoint; Pos: Integer): Integer;
var k: Integer;
begin
  if Length(E) = 0 then Exit(64);
  if Pos <= E[0].X then Exit(E[0].Y);

  for k:=0 to High(E)-1 do
    if Pos < E[k+1].X then begin
      if E[k+1].X = E[k].X then Exit(E[k+1].Y);
      Exit(E[k].Y + (E[k+1].Y - E[k].Y) * (Pos - E[k].X) div (E[k+1].X - E[k].X));
    end;

  Result := E[High(E)].Y;
end;

//frequency step per output frame; a sample plays at its C5Speed on note 61
function NoteStep(const S: TSample; Note, Rate: Integer): Double;
begin
  Result := S.C5Speed * Power(2, (Note + S.RelativeNote - 61)/12.0) / Rate;
end;

//Tryby okresowe (MOD, S3M, XM bez LinearPeriods): slajdy i wibrato dodaja
//STALA do okresu Amigi, a nie mnoza czestotliwosci. Okres w konwencji
//OpenMPT/ST3 to 8363*1712/freq, wiec dla glosu period = PC/step, gdzie
//PC = 8363*1712/Rate. To dokladnie ten model, ktorego brak trzymal
//pitch-slides.s3m na 0.112 (zcr 0.46) i psul warianty *-amiga.xm.
function StepToPeriod(Step, PC: Double): Double;
begin
  if Step < 1e-9 then Exit(1e9);
  Result := PC / Step;
end;

function PeriodToStep(Period, PC: Double): Double;
begin
  if Period < 1 then Period := 1;
  if Period > 32000 then Period := 32000;
  Result := PC / Period;
end;

//przebieg oscylatora wibrata/tremola, wynik -1..1; Pos w tickach, Cycle to
//dlugosc okresu (Module.VibCycle). 0=sinus, 1=pila w dol, 2=kwadrat,
//3=losowy (ModRandomTable z OpenMPT Tables.cpp:350). Bit 4 (bez resetu
//fazy przy nowej nucie) maskuje "and 3" - tu juz nie ma znaczenia.
function OscValue(Wave: Byte; Pos, Cycle: Integer): Double;
const RandTab: array[0..63] of ShortInt = (
  98,-127,-43,88,102,41,-65,-94,125,20,-71,-86,-70,-32,-16,-96,
  17,72,107,-5,116,-69,-62,-40,10,-61,65,109,-18,-38,-13,-76,
  -23,88,21,-94,8,106,21,-112,6,109,20,-88,-30,9,-127,118,
  42,-34,89,-4,-51,-72,21,-29,112,123,84,-101,-92,98,-54,-95);
var P: Double;
begin
  if Cycle < 1 then Cycle := 64;
  P := (Pos mod Cycle) / Cycle;
  case Wave and 3 of
    1: //pila: 0 -> -1 w pierwszej polowie, +1 -> 0 w drugiej (ModRampDownTable)
       if P < 0.5 then Result := -2*P else Result := 2*(1-P);
    2: if P < 0.5 then Result := 1 else Result := -1;
    3: Result := RandTab[(Pos * 64 div Cycle) and 63] / 127.0;
    else Result := Sin(P * 2 * Pi);
  end;
end;

procedure RenderModule(Module: TModule; Audio: TXelAudio;
  SampleRate: Integer = 44100; MaxSeconds: Integer = 600);
var V: array of TVoice;
    Order, Row, Tick, Speed, Tempo, Frames, F, CN, i, Pat, NextOrder, NextRow, DelayRows: Integer;
    GLoopRow, GLoopCount: Integer; //wspolny stan petli patternu (ST3)
    GlobalVol: Integer;  //globalna glosnosc 0..128, zmienia ja Vxx
    LastOrder: Integer;
    PC: Double;          //stala okres<->step: 8363*1712/SampleRate
    UsePeriods: Boolean; //MOD/S3M zawsze; XM tylko bez LinearPeriods
    PerScale: Integer;   //jednostki okresu PT na jednostke parametru:
                         //S3M slajduje po 4 (ST3), MOD po 1; XM-amiga ma
                         //okresy 4x drobniejsze, wiec param*4 XM = param PT
    C: TCell;
    S: ^TSample;
    L, R, X, VL, VR, Frac, S0, S1, EffStep: Double;
    LI, RI: Integer;
    TotalFrames, FrameLimit: Int64;
    FramesAcc: Double;
    StopSong: Boolean;

  procedure PutFrame(ALeft, ARight: Integer);
  begin
    if TotalFrames >= Length(Audio.FFrames) then
      SetLength(Audio.FFrames, Length(Audio.FFrames) + 65536);

    Audio.FFrames[TotalFrames].Left := ALeft;
    Audio.FFrames[TotalFrames].Right := ARight;
    Inc(TotalFrames);
  end;

  //move the channel's playing voice to a background slot (IT New Note Action)
  //Action: 0 = continue, 1 = note off, 2 = fade
  procedure MoveToBackground(Ch, Action: Integer);
  var Slot, i: Integer;
      Q, Best: Double;
  begin
    if Length(V) <= Module.Channels then Exit;

    Slot := -1;
    for i:=Module.Channels to High(V) do
      if not V[i].Active then begin
        Slot := i;
        Break;
      end;

    if Slot < 0 then begin //steal the quietest background voice
      Best := 1e30;
      for i:=Module.Channels to High(V) do begin
        Q := V[i].Volume * V[i].EnvVol * V[i].Fade;
        if Q < Best then begin
          Best := Q;
          Slot := i;
        end;
      end;
    end;
    if Slot < 0 then Exit;

    V[Slot] := V[Ch];
    V[Slot].HasDelay := False;

    case Action of
      1: begin
           V[Slot].KeyOff := True;
           V[Slot].Fading := True;
         end;
      2: V[Slot].Fading := True;
    end;
  end;

  function HasVolEnv(II: Integer): Boolean;
  begin
    Result := (II >= 0) and (II < Length(Module.Instruments)) and
              Module.Instruments[II].EnvOn;
  end;

  procedure StartNote(Ch: Integer; const Cell: TCell);
  var SI, II, NN, K: Integer;
  begin
    if Cell.Note = 254 then begin //note cut
      V[Ch].Active := False;
      Exit;
    end;
    if Cell.Note = 255 then begin //note off: release envelope, start fadeout
      V[Ch].KeyOff := True;
      V[Ch].Fading := True;
      //without a volume envelope XM cuts the note; IT lets it fade
      if (not HasVolEnv(V[Ch].Instrument)) and (Module.FormatName <> 'IT') then
        V[Ch].Volume := 0;
      Exit;
    end;

    //the new instrument is only assigned after the NNA check below,
    //which needs to see the instrument of the old voice
    II := V[Ch].Instrument;
    if Cell.Instrument > 0 then II := Cell.Instrument - 1;
    NN := Cell.Note;
    if NN = 0 then Exit;

    SI := -1;
    if (II >= 0) and (II < Length(Module.Instruments)) then begin
      SI := Module.Instruments[II].NoteSample[ClampI(NN-1, 0, 119)];
      NN := Module.Instruments[II].NoteTranspose[ClampI(NN-1, 0, 119)];
    end;

    if (SI < 0) and (Cell.Instrument > 0) and (Cell.Instrument <= Length(Module.Samples)) then
      SI := Cell.Instrument - 1;
    if (SI < 0) or (SI >= Length(Module.Samples)) or (Length(Module.Samples[SI].Data) = 0) then
      Exit;

    if Cell.Effect in [FX_TONE_PORTA, FX_PORTAVOL] then begin
      //tone portamento slides from the current pitch, no retrigger
      V[Ch].Instrument := II;
      V[Ch].Sample := SI;
      V[Ch].Note := NN;
      V[Ch].BaseStep := NoteStep(Module.Samples[SI], NN, SampleRate);
      if V[Ch].Step = 0 then V[Ch].Step := V[Ch].BaseStep;
      Exit;
    end;

    //IT Duplicate Check (DCT/DCA, Snd_fx.cpp:2387-2484): PRZED akcja NNA nowa
    //nuta z instrumentem wycisza zduplikowane glosy pochodzace z TEGO kanalu
    //(kanalowy + tlo). Duplikat liczy sie tylko w obrebie tego samego
    //instrumentu; typ rozstrzyga nuta/sampel/instrument, akcja: cut/off/fade.
    if (Module.FormatName = 'IT') and (II >= 0) and (II < Length(Module.Instruments)) and
       (Module.Instruments[II].DCT > 0) then
      for K := 0 to High(V) do begin
        if not V[K].Active then Continue;
        if (K <> Ch) and ((K < Module.Channels) or (V[K].HostCh <> Ch)) then Continue;
        if V[K].Instrument <> II then Continue;
        case Module.Instruments[II].DCT of
          1: if V[K].Note <> NN then Continue;   //nuta (+instrument)
          2: if V[K].Sample <> SI then Continue; //sampel (+instrument)
        end; //3 = instrument: rownosc II juz sprawdzona
        case Module.Instruments[II].DCA of
          0: V[K].Active := False;                              //cut
          1: begin V[K].KeyOff := True; end;                    //note off
          else V[K].Fading := True;                             //fade
        end;
      end;

    //IT New Note Action of the voice being replaced
    if V[Ch].Active and (Module.FormatName = 'IT') and
       (V[Ch].Instrument >= 0) and (V[Ch].Instrument < Length(Module.Instruments)) then
      case Module.Instruments[V[Ch].Instrument].NNA of
        1: MoveToBackground(Ch, 0); //continue
        2: MoveToBackground(Ch, 1); //note off
        3: MoveToBackground(Ch, 2); //fade
      end;

    V[Ch].Instrument := II;
    V[Ch].Sample := SI;
    V[Ch].Note := NN;
    V[Ch].BaseStep := NoteStep(Module.Samples[SI], NN, SampleRate);

    V[Ch].Step := V[Ch].BaseStep;
    V[Ch].Pos := 0;
    V[Ch].Direction := 1;
    V[Ch].Active := True;
    V[Ch].Volume := Module.Samples[SI].Volume;
    V[Ch].Pan := Module.Samples[SI].Panning;
    //przebieg +4 = "bez resetu fazy" przy nowej nucie (E4x/E7x, S3x/S4x)
    if V[Ch].VibWave < 4 then V[Ch].VibPos := 0;
    if V[Ch].TremWave < 4 then V[Ch].TremPos := 0;
    //FT2: swieza nuta ustawia stan tremoru $20 (Snd_fx.cpp:2991) - z flaga $80
    //daje $A0, czyli faza "on" bez wyciszenia az do pierwszego przeladowania
    if Module.FormatName = 'XM' then V[Ch].TremorPos := $20
    else V[Ch].TremorPos := 0;
    V[Ch].TremVol := 0; //FT2: nuta z instrumentem zdejmuje wyciszenie tremoru
    V[Ch].AVPos := 0; V[Ch].AVDepth := 0; V[Ch].AVDelta := 0;

    V[Ch].EnvPos := 0;
    V[Ch].EnvVol := 1;
    V[Ch].Fade := 1;
    V[Ch].KeyOff := False;
    V[Ch].Fading := False;
    V[Ch].FadeDec := 0;
    if (II >= 0) and (II < Length(Module.Instruments)) then
      V[Ch].FadeDec := Module.Instruments[II].FadeOut;
  end;

  //advances the volume envelope and fadeout of one voice by one tick
  procedure AdvanceEnvelope(Idx: Integer);
  var Ins: ^TInstrument;
      II, LastX: Integer;
  begin
    II := V[Idx].Instrument;

    if HasVolEnv(II) and (Length(Module.Instruments[II].Env) > 0) then begin
      Ins := @Module.Instruments[II];
      V[Idx].EnvVol := EnvInterp(Ins^.Env, V[Idx].EnvPos) / 64.0;

      Inc(V[Idx].EnvPos);

      if (not V[Idx].KeyOff) and Ins^.EnvSustain then begin
        //held note: loop the sustain part (XM sustain point = empty loop)
        if V[Idx].EnvPos > Ins^.Env[Ins^.EnvSusEnd].X then
          V[Idx].EnvPos := Ins^.Env[Ins^.EnvSusStart].X;
      end
      else if Ins^.EnvLoop then begin
        if V[Idx].EnvPos > Ins^.Env[Ins^.EnvLoopEnd].X then
          V[Idx].EnvPos := Ins^.Env[Ins^.EnvLoopStart].X;
      end;

      LastX := Ins^.Env[High(Ins^.Env)].X;
      if V[Idx].EnvPos > LastX then begin
        V[Idx].EnvPos := LastX;
        //koniec obwiedni glosnosci (bez aktywnego sustain/loop - te cofnely
        //pozycje wyzej): IT rozpoczyna fadeout OD RAZU, takze bez key-off;
        //inne formaty dopiero po key-off (Sndmix.cpp:1344-1349). Bez tego
        //glos gral wiecznie na ostatniej wartosci obwiedni (zelda rms 2,16).
        if (Module.FormatName = 'IT') or V[Idx].KeyOff then
          V[Idx].Fading := True;
        //ostatni wezel = 0 konczy glos natychmiast (IT, Sndmix.cpp:1352-1358)
        if (Module.FormatName = 'IT') and (Ins^.Env[High(Ins^.Env)].Y = 0) then
          V[Idx].Active := False;
      end;

      //a released envelope that reached silence ends the voice
      if V[Idx].KeyOff and (V[Idx].EnvVol <= 0.001) then V[Idx].Active := False;
    end
    else begin
      V[Idx].EnvVol := 1.0;
      //key-off bez obwiedni glosnosci: FT2 tnie glos natychmiast, IT rusza
      //fadeout - u nas decyduje FadeDec (IT ma >0). Dawne "graj dalej z 1.0"
      //zawyzalo glosnosc kazdego pliku z key-offami (key-off.xm: rms 2,56).
      if V[Idx].KeyOff then begin
        if V[Idx].FadeDec > 0 then V[Idx].Fading := True
        else V[Idx].Active := False;
      end;
    end;

    if V[Idx].Fading then begin
      V[Idx].Fade := V[Idx].Fade - V[Idx].FadeDec/65536.0;
      if V[Idx].Fade <= 0 then begin
        V[Idx].Fade := 0;
        V[Idx].Active := False;
      end;
    end;
  end;

  //auto-wibrato sampla (XM), model MPT z Sndmix.cpp:1870-1966. Wynik zapisuje
  //w V[Idx].AVDelta (delta okresu w jednostkach PT*4), mikser aplikuje ja
  //do kroku odczytu. Glebokosc narasta liniowo przez VibSweep tickow.
  procedure AutoVibTick(Idx: Integer);
  var S: ^TSample; Full, N, VD: Integer;
  begin
    V[Idx].AVDelta := 0;
    if (V[Idx].Sample < 0) or (V[Idx].Sample >= Length(Module.Samples)) then Exit;
    S := @Module.Samples[V[Idx].Sample];
    if S^.VibDepth = 0 then Exit;

    Full := S^.VibDepth * 256;
    if S^.VibSweep = 0 then V[Idx].AVDepth := Full
    else begin
      if not V[Idx].KeyOff then Inc(V[Idx].AVDepth, Full div Max(1, S^.VibSweep));
      if V[Idx].AVDepth > Full then V[Idx].AVDepth := Full;
    end;

    Inc(V[Idx].AVPos, S^.VibRate);
    case S^.VibType of
      1: if (V[Idx].AVPos and 128) <> 0 then VD := 64 else VD := -64; //kwadrat
      2: VD := ((64 + (V[Idx].AVPos div 2)) and $7F) - 64;            //pila w gore
      3: VD := ((64 - (V[Idx].AVPos div 2)) and $7F) - 64;            //pila w dol
      else VD := -Round(64 * Sin((V[Idx].AVPos and $FF) * 2 * Pi / 256)); //sinus
    end;

    //n = vdelta * glebokosc / 256; delta okresu = n / 64 (Sndmix.cpp:1966)
    N := (VD * V[Idx].AVDepth) div 256;
    V[Idx].AVDelta := N / 64.0;
  end;

  //Dxy - takze czesc slajdowa Kxy/Lxy
  procedure VolSlideTick(Ch, T: Integer; P: Byte);
  var A, B: Integer;
  begin
    if (T = 0) and (P <> 0) then V[Ch].MemVol := P;
    A := V[Ch].MemVol shr 4;
    B := V[Ch].MemVol and 15;

    if Module.FineVolSlides and (B = $F) and (A > 0) then begin
      //DxF: fine slide up, tick 0 only
      if T = 0 then V[Ch].Volume := ClampI(V[Ch].Volume + A, 0, 64);
    end
    else if Module.FineVolSlides and (A = $F) and (B > 0) then begin
      //DFy: fine slide down, tick 0 only
      if T = 0 then V[Ch].Volume := ClampI(V[Ch].Volume - B, 0, 64);
    end
    else if (T > 0) or Module.FastVolSlides then
      V[Ch].Volume := ClampI(V[Ch].Volume + A - B, 0, 64);
  end;

  //Hxy/Uxy oraz czesc wibrata Kxy; DepthScale = 1 (Hxy) lub 0.25 (Uxy).
  //Model OpenMPT (Sndmix.cpp ProcessVibrato + DoFreqSlide "period -= amount"):
  //delta okresu = +ModSinus[pos and 63]*(4*depth)/64 ~ sin*8*depth cwiartek
  //jednostek PT (PerScale=4), pozycja rusza sie o rate DOPIERO PO delcie
  //i tylko na tickach > 0.
  procedure VibratoTick(Ch, T: Integer; DepthScale: Double);
  var D: Double;
  begin
    D := OscValue(V[Ch].VibWave, V[Ch].VibPos, Module.VibCycle);
    //FT2/PT maja pile odwrocona wzgledem ST3/IT (Sndmix.cpp:1698,
    //test VibratoWaveforms.xm)
    if ((V[Ch].VibWave and 3) = 1) and (Module.FormatName <> 'S3M') and
       (Module.FormatName <> 'IT') then D := -D;
    if UsePeriods then
      V[Ch].Step := PeriodToStep(StepToPeriod(V[Ch].BaseStep, PC) +
        D * (V[Ch].MemVib and 15) * 2 * DepthScale * PerScale, PC)
    else begin
      //IT: ITSinusTable ma amplitude 64 (nie 127) i vdepth=7 - netto 4x
      //slabiej niz FT2 przy tym samym parametrze
      if Module.FormatName = 'IT' then DepthScale := DepthScale * 0.25;
      //pierwsza polowa sinusa = pitch W DOL (period rosnie) jak w FT2
      V[Ch].Step := V[Ch].BaseStep * Power(2,
        -D * (V[Ch].MemVib and 15) * DepthScale / 96);
    end;
    if T > 0 then Inc(V[Ch].VibPos, V[Ch].MemVib shr 4);
  end;

  //Gxx oraz czesc portamento Lxy (tam P=0 - slizg z pamieci)
  procedure TonePortaTick(Ch, T: Integer; P: Byte);
  var PTgt, PCur: Double;
  begin
    if T = 0 then Exit;
    if P <> 0 then V[Ch].MemPorta := P;
    if UsePeriods then begin
      //cel i pozycja w okresach; przesuwamy o stala na tick
      PTgt := StepToPeriod(V[Ch].BaseStep, PC);
      PCur := StepToPeriod(V[Ch].Step, PC);
      if PCur > PTgt then PCur := Max(PTgt, PCur - V[Ch].MemPorta*PerScale)
      else PCur := Min(PTgt, PCur + V[Ch].MemPorta*PerScale);
      V[Ch].Step := PeriodToStep(PCur, PC);
    end
    else if V[Ch].Step < V[Ch].BaseStep then
      V[Ch].Step := Min(V[Ch].BaseStep,
        V[Ch].Step * Power(2, V[Ch].MemPorta*Module.PortaScale/768.0))
    else
      V[Ch].Step := Max(V[Ch].BaseStep,
        V[Ch].Step / Power(2, V[Ch].MemPorta*Module.PortaScale/768.0));
  end;

  procedure ApplyTick(Ch, T: Integer; const Cell: TCell);
  var P, A, B: Integer;
  begin
    P := Cell.Param;

    if (Cell.Volume > 0) and (T = 0) then V[Ch].Volume := Cell.Volume - 1;

    case Cell.Effect of
      FX_SETVOL:
        if T = 0 then V[Ch].Volume := ClampI(P, 0, 64);

      FX_PAN:
        if T = 0 then V[Ch].Pan := P;

      FX_SETPAN4:
        if T = 0 then V[Ch].Pan := P * 17;

      FX_SPEED:
        if (T = 0) and (P > 0) then Speed := P;

      FX_TEMPO:
        if (T = 0) and (P >= 32) then Tempo := P;

      FX_OFFSET:
        if T = 0 then begin
          if P <> 0 then V[Ch].Param := P;
          V[Ch].Pos := V[Ch].Param * 256;
        end;

      FX_FINEUP:
        if T = 0 then begin
          if UsePeriods then
            V[Ch].BaseStep := PeriodToStep(StepToPeriod(V[Ch].BaseStep, PC) - P*PerScale, PC)
          else
            V[Ch].BaseStep := V[Ch].BaseStep * Power(2, P/768.0);
          V[Ch].Step := V[Ch].BaseStep;
        end;

      FX_FINEDOWN:
        if T = 0 then begin
          if UsePeriods then
            V[Ch].BaseStep := PeriodToStep(StepToPeriod(V[Ch].BaseStep, PC) + P*PerScale, PC)
          else
            V[Ch].BaseStep := V[Ch].BaseStep / Power(2, P/768.0);
          V[Ch].Step := V[Ch].BaseStep;
        end;

      FX_PORTA_UP: begin
        if (T = 0) and (P <> 0) then V[Ch].MemPorta := P;
        A := V[Ch].MemPorta;
        if ((Module.FormatName = 'S3M') or (Module.FormatName = 'IT')) and (A >= $E0) then begin
          //FFx fine (x jednostek slajdu) / EFx extra-fine (x/4),
          //tylko na ticku 0 - ST3 koduje je w gornym nibblu parametru E/F
          if T = 0 then begin
            B := A and 15;
            if UsePeriods then begin
              if (A shr 4) = $F then B := B * PerScale;
              V[Ch].BaseStep := PeriodToStep(StepToPeriod(V[Ch].BaseStep, PC) - B, PC);
            end
            else begin //IT z linear slides: jak jeden tick zwyklego slajdu
              if (A shr 4) = $E then
                V[Ch].BaseStep := V[Ch].BaseStep * Power(2, B/768.0)
              else
                V[Ch].BaseStep := V[Ch].BaseStep * Power(2, B*Module.PortaScale/768.0);
            end;
            V[Ch].Step := V[Ch].BaseStep;
          end;
        end
        else if T > 0 then begin
          if UsePeriods then
            //w gore = okres MALEJE o stala liczbe jednostek na tick
            V[Ch].BaseStep := PeriodToStep(
              StepToPeriod(V[Ch].BaseStep, PC) - A*PerScale, PC)
          else
            V[Ch].BaseStep := Min(1024,
              V[Ch].BaseStep * Power(2, A*Module.PortaScale/768.0));
          V[Ch].Step := V[Ch].BaseStep;
        end;
      end;

      FX_PORTA_DOWN: begin
        if (T = 0) and (P <> 0) then V[Ch].MemPorta := P;
        A := V[Ch].MemPorta;
        if ((Module.FormatName = 'S3M') or (Module.FormatName = 'IT')) and (A >= $E0) then begin
          if T = 0 then begin
            B := A and 15;
            if UsePeriods then begin
              if (A shr 4) = $F then B := B * PerScale;
              V[Ch].BaseStep := PeriodToStep(StepToPeriod(V[Ch].BaseStep, PC) + B, PC);
            end
            else begin
              if (A shr 4) = $E then
                V[Ch].BaseStep := V[Ch].BaseStep / Power(2, B/768.0)
              else
                V[Ch].BaseStep := V[Ch].BaseStep / Power(2, B*Module.PortaScale/768.0);
            end;
            V[Ch].Step := V[Ch].BaseStep;
          end;
        end
        else if T > 0 then begin
          if UsePeriods then
            V[Ch].BaseStep := PeriodToStep(
              StepToPeriod(V[Ch].BaseStep, PC) + A*PerScale, PC)
          else
            V[Ch].BaseStep := Max(1/1024,
              V[Ch].BaseStep / Power(2, A*Module.PortaScale/768.0));
          V[Ch].Step := V[Ch].BaseStep;
        end;
      end;

      FX_TONE_PORTA: TonePortaTick(Ch, T, P);

      FX_VOLSLIDE: VolSlideTick(Ch, T, P);

      FX_VIBVOL: begin //Kxy = H00 + Dxy
        VibratoTick(Ch, T, 1.0);
        VolSlideTick(Ch, T, P);
      end;

      FX_PORTAVOL: begin //Lxy = G00 + Dxy
        TonePortaTick(Ch, T, 0);
        VolSlideTick(Ch, T, P);
      end;

      FX_GLOBALVOL:
        if T = 0 then begin
          //S3M Vxx ma zakres 0..64 (x2 do skali 0..128); IT ma pelne 0..128
          if Module.FormatName = 'IT' then GlobalVol := ClampI(P, 0, 128)
          else GlobalVol := ClampI(P * 2, 0, 128);
        end;

      FX_ARPEGGIO: begin
        if Module.FormatName = 'XM' then begin
          //FT2: licznik arp idzie WSTECZ (Speed-T), a jego LUT ma tylko 16
          //wpisow - powyzej 16 tickow czyta z tablicy wibrata (=> zawsze y),
          //dokladnie 16 => baza; tick 0 gra baze (Sndmix.cpp:1552-1576,
          //test Arpeggio.xm). Stary "T mod 3" gral x i y w ZLEJ kolejnosci.
          A := 0;
          if T > 0 then begin
            B := Speed - T;
            if B > 16 then B := 2
            else if B = 16 then B := 0
            else B := B mod 3;
            case B of
              1: A := P shr 4;
              2: A := P and 15;
            end;
          end;
        end
        else
          case T mod 3 of
            1: A := P shr 4;
            2: A := P and 15;
            else A := 0;
          end;
        V[Ch].Step := V[Ch].BaseStep * Power(2, A/12);
      end;

      FX_VIBRATO: begin
        if P <> 0 then V[Ch].MemVib := P;
        VibratoTick(Ch, T, 1.0);
      end;

      FX_FINEVIB: begin
        //Uxy: like vibrato but depth divided by 4 (vibrato-fine.s3m used to
        //play a pure tone because the U letter was not mapped at all)
        if P <> 0 then V[Ch].MemVib := P;
        VibratoTick(Ch, T, 0.25);
      end;

      FX_TREMOLO: begin
        if P <> 0 then V[Ch].MemTrem := P;
        //OpenMPT: vol += table*(4*depth)/2^atten na skali 0..256; atten=5 dla
        //XM/MOD (u nas 0..64 => *4), 6 dla S3M/IT (=> *2). Sndmix.cpp:928.
        if (Module.FormatName = 'S3M') or (Module.FormatName = 'IT') then A := 2
        else A := 4;
        V[Ch].TremVol := Round(OscValue(V[Ch].TremWave, V[Ch].TremPos, Module.VibCycle)
          * (V[Ch].MemTrem and 15) * A);
        if T > 0 then Inc(V[Ch].TremPos, V[Ch].MemTrem shr 4);
      end;

      FX_VIBWAVE:
        if T = 0 then V[Ch].VibWave := P and 7;

      FX_TREMWAVE:
        if T = 0 then V[Ch].TremWave := P and 7;

      FX_GLISSANDO:
        if T = 0 then V[Ch].Glissando := P <> 0;

      FX_TREMOR:
        if Module.FormatName = 'XM' then begin
          //maszyna stanow FT2 (Sndmix.cpp:972-1001): TremorPos to bajt stanu -
          // $80 aktywny, $C0 faza "on", dolne bity licznik; $20 znika po nucie.
          //Czasy on/off to SUROWE x i y (bez +1 jak w ST3), advance tylko T>0.
          if (T = 0) and (P <> 0) then V[Ch].MemTremor := P;
          if T = 0 then V[Ch].TremorPos := V[Ch].TremorPos or $80
          else begin
            A := V[Ch].TremorPos and (not $20);
            if A = $80 then A := (V[Ch].MemTremor shr 4) or $C0      //koniec off
            else if A = $C0 then A := (V[Ch].MemTremor and 15) or $80 //koniec on
            else A := A - 1;
            V[Ch].TremorPos := A;
          end;
          if (V[Ch].TremorPos and $E0) = $80 then V[Ch].TremVol := -64
          else V[Ch].TremVol := 0;
        end
        else begin
          if P <> 0 then V[Ch].MemTremor := P;
          A := (V[Ch].MemTremor shr 4) + 1; //ticks on
          B := (V[Ch].MemTremor and 15) + 1; //ticks off
          if (V[Ch].TremorPos mod (A+B)) >= A then V[Ch].TremVol := -64
          else V[Ch].TremVol := 0;
          Inc(V[Ch].TremorPos);
        end;

      FX_RETRIG: begin
        //E9x (MOD, param 0..15) oraz Rxy/Qxy (XM/S3M/IT): dolny nibble to
        //interwal, gorny to zmiana glosnosci przy kazdym retrigu wg tabeli
        //FT2/ST3 (retrigTable, Snd_fx.cpp RetrigNote); pamiec parametru.
        if (T = 0) and (P <> 0) then V[Ch].MemRetrig := P;
        A := V[Ch].MemRetrig and 15;
        if (A > 0) and (T > 0) and (T mod A = 0) then begin
          V[Ch].Pos := 0;
          case V[Ch].MemRetrig shr 4 of
            1: Dec(V[Ch].Volume, 1);
            2: Dec(V[Ch].Volume, 2);
            3: Dec(V[Ch].Volume, 4);
            4: Dec(V[Ch].Volume, 8);
            5: Dec(V[Ch].Volume, 16);
            6: V[Ch].Volume := (V[Ch].Volume * 2) div 3;
            7: V[Ch].Volume := V[Ch].Volume div 2;
            9: Inc(V[Ch].Volume, 1);
            10: Inc(V[Ch].Volume, 2);
            11: Inc(V[Ch].Volume, 4);
            12: Inc(V[Ch].Volume, 8);
            13: Inc(V[Ch].Volume, 16);
            14: V[Ch].Volume := (V[Ch].Volume * 3) div 2;
            15: V[Ch].Volume := V[Ch].Volume * 2;
          end;
          V[Ch].Volume := ClampI(V[Ch].Volume, 0, 64);
        end;
      end;

      FX_NOTECUT:
        if T = P then V[Ch].Volume := 0;

      FX_NOTEDELAY:
        if (T = P) and V[Ch].HasDelay then begin
          StartNote(Ch, V[Ch].Delayed);
          V[Ch].HasDelay := False;
        end;
    end;
  end;

begin
  if (SampleRate < 8000) or (SampleRate > 192000) then
    raise ETrackerError.Create('Sample rate outside 8000..192000');

  Audio.FSampleRate := SampleRate;
  Audio.FSampleSize := 16;
  SetLength(Audio.FFrames, 0);

  PC := 8363.0 * 1712.0 / SampleRate;
  UsePeriods := (Module.FormatName = 'MOD') or (Module.FormatName = 'S3M') or
    ((Module.FormatName = 'XM') and not Module.LinearPeriods);
  //OpenMPT trzyma okres wewnetrznie w cwiartkach jednostek ProTrackera
  //(C5=1712, nie 428) i KAZDY slajd to param*4 (Snd_fx.cpp:4221 itd.),
  //extra-fine = param*1 - dla wszystkich formatow okresowych jednakowo
  PerScale := 4;
  GlobalVol := Module.GlobalSongVolume;

  //channel voices followed by a pool of background voices for the IT NNA
  SetLength(V, Module.Channels + 64);
  for i:=0 to High(V) do begin
    V[i].Sample := -1;
    V[i].Instrument := -1;
    V[i].HostCh := i; //glosy tla dziedzicza HostCh przy kopii w MoveToBackground
    if i < Module.Channels then V[i].Pan := Module.ChannelPan[i]
    else V[i].Pan := 128;
    V[i].Direction := 1;
    V[i].LoopRow := 0;
    V[i].EnvVol := 1;
    V[i].Fade := 1;
    GLoopRow := 0;
    GLoopCount := 0;
  end;

  Order := 0;
  Row := 0;
  Speed := Max(1, Module.InitialSpeed);
  Tempo := Max(32, Module.InitialTempo);
  FramesAcc := 0;
  TotalFrames := 0;
  FrameLimit := Int64(MaxSeconds) * SampleRate;
  StopSong := False;
  LastOrder := -1;

  while (Order < Length(Module.Orders)) and (TotalFrames < FrameLimit) and not StopSong do begin
    Pat := Module.Orders[Order];

    if Pat = 254 then begin //skip marker
      Inc(Order);
      Row := 0;
      Continue;
    end;
    if (Pat = 255) or (Pat >= Length(Module.Patterns)) then Break; //end of song

    if Row >= Module.Patterns[Pat].Rows then begin
      Inc(Order);
      Row := 0;
      Continue;
    end;

    if Order <> LastOrder then begin
      //pattern loop state does not carry over to another pattern
      GLoopRow := 0;
      GLoopCount := 0;
      for CN:=0 to High(V) do begin
        V[CN].LoopRow := 0;
        V[CN].LoopCount := 0;
      end;
      LastOrder := Order;
    end;

    NextOrder := Order;
    NextRow := Row + 1;
    DelayRows := 0;

    //row start: trigger notes and row-level effects
    for CN:=0 to Module.Channels-1 do begin
      C := Module.Patterns[Pat].Cells[Row*Module.Channels + CN];

      //vibrato and arpeggio offsets do not persist past the effect
      if (V[CN].Fx in [FX_VIBRATO, FX_FINEVIB, FX_VIBVOL, FX_ARPEGGIO]) and
         not (C.Effect in [FX_VIBRATO, FX_FINEVIB, FX_VIBVOL, FX_ARPEGGIO,
           FX_TONE_PORTA, FX_PORTAVOL]) then
        V[CN].Step := V[CN].BaseStep;

      V[CN].Fx := C.Effect;
      V[CN].Param := C.Param;

      //FT2: tremor zakonczony w fazie "off" wycisza kanal takze w wierszach
      //bez efektu (Sndmix.cpp:997 - test vol=0 stoi poza sprawdzeniem komendy);
      //odblokowuje dopiero nowa nuta z instrumentem (reset w StartNote)
      if (C.Effect <> FX_TREMOLO) and (C.Effect <> FX_TREMOR) and
         not ((Module.FormatName = 'XM') and ((V[CN].TremorPos and $E0) = $80)) then
        V[CN].TremVol := 0;

      if C.Effect = FX_NOTEDELAY then begin
        V[CN].Delayed := C;
        V[CN].HasDelay := True;
      end
      else StartNote(CN, C);

      if C.Effect = FX_JUMP then begin
        if C.Param <= Order then StopSong := True //backwards jump = song loop
        else begin
          NextOrder := C.Param;
          NextRow := 0;
        end;
      end
      else if C.Effect = FX_BREAK then begin
        NextOrder := Order + 1;
        NextRow := (C.Param shr 4)*10 + (C.Param and 15);
      end
      else if C.Effect = FX_PATDELAY then DelayRows := C.Param
      else if C.Effect = FX_PATLOOP then begin
        if Module.FormatName = 'S3M' then begin
          //ST3: JEDEN wspolny stan petli dla wszystkich kanalow; po zakonczeniu
          //petli jej poczatek przesuwa sie ZA wiersz SBx. Stan per kanal krecil
          //pattern-loop.s3m 4x za dlugo (71s zamiast 17s - kazdy kanal liczyl
          //swoja petle od nowa).
          if C.Param = 0 then GLoopRow := Row
          else begin
            if GLoopCount = 0 then begin
              GLoopCount := C.Param;
              NextRow := GLoopRow;
            end
            else begin
              Dec(GLoopCount);
              if GLoopCount > 0 then NextRow := GLoopRow
              else GLoopRow := Row + 1;
            end;
          end;
        end
        else begin
          if C.Param = 0 then V[CN].LoopRow := Row
          else begin
            if V[CN].LoopCount = 0 then V[CN].LoopCount := C.Param;
            if V[CN].LoopCount > 0 then begin
              Dec(V[CN].LoopCount);
              if V[CN].LoopCount > 0 then NextRow := V[CN].LoopRow;
            end;
          end;
        end;
      end;
    end;

    //ticks of this row (pattern delay repeats the row without retriggering)
    for Tick:=0 to Speed*(DelayRows+1) - 1 do begin

      for CN:=0 to Module.Channels-1 do begin
        C := Module.Patterns[Pat].Cells[Row*Module.Channels + CN];
        ApplyTick(CN, Tick mod Speed, C);
      end;

      for CN:=0 to High(V) do
        if V[CN].Active then begin AdvanceEnvelope(CN); AutoVibTick(CN); end;

      //carry the fractional part of the tick length to keep long-term timing exact
      FramesAcc := FramesAcc + SampleRate * 2.5 / Tempo;
      Frames := Trunc(FramesAcc);
      FramesAcc := FramesAcc - Frames;

      for F:=0 to Frames-1 do begin
        if TotalFrames >= FrameLimit then Break;
        L := 0;
        R := 0;

        for CN:=0 to High(V) do
          if V[CN].Active and (V[CN].Sample >= 0) then begin
            S := @Module.Samples[V[CN].Sample];

            if (V[CN].Pos < 0) or (V[CN].Pos > 1e12) then begin
              V[CN].Active := False;
              Continue;
            end;

            i := Trunc(V[CN].Pos);
            if i >= Length(S^.Data) then begin
              if S^.LoopEnabled and (S^.LoopEnd > S^.LoopStart) then begin
                if S^.PingPong then begin
                  V[CN].Direction := -1;
                  V[CN].Pos := S^.LoopEnd - 1;
                end
                else V[CN].Pos := S^.LoopStart;
                i := Trunc(V[CN].Pos);
              end
              else begin
                V[CN].Active := False;
                Continue;
              end;
            end;

            //linear interpolation between neighbouring sample points
            Frac := V[CN].Pos - i;
            S0 := S^.Data[i];
            if i+1 < Length(S^.Data) then S1 := S^.Data[i+1]
            else if S^.LoopEnabled and (S^.LoopEnd > S^.LoopStart) and not S^.PingPong then
              S1 := S^.Data[S^.LoopStart]
            else S1 := S0;

            //glosnosc globalna sampla (IT GvL, 0..64; 64 = neutralnie dla
            //innych formatow), GbV instrumentu (0..128), naglowkowe mv i gv
            //utworu wchodza do toru tak jak w IT - bez nich moduly IT graly
            //nawet 2,7x za glosno i clipowaly.
            X := (S0 + (S1-S0)*Frac)/32768.0
                 * (ClampI(V[CN].Volume + V[CN].TremVol, 0, 64)/64.0)
                 * (S^.GlobalVolume/64.0)
                 * (Module.MixVolume/128.0)
                 * (GlobalVol/128.0) //startuje z GlobalSongVolume, zmienia Vxx
                 * V[CN].EnvVol * V[CN].Fade;
            if (V[CN].Instrument >= 0) and (V[CN].Instrument < Length(Module.Instruments)) then
              X := X * (Module.Instruments[V[CN].Instrument].GlobalVolume/128.0);
            VL := (255 - V[CN].Pan)/255.0;
            VR := V[CN].Pan/255.0;
            L := L + X*VL;
            R := R + X*VR;

            EffStep := V[CN].Step;
            //glissando (E3x/S1x): podczas tone porta slyszalny ton skacze po
            //poltonach, a wewnetrzny slizg (Step) plynie dalej gladko
            //(Sndmix.cpp:2307-2316). Siatka poltonow = BaseStep*2^(k/12),
            //bo BaseStep to nuta docelowa z tego samego strojenia sampla.
            if V[CN].Glissando and (V[CN].Fx in [FX_TONE_PORTA, FX_PORTAVOL]) and
               (V[CN].BaseStep > 1e-12) and (EffStep > 1e-12) then
              EffStep := V[CN].BaseStep *
                Power(2, Round(12 * Log2(EffStep / V[CN].BaseStep)) / 12.0);
            //auto-wibrato modyfikuje krok jak dodatkowa delta okresu; nie ruszamy
            //V[CN].Step, bo efekty co tick licza go od nowa z BaseStep
            if V[CN].AVDelta <> 0 then begin
              if UsePeriods then
                EffStep := PeriodToStep(StepToPeriod(EffStep, PC) + V[CN].AVDelta, PC)
              else
                EffStep := EffStep * Power(2, -V[CN].AVDelta/768.0);
            end;
            V[CN].Pos := V[CN].Pos + EffStep * V[CN].Direction;

            if S^.LoopEnabled then begin
              if V[CN].Direction > 0 then begin
                if V[CN].Pos >= S^.LoopEnd then begin
                  if S^.PingPong then begin
                    V[CN].Pos := S^.LoopEnd - 1;
                    V[CN].Direction := -1;
                  end
                  else V[CN].Pos := S^.LoopStart + (V[CN].Pos - S^.LoopEnd);
                end;
              end
              else if V[CN].Pos < S^.LoopStart then begin
                V[CN].Pos := S^.LoopStart;
                V[CN].Direction := 1;
              end;
            end;
          end;

        //pelna skala 32768, nie 24576 - stare 24576/32768 dawalo rowniutkie
        //0,75 glosnosci referencji na kazdym pliku z poprawnym preampem
        LI := ClampI(Round(L*32768), -32768, 32767);
        RI := ClampI(Round(R*32768), -32768, 32767);
        PutFrame(LI, RI);
      end;
    end;

    Order := NextOrder;
    Row := NextRow;
    if Row >= Module.Patterns[Pat].Rows then begin
      Inc(Order);
      Row := 0;
    end;
  end;

  SetLength(Audio.FFrames, TotalFrames);
end;

{ TAudioTracker }

function TAudioTracker.LoadFromStream(Str: TStream): Boolean;
var M: TModule;
begin
  Result := False;

  M := TModule.Create;
  try
    try
      M.LoadFromStream(Str);
    except
      on ETrackerError do Exit;
    end;

    RenderModule(M, FHandle, TrackerSampleRate, TrackerMaxSeconds);
  finally
    M.Free;
  end;

  Result := Length(FHandle.FFrames) > 0;
end;

initialization
  RegisterAudioFormat('mod', TAudioTracker);
  RegisterAudioFormat('xm', TAudioTracker);
  RegisterAudioFormat('s3m', TAudioTracker);
  RegisterAudioFormat('it', TAudioTracker);

end.
