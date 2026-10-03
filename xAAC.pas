unit xAAC;

{$mode objfpc}{$H+}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	AAC decoder (MPEG-4 AAC-LC, ISO/IEC 14496-3) in pure Pascal   //
//		Main and LTP streams decode when they do not use prediction.  //
//		HE-AAC: SBR is decoded by xSBR (explicit and implicit         //
//		signalling); parametric stereo (HE-AAC v2) is output as mono. //
// Version:	0.2                                                           //
// Date:	01-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Free Pascal                                            //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

interface

uses SysUtils, Math, xSBR;

type
  EAacError = class(Exception);

  { TAacDecoder - decodes raw_data_blocks (one MP4 sample or the payload of
    one ADTS frame) into 1024 samples per channel. More than two channels
    are downmixed to stereo. }

  TAacDecoder = class
  private type
    TIcs = record
      WindowSequence, WindowShape, MaxSfb: Integer;
      NumWindows, NumGroups, NumSwb: Integer;
      GroupLen: array[0..7] of Integer;
      SwbOffset: array[0..52] of Integer;
      SfbCb: array[0..7, 0..51] of Byte;
      Sf: array[0..7, 0..51] of Integer;
      PulsePresent: Boolean;
      PulseStartSfb, NumPulse: Integer;
      PulseOffset, PulseAmp: array[0..3] of Integer;
      TnsPresent: Boolean;
      TnsNFilt, TnsCoefRes: array[0..7] of Integer;
      TnsLength, TnsOrder, TnsDirection, TnsCompress: array[0..7, 0..3] of Integer;
      TnsCoef: array[0..7, 0..3, 0..31] of Integer;
      Quant: array[0..1023] of Integer;
      Spec: array[0..1023] of Single;
    end;
    PIcs = ^TIcs;

    TChannelState = record
      Overlap: array[0..1023] of Single;
      PrevShape: Integer;
    end;
  private
    FObjectType, FSfIndex, FSampleRate, FChannelConfig: Integer;
    FConfigured: Boolean;
    // bit reader
    FData: PByte;
    FBitLen, FBitPos: Integer;
    // per element
    FIcs: array[0..1] of TIcs;
    FMsMaskPresent: Integer;
    FMsUsed: array[0..7, 0..51] of Boolean;
    // channels of the current frame (time domain) and their filter bank state
    FState: array[0..7] of TChannelState;
    FTime: array[0..7, 0..1023] of Single;
    FNumChannels: Integer;   // channels decoded in the current frame
    // SBR (HE-AAC)
    FSbr: array[0..7] of TSbrDecoder;   // per element
    FElemStart, FElemCount: array[0..7] of Integer;
    FNumElems: Integer;
    FExplicitSbr, FSbrDecided, FSbrActive: Boolean;
    FFrameLen: Integer;
    FTimeSbr: array[0..7, 0..2047] of Single;
    FOutChannels: Integer;   // 1 or 2, fixed after the first frame
    FOutput: array of Single; // interleaved, FOutChannels * 1024
    FRandState: Cardinal;
    // filter bank work buffers
    FBuf: array[0..2047] of Single;

    function GetBits(N: Integer): Cardinal;
    function Get1: Cardinal; inline;
    procedure SkipBits(N: Integer);
    procedure ByteAlign;
    function DecodeHuff(Tree: Integer): Integer;

    procedure ReadIcsInfo(var Ics: TIcs);
    procedure SetupBands(var Ics: TIcs);
    procedure ReadSectionData(var Ics: TIcs);
    procedure ReadScaleFactors(var Ics: TIcs; GlobalGain: Integer);
    procedure ReadPulse(var Ics: TIcs);
    procedure ReadTns(var Ics: TIcs);
    procedure ReadSpectral(var Ics: TIcs);
    procedure ReadIcs(var Ics: TIcs; CommonWindow: Boolean);
    procedure Dequantize(var Ics: TIcs);
    procedure ApplyPns(var Ics: TIcs; Partner: PIcs);
    procedure ApplyMsIs(var L, R: TIcs);
    procedure ApplyTns(var Ics: TIcs);
    procedure FilterBank(var Ics: TIcs; Ch: Integer);
    procedure SkipPce;
    procedure SkipCce;
    procedure MixOutput;
    procedure FreeSbr;
    function GetOutputRate: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { AudioSpecificConfig from an MP4 'esds' box }
    procedure ConfigureASC(const ASC: array of Byte);
    { ObjectType: 1 Main, 2 LC, 4 LTP; SfIndex: sampling frequency index }
    procedure Configure(ObjectType, SfIndex, ChannelConfig: Integer);
    procedure Reset;
    { decodes one raw_data_block; returns the number of samples per channel
      stored in Output: 1024, or 2048 with SBR }
    function DecodeFrame(Data: PByte; Len: Integer): Integer;
    function Output: PSingle;
    { replaces the output of a damaged frame with silence }
    procedure OutputSilence;
    { output sample rate: twice the core rate when SBR is used (known after
      the first frame) }
    property SampleRate: Integer read GetOutputRate;
    property CoreSampleRate: Integer read FSampleRate;
    property SbrActive: Boolean read FSbrActive;
    property ObjectType: Integer read FObjectType;
    property ChannelConfig: Integer read FChannelConfig;
    property OutChannels: Integer read FOutChannels;
  end;

const
  AacSampleRates: array[0..12] of Integer = (96000, 88200, 64000, 48000, 44100,
    32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350);

implementation

type
  TAacCode = record
    C: Cardinal;
    L: Byte;
  end;

