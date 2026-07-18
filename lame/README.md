# Usage

Usage: wav2mp3 input.wav output.mp3 BITRATE

# Usage in code

  uses LameSimple;

  function WAVToPCM(const WavBytes: TBytes; out Info: TPCMInfo): TPCMSamples;
  
  function PCMToMP3(const Samples: TPCMSamples; const Info: TPCMInfo; BitrateKbps: Integer): TBytes;
  
