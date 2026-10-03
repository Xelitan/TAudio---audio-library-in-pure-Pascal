unit XelAudio;

interface

uses
  xAudio, mp3, vorbis, xAIFF, xAU, xAudioBase, xCAF, xFlac, xFunctions,
  xMP3, xOgg, xStreams, xTracker, xWav, xPlayback, xAAC, xM4A, xSBR, xAC3, xDemux, xMKV, xAVI,
  LameBitstream, LameCore, LameEncoder, 
  LameFFT, LameMDCT, LamePsyModel, LameQuantize, LameQuantizePvt, 
  LameReservoir, LameSimple, LameTables, LameTakehiro, LameTypes, LameUtils, 
  LameVbrTag;

type TXelAudio = class(xAudio.TXelAudio)
     end;

implementation

end.
