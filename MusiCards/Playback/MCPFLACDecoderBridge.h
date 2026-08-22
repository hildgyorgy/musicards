#ifndef MCPFLACDecoderBridge_h
#define MCPFLACDecoderBridge_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct MCPFLACDecoder MCPFLACDecoder;

typedef int (*MCPFLACReadCallback)(
    void *context,
    uint8_t *buffer,
    size_t *byteCount
);
typedef int (*MCPFLACSeekCallback)(void *context, uint64_t offset);
typedef int (*MCPFLACTellCallback)(
    void *context,
    uint64_t *offset
);
typedef int (*MCPFLACLengthCallback)(
    void *context,
    uint64_t *length
);
typedef bool (*MCPFLACEofCallback)(void *context);
typedef void (*MCPFLACMetadataCallback)(
    void *context,
    uint32_t sampleRate,
    uint32_t channels,
    uint32_t bitsPerSample,
    uint64_t totalSamples
);
typedef int (*MCPFLACWriteCallback)(
    void *context,
    uint32_t frameCount,
    uint32_t channels,
    uint32_t bitsPerSample,
    const int32_t *interleavedSamples
);
typedef void (*MCPFLACErrorCallback)(void *context, int status);

MCPFLACDecoder *MCPFLACDecoderCreate(void);

int MCPFLACDecoderInitialize(
    MCPFLACDecoder *decoder,
    MCPFLACReadCallback readCallback,
    MCPFLACSeekCallback seekCallback,
    MCPFLACTellCallback tellCallback,
    MCPFLACLengthCallback lengthCallback,
    MCPFLACEofCallback eofCallback,
    MCPFLACWriteCallback writeCallback,
    MCPFLACMetadataCallback metadataCallback,
    MCPFLACErrorCallback errorCallback,
    void *context
);

bool MCPFLACDecoderProcessMetadata(MCPFLACDecoder *decoder);
bool MCPFLACDecoderProcessSingle(MCPFLACDecoder *decoder);
bool MCPFLACDecoderSeekAbsolute(
    MCPFLACDecoder *decoder,
    uint64_t frame
);
bool MCPFLACDecoderHasEnded(const MCPFLACDecoder *decoder);
void MCPFLACDecoderDestroy(MCPFLACDecoder *decoder);

#endif
