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