const
{ AAC Huffman codebooks, ISO/IEC 14496-3 tables 4.A.1 - 4.A.12:
  codeword and length for each symbol index. Generated - do not edit. }

  AAC_CB1: array[0..80] of TAacCode = (
    (C:$7f8;L:11), (C:$1f1;L:9), (C:$7fd;L:11), (C:$3f5;L:10), (C:$68;L:7), (C:$3f0;L:10),
    (C:$7f7;L:11), (C:$1ec;L:9), (C:$7f5;L:11), (C:$3f1;L:10), (C:$72;L:7), (C:$3f4;L:10),
    (C:$74;L:7), (C:$11;L:5), (C:$76;L:7), (C:$1eb;L:9), (C:$6c;L:7), (C:$3f6;L:10),
    (C:$7fc;L:11), (C:$1e1;L:9), (C:$7f1;L:11), (C:$1f0;L:9), (C:$61;L:7), (C:$1f6;L:9),
    (C:$7f2;L:11), (C:$1ea;L:9), (C:$7fb;L:11), (C:$1f2;L:9), (C:$69;L:7), (C:$1ed;L:9),
    (C:$77;L:7), (C:$17;L:5), (C:$6f;L:7), (C:$1e6;L:9), (C:$64;L:7), (C:$1e5;L:9),
    (C:$67;L:7), (C:$15;L:5), (C:$62;L:7), (C:$12;L:5), (C:$0;L:1), (C:$14;L:5),
    (C:$65;L:7), (C:$16;L:5), (C:$6d;L:7), (C:$1e9;L:9), (C:$63;L:7), (C:$1e4;L:9),
    (C:$6b;L:7), (C:$13;L:5), (C:$71;L:7), (C:$1e3;L:9), (C:$70;L:7), (C:$1f3;L:9),
    (C:$7fe;L:11), (C:$1e7;L:9), (C:$7f3;L:11), (C:$1ef;L:9), (C:$60;L:7), (C:$1ee;L:9),
    (C:$7f0;L:11), (C:$1e2;L:9), (C:$7fa;L:11), (C:$3f3;L:10), (C:$6a;L:7), (C:$1e8;L:9),
    (C:$75;L:7), (C:$10;L:5), (C:$73;L:7), (C:$1f4;L:9), (C:$6e;L:7), (C:$3f7;L:10),
    (C:$7f6;L:11), (C:$1e0;L:9), (C:$7f9;L:11), (C:$3f2;L:10), (C:$66;L:7), (C:$1f5;L:9),
    (C:$7ff;L:11), (C:$1f7;L:9), (C:$7f4;L:11)
  );
  AAC_CB2: array[0..80] of TAacCode = (
    (C:$1f3;L:9), (C:$6f;L:7), (C:$1fd;L:9), (C:$eb;L:8), (C:$23;L:6), (C:$ea;L:8),
    (C:$1f7;L:9), (C:$e8;L:8), (C:$1fa;L:9), (C:$f2;L:8), (C:$2d;L:6), (C:$70;L:7),
    (C:$20;L:6), (C:$6;L:5), (C:$2b;L:6), (C:$6e;L:7), (C:$28;L:6), (C:$e9;L:8),
    (C:$1f9;L:9), (C:$66;L:7), (C:$f8;L:8), (C:$e7;L:8), (C:$1b;L:6), (C:$f1;L:8),
    (C:$1f4;L:9), (C:$6b;L:7), (C:$1f5;L:9), (C:$ec;L:8), (C:$2a;L:6), (C:$6c;L:7),
    (C:$2c;L:6), (C:$a;L:5), (C:$27;L:6), (C:$67;L:7), (C:$1a;L:6), (C:$f5;L:8),
    (C:$24;L:6), (C:$8;L:5), (C:$1f;L:6), (C:$9;L:5), (C:$0;L:3), (C:$7;L:5),
    (C:$1d;L:6), (C:$b;L:5), (C:$30;L:6), (C:$ef;L:8), (C:$1c;L:6), (C:$64;L:7),
    (C:$1e;L:6), (C:$c;L:5), (C:$29;L:6), (C:$f3;L:8), (C:$2f;L:6), (C:$f0;L:8),
    (C:$1fc;L:9), (C:$71;L:7), (C:$1f2;L:9), (C:$f4;L:8), (C:$21;L:6), (C:$e6;L:8),
    (C:$f7;L:8), (C:$68;L:7), (C:$1f8;L:9), (C:$ee;L:8), (C:$22;L:6), (C:$65;L:7),
    (C:$31;L:6), (C:$2;L:4), (C:$26;L:6), (C:$ed;L:8), (C:$25;L:6), (C:$6a;L:7),
    (C:$1fb;L:9), (C:$72;L:7), (C:$1fe;L:9), (C:$69;L:7), (C:$2e;L:6), (C:$f6;L:8),
    (C:$1ff;L:9), (C:$6d;L:7), (C:$1f6;L:9)
  );
  AAC_CB3: array[0..80] of TAacCode = (
    (C:$0;L:1), (C:$9;L:4), (C:$ef;L:8), (C:$b;L:4), (C:$19;L:5), (C:$f0;L:8),
    (C:$1eb;L:9), (C:$1e6;L:9), (C:$3f2;L:10), (C:$a;L:4), (C:$35;L:6), (C:$1ef;L:9),
    (C:$34;L:6), (C:$37;L:6), (C:$1e9;L:9), (C:$1ed;L:9), (C:$1e7;L:9), (C:$3f3;L:10),
    (C:$1ee;L:9), (C:$3ed;L:10), (C:$1ffa;L:13), (C:$1ec;L:9), (C:$1f2;L:9), (C:$7f9;L:11),
    (C:$7f8;L:11), (C:$3f8;L:10), (C:$ff8;L:12), (C:$8;L:4), (C:$38;L:6), (C:$3f6;L:10),
    (C:$36;L:6), (C:$75;L:7), (C:$3f1;L:10), (C:$3eb;L:10), (C:$3ec;L:10), (C:$ff4;L:12),
    (C:$18;L:5), (C:$76;L:7), (C:$7f4;L:11), (C:$39;L:6), (C:$74;L:7), (C:$3ef;L:10),
    (C:$1f3;L:9), (C:$1f4;L:9), (C:$7f6;L:11), (C:$1e8;L:9), (C:$3ea;L:10), (C:$1ffc;L:13),
    (C:$f2;L:8), (C:$1f1;L:9), (C:$ffb;L:12), (C:$3f5;L:10), (C:$7f3;L:11), (C:$ffc;L:12),
    (C:$ee;L:8), (C:$3f7;L:10), (C:$7ffe;L:15), (C:$1f0;L:9), (C:$7f5;L:11), (C:$7ffd;L:15),
    (C:$1ffb;L:13), (C:$3ffa;L:14), (C:$ffff;L:16), (C:$f1;L:8), (C:$3f0;L:10), (C:$3ffc;L:14),
    (C:$1ea;L:9), (C:$3ee;L:10), (C:$3ffb;L:14), (C:$ff6;L:12), (C:$ffa;L:12), (C:$7ffc;L:15),
    (C:$7f2;L:11), (C:$ff5;L:12), (C:$fffe;L:16), (C:$3f4;L:10), (C:$7f7;L:11), (C:$7ffb;L:15),
    (C:$ff7;L:12), (C:$ff9;L:12), (C:$7ffa;L:15)
  );
  AAC_CB4: array[0..80] of TAacCode = (
    (C:$7;L:4), (C:$16;L:5), (C:$f6;L:8), (C:$18;L:5), (C:$8;L:4), (C:$ef;L:8),
    (C:$1ef;L:9), (C:$f3;L:8), (C:$7f8;L:11), (C:$19;L:5), (C:$17;L:5), (C:$ed;L:8),
    (C:$15;L:5), (C:$1;L:4), (C:$e2;L:8), (C:$f0;L:8), (C:$70;L:7), (C:$3f0;L:10),
    (C:$1ee;L:9), (C:$f1;L:8), (C:$7fa;L:11), (C:$ee;L:8), (C:$e4;L:8), (C:$3f2;L:10),
    (C:$7f6;L:11), (C:$3ef;L:10), (C:$7fd;L:11), (C:$5;L:4), (C:$14;L:5), (C:$f2;L:8),
    (C:$9;L:4), (C:$4;L:4), (C:$e5;L:8), (C:$f4;L:8), (C:$e8;L:8), (C:$3f4;L:10),
    (C:$6;L:4), (C:$2;L:4), (C:$e7;L:8), (C:$3;L:4), (C:$0;L:4), (C:$6b;L:7),
    (C:$e3;L:8), (C:$69;L:7), (C:$1f3;L:9), (C:$eb;L:8), (C:$e6;L:8), (C:$3f6;L:10),
    (C:$6e;L:7), (C:$6a;L:7), (C:$1f4;L:9), (C:$3ec;L:10), (C:$1f0;L:9), (C:$3f9;L:10),
    (C:$f5;L:8), (C:$ec;L:8), (C:$7fb;L:11), (C:$ea;L:8), (C:$6f;L:7), (C:$3f7;L:10),
    (C:$7f9;L:11), (C:$3f3;L:10), (C:$fff;L:12), (C:$e9;L:8), (C:$6d;L:7), (C:$3f8;L:10),
    (C:$6c;L:7), (C:$68;L:7), (C:$1f5;L:9), (C:$3ee;L:10), (C:$1f2;L:9), (C:$7f4;L:11),
    (C:$7f7;L:11), (C:$3f1;L:10), (C:$ffe;L:12), (C:$3ed;L:10), (C:$1f1;L:9), (C:$7f5;L:11),
    (C:$7fe;L:11), (C:$3f5;L:10), (C:$7fc;L:11)
  );
  AAC_CB5: array[0..80] of TAacCode = (
    (C:$1fff;L:13), (C:$ff7;L:12), (C:$7f4;L:11), (C:$7e8;L:11), (C:$3f1;L:10), (C:$7ee;L:11),
    (C:$7f9;L:11), (C:$ff8;L:12), (C:$1ffd;L:13), (C:$ffd;L:12), (C:$7f1;L:11), (C:$3e8;L:10),
    (C:$1e8;L:9), (C:$f0;L:8), (C:$1ec;L:9), (C:$3ee;L:10), (C:$7f2;L:11), (C:$ffa;L:12),
    (C:$ff4;L:12), (C:$3ef;L:10), (C:$1f2;L:9), (C:$e8;L:8), (C:$70;L:7), (C:$ec;L:8),
    (C:$1f0;L:9), (C:$3ea;L:10), (C:$7f3;L:11), (C:$7eb;L:11), (C:$1eb;L:9), (C:$ea;L:8),
    (C:$1a;L:5), (C:$8;L:4), (C:$19;L:5), (C:$ee;L:8), (C:$1ef;L:9), (C:$7ed;L:11),
    (C:$3f0;L:10), (C:$f2;L:8), (C:$73;L:7), (C:$b;L:4), (C:$0;L:1), (C:$a;L:4),
    (C:$71;L:7), (C:$f3;L:8), (C:$7e9;L:11), (C:$7ef;L:11), (C:$1ee;L:9), (C:$ef;L:8),
    (C:$18;L:5), (C:$9;L:4), (C:$1b;L:5), (C:$eb;L:8), (C:$1e9;L:9), (C:$7ec;L:11),
    (C:$7f6;L:11), (C:$3eb;L:10), (C:$1f3;L:9), (C:$ed;L:8), (C:$72;L:7), (C:$e9;L:8),
    (C:$1f1;L:9), (C:$3ed;L:10), (C:$7f7;L:11), (C:$ff6;L:12), (C:$7f0;L:11), (C:$3e9;L:10),
    (C:$1ed;L:9), (C:$f1;L:8), (C:$1ea;L:9), (C:$3ec;L:10), (C:$7f8;L:11), (C:$ff9;L:12),
    (C:$1ffc;L:13), (C:$ffc;L:12), (C:$ff5;L:12), (C:$7ea;L:11), (C:$3f3;L:10), (C:$3f2;L:10),
    (C:$7f5;L:11), (C:$ffb;L:12), (C:$1ffe;L:13)
  );
  AAC_CB6: array[0..80] of TAacCode = (
    (C:$7fe;L:11), (C:$3fd;L:10), (C:$1f1;L:9), (C:$1eb;L:9), (C:$1f4;L:9), (C:$1ea;L:9),
    (C:$1f0;L:9), (C:$3fc;L:10), (C:$7fd;L:11), (C:$3f6;L:10), (C:$1e5;L:9), (C:$ea;L:8),
    (C:$6c;L:7), (C:$71;L:7), (C:$68;L:7), (C:$f0;L:8), (C:$1e6;L:9), (C:$3f7;L:10),
    (C:$1f3;L:9), (C:$ef;L:8), (C:$32;L:6), (C:$27;L:6), (C:$28;L:6), (C:$26;L:6),
    (C:$31;L:6), (C:$eb;L:8), (C:$1f7;L:9), (C:$1e8;L:9), (C:$6f;L:7), (C:$2e;L:6),
    (C:$8;L:4), (C:$4;L:4), (C:$6;L:4), (C:$29;L:6), (C:$6b;L:7), (C:$1ee;L:9),
    (C:$1ef;L:9), (C:$72;L:7), (C:$2d;L:6), (C:$2;L:4), (C:$0;L:4), (C:$3;L:4),
    (C:$2f;L:6), (C:$73;L:7), (C:$1fa;L:9), (C:$1e7;L:9), (C:$6e;L:7), (C:$2b;L:6),
    (C:$7;L:4), (C:$1;L:4), (C:$5;L:4), (C:$2c;L:6), (C:$6d;L:7), (C:$1ec;L:9),
    (C:$1f9;L:9), (C:$ee;L:8), (C:$30;L:6), (C:$24;L:6), (C:$2a;L:6), (C:$25;L:6),
    (C:$33;L:6), (C:$ec;L:8), (C:$1f2;L:9), (C:$3f8;L:10), (C:$1e4;L:9), (C:$ed;L:8),
    (C:$6a;L:7), (C:$70;L:7), (C:$69;L:7), (C:$74;L:7), (C:$f1;L:8), (C:$3fa;L:10),
    (C:$7ff;L:11), (C:$3f9;L:10), (C:$1f6;L:9), (C:$1ed;L:9), (C:$1f8;L:9), (C:$1e9;L:9),
    (C:$1f5;L:9), (C:$3fb;L:10), (C:$7fc;L:11)
  );
  AAC_CB7: array[0..63] of TAacCode = (
    (C:$0;L:1), (C:$5;L:3), (C:$37;L:6), (C:$74;L:7), (C:$f2;L:8), (C:$1eb;L:9),
    (C:$3ed;L:10), (C:$7f7;L:11), (C:$4;L:3), (C:$c;L:4), (C:$35;L:6), (C:$71;L:7),
    (C:$ec;L:8), (C:$ee;L:8), (C:$1ee;L:9), (C:$1f5;L:9), (C:$36;L:6), (C:$34;L:6),
    (C:$72;L:7), (C:$ea;L:8), (C:$f1;L:8), (C:$1e9;L:9), (C:$1f3;L:9), (C:$3f5;L:10),
    (C:$73;L:7), (C:$70;L:7), (C:$eb;L:8), (C:$f0;L:8), (C:$1f1;L:9), (C:$1f0;L:9),
    (C:$3ec;L:10), (C:$3fa;L:10), (C:$f3;L:8), (C:$ed;L:8), (C:$1e8;L:9), (C:$1ef;L:9),
    (C:$3ef;L:10), (C:$3f1;L:10), (C:$3f9;L:10), (C:$7fb;L:11), (C:$1ed;L:9), (C:$ef;L:8),
    (C:$1ea;L:9), (C:$1f2;L:9), (C:$3f3;L:10), (C:$3f8;L:10), (C:$7f9;L:11), (C:$7fc;L:11),
    (C:$3ee;L:10), (C:$1ec;L:9), (C:$1f4;L:9), (C:$3f4;L:10), (C:$3f7;L:10), (C:$7f8;L:11),
    (C:$ffd;L:12), (C:$ffe;L:12), (C:$7f6;L:11), (C:$3f0;L:10), (C:$3f2;L:10), (C:$3f6;L:10),
    (C:$7fa;L:11), (C:$7fd;L:11), (C:$ffc;L:12), (C:$fff;L:12)
  );
  AAC_CB8: array[0..63] of TAacCode = (
    (C:$e;L:5), (C:$5;L:4), (C:$10;L:5), (C:$30;L:6), (C:$6f;L:7), (C:$f1;L:8),
    (C:$1fa;L:9), (C:$3fe;L:10), (C:$3;L:4), (C:$0;L:3), (C:$4;L:4), (C:$12;L:5),
    (C:$2c;L:6), (C:$6a;L:7), (C:$75;L:7), (C:$f8;L:8), (C:$f;L:5), (C:$2;L:4),
    (C:$6;L:4), (C:$14;L:5), (C:$2e;L:6), (C:$69;L:7), (C:$72;L:7), (C:$f5;L:8),
    (C:$2f;L:6), (C:$11;L:5), (C:$13;L:5), (C:$2a;L:6), (C:$32;L:6), (C:$6c;L:7),
    (C:$ec;L:8), (C:$fa;L:8), (C:$71;L:7), (C:$2b;L:6), (C:$2d;L:6), (C:$31;L:6),
    (C:$6d;L:7), (C:$70;L:7), (C:$f2;L:8), (C:$1f9;L:9), (C:$ef;L:8), (C:$68;L:7),
    (C:$33;L:6), (C:$6b;L:7), (C:$6e;L:7), (C:$ee;L:8), (C:$f9;L:8), (C:$3fc;L:10),
    (C:$1f8;L:9), (C:$74;L:7), (C:$73;L:7), (C:$ed;L:8), (C:$f0;L:8), (C:$f6;L:8),
    (C:$1f6;L:9), (C:$1fd;L:9), (C:$3fd;L:10), (C:$f3;L:8), (C:$f4;L:8), (C:$f7;L:8),
    (C:$1f7;L:9), (C:$1fb;L:9), (C:$1fc;L:9), (C:$3ff;L:10)
  );
  AAC_CB9: array[0..168] of TAacCode = (
    (C:$0;L:1), (C:$5;L:3), (C:$37;L:6), (C:$e7;L:8), (C:$1de;L:9), (C:$3ce;L:10),
    (C:$3d9;L:10), (C:$7c8;L:11), (C:$7cd;L:11), (C:$fc8;L:12), (C:$fdd;L:12), (C:$1fe4;L:13),
    (C:$1fec;L:13), (C:$4;L:3), (C:$c;L:4), (C:$35;L:6), (C:$72;L:7), (C:$ea;L:8),
    (C:$ed;L:8), (C:$1e2;L:9), (C:$3d1;L:10), (C:$3d3;L:10), (C:$3e0;L:10), (C:$7d8;L:11),
    (C:$fcf;L:12), (C:$fd5;L:12), (C:$36;L:6), (C:$34;L:6), (C:$71;L:7), (C:$e8;L:8),
    (C:$ec;L:8), (C:$1e1;L:9), (C:$3cf;L:10), (C:$3dd;L:10), (C:$3db;L:10), (C:$7d0;L:11),
    (C:$fc7;L:12), (C:$fd4;L:12), (C:$fe4;L:12), (C:$e6;L:8), (C:$70;L:7), (C:$e9;L:8),
    (C:$1dd;L:9), (C:$1e3;L:9), (C:$3d2;L:10), (C:$3dc;L:10), (C:$7cc;L:11), (C:$7ca;L:11),
    (C:$7de;L:11), (C:$fd8;L:12), (C:$fea;L:12), (C:$1fdb;L:13), (C:$1df;L:9), (C:$eb;L:8),
    (C:$1dc;L:9), (C:$1e6;L:9), (C:$3d5;L:10), (C:$3de;L:10), (C:$7cb;L:11), (C:$7dd;L:11),
    (C:$7dc;L:11), (C:$fcd;L:12), (C:$fe2;L:12), (C:$fe7;L:12), (C:$1fe1;L:13), (C:$3d0;L:10),
    (C:$1e0;L:9), (C:$1e4;L:9), (C:$3d6;L:10), (C:$7c5;L:11), (C:$7d1;L:11), (C:$7db;L:11),
    (C:$fd2;L:12), (C:$7e0;L:11), (C:$fd9;L:12), (C:$feb;L:12), (C:$1fe3;L:13), (C:$1fe9;L:13),
    (C:$7c4;L:11), (C:$1e5;L:9), (C:$3d7;L:10), (C:$7c6;L:11), (C:$7cf;L:11), (C:$7da;L:11),
    (C:$fcb;L:12), (C:$fda;L:12), (C:$fe3;L:12), (C:$fe9;L:12), (C:$1fe6;L:13), (C:$1ff3;L:13),
    (C:$1ff7;L:13), (C:$7d3;L:11), (C:$3d8;L:10), (C:$3e1;L:10), (C:$7d4;L:11), (C:$7d9;L:11),
    (C:$fd3;L:12), (C:$fde;L:12), (C:$1fdd;L:13), (C:$1fd9;L:13), (C:$1fe2;L:13), (C:$1fea;L:13),
    (C:$1ff1;L:13), (C:$1ff6;L:13), (C:$7d2;L:11), (C:$3d4;L:10), (C:$3da;L:10), (C:$7c7;L:11),
    (C:$7d7;L:11), (C:$7e2;L:11), (C:$fce;L:12), (C:$fdb;L:12), (C:$1fd8;L:13), (C:$1fee;L:13),
    (C:$3ff0;L:14), (C:$1ff4;L:13), (C:$3ff2;L:14), (C:$7e1;L:11), (C:$3df;L:10), (C:$7c9;L:11),
    (C:$7d6;L:11), (C:$fca;L:12), (C:$fd0;L:12), (C:$fe5;L:12), (C:$fe6;L:12), (C:$1feb;L:13),
    (C:$1fef;L:13), (C:$3ff3;L:14), (C:$3ff4;L:14), (C:$3ff5;L:14), (C:$fe0;L:12), (C:$7ce;L:11),
    (C:$7d5;L:11), (C:$fc6;L:12), (C:$fd1;L:12), (C:$fe1;L:12), (C:$1fe0;L:13), (C:$1fe8;L:13),
    (C:$1ff0;L:13), (C:$3ff1;L:14), (C:$3ff8;L:14), (C:$3ff6;L:14), (C:$7ffc;L:15), (C:$fe8;L:12),
    (C:$7df;L:11), (C:$fc9;L:12), (C:$fd7;L:12), (C:$fdc;L:12), (C:$1fdc;L:13), (C:$1fdf;L:13),
    (C:$1fed;L:13), (C:$1ff5;L:13), (C:$3ff9;L:14), (C:$3ffb;L:14), (C:$7ffd;L:15), (C:$7ffe;L:15),
    (C:$1fe7;L:13), (C:$fcc;L:12), (C:$fd6;L:12), (C:$fdf;L:12), (C:$1fde;L:13), (C:$1fda;L:13),
    (C:$1fe5;L:13), (C:$1ff2;L:13), (C:$3ffa;L:14), (C:$3ff7;L:14), (C:$3ffc;L:14), (C:$3ffd;L:14),
    (C:$7fff;L:15)
  );
  AAC_CB10: array[0..168] of TAacCode = (
    (C:$22;L:6), (C:$8;L:5), (C:$1d;L:6), (C:$26;L:6), (C:$5f;L:7), (C:$d3;L:8),
    (C:$1cf;L:9), (C:$3d0;L:10), (C:$3d7;L:10), (C:$3ed;L:10), (C:$7f0;L:11), (C:$7f6;L:11),
    (C:$ffd;L:12), (C:$7;L:5), (C:$0;L:4), (C:$1;L:4), (C:$9;L:5), (C:$20;L:6),
    (C:$54;L:7), (C:$60;L:7), (C:$d5;L:8), (C:$dc;L:8), (C:$1d4;L:9), (C:$3cd;L:10),
    (C:$3de;L:10), (C:$7e7;L:11), (C:$1c;L:6), (C:$2;L:4), (C:$6;L:5), (C:$c;L:5),
    (C:$1e;L:6), (C:$28;L:6), (C:$5b;L:7), (C:$cd;L:8), (C:$d9;L:8), (C:$1ce;L:9),
    (C:$1dc;L:9), (C:$3d9;L:10), (C:$3f1;L:10), (C:$25;L:6), (C:$b;L:5), (C:$a;L:5),
    (C:$d;L:5), (C:$24;L:6), (C:$57;L:7), (C:$61;L:7), (C:$cc;L:8), (C:$dd;L:8),
    (C:$1cc;L:9), (C:$1de;L:9), (C:$3d3;L:10), (C:$3e7;L:10), (C:$5d;L:7), (C:$21;L:6),
    (C:$1f;L:6), (C:$23;L:6), (C:$27;L:6), (C:$59;L:7), (C:$64;L:7), (C:$d8;L:8),
    (C:$df;L:8), (C:$1d2;L:9), (C:$1e2;L:9), (C:$3dd;L:10), (C:$3ee;L:10), (C:$d1;L:8),
    (C:$55;L:7), (C:$29;L:6), (C:$56;L:7), (C:$58;L:7), (C:$62;L:7), (C:$ce;L:8),
    (C:$e0;L:8), (C:$e2;L:8), (C:$1da;L:9), (C:$3d4;L:10), (C:$3e3;L:10), (C:$7eb;L:11),
    (C:$1c9;L:9), (C:$5e;L:7), (C:$5a;L:7), (C:$5c;L:7), (C:$63;L:7), (C:$ca;L:8),
    (C:$da;L:8), (C:$1c7;L:9), (C:$1ca;L:9), (C:$1e0;L:9), (C:$3db;L:10), (C:$3e8;L:10),
    (C:$7ec;L:11), (C:$1e3;L:9), (C:$d2;L:8), (C:$cb;L:8), (C:$d0;L:8), (C:$d7;L:8),
    (C:$db;L:8), (C:$1c6;L:9), (C:$1d5;L:9), (C:$1d8;L:9), (C:$3ca;L:10), (C:$3da;L:10),
    (C:$7ea;L:11), (C:$7f1;L:11), (C:$1e1;L:9), (C:$d4;L:8), (C:$cf;L:8), (C:$d6;L:8),
    (C:$de;L:8), (C:$e1;L:8), (C:$1d0;L:9), (C:$1d6;L:9), (C:$3d1;L:10), (C:$3d5;L:10),
    (C:$3f2;L:10), (C:$7ee;L:11), (C:$7fb;L:11), (C:$3e9;L:10), (C:$1cd;L:9), (C:$1c8;L:9),
    (C:$1cb;L:9), (C:$1d1;L:9), (C:$1d7;L:9), (C:$1df;L:9), (C:$3cf;L:10), (C:$3e0;L:10),
    (C:$3ef;L:10), (C:$7e6;L:11), (C:$7f8;L:11), (C:$ffa;L:12), (C:$3eb;L:10), (C:$1dd;L:9),
    (C:$1d3;L:9), (C:$1d9;L:9), (C:$1db;L:9), (C:$3d2;L:10), (C:$3cc;L:10), (C:$3dc;L:10),
    (C:$3ea;L:10), (C:$7ed;L:11), (C:$7f3;L:11), (C:$7f9;L:11), (C:$ff9;L:12), (C:$7f2;L:11),
    (C:$3ce;L:10), (C:$1e4;L:9), (C:$3cb;L:10), (C:$3d8;L:10), (C:$3d6;L:10), (C:$3e2;L:10),
    (C:$3e5;L:10), (C:$7e8;L:11), (C:$7f4;L:11), (C:$7f5;L:11), (C:$7f7;L:11), (C:$ffb;L:12),
    (C:$7fa;L:11), (C:$3ec;L:10), (C:$3df;L:10), (C:$3e1;L:10), (C:$3e4;L:10), (C:$3e6;L:10),
    (C:$3f0;L:10), (C:$7e9;L:11), (C:$7ef;L:11), (C:$ff8;L:12), (C:$ffe;L:12), (C:$ffc;L:12),
    (C:$fff;L:12)
  );
  AAC_CB11: array[0..288] of TAacCode = (
    (C:$0;L:4), (C:$6;L:5), (C:$19;L:6), (C:$3d;L:7), (C:$9c;L:8), (C:$c6;L:8),
    (C:$1a7;L:9), (C:$390;L:10), (C:$3c2;L:10), (C:$3df;L:10), (C:$7e6;L:11), (C:$7f3;L:11),
    (C:$ffb;L:12), (C:$7ec;L:11), (C:$ffa;L:12), (C:$ffe;L:12), (C:$38e;L:10), (C:$5;L:5),
    (C:$1;L:4), (C:$8;L:5), (C:$14;L:6), (C:$37;L:7), (C:$42;L:7), (C:$92;L:8),
    (C:$af;L:8), (C:$191;L:9), (C:$1a5;L:9), (C:$1b5;L:9), (C:$39e;L:10), (C:$3c0;L:10),
    (C:$3a2;L:10), (C:$3cd;L:10), (C:$7d6;L:11), (C:$ae;L:8), (C:$17;L:6), (C:$7;L:5),
    (C:$9;L:5), (C:$18;L:6), (C:$39;L:7), (C:$40;L:7), (C:$8e;L:8), (C:$a3;L:8),
    (C:$b8;L:8), (C:$199;L:9), (C:$1ac;L:9), (C:$1c1;L:9), (C:$3b1;L:10), (C:$396;L:10),
    (C:$3be;L:10), (C:$3ca;L:10), (C:$9d;L:8), (C:$3c;L:7), (C:$15;L:6), (C:$16;L:6),
    (C:$1a;L:6), (C:$3b;L:7), (C:$44;L:7), (C:$91;L:8), (C:$a5;L:8), (C:$be;L:8),
    (C:$196;L:9), (C:$1ae;L:9), (C:$1b9;L:9), (C:$3a1;L:10), (C:$391;L:10), (C:$3a5;L:10),
    (C:$3d5;L:10), (C:$94;L:8), (C:$9a;L:8), (C:$36;L:7), (C:$38;L:7), (C:$3a;L:7),
    (C:$41;L:7), (C:$8c;L:8), (C:$9b;L:8), (C:$b0;L:8), (C:$c3;L:8), (C:$19e;L:9),
    (C:$1ab;L:9), (C:$1bc;L:9), (C:$39f;L:10), (C:$38f;L:10), (C:$3a9;L:10), (C:$3cf;L:10),
    (C:$93;L:8), (C:$bf;L:8), (C:$3e;L:7), (C:$3f;L:7), (C:$43;L:7), (C:$45;L:7),
    (C:$9e;L:8), (C:$a7;L:8), (C:$b9;L:8), (C:$194;L:9), (C:$1a2;L:9), (C:$1ba;L:9),
    (C:$1c3;L:9), (C:$3a6;L:10), (C:$3a7;L:10), (C:$3bb;L:10), (C:$3d4;L:10), (C:$9f;L:8),
    (C:$1a0;L:9), (C:$8f;L:8), (C:$8d;L:8), (C:$90;L:8), (C:$98;L:8), (C:$a6;L:8),
    (C:$b6;L:8), (C:$c4;L:8), (C:$19f;L:9), (C:$1af;L:9), (C:$1bf;L:9), (C:$399;L:10),
    (C:$3bf;L:10), (C:$3b4;L:10), (C:$3c9;L:10), (C:$3e7;L:10), (C:$a8;L:8), (C:$1b6;L:9),
    (C:$ab;L:8), (C:$a4;L:8), (C:$aa;L:8), (C:$b2;L:8), (C:$c2;L:8), (C:$c5;L:8),
    (C:$198;L:9), (C:$1a4;L:9), (C:$1b8;L:9), (C:$38c;L:10), (C:$3a4;L:10), (C:$3c4;L:10),
    (C:$3c6;L:10), (C:$3dd;L:10), (C:$3e8;L:10), (C:$ad;L:8), (C:$3af;L:10), (C:$192;L:9),
    (C:$bd;L:8), (C:$bc;L:8), (C:$18e;L:9), (C:$197;L:9), (C:$19a;L:9), (C:$1a3;L:9),
    (C:$1b1;L:9), (C:$38d;L:10), (C:$398;L:10), (C:$3b7;L:10), (C:$3d3;L:10), (C:$3d1;L:10),
    (C:$3db;L:10), (C:$7dd;L:11), (C:$b4;L:8), (C:$3de;L:10), (C:$1a9;L:9), (C:$19b;L:9),
    (C:$19c;L:9), (C:$1a1;L:9), (C:$1aa;L:9), (C:$1ad;L:9), (C:$1b3;L:9), (C:$38b;L:10),
    (C:$3b2;L:10), (C:$3b8;L:10), (C:$3ce;L:10), (C:$3e1;L:10), (C:$3e0;L:10), (C:$7d2;L:11),
    (C:$7e5;L:11), (C:$b7;L:8), (C:$7e3;L:11), (C:$1bb;L:9), (C:$1a8;L:9), (C:$1a6;L:9),
    (C:$1b0;L:9), (C:$1b2;L:9), (C:$1b7;L:9), (C:$39b;L:10), (C:$39a;L:10), (C:$3ba;L:10),
    (C:$3b5;L:10), (C:$3d6;L:10), (C:$7d7;L:11), (C:$3e4;L:10), (C:$7d8;L:11), (C:$7ea;L:11),
    (C:$ba;L:8), (C:$7e8;L:11), (C:$3a0;L:10), (C:$1bd;L:9), (C:$1b4;L:9), (C:$38a;L:10),
    (C:$1c4;L:9), (C:$392;L:10), (C:$3aa;L:10), (C:$3b0;L:10), (C:$3bc;L:10), (C:$3d7;L:10),
    (C:$7d4;L:11), (C:$7dc;L:11), (C:$7db;L:11), (C:$7d5;L:11), (C:$7f0;L:11), (C:$c1;L:8),
    (C:$7fb;L:11), (C:$3c8;L:10), (C:$3a3;L:10), (C:$395;L:10), (C:$39d;L:10), (C:$3ac;L:10),
    (C:$3ae;L:10), (C:$3c5;L:10), (C:$3d8;L:10), (C:$3e2;L:10), (C:$3e6;L:10), (C:$7e4;L:11),
    (C:$7e7;L:11), (C:$7e0;L:11), (C:$7e9;L:11), (C:$7f7;L:11), (C:$190;L:9), (C:$7f2;L:11),
    (C:$393;L:10), (C:$1be;L:9), (C:$1c0;L:9), (C:$394;L:10), (C:$397;L:10), (C:$3ad;L:10),
    (C:$3c3;L:10), (C:$3c1;L:10), (C:$3d2;L:10), (C:$7da;L:11), (C:$7d9;L:11), (C:$7df;L:11),
    (C:$7eb;L:11), (C:$7f4;L:11), (C:$7fa;L:11), (C:$195;L:9), (C:$7f8;L:11), (C:$3bd;L:10),
    (C:$39c;L:10), (C:$3ab;L:10), (C:$3a8;L:10), (C:$3b3;L:10), (C:$3b9;L:10), (C:$3d0;L:10),
    (C:$3e3;L:10), (C:$3e5;L:10), (C:$7e2;L:11), (C:$7de;L:11), (C:$7ed;L:11), (C:$7f1;L:11),
    (C:$7f9;L:11), (C:$7fc;L:11), (C:$193;L:9), (C:$ffd;L:12), (C:$3dc;L:10), (C:$3b6;L:10),
    (C:$3c7;L:10), (C:$3cc;L:10), (C:$3cb;L:10), (C:$3d9;L:10), (C:$3da;L:10), (C:$7d3;L:11),
    (C:$7e1;L:11), (C:$7ee;L:11), (C:$7ef;L:11), (C:$7f5;L:11), (C:$7f6;L:11), (C:$ffc;L:12),
    (C:$fff;L:12), (C:$19d;L:9), (C:$1c2;L:9), (C:$b5;L:8), (C:$a1;L:8), (C:$96;L:8),
    (C:$97;L:8), (C:$95;L:8), (C:$99;L:8), (C:$a0;L:8), (C:$a2;L:8), (C:$ac;L:8),
    (C:$a9;L:8), (C:$b1;L:8), (C:$b3;L:8), (C:$bb;L:8), (C:$c0;L:8), (C:$18f;L:9),
    (C:$4;L:5)
  );
  AAC_SF: array[0..120] of TAacCode = (
    (C:$3ffe8;L:18), (C:$3ffe6;L:18), (C:$3ffe7;L:18), (C:$3ffe5;L:18), (C:$7fff5;L:19), (C:$7fff1;L:19),
    (C:$7ffed;L:19), (C:$7fff6;L:19), (C:$7ffee;L:19), (C:$7ffef;L:19), (C:$7fff0;L:19), (C:$7fffc;L:19),
    (C:$7fffd;L:19), (C:$7ffff;L:19), (C:$7fffe;L:19), (C:$7fff7;L:19), (C:$7fff8;L:19), (C:$7fffb;L:19),
    (C:$7fff9;L:19), (C:$3ffe4;L:18), (C:$7fffa;L:19), (C:$3ffe3;L:18), (C:$1ffef;L:17), (C:$1fff0;L:17),
    (C:$fff5;L:16), (C:$1ffee;L:17), (C:$fff2;L:16), (C:$fff3;L:16), (C:$fff4;L:16), (C:$fff1;L:16),
    (C:$7ff6;L:15), (C:$7ff7;L:15), (C:$3ff9;L:14), (C:$3ff5;L:14), (C:$3ff7;L:14), (C:$3ff3;L:14),
    (C:$3ff6;L:14), (C:$3ff2;L:14), (C:$1ff7;L:13), (C:$1ff5;L:13), (C:$ff9;L:12), (C:$ff7;L:12),
    (C:$ff6;L:12), (C:$7f9;L:11), (C:$ff4;L:12), (C:$7f8;L:11), (C:$3f9;L:10), (C:$3f7;L:10),
    (C:$3f5;L:10), (C:$1f8;L:9), (C:$1f7;L:9), (C:$fa;L:8), (C:$f8;L:8), (C:$f6;L:8),
    (C:$79;L:7), (C:$3a;L:6), (C:$38;L:6), (C:$1a;L:5), (C:$b;L:4), (C:$4;L:3),
    (C:$0;L:1), (C:$a;L:4), (C:$c;L:4), (C:$1b;L:5), (C:$39;L:6), (C:$3b;L:6),
    (C:$78;L:7), (C:$7a;L:7), (C:$f7;L:8), (C:$f9;L:8), (C:$1f6;L:9), (C:$1f9;L:9),
    (C:$3f4;L:10), (C:$3f6;L:10), (C:$3f8;L:10), (C:$7f5;L:11), (C:$7f4;L:11), (C:$7f6;L:11),
    (C:$7f7;L:11), (C:$ff5;L:12), (C:$ff8;L:12), (C:$1ff4;L:13), (C:$1ff6;L:13), (C:$1ff8;L:13),
    (C:$3ff8;L:14), (C:$3ff4;L:14), (C:$fff0;L:16), (C:$7ff4;L:15), (C:$fff6;L:16), (C:$7ff5;L:15),
    (C:$3ffe2;L:18), (C:$7ffd9;L:19), (C:$7ffda;L:19), (C:$7ffdb;L:19), (C:$7ffdc;L:19), (C:$7ffdd;L:19),
    (C:$7ffde;L:19), (C:$7ffd8;L:19), (C:$7ffd2;L:19), (C:$7ffd3;L:19), (C:$7ffd4;L:19), (C:$7ffd5;L:19),
    (C:$7ffd6;L:19), (C:$7fff2;L:19), (C:$7ffdf;L:19), (C:$7ffe7;L:19), (C:$7ffe8;L:19), (C:$7ffe9;L:19),
    (C:$7ffea;L:19), (C:$7ffeb;L:19), (C:$7ffe6;L:19), (C:$7ffe0;L:19), (C:$7ffe1;L:19), (C:$7ffe2;L:19),
    (C:$7ffe3;L:19), (C:$7ffe4;L:19), (C:$7ffe5;L:19), (C:$7ffd7;L:19), (C:$7ffec;L:19), (C:$7fff4;L:19),
    (C:$7fff3;L:19)
  );

  NumSwbLong: array[0..12] of Integer = (41, 41, 47, 49, 49, 51, 47, 47, 43, 43, 43, 40, 40);
  NumSwbShort: array[0..12] of Integer = (12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15);

  SwbLong96: array[0..41] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56,
    64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240,
    276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024);
  SwbLong64: array[0..47] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56,
    64, 72, 80, 88, 100, 112, 124, 140, 156, 172, 192, 216, 240, 268,
    304, 344, 384, 424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824,
    864, 904, 944, 984, 1024);
  SwbLong48: array[0..49] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72,
    80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292,
    320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736,
    768, 800, 832, 864, 896, 928, 1024);
  SwbLong32: array[0..51] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72,
    80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292,
    320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736,
    768, 800, 832, 864, 896, 928, 960, 992, 1024);
  SwbLong24: array[0..47] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68,
    76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220,
    240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704,
    768, 832, 896, 960, 1024);
  SwbLong16: array[0..43] of Word = (0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124,
    136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344,
    368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024);
  SwbLong8: array[0..40] of Word = (0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172,
    188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448,
    476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024);

  SwbShort96: array[0..12] of Word = (0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128);
  SwbShort48: array[0..14] of Word = (0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128);
  SwbShort24: array[0..15] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128);
  SwbShort16: array[0..15] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128);
  SwbShort8: array[0..15] of Word = (0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128);

  // highest band TNS may filter: long, short windows (Main/LC)
  TnsMaxBands: array[0..12, 0..1] of Integer = ((31, 9), (31, 9), (34, 10), (40, 14), (42, 14),
    (51, 14), (46, 14), (46, 14), (42, 14), (42, 14), (42, 14), (39, 14), (39, 14));

  ONLY_LONG_SEQUENCE = 0;
  LONG_START_SEQUENCE = 1;
  EIGHT_SHORT_SEQUENCE = 2;
  LONG_STOP_SEQUENCE = 3;

  ZERO_HCB = 0;
  ESC_HCB = 11;
  NOISE_HCB = 13;
  INTENSITY_HCB2 = 14;
  INTENSITY_HCB = 15;

  ID_SCE = 0; ID_CPE = 1; ID_CCE = 2; ID_LFE = 3; ID_DSE = 4; ID_PCE = 5; ID_FIL = 6; ID_END = 7;

