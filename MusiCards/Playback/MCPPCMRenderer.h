#ifndef MCPPCMRenderer_h
#define MCPPCMRenderer_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct MCPPCMRenderer MCPPCMRenderer;

typedef struct {
    float left;
    float right;
} MCPPCMSignalLevels;

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

MCPPCMRenderer * _Nullable MCPPCMRendererCreate(
    uint64_t frameCapacity,
    uint32_t channelCount
);

void MCPPCMRendererDestroy(MCPPCMRenderer *renderer);

uint32_t MCPPCMRendererWritableFrames(const MCPPCMRenderer *renderer);

uint32_t MCPPCMRendererWrite(
    MCPPCMRenderer *renderer,
    const float *samples,
    uint32_t frameCount
);

void MCPPCMRendererMarkEndOfStream(MCPPCMRenderer *renderer);

void MCPPCMRendererSetPlaying(
    MCPPCMRenderer *renderer,
    bool isPlaying
);

void MCPPCMRendererReset(
    MCPPCMRenderer *renderer,
    uint64_t frame
);

uint64_t MCPPCMRendererCurrentFrame(const MCPPCMRenderer *renderer);
uint64_t MCPPCMRendererUnderrunCount(const MCPPCMRenderer *renderer);
bool MCPPCMRendererDidFinish(const MCPPCMRenderer *renderer);
// RMS of the last rendered block, before system/DAC volume. Mono is mirrored.
MCPPCMSignalLevels MCPPCMRendererSignalLevels(const MCPPCMRenderer *renderer);

OSStatus MCPPCMRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList * _Nullable ioData
);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#endif
