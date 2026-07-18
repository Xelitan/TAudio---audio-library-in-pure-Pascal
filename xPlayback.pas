unit xPlayback;
{$mode objfpc}{$H+}

interface

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description: Cross-platform PCM playback backend for XelAudioPkg          //
//              Windows: winmm waveOut                                        //
//              Linux:   ALSA (libasound, loaded dynamically)                //
//              macOS:   AudioToolbox AudioQueue                              //
// License:     MIT                                                          //
// Copyright:   (c) 2026 Xelitan.com. All rights reserved.                   //
//                                                                            //
// The API plays 16-bit stereo PCM from memory. Blocking=True returns once   //
// everything has played (semantics of the old sndPlaySound SND_SYNC);       //
// False plays in the background and StopPlayback interrupts. When the       //
// backend is unavailable (e.g. no libasound), PlayPCM16 returns False and   //
// does nothing - no exceptions are raised.                                  //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

uses Classes, SysUtils;

function PlayPCM16(const Data: array of SmallInt; FrameCount, SampleRate: Integer;
  Blocking: Boolean = True): Boolean;
procedure StopPlayback;

implementation

{$IFDEF WINDOWS}
uses MMSystem;

var
  CurDev: HWAVEOUT = 0;
  CurHdr: TWaveHdr;
  CurBuf: array of SmallInt;

procedure StopPlayback;
begin
  if CurDev = 0 then Exit;
  waveOutReset(CurDev);
  waveOutUnprepareHeader(CurDev, @CurHdr, SizeOf(CurHdr));
  waveOutClose(CurDev);
  CurDev := 0;
  SetLength(CurBuf, 0);
end;

function PlayPCM16(const Data: array of SmallInt; FrameCount, SampleRate: Integer;
  Blocking: Boolean): Boolean;
var Fmt: TWaveFormatEx;
begin
  Result := False;
  if FrameCount < 1 then Exit;
  StopPlayback;

  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.wFormatTag := WAVE_FORMAT_PCM;
  Fmt.nChannels := 2;
  Fmt.nSamplesPerSec := SampleRate;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := 4;
  Fmt.nAvgBytesPerSec := SampleRate * 4;

  if waveOutOpen(@CurDev, WAVE_MAPPER, @Fmt, 0, 0, CALLBACK_NULL) <> MMSYSERR_NOERROR then begin
    CurDev := 0;
    Exit;
  end;

  //waveOut plays asynchronously from the caller's buffer - copy the data so
  //the caller may free its own right after we return (non-blocking mode)
  SetLength(CurBuf, FrameCount * 2);
  Move(Data[0], CurBuf[0], FrameCount * 4);

  FillChar(CurHdr, SizeOf(CurHdr), 0);
  CurHdr.lpData := PChar(@CurBuf[0]);
  CurHdr.dwBufferLength := FrameCount * 4;

  if waveOutPrepareHeader(CurDev, @CurHdr, SizeOf(CurHdr)) <> MMSYSERR_NOERROR then begin
    waveOutClose(CurDev); CurDev := 0; Exit;
  end;
  if waveOutWrite(CurDev, @CurHdr, SizeOf(CurHdr)) <> MMSYSERR_NOERROR then begin
    waveOutUnprepareHeader(CurDev, @CurHdr, SizeOf(CurHdr));
    waveOutClose(CurDev); CurDev := 0; Exit;
  end;

  if Blocking then begin
    while (CurHdr.dwFlags and WHDR_DONE) = 0 do Sleep(20);
    StopPlayback;
  end;
  Result := True;
end;
{$ENDIF}

{$IFDEF LINUX}
uses dl;
//NOTE for console programs on unix: FPC threads require the cthreads unit
//to be FIRST in the main program's uses clause (LCL apps handle this already).

//ALSA is loaded dynamically - playback works wherever libasound is present,
//and without it the library still links and everything except Play/Stop
//works normally.
const
  SND_PCM_STREAM_PLAYBACK = 0;
  SND_PCM_FORMAT_S16_LE = 2;
  SND_PCM_ACCESS_RW_INTERLEAVED = 3;

type
  Tsnd_pcm_open = function(var pcm: Pointer; name: PChar; stream: Integer;
    mode: Integer): Integer; cdecl;
  Tsnd_pcm_set_params = function(pcm: Pointer; format, access: Integer;
    channels, rate: Cardinal; soft_resample: Integer; latency: Cardinal): Integer; cdecl;
  Tsnd_pcm_writei = function(pcm: Pointer; buf: Pointer; frames: NativeUInt): NativeInt; cdecl;
  Tsnd_pcm_drain = function(pcm: Pointer): Integer; cdecl;
  Tsnd_pcm_drop = function(pcm: Pointer): Integer; cdecl;
  Tsnd_pcm_close = function(pcm: Pointer): Integer; cdecl;
  Tsnd_pcm_prepare = function(pcm: Pointer): Integer; cdecl;

