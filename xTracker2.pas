unit xTracker2;

{$mode delphi}{$H+}

interface

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	TAudio - convert and modify sound files                       //
//              Extended tracker formats via the OpenMPT translation          //
//              (units in the xm-it/openmpt directory)                        //
// Version:	0.1                                                           //
// License:     MIT (loaders and player: based on OpenMPT, BSD-3-Clause,     //
//              see xm-it/openmpt/LICENSE_OPENMPT)                            //
// Target:	Win64, Free Pascal, Delphi                                    //
// Copyright:	(c) 2025 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
// Registered formats (verified against libopenmpt where possible):          //
//   669, AMS, DBM, DSM, FAR, GDM, ICE, J2B/AM, MDL, MED (MMD0/MMD1), MTM,   //
//   OKT, PLM, PSM, PTM, ULT, DIGI                                           //
// Registered but without a reference decoder (render only checked to make   //
//   sound): FC/FC13/FC14/SMOD, FTM, GMC, IMS, KRIS, Puma, RTM, GT2/GTK,     //
//   DTM, IMF, ITP, PT36/MODL, STP, STK/M15                                  //
//                                                                            //
// MOD, XM, S3M and IT are handled by the lighter player in xTracker.pas.    //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

uses Classes, SysUtils, xAudio, xAudioBase, Dialogs;

type
  { TAudioTracker2 }

  TAudioTracker2 = class(TAudioBase)
  public
    function LoadFromStream(Str: TStream): Boolean; override;
  end;

var
  //settings used when a module is loaded through TAudio
  Tracker2SampleRate: Integer = 44100;
  Tracker2MaxSeconds: Integer = 600;

implementation

uses
  uBinaryReader, uTrackerModel, uTrackerPlayer, uWavWriter, uLoaderRegistry,
  uMDLCompression, uDMFCompression, uAMSCompression, uDSymCompression,
  uLoad669, uLoadMTM, uLoadFAR, uLoadOKT, uLoadULT, uLoadDSM, uLoadPTM,
  uLoadGDM, uLoadDIGI, uLoadIMS, uLoadGMC, uLoadKRIS, uLoadICE, uLoadPLM,
  uLoadRTM, uLoadDBM, uLoadMDL, uLoadAMS, uLoadPSM, uLoadFC, uLoadPuma,
  uLoadGT2, uLoadFTM, uLoadMED, uLoadJ2B,
  uLoadSTM, uLoadSFX, uLoadAMF, uLoadDMF, uLoadMT2, uLoadDSym, uLoadETX,
  uLoadUNIC, uLoadSymMOD, uLoadMO3,
  uLoad667, uLoadC67, uLoadCBA, uLoadFMT, uLoadTCB, uLoadXMF, uLoadMUSKM,
  uLoadUAX, uLoadMID,
  //OpenMPT-ported loaders that were only wired into the tracker2wav test
  //harness before; register them here so the app can load them too
  uLoadDTM, uLoadIMF, uLoadITP, uLoadPT36, uLoadSTP, uLoadSTK,
  //fallback MOD loader for packed formats that decode to a plain M.K. module
  //(e.g. some .unic files); registry orders it after the specific loaders
  uLoadMOD,
  //IT/XM/S3M loaders here serve container-unwrapped content only (e.g. a .umx
  //wrapping an IT module); plain .it/.xm/.s3m still route to the light xTracker
  uLoadIT, uLoadXM, uLoadS3M;

function TAudioTracker2.LoadFromStream(Str: TStream): Boolean;
var Bytes: TByteArray;
    M: TTrackerModule;
    Col: TPCMCollector;
    Options: TRenderOptions;
    NumFrames, i: Integer;
begin
  Result := False;

  SetLength(Bytes, Str.Size - Str.Position);
  if Length(Bytes) = 0 then Exit;
  Str.ReadBuffer(Bytes[0], Length(Bytes));

  try
    M := LoadTrackerModuleFromBytes(Bytes);
  except
    on EModuleFormatError do Exit;
  end;

  Col := TPCMCollector.Create;
  try
    Options.SampleRate := Tracker2SampleRate;
    Options.MaxSeconds := Tracker2MaxSeconds;
    Options.Gain := 1.0;

    try
      RenderModule(M, Options, Col);
    except
      on EModuleFormatError do Exit;
    end;

    NumFrames := Col.Used div 2;
    FHandle.FSampleRate := Options.SampleRate;
    FHandle.FSampleSize := 16;
    SetLength(FHandle.FFrames, NumFrames);

    for i:=0 to NumFrames-1 do begin
      FHandle.FFrames[i].Left  := Col.Data[i*2];
      FHandle.FFrames[i].Right := Col.Data[i*2+1];
    end;
  finally
    Col.Free;
    M.Free;
  end;

  Result := NumFrames > 0;