var
  // Huffman decoding trees: node i has children Tree[2i], Tree[2i+1];
  // a child >= 0 is an inner node, a child < 0 is the leaf -(symbol+1)
  HuffTree: array of Integer;
  HuffRoot: array[0..12] of Integer; // 1..11 spectral, 12 scale factors
  IQTable: array[0..8191] of Single;
  WinLong: array[0..1, 0..1023] of Single;  // rising halves, [sine, KBD]
  WinShort: array[0..1, 0..127] of Single;
  // FFT (sizes 512 and 64) and IMDCT twiddles
  TwPre512, TwPost512: array[0..511] of record Re, Im: Single; end;
  TwPre64, TwPost64: array[0..63] of record Re, Im: Single; end;
  FftCos512, FftSin512: array[0..255] of Single;
  FftCos64, FftSin64: array[0..31] of Single;
  BitRev512: array[0..511] of Word;
  BitRev64: array[0..63] of Word;
  TablesReady: Boolean = False;

{ ---------------------------------------------------------------------------
  Static tables }

procedure AddCodebook(Book: Integer; const Codes: array of TAacCode);
var Root, i, j, Node, Bit, Next: Integer;
begin
  Root := Length(HuffTree) div 2;
  SetLength(HuffTree, Length(HuffTree) + 2);
  HuffTree[2*Root] := 0;
  HuffTree[2*Root+1] := 0;
  HuffRoot[Book] := Root;

  for i:=0 to High(Codes) do begin
    Node := Root;
    for j:=Codes[i].L-1 downto 0 do begin
      Bit := (Codes[i].C shr j) and 1;
      if j = 0 then
        HuffTree[2*Node + Bit] := -(i + 1)
      else begin
        Next := HuffTree[2*Node + Bit];
        if Next = 0 then begin
          Next := Length(HuffTree) div 2;
          SetLength(HuffTree, Length(HuffTree) + 2);
          HuffTree[2*Next] := 0;
          HuffTree[2*Next+1] := 0;
          HuffTree[2*Node + Bit] := Next;
        end;
        Node := Next;
      end;
    end;
  end;
