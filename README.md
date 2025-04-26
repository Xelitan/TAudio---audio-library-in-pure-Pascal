# TAudio - audio library in pure Pascal

Requires no DLLs or external programs. Decodes MP3, WAV, AU, OGG, AIFF.

## How to start?
Add to uses:
```
xAudio, xAIFF, xMP3, xOGG, xAU, xWav
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