end;

initialization
  //formats verified against libopenmpt through ffmpeg
  RegisterAudioFormat('669',  TAudioTracker2);
  RegisterAudioFormat('ams',  TAudioTracker2);
  RegisterAudioFormat('dbm',  TAudioTracker2);
  RegisterAudioFormat('dsm',  TAudioTracker2);
  RegisterAudioFormat('far',  TAudioTracker2);
  RegisterAudioFormat('gdm',  TAudioTracker2);
  RegisterAudioFormat('ice',  TAudioTracker2);
  RegisterAudioFormat('j2b',  TAudioTracker2);
  RegisterAudioFormat('am',   TAudioTracker2);
  RegisterAudioFormat('mdl',  TAudioTracker2);
  RegisterAudioFormat('med',  TAudioTracker2);
  RegisterAudioFormat('mmd0', TAudioTracker2);
  RegisterAudioFormat('mmd1', TAudioTracker2);
  RegisterAudioFormat('mtm',  TAudioTracker2);
  RegisterAudioFormat('okt',  TAudioTracker2);
  RegisterAudioFormat('plm',  TAudioTracker2);
  RegisterAudioFormat('psm',  TAudioTracker2);
  RegisterAudioFormat('ptm',  TAudioTracker2);
  RegisterAudioFormat('ult',  TAudioTracker2);
  RegisterAudioFormat('digi', TAudioTracker2);
  RegisterAudioFormat('stm',  TAudioTracker2);
  RegisterAudioFormat('dsym', TAudioTracker2);
  RegisterAudioFormat('amf',  TAudioTracker2);
  RegisterAudioFormat('sfx',  TAudioTracker2);
  RegisterAudioFormat('unic', TAudioTracker2);

  //decode correctly but the built-in player is not sample-accurate for these
  RegisterAudioFormat('dmf',  TAudioTracker2);
  RegisterAudioFormat('mt2',  TAudioTracker2);
  RegisterAudioFormat('mo3',  TAudioTracker2);

  //no reference decoder available; verified only to produce audio
  RegisterAudioFormat('fc',   TAudioTracker2);
  RegisterAudioFormat('fc13', TAudioTracker2);
  RegisterAudioFormat('fc14', TAudioTracker2);
  RegisterAudioFormat('smod', TAudioTracker2);
  RegisterAudioFormat('ftm',  TAudioTracker2);
  RegisterAudioFormat('gmc',  TAudioTracker2);
  RegisterAudioFormat('ims',  TAudioTracker2);
  RegisterAudioFormat('kris', TAudioTracker2);
  RegisterAudioFormat('puma', TAudioTracker2);
  RegisterAudioFormat('rtm',  TAudioTracker2);
  RegisterAudioFormat('gt2',  TAudioTracker2);
  RegisterAudioFormat('gtk',  TAudioTracker2);
  RegisterAudioFormat('etx',  TAudioTracker2);
  RegisterAudioFormat('667',  TAudioTracker2);
  RegisterAudioFormat('c67',  TAudioTracker2);
  RegisterAudioFormat('cba',  TAudioTracker2);
  RegisterAudioFormat('fmt',  TAudioTracker2);
  RegisterAudioFormat('tcb',  TAudioTracker2);
  RegisterAudioFormat('xmf',  TAudioTracker2);
  RegisterAudioFormat('mus',  TAudioTracker2);
  RegisterAudioFormat('dtm',  TAudioTracker2);  //Digital Tracker ('D.T.')
  RegisterAudioFormat('imf',  TAudioTracker2);  //Imago Orpheus ('IM10')
  RegisterAudioFormat('itp',  TAudioTracker2);  //Impulse Tracker Project
  RegisterAudioFormat('pt36', TAudioTracker2);  //ProTracker 3.6 IFF (FORM/MODL)
  RegisterAudioFormat('modl', TAudioTracker2);  //  "   alternate extension
  RegisterAudioFormat('stp',  TAudioTracker2);  //Soundtracker Pro II ('STP3')
  RegisterAudioFormat('stk',  TAudioTracker2);  //15-sample Ultimate Soundtracker
  RegisterAudioFormat('m15',  TAudioTracker2);  //  "   (alternate extension)
  RegisterAudioFormat('umx',  TAudioTracker2);  //Unreal music container
  RegisterAudioFormat('mid',  TAudioTracker2);
  RegisterAudioFormat('midi', TAudioTracker2);
  //note: .uax (Unreal sound package) is a sample ripper with no song, so it is
  //not exposed as a playable format even though its loader is compiled in

end.