var
  AsoundLib: Pointer = nil;
  AsoundTried: Boolean = False;
  snd_pcm_open: Tsnd_pcm_open = nil;
  snd_pcm_set_params: Tsnd_pcm_set_params = nil;
  snd_pcm_writei: Tsnd_pcm_writei = nil;
  snd_pcm_drain: Tsnd_pcm_drain = nil;
  snd_pcm_drop: Tsnd_pcm_drop = nil;
  snd_pcm_close: Tsnd_pcm_close = nil;
  snd_pcm_prepare: Tsnd_pcm_prepare = nil;
  CurPcm: Pointer = nil;
  PlayThread: TThread = nil;

function LoadAsound: Boolean;
begin
  if not AsoundTried then begin
    AsoundTried := True;
    AsoundLib := dlopen('libasound.so.2', RTLD_NOW);
    if AsoundLib = nil then AsoundLib := dlopen('libasound.so', RTLD_NOW);
    if AsoundLib <> nil then begin
      Pointer(snd_pcm_open)       := dlsym(AsoundLib, 'snd_pcm_open');
      Pointer(snd_pcm_set_params) := dlsym(AsoundLib, 'snd_pcm_set_params');
      Pointer(snd_pcm_writei)     := dlsym(AsoundLib, 'snd_pcm_writei');
      Pointer(snd_pcm_drain)      := dlsym(AsoundLib, 'snd_pcm_drain');
      Pointer(snd_pcm_drop)       := dlsym(AsoundLib, 'snd_pcm_drop');
      Pointer(snd_pcm_close)      := dlsym(AsoundLib, 'snd_pcm_close');
      Pointer(snd_pcm_prepare)    := dlsym(AsoundLib, 'snd_pcm_prepare');
    end;
  end;
  Result := (AsoundLib <> nil) and Assigned(snd_pcm_open) and
    Assigned(snd_pcm_set_params) and Assigned(snd_pcm_writei) and
    Assigned(snd_pcm_close);
end;

type
  //non-blocking playback: the thread feeds ALSA and finishes on its own
  TAlsaPlayThread = class(TThread)
  public
    Buf: array of SmallInt;
    Frames: Integer;
    procedure Execute; override;
  end;

procedure TAlsaPlayThread.Execute;
var Done, N: NativeInt;
begin
  Done := 0;
  while (not Terminated) and (Done < Frames) do begin
    N := snd_pcm_writei(CurPcm, @Buf[Done * 2], Frames - Done);
    if N < 0 then begin
      if Assigned(snd_pcm_prepare) then snd_pcm_prepare(CurPcm) else Break;
    end
    else Inc(Done, N);
  end;
  if not Terminated then
    if Assigned(snd_pcm_drain) then snd_pcm_drain(CurPcm);
end;

procedure StopPlayback;
begin
  if PlayThread <> nil then begin
    PlayThread.Terminate;
    PlayThread.WaitFor;
    FreeAndNil(PlayThread);
  end;
  if CurPcm <> nil then begin
    if Assigned(snd_pcm_drop) then snd_pcm_drop(CurPcm);
    snd_pcm_close(CurPcm);
    CurPcm := nil;
  end;
end;

function PlayPCM16(const Data: array of SmallInt; FrameCount, SampleRate: Integer;
  Blocking: Boolean): Boolean;
var T: TAlsaPlayThread;
begin
  Result := False;
  if (FrameCount < 1) or not LoadAsound then Exit;
  StopPlayback;

  if snd_pcm_open(CurPcm, 'default', SND_PCM_STREAM_PLAYBACK, 0) < 0 then begin
    CurPcm := nil; Exit;
  end;
  if snd_pcm_set_params(CurPcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
    2, SampleRate, 1, 200000) < 0 then begin
    snd_pcm_close(CurPcm); CurPcm := nil; Exit;
  end;

  T := TAlsaPlayThread.Create(True);
  SetLength(T.Buf, FrameCount * 2);
  Move(Data[0], T.Buf[0], FrameCount * 4);
  T.Frames := FrameCount;
  PlayThread := T;
  T.Start;

  if Blocking then begin
    PlayThread.WaitFor;
    StopPlayback;
  end;
  //in non-blocking mode the thread keeps playing in the background;
  //StopPlayback interrupts it

  Result := True;
end;
{$ENDIF}

{$IFDEF DARWIN}
//AudioToolbox AudioQueue - a system framework present on every macOS.
//Assembler symbols on darwin carry a '_' prefix (as in the FPC headers).
{$PACKRECORDS C} //struct layout matching the ABI of Apple frameworks
{$linkframework AudioToolbox}
{$linkframework CoreFoundation}

