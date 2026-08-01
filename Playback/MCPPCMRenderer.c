#include "MCPPCMRenderer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct MCPPCMRenderer {
    float *samples;
    uint64_t frameCapacity;
    uint32_t channelCount;
    _Atomic uint64_t readCursor;
    _Atomic uint64_t writeCursor;
    _Atomic uint64_t currentFrame;
    _Atomic bool isPlaying;
    _Atomic bool reachedEndOfStream;
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
    atomic_init(&renderer->readCursor, 0);
    atomic_init(&renderer->writeCursor, 0);
    atomic_init(&renderer->currentFrame, 0);
    atomic_init(&renderer->isPlaying, false);
    atomic_init(&renderer->reachedEndOfStream, false);
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

uint32_t MCPPCMRendererWritableFrames(const MCPPCMRenderer *renderer) {
    if (renderer == NULL) {
        return 0;
    }

    uint64_t readCursor = atomic_load_explicit(
        &renderer->readCursor,
        memory_order_acquire
    );
    uint64_t writeCursor = atomic_load_explicit(
        &renderer->writeCursor,
        memory_order_acquire
    );
    uint64_t bufferedFrames = writeCursor - readCursor;
    return bufferedFrames < renderer->frameCapacity
        ? (uint32_t)(renderer->frameCapacity - bufferedFrames)
        : 0;
}

uint32_t MCPPCMRendererWrite(
    MCPPCMRenderer *renderer,
    const float *samples,
    uint32_t frameCount
) {
    if (renderer == NULL || samples == NULL || frameCount == 0) {
        return 0;
    }

    uint32_t writableFrames = MCPPCMRendererWritableFrames(renderer);
    uint32_t framesToWrite = frameCount < writableFrames
        ? frameCount
        : writableFrames;
    if (framesToWrite == 0) {
        return 0;
    }

    uint64_t writeCursor = atomic_load_explicit(
        &renderer->writeCursor,
        memory_order_relaxed
    );
    uint64_t writeOffset = writeCursor % renderer->frameCapacity;
    uint32_t firstFrames = framesToWrite;
    uint64_t framesBeforeWrap = renderer->frameCapacity - writeOffset;
    if (framesBeforeWrap < firstFrames) {
        firstFrames = (uint32_t)framesBeforeWrap;
    }

    size_t bytesPerFrame = renderer->channelCount * sizeof(float);
    memcpy(
        renderer->samples + writeOffset * renderer->channelCount,
        samples,
        (size_t)firstFrames * bytesPerFrame
    );

    uint32_t secondFrames = framesToWrite - firstFrames;
    if (secondFrames > 0) {
        memcpy(
            renderer->samples,
            samples + (size_t)firstFrames * renderer->channelCount,
            (size_t)secondFrames * bytesPerFrame
        );
    }

    atomic_store_explicit(
        &renderer->writeCursor,
        writeCursor + framesToWrite,
        memory_order_release
    );
    return framesToWrite;
}

void MCPPCMRendererMarkEndOfStream(MCPPCMRenderer *renderer) {
    if (renderer == NULL) {
        return;
    }
    atomic_store_explicit(
        &renderer->reachedEndOfStream,
        true,
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

void MCPPCMRendererReset(
    MCPPCMRenderer *renderer,
    uint64_t frame
) {
    if (renderer == NULL) {
        return;
    }

    atomic_store_explicit(&renderer->readCursor, 0, memory_order_release);
    atomic_store_explicit(&renderer->writeCursor, 0, memory_order_release);
    atomic_store_explicit(
        &renderer->currentFrame,
        frame,
        memory_order_release
    );
    atomic_store_explicit(
        &renderer->reachedEndOfStream,
        false,
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

    uint64_t readCursor = atomic_load_explicit(
        &renderer->readCursor,
        memory_order_relaxed
    );
    uint64_t writeCursor = atomic_load_explicit(
        &renderer->writeCursor,
        memory_order_acquire
    );
    uint64_t bufferedFrames = writeCursor - readCursor;
    UInt32 framesToCopy = bufferedFrames < inNumberFrames
        ? (UInt32)bufferedFrames
        : inNumberFrames;

    AudioBuffer *output = &ioData->mBuffers[0];
    size_t bytesPerFrame = renderer->channelCount * sizeof(float);
    size_t bytesToCopy = framesToCopy * bytesPerFrame;
    size_t requestedBytes = inNumberFrames * bytesPerFrame;

    if (output->mData == NULL || output->mDataByteSize < requestedBytes) {
        return kAudio_ParamError;
    }

    uint64_t readOffset = readCursor % renderer->frameCapacity;
    UInt32 firstFrames = framesToCopy;
    uint64_t framesBeforeWrap = renderer->frameCapacity - readOffset;
    if (framesBeforeWrap < firstFrames) {
        firstFrames = (UInt32)framesBeforeWrap;
    }
    memcpy(output->mData,
           renderer->samples + readOffset * renderer->channelCount,
           (size_t)firstFrames * bytesPerFrame);

    UInt32 secondFrames = framesToCopy - firstFrames;
    if (secondFrames > 0) {
        memcpy((uint8_t *)output->mData + (size_t)firstFrames * bytesPerFrame,
               renderer->samples,
               (size_t)secondFrames * bytesPerFrame);
    }
    memset((uint8_t *)output->mData + bytesToCopy, 0, requestedBytes - bytesToCopy);
    atomic_store_explicit(
        &renderer->readCursor,
        readCursor + framesToCopy,
        memory_order_release
    );
    uint64_t currentFrame = atomic_load_explicit(
        &renderer->currentFrame,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &renderer->currentFrame,
        currentFrame + framesToCopy,
        memory_order_release
    );

    bool reachedEndOfStream = atomic_load_explicit(
        &renderer->reachedEndOfStream,
        memory_order_acquire
    );
    if (reachedEndOfStream && framesToCopy < inNumberFrames) {
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
