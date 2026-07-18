{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
program wav2mp3;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//
// Usage:
//   wav2mp3 input.wav output.mp3 [bitrate]
//
// Notes:
//   * WAVToPCM strips the RIFF/WAVE header and returns normalized signed
//     16-bit interleaved PCM samples plus metadata.
//   * The original WAV may be 8-bit or 16-bit PCM. 8-bit unsigned PCM is
//     converted to signed 16-bit samples because LAME encodes 16-bit PCM.
//   * PCMToMP3 accepts the PCM samples, metadata, and a CBR bitrate in kbps.

uses
  SysUtils, Classes, LameSimple;

function LoadBytesFromFile(const FileName: string): TBytes;
var
  S: TFileStream;
begin
  S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, S.Size);
    if S.Size > 0 then
      S.ReadBuffer(Result[0], S.Size);
  finally
    S.Free;
  end;
end;

procedure SaveBytesToFile(const FileName: string; const Bytes: TBytes);
var
  S: TFileStream;
begin
  S := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Bytes) > 0 then
      S.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    S.Free;
  end;
end;

var
  WavBytes, Mp3Bytes: TBytes;
  Pcm: TPCMSamples;
  Info: TPCMInfo;
  Bitrate: Integer;
begin
  if not (ParamCount in [2, 3]) then
  begin
    WriteLn('Usage: wav2mp3 input.wav output.mp3 [bitrate-kbps]');
    WriteLn('Example: wav2mp3 input.wav output.mp3 128');
    Halt(1);
  end;

  Bitrate := 256;
  if ParamCount = 3 then
    Bitrate := StrToInt(ParamStr(3));

  try
    WavBytes := LoadBytesFromFile(ParamStr(1));
    Pcm := WAVToPCM(WavBytes, Info); //TODO: extend to handle more WAV formats

    Mp3Bytes := PCMToMP3(Pcm, Info, Bitrate);
    SaveBytesToFile(ParamStr(2), Mp3Bytes);

    WriteLn('MP3 saved: ', Length(Mp3Bytes), ' bytes, ', Bitrate, ' kbps CBR -> ', ParamStr(2));
  except
    on E: Exception do
    begin
      WriteLn('Error: ', E.Message);
      Halt(1);
    end;
  end;
end.