type
  AudioStreamBasicDescription = record
    mSampleRate: Double;
    mFormatID: UInt32;
    mFormatFlags: UInt32;
    mBytesPerPacket: UInt32;
    mFramesPerPacket: UInt32;
    mBytesPerFrame: UInt32;
    mChannelsPerFrame: UInt32;
    mBitsPerChannel: UInt32;
    mReserved: UInt32;
  end;
  AudioQueueRef = Pointer;
  AudioQueueBufferRef = ^AudioQueueBuffer;
  AudioQueueBuffer = record
    mAudioDataBytesCapacity: UInt32;
    mAudioData: Pointer;
    mAudioDataByteSize: UInt32;
    mUserData: Pointer;
    //further fields not needed for this usage
  end;
  AQOutputCallback = procedure(inUserData: Pointer; inAQ: AudioQueueRef;
    inBuffer: AudioQueueBufferRef); cdecl;

const
  kAudioFormatLinearPCM = $6C70636D; // 'lpcm'
  kLinearPCMFormatFlagIsSignedInteger = 4;
  kLinearPCMFormatFlagIsPacked = 8;

function AudioQueueNewOutput(const inFormat: AudioStreamBasicDescription;
  inCallbackProc: AQOutputCallback; inUserData: Pointer; inCallbackRunLoop: Pointer;
  inCallbackRunLoopMode: Pointer; inFlags: UInt32; var outAQ: AudioQueueRef): Integer;
  cdecl; external name '_AudioQueueNewOutput';
function AudioQueueAllocateBuffer(inAQ: AudioQueueRef; inBufferByteSize: UInt32;
  var outBuffer: AudioQueueBufferRef): Integer; cdecl; external name '_AudioQueueAllocateBuffer';
function AudioQueueEnqueueBuffer(inAQ: AudioQueueRef; inBuffer: AudioQueueBufferRef;
  inNumPacketDescs: UInt32; inPacketDescs: Pointer): Integer; cdecl;
  external name '_AudioQueueEnqueueBuffer';
function AudioQueueStart(inAQ: AudioQueueRef; inStartTime: Pointer): Integer; cdecl;
  external name '_AudioQueueStart';
function AudioQueueStop(inAQ: AudioQueueRef; inImmediate: Boolean): Integer; cdecl;
  external name '_AudioQueueStop';
function AudioQueueDispose(inAQ: AudioQueueRef; inImmediate: Boolean): Integer; cdecl;
  external name '_AudioQueueDispose';

var
  CurQueue: AudioQueueRef = nil;
  QueueDone: Boolean = False;

procedure AQCallback(inUserData: Pointer; inAQ: AudioQueueRef;
  inBuffer: AudioQueueBufferRef); cdecl;
begin
  //single buffer: when it comes back, the data has run out
  QueueDone := True;
end;

procedure StopPlayback;
begin
  if CurQueue = nil then Exit;
  AudioQueueStop(CurQueue, True);
  AudioQueueDispose(CurQueue, True);
  CurQueue := nil;
end;

function PlayPCM16(const Data: array of SmallInt; FrameCount, SampleRate: Integer;
  Blocking: Boolean): Boolean;
var Fmt: AudioStreamBasicDescription;
    Buf: AudioQueueBufferRef;
    Bytes: UInt32;
begin
  Result := False;
  if FrameCount < 1 then Exit;
  StopPlayback;
  QueueDone := False;

  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.mSampleRate := SampleRate;
  Fmt.mFormatID := kAudioFormatLinearPCM;
  Fmt.mFormatFlags := kLinearPCMFormatFlagIsSignedInteger or kLinearPCMFormatFlagIsPacked;
  Fmt.mBytesPerPacket := 4;
  Fmt.mFramesPerPacket := 1;
  Fmt.mBytesPerFrame := 4;
  Fmt.mChannelsPerFrame := 2;
  Fmt.mBitsPerChannel := 16;

  if AudioQueueNewOutput(Fmt, @AQCallback, nil, nil, nil, 0, CurQueue) <> 0 then begin
    CurQueue := nil; Exit;
  end;

  Bytes := FrameCount * 4;
  if AudioQueueAllocateBuffer(CurQueue, Bytes, Buf) <> 0 then begin
    StopPlayback; Exit;
  end;
  Move(Data[0], PByte(Buf^.mAudioData)^, Bytes);
  Buf^.mAudioDataByteSize := Bytes;
  AudioQueueEnqueueBuffer(CurQueue, Buf, 0, nil);
  if AudioQueueStart(CurQueue, nil) <> 0 then begin
    StopPlayback; Exit;
  end;

  if Blocking then begin
    while not QueueDone do Sleep(20);
    StopPlayback;
  end;
  Result := True;
end;
{$ENDIF}

{$IF not defined(WINDOWS) and not defined(LINUX) and not defined(DARWIN)}
//platform without a backend: the library still works, only playback is unavailable
procedure StopPlayback;
begin
end;

function PlayPCM16(const Data: array of SmallInt; FrameCount, SampleRate: Integer;
  Blocking: Boolean): Boolean;
begin
  Result := False;
end;
{$ENDIF}

initialization
finalization
  StopPlayback;
end.