end;

function BesselI0(X: Double): Double;
var Sum, Term, K: Double;
begin
  Sum := 1;
  Term := 1;
  K := 1;
  repeat
    Term := Term * Sqr(X / (2 * K));
    Sum := Sum + Term;
    K := K + 1;
  until Term < 1e-12 * Sum;
  Result := Sum;
end;

procedure MakeKbd(Alpha: Double; N: Integer; Dest: PSingle);
var W: array of Double;
    i: Integer;
    Total, Acc: Double;
begin
  SetLength(W, N div 2 + 1);
  Total := 0;
  for i:=0 to N div 2 do begin
    W[i] := BesselI0(Pi * Alpha * Sqrt(Max(0, 1 - Sqr((i - N/4) / (N/4)))));
    Total := Total + W[i];
  end;
  Acc := 0;
  for i:=0 to N div 2 - 1 do begin
    Acc := Acc + W[i];
    Dest[i] := Sqrt(Acc / Total);
  end;
end;

procedure MakeFft(N: Integer; Cs, Sn: PSingle; Rev: PWord);
var i, j, Bits: Integer;
begin
  for i:=0 to N div 2 - 1 do begin
    Cs[i] := Cos(2*Pi*i/N);
    Sn[i] := -Sin(2*Pi*i/N);
  end;
  Bits := 0;
  while (1 shl Bits) < N do Inc(Bits);
  for i:=0 to N-1 do begin
    Rev[i] := 0;
    for j:=0 to Bits-1 do
      if (i shr j) and 1 <> 0 then Rev[i] := Rev[i] or (1 shl (Bits-1-j));
  end;
