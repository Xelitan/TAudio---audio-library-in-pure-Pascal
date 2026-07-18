# TAudio - audio library in pure Pascal

Requires no DLLs or external programs. Reads MP3, WAV, AU, OGG, AIFF, CAF, FLAC, XM, MOD, IT, S3M. Writes WAV, MP3, AU, AIFF, FLAC.

## How to start?
Install package and add to uses:
```
XelAudio
```

## Converting file

```
  if not OpenDialog1.Execute then Exit;

  a := TAudio.Create;
  a.LoadFromFile(OpenDialog1.Filename);
  a.SaveToFile('output.wav');
  a.Free;
```

## Other functions
Methods of TAudio:
```
    function FindPeak: Integer;
    procedure Cut(FromTime, ToTime: Integer);
    procedure FadeOut(Durationn: Integer);
    procedure Waveform(Bmp: TBitmap);
    procedure Play;
    procedure Stop;
    procedure Normalize;
    procedure SetSampleRate(Rate: Cardinal);
```
