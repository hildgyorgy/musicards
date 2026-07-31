#include "MCPPCMRenderer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct MCPPCMRenderer {
    float *samples;
    uint64_t frameCapacity;
    uint32_t channelCount;
    _Atomic uint64_t frameCount;
    _Atomic uint64_t currentFrame;
    _Atomic bool isPlaying;
    _Atomic bool didFinish;
};

MCPPCMRenderer *MCPPCMRendererCreate(
    uint64_t frameCapacity,
    uint32_t channelCount
) {
    if (frameCapacity == 0 || channelCount == 0) {
        return NULL;
    }

    MCPPCMRenderer *renderer = calloc(1, sizeof(MCPPCMRenderer));
    if (renderer == NULL) {
        return NULL;
    }

    if (frameCapacity > SIZE_MAX / channelCount / sizeof(float)) {
        free(renderer);
        return NULL;
    }

    renderer->samples = calloc(
        (size_t)(frameCapacity * channelCount),
        sizeof(float)
    );

    if (renderer->samples == NULL) {
        free(renderer);
        return NULL;
    }

    renderer->frameCapacity = frameCapacity;
    renderer->channelCount = channelCount;
    atomic_init(&renderer->frameCount, 0);
    atomic_init(&renderer->currentFrame, 0);
    atomic_init(&renderer->isPlaying, false);
    atomic_init(&renderer->didFinish, false);
    return renderer;
}

void MCPPCMRendererDestroy(MCPPCMRenderer *renderer) {
    if (renderer == NULL) {
        return;
    }

    free(renderer->samples);
    free(renderer);
}

float *MCPPCMRendererMutableSamples(MCPPCMRenderer *renderer) {
    return renderer == NULL ? NULL : renderer->samples;
}

void MCPPCMRendererSetFrameCount(
    MCPPCMRenderer *renderer,
    uint64_t frameCount
) {
    if (renderer == NULL) {
        return;
    }

    uint64_t boundedFrameCount = frameCount < renderer->frameCapacity
        ? frameCount
        : renderer->frameCapacity;
    atomic_store_explicit(
        &renderer->frameCount,
        boundedFrameCount,
        memory_order_release
    );
}

void MCPPCMRendererSetPlaying(
    MCPPCMRenderer *renderer,
    bool isPlaying
) {
    if (renderer == NULL) {
        return;
    }

    atomic_store_explicit(
        &renderer->isPlaying,
        isPlaying,
        memory_order_release
    );

    if (isPlaying) {
        atomic_store_explicit(
            &renderer->didFinish,
            false,
            memory_order_release
        );
    }
}

void MCPPCMRendererSeek(
    MCPPCMRenderer *renderer,
    uint64_t frame
) {
    if (renderer == NULL) {
        return;
    }

    uint64_t frameCount = atomic_load_explicit(
        &renderer->frameCount,
        memory_order_acquire
    );
    uint64_t boundedFrame = frame < frameCount ? frame : frameCount;
    atomic_store_explicit(
        &renderer->currentFrame,
        boundedFrame,
        memory_order_release
    );
    atomic_store_explicit(
        &renderer->didFinish,
        false,
        memory_order_release
    );
}

uint64_t MCPPCMRendererCurrentFrame(const MCPPCMRenderer *renderer) {
    return renderer == NULL
        ? 0
        : atomic_load_explicit(
            &renderer->currentFrame,
            memory_order_acquire
        );
}

uint64_t MCPPCMRendererFrameCount(const MCPPCMRenderer *renderer) {
    return renderer == NULL
        ? 0
        : atomic_load_explicit(
            &renderer->frameCount,
            memory_order_acquire
        );
}

bool MCPPCMRendererDidFinish(const MCPPCMRenderer *renderer) {
    return renderer != NULL
        && atomic_load_explicit(
            &renderer->didFinish,
            memory_order_acquire
        );
}

static void MCPZeroOutput(AudioBufferList *ioData) {
    for (UInt32 index = 0; index < ioData->mNumberBuffers; index++) {
        AudioBuffer *buffer = &ioData->mBuffers[index];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

OSStatus MCPPCMRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    (void)inTimeStamp;
    (void)inBusNumber;

    MCPPCMRenderer *renderer = inRefCon;
    if (renderer == NULL || ioData == NULL || ioData->mNumberBuffers != 1) {
        return kAudio_ParamError;
    }

    bool isPlaying = atomic_load_explicit(
        &renderer->isPlaying,
        memory_order_acquire
    );

    if (!isPlaying) {
        MCPZeroOutput(ioData);
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    uint64_t currentFrame = atomic_load_explicit(
        &renderer->currentFrame,
        memory_order_relaxed
    );
    uint64_t frameCount = atomic_load_explicit(
        &renderer->frameCount,
        memory_order_acquire
    );
    uint64_t remainingFrames = currentFrame < frameCount
        ? frameCount - currentFrame
        : 0;
    UInt32 framesToCopy = remainingFrames < inNumberFrames
        ? (UInt32)remainingFrames
        : inNumberFrames;

    AudioBuffer *output = &ioData->mBuffers[0];
    size_t bytesPerFrame = renderer->channelCount * sizeof(float);
    size_t bytesToCopy = framesToCopy * bytesPerFrame;
    size_t requestedBytes = inNumberFrames * bytesPerFrame;

    if (output->mData == NULL || output->mDataByteSize < requestedBytes) {
        return kAudio_ParamError;
    }

    memcpy(
        output->mData,
        renderer->samples + currentFrame * renderer->channelCount,
        bytesToCopy
    );
    memset((uint8_t *)output->mData + bytesToCopy, 0, requestedBytes - bytesToCopy);
    atomic_store_explicit(
        &renderer->currentFrame,
        currentFrame + framesToCopy,
        memory_order_release
    );

    if (framesToCopy < inNumberFrames) {
        atomic_store_explicit(
            &renderer->isPlaying,
            false,
            memory_order_release
        );
        atomic_store_explicit(
            &renderer->didFinish,
            true,
            memory_order_release
        );
    }

    return noErr;
}