end;

procedure InitTables;
var i: Integer;
begin
  if TablesReady then Exit;

  SetLength(HuffTree, 0);
  AddCodebook(1, AAC_CB1);
  AddCodebook(2, AAC_CB2);
  AddCodebook(3, AAC_CB3);
  AddCodebook(4, AAC_CB4);
  AddCodebook(5, AAC_CB5);
  AddCodebook(6, AAC_CB6);
  AddCodebook(7, AAC_CB7);
  AddCodebook(8, AAC_CB8);
  AddCodebook(9, AAC_CB9);
  AddCodebook(10, AAC_CB10);
  AddCodebook(11, AAC_CB11);
  AddCodebook(12, AAC_SF);

  for i:=0 to 8191 do IQTable[i] := Power(i, 4/3);

  for i:=0 to 1023 do WinLong[0, i] := Sin(Pi/2048 * (i + 0.5));
  for i:=0 to 127 do WinShort[0, i] := Sin(Pi/256 * (i + 0.5));
  MakeKbd(4, 2048, @WinLong[1, 0]);
  MakeKbd(6, 256, @WinShort[1, 0]);

  // IMDCT via DCT-IV of size M via a complex FFT of size M/2:
  // pre-twiddle exp(-i*pi*(k+1/4)/M), post-twiddle exp(-i*pi*k/M)
  for i:=0 to 511 do begin
    TwPre512[i].Re := Cos(Pi*(i + 0.25)/1024);  TwPre512[i].Im := -Sin(Pi*(i + 0.25)/1024);
    TwPost512[i].Re := Cos(Pi*i/1024);          TwPost512[i].Im := -Sin(Pi*i/1024);
  end;
  for i:=0 to 63 do begin
    TwPre64[i].Re := Cos(Pi*(i + 0.25)/128);  TwPre64[i].Im := -Sin(Pi*(i + 0.25)/128);
    TwPost64[i].Re := Cos(Pi*i/128);          TwPost64[i].Im := -Sin(Pi*i/128);
  end;
  MakeFft(512, @FftCos512[0], @FftSin512[0], @BitRev512[0]);
  MakeFft(64, @FftCos64[0], @FftSin64[0], @BitRev64[0]);

  TablesReady := True;
end;

{ in-place complex FFT (forward, exp(-2 pi i kn/N)) }
procedure Fft(Re, Im: PSingle; N: Integer; Cs, Sn: PSingle; Rev: PWord);
var i, j, Len, Half, Step, k: Integer;
    TRe, TIm, WRe, WIm, URe, UIm: Single;
begin
  for i:=0 to N-1 do begin
    j := Rev[i];
    if j > i then begin
      TRe := Re[i]; Re[i] := Re[j]; Re[j] := TRe;
      TIm := Im[i]; Im[i] := Im[j]; Im[j] := TIm;
    end;
  end;
  Len := 2;
  while Len <= N do begin
    Half := Len div 2;
    Step := N div Len;
    i := 0;
    while i < N do begin
      for k:=0 to Half-1 do begin
        WRe := Cs[k*Step];
        WIm := Sn[k*Step];
        j := i + k + Half;
        TRe := Re[j]*WRe - Im[j]*WIm;
        TIm := Re[j]*WIm + Im[j]*WRe;
        URe := Re[i+k];
        UIm := Im[i+k];
        Re[i+k] := URe + TRe;
        Im[i+k] := UIm + TIm;
        Re[j] := URe - TRe;
        Im[j] := UIm - TIm;
      end;
      Inc(i, Len);
    end;
    Len := Len * 2;
  end;
end;

{ IMDCT: M spectral values -> 2M time samples, x[n] = 2/N sum X[k] cos(2pi/N (n+n0)(k+1/2)) }
procedure Imdct(X: PSingle; M: Integer; Dest: PSingle);
var Re, Im: array[0..511] of Single;
    Y: array[0..1023] of Single;
    k, n, H: Integer;
    a, b, c, d, Scale: Single;
begin
  H := M div 2;
  for k:=0 to H-1 do begin
    a := X[2*k];
    b := X[M-1-2*k];
    if M = 1024 then begin c := TwPre512[k].Re; d := TwPre512[k].Im; end
    else begin c := TwPre64[k].Re; d := TwPre64[k].Im; end;
    Re[k] := a*c - b*d;
    Im[k] := a*d + b*c;
  end;
  if M = 1024 then Fft(@Re[0], @Im[0], 512, @FftCos512[0], @FftSin512[0], @BitRev512[0])
  else Fft(@Re[0], @Im[0], 64, @FftCos64[0], @FftSin64[0], @BitRev64[0]);
  Scale := 1 / M; // 2/N with N = 2M
  for k:=0 to H-1 do begin
    if M = 1024 then begin c := TwPost512[k].Re; d := TwPost512[k].Im; end
    else begin c := TwPost64[k].Re; d := TwPost64[k].Im; end;
    a := Re[k]*c - Im[k]*d;
    b := Re[k]*d + Im[k]*c;
    Y[2*k] := a * Scale;
    Y[M-1-2*k] := -b * Scale;
  end;
  for n:=0 to H-1 do Dest[n] := Y[n + H];
  for n:=H to 3*H-1 do Dest[n] := -Y[3*H-1-n];
  for n:=3*H to 2*M-1 do Dest[n] := -Y[n-3*H];
end;

{ ---------------------------------------------------------------------------
  TAacDecoder }

constructor TAacDecoder.Create;
begin
  inherited Create;
  InitTables;
  FRandState := $1F2E3D4C;
  FFrameLen := 1024;
end;

destructor TAacDecoder.Destroy;
begin
  FreeSbr;
  inherited Destroy;
end;

procedure TAacDecoder.FreeSbr;
var i: Integer;
begin
  for i:=0 to 7 do FreeAndNil(FSbr[i]);
  FSbrDecided := False;
  FSbrActive := False;
  FFrameLen := 1024;
