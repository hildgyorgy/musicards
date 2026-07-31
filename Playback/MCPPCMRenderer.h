#ifndef MCPPCMRenderer_h
#define MCPPCMRenderer_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct MCPPCMRenderer MCPPCMRenderer;

MCPPCMRenderer *MCPPCMRendererCreate(
    uint64_t frameCapacity,
    uint32_t channelCount
);

void MCPPCMRendererDestroy(MCPPCMRenderer *renderer);

float *MCPPCMRendererMutableSamples(MCPPCMRenderer *renderer);

void MCPPCMRendererSetFrameCount(
    MCPPCMRenderer *renderer,
    uint64_t frameCount
);

void MCPPCMRendererSetPlaying(
    MCPPCMRenderer *renderer,
    bool isPlaying
);

void MCPPCMRendererSeek(
    MCPPCMRenderer *renderer,
    uint64_t frame
);

uint64_t MCPPCMRendererCurrentFrame(const MCPPCMRenderer *renderer);
uint64_t MCPPCMRendererFrameCount(const MCPPCMRenderer *renderer);
bool MCPPCMRendererDidFinish(const MCPPCMRenderer *renderer);

OSStatus MCPPCMRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
);

#endif

