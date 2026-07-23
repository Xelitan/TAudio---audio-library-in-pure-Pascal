# TXelAudio - audio library in pure Pascal

Requires no DLLs or external programs. Reads MP3, WAV, AU, OGG, AIFF, CAF, FLAC, XM, MOD, IT, S3M. Writes WAV, MP3, AU, AIFF, FLAC.

## How to start?
Install package and add to uses:
```
XelAudio
```

## Converting file

```
  if not OpenDialog1.Execute then Exit;

  a := TXelAudio.Create;
  a.LoadFromFile(OpenDialog1.Filename);
  a.SaveToFile('output.wav');
  a.SaveToFile('output.mp3', 128); //second paramater is bitrate in kbit/s. From 112 to 320 in case of mp3
  a.Free;
```

## Drawing a waveform
```
  a := TXelAudio.Create;
  try
    a.LoadFromFile('test.flac');
    bmp := TBitmap.Create;
    try
      bmp.SetSize(Image1.Width, Image1.Height);
      a.WaveForm(bmp);
      Image1.Picture.Bitmap.Assign(bmp);
    finally
      bmp.Free;
    end;
  finally
    a.Free;
  end; 
```

## Other functions
Methods of TXelAudio:
```
    function FindPeak: Integer;
    procedure Cut(FromTime, ToTime: Extended); //time in seconds
    procedure FadeOut(Durationn: Extended); //time in seconds
    procedure Waveform(Bmp: TBitmap); //draws a waveform that fits the bitmap
    procedure Play;
    procedure Stop;
    procedure Normalize;
    procedure SetSampleRate(Rate: Cardinal);
```