end;

function TAacDecoder.GetOutputRate: Integer;
begin
  if FSbrActive then Result := 2 * FSampleRate else Result := FSampleRate;
end;

procedure TAacDecoder.Reset;
var i: Integer;
begin
  FreeSbr;
  for i:=0 to 7 do begin
    FillChar(FState[i].Overlap, SizeOf(FState[i].Overlap), 0);
    FState[i].PrevShape := 0;
  end;
end;

procedure TAacDecoder.Configure(ObjectType, SfIndex, ChannelConfig: Integer);
begin
  if not (ObjectType in [1, 2, 4]) then
    raise EAacError.CreateFmt('Unsupported AAC object type %d', [ObjectType]);
  if (SfIndex < 0) or (SfIndex > 12) then
    raise EAacError.CreateFmt('Unsupported AAC sampling frequency index %d', [SfIndex]);
  FObjectType := ObjectType;
  FSfIndex := SfIndex;
  FSampleRate := AacSampleRates[SfIndex];
  FChannelConfig := ChannelConfig;
  FExplicitSbr := False;
  FOutChannels := 0;
  if ChannelConfig = 1 then FOutChannels := 1
  else if ChannelConfig >= 2 then FOutChannels := 2;
  FConfigured := True;
  Reset;
end;

procedure TAacDecoder.ConfigureASC(const ASC: array of Byte);
var ObjType, SfIdx, ChCfg, Rate: Integer;
    Explicit: Boolean;

  function GetObjType: Integer;
  begin
    Result := GetBits(5);
    if Result = 31 then Result := 32 + Integer(GetBits(6));
  end;

  function GetSfIdx: Integer;
  begin
    Result := GetBits(4);
    if Result = 15 then begin
      Rate := GetBits(24);
      // map an explicit rate to the nearest table entry
      Result := 0;
      while (Result < 12) and (AacSampleRates[Result] > Rate) do Inc(Result);
    end;
  end;

begin
  if Length(ASC) < 2 then raise EAacError.Create('AudioSpecificConfig too short');
  FData := @ASC[0];
  FBitLen := Length(ASC) * 8;
  FBitPos := 0;

  ObjType := GetObjType;
  SfIdx := GetSfIdx;
  ChCfg := GetBits(4);
  Explicit := (ObjType = 5) or (ObjType = 29);
  if Explicit then begin
    // explicit SBR / PS: the core follows
    GetSfIdx;                // extension sampling frequency
    ObjType := GetObjType;
  end;
  if ObjType in [1, 2, 3, 4, 6, 7] then begin
    // GASpecificConfig
    if Get1 <> 0 then raise EAacError.Create('AAC frames of 960 samples are not supported');
    if Get1 <> 0 then SkipBits(14); // core coder delay
    // extension flag and program config element are not needed
  end;
  Configure(ObjType, SfIdx, ChCfg);
  FExplicitSbr := Explicit;
end;

function TAacDecoder.Output: PSingle;
begin
  Result := @FOutput[0];
end;

procedure TAacDecoder.OutputSilence;
begin
  FNumChannels := 0;
  MixOutput;
end;

{ bit reader }

function TAacDecoder.GetBits(N: Integer): Cardinal;
var i: Integer;
begin
  if FBitPos + N > FBitLen then raise EAacError.Create('AAC frame truncated');
  Result := 0;
  for i:=1 to N do begin
    Result := (Result shl 1) or ((FData[FBitPos shr 3] shr (7 - (FBitPos and 7))) and 1);
    Inc(FBitPos);
  end;
end;

function TAacDecoder.Get1: Cardinal;
begin
  if FBitPos >= FBitLen then raise EAacError.Create('AAC frame truncated');
  Result := (FData[FBitPos shr 3] shr (7 - (FBitPos and 7))) and 1;
  Inc(FBitPos);
end;

procedure TAacDecoder.SkipBits(N: Integer);
begin
  if FBitPos + N > FBitLen then raise EAacError.Create('AAC frame truncated');
  Inc(FBitPos, N);
end;

procedure TAacDecoder.ByteAlign;
begin
  FBitPos := (FBitPos + 7) and not 7;
end;

function TAacDecoder.DecodeHuff(Tree: Integer): Integer;
var Node: Integer;
begin
  Node := HuffRoot[Tree];
  repeat
    Node := HuffTree[2*Node + Integer(Get1)];
  until Node <= 0;
  if Node = 0 then raise EAacError.Create('Invalid AAC Huffman code');
  Result := -Node - 1;
end;

{ syntax }

procedure TAacDecoder.SetupBands(var Ics: TIcs);
var i, g, w: Integer;
begin
  if Ics.WindowSequence = EIGHT_SHORT_SEQUENCE then begin
    Ics.NumWindows := 8;
    Ics.NumSwb := NumSwbShort[FSfIndex];
    for i:=0 to Ics.NumSwb do
      case FSfIndex of
        0, 1, 2: Ics.SwbOffset[i] := SwbShort96[i];
        3, 4, 5: Ics.SwbOffset[i] := SwbShort48[i];
        6, 7: Ics.SwbOffset[i] := SwbShort24[i];
        8, 9, 10: Ics.SwbOffset[i] := SwbShort16[i];
        else Ics.SwbOffset[i] := SwbShort8[i];
      end;
    // groups from scale_factor_grouping (stored in GroupLen[0] temporarily)
    g := 0;
    w := Ics.GroupLen[0];
    Ics.NumGroups := 1;
    Ics.GroupLen[0] := 1;
    for i:=6 downto 0 do
      if (w shr i) and 1 <> 0 then Inc(Ics.GroupLen[g])
      else begin
        Inc(g);
        Ics.GroupLen[g] := 1;
        Inc(Ics.NumGroups);
      end;
  end
  else begin
    Ics.NumWindows := 1;
    Ics.NumGroups := 1;
    Ics.GroupLen[0] := 1;
    Ics.NumSwb := NumSwbLong[FSfIndex];
    for i:=0 to Ics.NumSwb do
      case FSfIndex of
        0, 1: Ics.SwbOffset[i] := SwbLong96[i];
        2: Ics.SwbOffset[i] := SwbLong64[i];
        3, 4: Ics.SwbOffset[i] := SwbLong48[i];
        5: Ics.SwbOffset[i] := SwbLong32[i];
        6, 7: Ics.SwbOffset[i] := SwbLong24[i];
        8, 9, 10: Ics.SwbOffset[i] := SwbLong16[i];
        else Ics.SwbOffset[i] := SwbLong8[i];
      end;
  end;
  if Ics.MaxSfb > Ics.NumSwb then raise EAacError.Create('Invalid AAC max_sfb');
end;

procedure TAacDecoder.ReadIcsInfo(var Ics: TIcs);
begin
  Get1; // ics_reserved_bit
  Ics.WindowSequence := GetBits(2);
  Ics.WindowShape := Get1;
  if Ics.WindowSequence = EIGHT_SHORT_SEQUENCE then begin
    Ics.MaxSfb := GetBits(4);
    Ics.GroupLen[0] := GetBits(7); // scale_factor_grouping, see SetupBands
  end
  else begin
    Ics.MaxSfb := GetBits(6);
    if Get1 <> 0 then begin // predictor_data_present
      if FObjectType = 4 then raise EAacError.Create('AAC-LTP prediction is not supported')
      else raise EAacError.Create('AAC Main prediction is not supported');
    end;
  end;
  SetupBands(Ics);
end;

procedure TAacDecoder.ReadSectionData(var Ics: TIcs);
var g, k, Cb, Len, Inc_, Bits, Esc, i: Integer;
begin
  if Ics.WindowSequence = EIGHT_SHORT_SEQUENCE then Bits := 3 else Bits := 5;
  Esc := (1 shl Bits) - 1;
  for g:=0 to Ics.NumGroups-1 do begin
    k := 0;
    while k < Ics.MaxSfb do begin
      Cb := GetBits(4);
      if Cb = 12 then raise EAacError.Create('Invalid AAC codebook');
      Len := 0;
      repeat
        Inc_ := GetBits(Bits);
        Inc(Len, Inc_);
      until Inc_ <> Esc;
      if k + Len > Ics.MaxSfb then raise EAacError.Create('Invalid AAC section data');
      for i:=k to k+Len-1 do Ics.SfbCb[g, i] := Cb;
      Inc(k, Len);
    end;
    for i:=Ics.MaxSfb to 51 do Ics.SfbCb[g, i] := ZERO_HCB;
  end;
end;

procedure TAacDecoder.ReadScaleFactors(var Ics: TIcs; GlobalGain: Integer);
var g, sfb, ScaleFactor, IsPosition, NoiseEnergy: Integer;
    NoisePcm: Boolean;
begin
  ScaleFactor := GlobalGain;
  IsPosition := 0;
  NoiseEnergy := GlobalGain - 90;
  NoisePcm := True;
  for g:=0 to Ics.NumGroups-1 do
    for sfb:=0 to Ics.MaxSfb-1 do
      case Ics.SfbCb[g, sfb] of
        ZERO_HCB: Ics.Sf[g, sfb] := 0;
        INTENSITY_HCB, INTENSITY_HCB2: begin
          Inc(IsPosition, DecodeHuff(12) - 60);
          Ics.Sf[g, sfb] := IsPosition;
        end;
        NOISE_HCB: begin
          if NoisePcm then begin
            NoisePcm := False;
            Inc(NoiseEnergy, Integer(GetBits(9)) - 256);
          end
          else Inc(NoiseEnergy, DecodeHuff(12) - 60);
          Ics.Sf[g, sfb] := NoiseEnergy;
        end;
        else begin
          Inc(ScaleFactor, DecodeHuff(12) - 60);
          if (ScaleFactor < 0) or (ScaleFactor > 255) then raise EAacError.Create('Invalid AAC scale factor');
          Ics.Sf[g, sfb] := ScaleFactor;
        end;
      end;
end;

procedure TAacDecoder.ReadPulse(var Ics: TIcs);
var i: Integer;
begin
  Ics.NumPulse := GetBits(2) + 1;
  Ics.PulseStartSfb := GetBits(6);
  if Ics.PulseStartSfb >= Ics.NumSwb then raise EAacError.Create('Invalid AAC pulse data');
  for i:=0 to Ics.NumPulse-1 do begin
    Ics.PulseOffset[i] := GetBits(5);
    Ics.PulseAmp[i] := GetBits(4);
  end;
end;

procedure TAacDecoder.ReadTns(var Ics: TIcs);
var w, f, i, Bits: Integer;
    Short: Boolean;
    V: Cardinal;
begin
  Short := Ics.WindowSequence = EIGHT_SHORT_SEQUENCE;
  for w:=0 to Ics.NumWindows-1 do begin
    if Short then Ics.TnsNFilt[w] := Get1 else Ics.TnsNFilt[w] := GetBits(2);
    if Ics.TnsNFilt[w] > 0 then Ics.TnsCoefRes[w] := Get1;
    for f:=0 to Ics.TnsNFilt[w]-1 do begin
      if Short then begin
        Ics.TnsLength[w, f] := GetBits(4);
        Ics.TnsOrder[w, f] := GetBits(3);
      end
      else begin
        Ics.TnsLength[w, f] := GetBits(6);
        Ics.TnsOrder[w, f] := GetBits(5);
      end;
      if Ics.TnsOrder[w, f] > 0 then begin
        Ics.TnsDirection[w, f] := Get1;
        Ics.TnsCompress[w, f] := Get1;
        Bits := Ics.TnsCoefRes[w] + 3 - Ics.TnsCompress[w, f];
        for i:=0 to Ics.TnsOrder[w, f]-1 do begin
          V := GetBits(Bits);
          if V and (1 shl (Bits-1)) <> 0 then Ics.TnsCoef[w, f, i] := Integer(V) - (1 shl Bits)
          else Ics.TnsCoef[w, f, i] := V;
        end;
      end;
    end;
  end;
end;

procedure TAacDecoder.ReadSpectral(var Ics: TIcs);
var g, sfb, w, Win, k, Start, Width, Cb, Idx, Dim, Modulo, Off, i, V, N: Integer;
    Unsigned: Boolean;
    Vals: array[0..3] of Integer;
begin
  FillChar(Ics.Quant, SizeOf(Ics.Quant), 0);
  Win := 0;
  for g:=0 to Ics.NumGroups-1 do begin
    for sfb:=0 to Ics.MaxSfb-1 do begin
      Cb := Ics.SfbCb[g, sfb];
      if (Cb = ZERO_HCB) or (Cb >= NOISE_HCB) then Continue;
      Start := Ics.SwbOffset[sfb];
      Width := Ics.SwbOffset[sfb+1] - Start;
      if Cb <= 4 then Dim := 4 else Dim := 2;
      Unsigned := Cb in [3, 4, 7, 8, 9, 10, 11];
      case Cb of
        1, 2: begin Modulo := 3; Off := 1; end;
        3, 4: begin Modulo := 3; Off := 0; end;
        5, 6: begin Modulo := 9; Off := 4; end;
        7, 8: begin Modulo := 8; Off := 0; end;
        9, 10: begin Modulo := 13; Off := 0; end;
        else begin Modulo := 17; Off := 0; end;
      end;
      for w:=0 to Ics.GroupLen[g]-1 do begin
        k := 0;
        while k < Width do begin
          Idx := DecodeHuff(Cb);
          for i:=Dim-1 downto 0 do begin
            Vals[i] := Idx mod Modulo - Off;
            Idx := Idx div Modulo;
          end;
          if Unsigned then
            for i:=0 to Dim-1 do
              if (Vals[i] <> 0) and (Get1 <> 0) then Vals[i] := -Vals[i];
          if Cb = ESC_HCB then
            for i:=0 to 1 do
              if Abs(Vals[i]) = 16 then begin
                N := 4;
                while Get1 <> 0 do begin
                  Inc(N);
                  if N > 12 then raise EAacError.Create('Invalid AAC escape sequence');
                end;
                V := (1 shl N) + Integer(GetBits(N));
                if Vals[i] < 0 then Vals[i] := -V else Vals[i] := V;
              end;
          for i:=0 to Dim-1 do
            Ics.Quant[(Win + w)*128*Ord(Ics.NumWindows = 8) + Start + k + i] := Vals[i];
          Inc(k, Dim);
        end;
      end;
    end;
    Inc(Win, Ics.GroupLen[g]);
  end;
end;

procedure TAacDecoder.ReadIcs(var Ics: TIcs; CommonWindow: Boolean);
var GlobalGain: Integer;
begin
  GlobalGain := GetBits(8);
  if not CommonWindow then ReadIcsInfo(Ics);
  ReadSectionData(Ics);
  ReadScaleFactors(Ics, GlobalGain);
  Ics.PulsePresent := Get1 <> 0;
  if Ics.PulsePresent then begin
    if Ics.WindowSequence = EIGHT_SHORT_SEQUENCE then raise EAacError.Create('AAC pulse data in short window');
    ReadPulse(Ics);
  end;
  Ics.TnsPresent := Get1 <> 0;
  if Ics.TnsPresent then ReadTns(Ics);
  if Get1 <> 0 then raise EAacError.Create('AAC gain control is not supported');
  ReadSpectral(Ics);
end;

{ reconstruction }

procedure TAacDecoder.Dequantize(var Ics: TIcs);
var g, sfb, w, Win, k, Base, q, i, Pos: Integer;
    Gain: Single;
begin
  if Ics.PulsePresent then begin
    Pos := Ics.SwbOffset[Ics.PulseStartSfb];
    for i:=0 to Ics.NumPulse-1 do begin
      Inc(Pos, Ics.PulseOffset[i]);
      if Pos > 1023 then Break;
      if Ics.Quant[Pos] > 0 then Inc(Ics.Quant[Pos], Ics.PulseAmp[i])
      else Dec(Ics.Quant[Pos], Ics.PulseAmp[i]);
    end;
  end;

  FillChar(Ics.Spec, SizeOf(Ics.Spec), 0);
  Win := 0;
  for g:=0 to Ics.NumGroups-1 do begin
    for w:=0 to Ics.GroupLen[g]-1 do begin
      Base := (Win + w) * 128 * Ord(Ics.NumWindows = 8);
      for sfb:=0 to Ics.MaxSfb-1 do begin
        if Ics.SfbCb[g, sfb] in [ZERO_HCB, NOISE_HCB, INTENSITY_HCB2, INTENSITY_HCB] then Continue;
        Gain := Power(2, 0.25 * (Ics.Sf[g, sfb] - 100));
        for k:=Base + Ics.SwbOffset[sfb] to Base + Ics.SwbOffset[sfb+1] - 1 do begin
          q := Ics.Quant[k];
          if q > 8191 then q := 8191 else if q < -8191 then q := -8191;
          if q >= 0 then Ics.Spec[k] := IQTable[q] * Gain
          else Ics.Spec[k] := -IQTable[-q] * Gain;
        end;
      end;
    end;
    Inc(Win, Ics.GroupLen[g]);
  end;
end;

{ perceptual noise substitution; when both channels of a pair have noise in a
  band with M/S on, the right channel uses the same noise vector (with its own
  energy) }
procedure TAacDecoder.ApplyPns(var Ics: TIcs; Partner: PIcs);
var g, sfb, w, Win, k, Base, Lo, Hi: Integer;
    Energy, Scale: Double;
    Nrg: Integer;
begin
  Win := 0;
  for g:=0 to Ics.NumGroups-1 do begin
    for sfb:=0 to Ics.MaxSfb-1 do begin
      if Ics.SfbCb[g, sfb] <> NOISE_HCB then Continue;
      for w:=0 to Ics.GroupLen[g]-1 do begin
        Base := (Win + w) * 128 * Ord(Ics.NumWindows = 8);
        Lo := Base + Ics.SwbOffset[sfb];
        Hi := Base + Ics.SwbOffset[sfb+1] - 1;
        Energy := 0;
        if (Partner <> nil) and (FMsMaskPresent > 0) and
           ((FMsMaskPresent = 2) or FMsUsed[g, sfb]) and (Partner^.SfbCb[g, sfb] = NOISE_HCB) then
          // correlated noise: the left channel's noise vector with this channel's energy
          for k:=Lo to Hi do begin
            Ics.Spec[k] := Partner^.Spec[k];
            Energy := Energy + Sqr(Double(Ics.Spec[k]));
          end
        else
          for k:=Lo to Hi do begin
            FRandState := Cardinal(QWord(FRandState) * 1664525 + 1013904223);
            Ics.Spec[k] := LongInt(FRandState);
            Energy := Energy + Sqr(Double(Ics.Spec[k]));
          end;
        if Energy > 0 then begin
          Nrg := EnsureRange(Ics.Sf[g, sfb], -120, 120);
          Scale := Power(2, 0.25 * Nrg) / Sqrt(Energy);
          for k:=Lo to Hi do Ics.Spec[k] := Ics.Spec[k] * Scale;
        end;
      end;
    end;
    Inc(Win, Ics.GroupLen[g]);
  end;
end;

procedure TAacDecoder.ApplyMsIs(var L, R: TIcs);
var g, sfb, w, Win, k, Base, Cb: Integer;
    Scale, A, B: Single;
    MsOn: Boolean;
begin
  Win := 0;
  for g:=0 to R.NumGroups-1 do begin
    for sfb:=0 to R.MaxSfb-1 do begin
      Cb := R.SfbCb[g, sfb];
      MsOn := (FMsMaskPresent = 2) or ((FMsMaskPresent = 1) and FMsUsed[g, sfb]);
      for w:=0 to R.GroupLen[g]-1 do begin
        Base := (Win + w) * 128 * Ord(R.NumWindows = 8);
        if (Cb = INTENSITY_HCB) or (Cb = INTENSITY_HCB2) then begin
          Scale := Power(0.5, 0.25 * R.Sf[g, sfb]);
          if Cb = INTENSITY_HCB2 then Scale := -Scale;
          if (FMsMaskPresent = 1) and FMsUsed[g, sfb] then Scale := -Scale;
          for k:=Base + R.SwbOffset[sfb] to Base + R.SwbOffset[sfb+1] - 1 do
            R.Spec[k] := L.Spec[k] * Scale;
        end
        else if MsOn and (L.SfbCb[g, sfb] <> NOISE_HCB) and (Cb <> NOISE_HCB) then
          for k:=Base + R.SwbOffset[sfb] to Base + R.SwbOffset[sfb+1] - 1 do begin
            A := L.Spec[k];
            B := R.Spec[k];
            L.Spec[k] := A + B;
            R.Spec[k] := A - B;
          end;
      end;
    end;
    Inc(Win, R.GroupLen[g]);
  end;
end;

procedure TAacDecoder.ApplyTns(var Ics: TIcs);
var w, f, i, m, Order, Bottom, Top, Start, Stop, Size, Inc_, MaxBands, Bits, n, Base: Integer;
    Iqfac, IqfacM: Double;
    Parcor, Lpc, Tmp: array[0..31] of Double;
    State: array[0..31] of Double;
    Y: Double;
    P: PSingle;
begin
  if not Ics.TnsPresent then Exit;
  MaxBands := TnsMaxBands[FSfIndex, Ord(Ics.NumWindows = 8)];
  for w:=0 to Ics.NumWindows-1 do begin
    Bottom := Ics.NumSwb;
    Base := w * 128 * Ord(Ics.NumWindows = 8);
    for f:=0 to Ics.TnsNFilt[w]-1 do begin
      Top := Bottom;
      Bottom := Max(Top - Ics.TnsLength[w, f], 0);
      Order := Min(Ics.TnsOrder[w, f], 20);
      if Order = 0 then Continue;
      // coefficients: inverse quantization (parcor) and step-up to LPC
      Bits := Ics.TnsCoefRes[w] + 3;
      Iqfac := ((1 shl (Bits-1)) - 0.5) / (Pi/2);
      IqfacM := ((1 shl (Bits-1)) + 0.5) / (Pi/2);
      for i:=0 to Order-1 do
        if Ics.TnsCoef[w, f, i] >= 0 then Parcor[i] := Sin(Ics.TnsCoef[w, f, i] / Iqfac)
        else Parcor[i] := Sin(Ics.TnsCoef[w, f, i] / IqfacM);
      Lpc[0] := 1;
      for m:=1 to Order do begin
        for i:=1 to m-1 do Tmp[i] := Lpc[i] + Parcor[m-1] * Lpc[m-i];
        for i:=1 to m-1 do Lpc[i] := Tmp[i];
        Lpc[m] := Parcor[m-1];
      end;
      Start := Ics.SwbOffset[Min(Min(Bottom, MaxBands), Ics.MaxSfb)];
      Stop := Ics.SwbOffset[Min(Min(Top, MaxBands), Ics.MaxSfb)];
      Size := Stop - Start;
      if Size <= 0 then Continue;
      if Ics.TnsDirection[w, f] <> 0 then begin
        Inc_ := -1;
        P := @Ics.Spec[Base + Stop - 1];
      end
      else begin
        Inc_ := 1;
        P := @Ics.Spec[Base + Start];
      end;
      // all-pole filter y[n] = x[n] - sum lpc[i] y[n-i]
      FillChar(State, SizeOf(State), 0);
      for n:=0 to Size-1 do begin
        Y := P^;
        for i:=1 to Order do Y := Y - Lpc[i] * State[i-1];
        for i:=Order-1 downto 1 do State[i] := State[i-1];
        State[0] := Y;
        P^ := Y;
        Inc(P, Inc_);
      end;
    end;
  end;
end;

procedure TAacDecoder.FilterBank(var Ics: TIcs; Ch: Integer);
var n, w, Ps, Cs: Integer;
    Short: array[0..255] of Single;
    Out_: PSingle;
begin
  Ps := FState[Ch].PrevShape;
  Cs := Ics.WindowShape;
  if Ics.WindowSequence = EIGHT_SHORT_SEQUENCE then begin
    FillChar(FBuf, SizeOf(FBuf), 0);
    for w:=0 to 7 do begin
      Imdct(@Ics.Spec[w*128], 128, @Short[0]);
      for n:=0 to 127 do begin
        if w = 0 then Short[n] := Short[n] * WinShort[Ps, n]
        else Short[n] := Short[n] * WinShort[Cs, n];
        Short[128+n] := Short[128+n] * WinShort[Cs, 127-n];
      end;
      for n:=0 to 255 do
        FBuf[448 + 128*w + n] := FBuf[448 + 128*w + n] + Short[n];
    end;
  end
  else begin
    Imdct(@Ics.Spec[0], 1024, @FBuf[0]);
    // left half
    if Ics.WindowSequence = LONG_STOP_SEQUENCE then begin
      for n:=0 to 447 do FBuf[n] := 0;
      for n:=448 to 575 do FBuf[n] := FBuf[n] * WinShort[Ps, n-448];
    end
    else
      for n:=0 to 1023 do FBuf[n] := FBuf[n] * WinLong[Ps, n];
    // right half
    if Ics.WindowSequence = LONG_START_SEQUENCE then begin
      for n:=1472 to 1599 do FBuf[n] := FBuf[n] * WinShort[Cs, 127-(n-1472)];
      for n:=1600 to 2047 do FBuf[n] := 0;
    end
    else
      for n:=0 to 1023 do FBuf[1024+n] := FBuf[1024+n] * WinLong[Cs, 1023-n];
  end;
  Out_ := @FTime[Ch, 0];
  for n:=0 to 1023 do begin
    Out_[n] := FBuf[n] + FState[Ch].Overlap[n];
    FState[Ch].Overlap[n] := FBuf[1024+n];
  end;
  FState[Ch].PrevShape := Cs;
end;

procedure TAacDecoder.SkipPce;
var Front, Side, Back, Lfe, Assoc, Cc, i, N: Integer;
begin
  GetBits(4); // element_instance_tag
  GetBits(2); // object_type
  GetBits(4); // sampling_frequency_index
  Front := GetBits(4);
  Side := GetBits(4);
  Back := GetBits(4);
  Lfe := GetBits(2);
  Assoc := GetBits(3);
  Cc := GetBits(4);
  if Get1 <> 0 then GetBits(4); // mono_mixdown
  if Get1 <> 0 then GetBits(4); // stereo_mixdown
  if Get1 <> 0 then GetBits(3); // matrix_mixdown
  for i:=1 to Front + Side + Back do GetBits(5);
  for i:=1 to Lfe + Assoc do GetBits(4);
  for i:=1 to Cc do GetBits(5);
  ByteAlign;
  N := GetBits(8);
  SkipBits(8 * N);
end;

procedure TAacDecoder.SkipCce;
begin
  raise EAacError.Create('AAC coupling channel elements are not supported');
end;

procedure TAacDecoder.MixOutput;
const C = 0.70710678;
var i, n, Len: Integer;
    L, R, Norm: Single;
    Src: array[0..7] of PSingle;
begin
  if FOutChannels = 0 then
    if FNumChannels = 1 then FOutChannels := 1 else FOutChannels := 2;
  Len := FFrameLen;
  SetLength(FOutput, FOutChannels * Len);
  if FNumChannels = 0 then begin
    FillChar(FOutput[0], Length(FOutput) * SizeOf(Single), 0);
    Exit;
  end;
  for i:=0 to FNumChannels-1 do begin
    if Len = 2048 then Src[i] := @FTimeSbr[i, 0] else Src[i] := @FTime[i, 0];
    // damaged frames must not produce NaN or infinity
    for n:=0 to Len-1 do
      if not (Abs(Src[i][n]) < 1E7) then Src[i][n] := 0;
  end;
  if FOutChannels = 1 then begin
    if FNumChannels = 1 then
      for i:=0 to Len-1 do FOutput[i] := Src[0][i] / 32768
    else
      for i:=0 to Len-1 do FOutput[i] := (Src[0][i] + Src[1][i]) / 65536;
    Exit;
  end;
  case FNumChannels of
    1: for i:=0 to Len-1 do begin
         FOutput[2*i] := Src[0][i] / 32768;
         FOutput[2*i+1] := FOutput[2*i];
       end;
    2: for i:=0 to Len-1 do begin
         FOutput[2*i] := Src[0][i] / 32768;
         FOutput[2*i+1] := Src[1][i] / 32768;
       end;
    else begin
      // C, L, R [, surround L, surround R] (channel configurations 3..7)
      n := FNumChannels;
      if n >= 5 then Norm := 1 / (1 + 2*C) else Norm := 1 / (1 + C);
      for i:=0 to Len-1 do begin
        L := Src[1][i] + C * Src[0][i];
        R := Src[2][i] + C * Src[0][i];
        if n >= 5 then begin
          L := L + C * Src[3][i];
          R := R + C * Src[4][i];
        end;
        FOutput[2*i] := L * Norm / 32768;
        FOutput[2*i+1] := R * Norm / 32768;
      end;
    end;
  end;
end;

function TAacDecoder.DecodeFrame(Data: PByte; Len: Integer): Integer;
var Id, i, g, sfb, Cnt, Esc, LastElem, PayloadEnd, ExtType, e, c: Integer;
    CommonWindow, SbrSeen, LastIsPair: Boolean;
begin
  if not FConfigured then raise EAacError.Create('AAC decoder not configured');
  FData := Data;
  FBitLen := Len * 8;
  FBitPos := 0;
  FNumChannels := 0;
  FNumElems := 0;
  LastElem := -1;
  LastIsPair := False;
  SbrSeen := False;

  while FBitPos + 3 <= FBitLen do begin
    Id := GetBits(3);
    case Id of
      ID_END: Break;
      ID_SCE, ID_LFE: begin
        GetBits(4); // element_instance_tag
        FMsMaskPresent := 0;
        ReadIcs(FIcs[0], False);
        LastElem := -1;
        if (FNumChannels < 8) and (FNumElems < 8) then begin
          Dequantize(FIcs[0]);
          ApplyPns(FIcs[0], nil);
          ApplyTns(FIcs[0]);
          FilterBank(FIcs[0], FNumChannels);
          FElemStart[FNumElems] := FNumChannels;
          FElemCount[FNumElems] := 1;
          if Id = ID_SCE then begin
            LastElem := FNumElems;
            LastIsPair := False;
          end;
          Inc(FNumElems);
          Inc(FNumChannels);
        end;
      end;
      ID_CPE: begin
        GetBits(4);
        CommonWindow := Get1 <> 0;
        FMsMaskPresent := 0;
        if CommonWindow then begin
          ReadIcsInfo(FIcs[0]);
          FMsMaskPresent := GetBits(2);
          if FMsMaskPresent = 1 then
            for g:=0 to FIcs[0].NumGroups-1 do
              for sfb:=0 to FIcs[0].MaxSfb-1 do FMsUsed[g, sfb] := Get1 <> 0;
          FIcs[1].WindowSequence := FIcs[0].WindowSequence;
          FIcs[1].WindowShape := FIcs[0].WindowShape;
          FIcs[1].MaxSfb := FIcs[0].MaxSfb;
          FIcs[1].NumWindows := FIcs[0].NumWindows;
          FIcs[1].NumGroups := FIcs[0].NumGroups;
          FIcs[1].NumSwb := FIcs[0].NumSwb;
          FIcs[1].GroupLen := FIcs[0].GroupLen;
          FIcs[1].SwbOffset := FIcs[0].SwbOffset;
        end;
        ReadIcs(FIcs[0], CommonWindow);
        ReadIcs(FIcs[1], CommonWindow);
        if FNumChannels < 7 then begin
          Dequantize(FIcs[0]);
          Dequantize(FIcs[1]);
          ApplyPns(FIcs[0], nil);
          ApplyPns(FIcs[1], @FIcs[0]);
          if CommonWindow then ApplyMsIs(FIcs[0], FIcs[1]);
          ApplyTns(FIcs[0]);
          ApplyTns(FIcs[1]);
          FilterBank(FIcs[0], FNumChannels);
          FilterBank(FIcs[1], FNumChannels + 1);
          LastElem := -1;
          if FNumElems < 8 then begin
            FElemStart[FNumElems] := FNumChannels;
            FElemCount[FNumElems] := 2;
            LastElem := FNumElems;
            LastIsPair := True;
            Inc(FNumElems);
          end;
          Inc(FNumChannels, 2);
        end
        else LastElem := -1;
      end;
      ID_CCE: SkipCce;
      ID_DSE: begin
        GetBits(4);
        i := Get1; // data_byte_align_flag
        Cnt := GetBits(8);
        if Cnt = 255 then Inc(Cnt, GetBits(8));
        if i <> 0 then ByteAlign;
        SkipBits(8 * Cnt);
      end;
      ID_PCE: SkipPce;
      ID_FIL: begin
        Cnt := GetBits(4);
        if Cnt = 15 then begin
          Esc := GetBits(8);
          Inc(Cnt, Esc - 1);
        end;
        PayloadEnd := FBitPos + 8 * Cnt;
        if PayloadEnd > FBitLen then raise EAacError.Create('AAC frame truncated');
        if Cnt > 0 then begin
          ExtType := GetBits(4);
          // SBR data of the preceding SCE/CPE (other payloads, e.g. DRC, are ignored)
          if ((ExtType = 13) or (ExtType = 14)) and (LastElem >= 0) and (FSampleRate <= 24000) then begin
            SbrSeen := True;
            if FSbr[LastElem] = nil then FSbr[LastElem] := TSbrDecoder.Create(FSampleRate);
            FSbr[LastElem].Parse(FData, FBitPos, PayloadEnd, ExtType = 14, LastIsPair);
          end;
        end;
        FBitPos := PayloadEnd;
        LastElem := -1;
      end;
    end;
  end;

  // HE-AAC: decided on the first frame (explicit signalling or SBR data present)
  if not FSbrDecided then begin
    FSbrActive := (FExplicitSbr or SbrSeen) and (FSampleRate <= 24000);
    FSbrDecided := True;
  end;
  if FSbrActive then begin
    for e:=0 to FNumElems-1 do begin
      if FSbr[e] = nil then FSbr[e] := TSbrDecoder.Create(FSampleRate);
      for c:=0 to FElemCount[e]-1 do
        FSbr[e].Process(c, @FTime[FElemStart[e] + c, 0], @FTimeSbr[FElemStart[e] + c, 0]);
      FSbr[e].FrameDone(FElemCount[e]);
    end;
    FFrameLen := 2048;
  end
  else FFrameLen := 1024;

  MixOutput;
  Result := FFrameLen;
end;

end.
